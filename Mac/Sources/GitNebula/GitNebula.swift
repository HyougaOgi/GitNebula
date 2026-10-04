import SwiftUI
import AppKit
import Foundation

struct Change: Identifiable, Sendable {
    var id: String { path }
    let code: String
    let path: String
    let original: String?
}

struct GitRepository: Sendable {
    let path: String
    func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        // File-backed output avoids a full pipe blocking the child on large diffs.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout")
        let error = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: error)
        defer { try? stdout.close(); try? stderr.close() }
        process.standardOutput = stdout; process.standardError = stderr
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitNebula", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: try Data(contentsOf: error), as: UTF8.self)])
        }
        return String(decoding: try Data(contentsOf: output), as: UTF8.self)
    }
    func changes() throws -> [Change] {
        let entries = try run(["status", "--porcelain=v1", "-z"]).split(separator: "\0", omittingEmptySubsequences: false)
        var result: [Change] = []; var index = 0
        while index < entries.count {
            let entry = String(entries[index]); index += 1
            guard entry.count >= 3 else { continue }
            let code = String(entry.prefix(2))
            let original = (code.contains("R") || code.contains("C")) && index < entries.count ? String(entries[index]) : nil
            result.append(Change(code: code, path: String(entry.dropFirst(3)), original: original))
            if code.contains("R") || code.contains("C") { index += 1 }
        }
        return result
    }
    func diff(_ file: String) throws -> String {
        guard try changes().contains(where: { $0.path == file }) else { throw failure("変更一覧にないファイルです") }
        if (try? run(["rev-parse", "--verify", "HEAD"])) == nil {
            return "初回コミット前のファイルです。"
        }
        let text = try run(["--literal-pathspecs", "diff", "HEAD", "--", file])
        return text.isEmpty ? "未追跡ファイル、またはテキスト差分のない変更です。" : text
    }
    func commit(_ files: [String], _ message: String) throws {
        let changes = try changes()
        let available = Set(changes.map(\.path))
        guard !files.isEmpty, files.allSatisfy(available.contains), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("変更ファイルとメッセージを指定してください") }
        let originals = changes.filter { files.contains($0.path) && $0.code.contains("R") }.compactMap(\.original)
        for original in originals where !files.contains(original) {
            if try entryExists(original) {
                throw failure("リネーム元に未選択のファイルがあります: \(original)。そのファイルも含める場合は選択してください。含めない場合は元の場所から移して再実行してください。")
            }
        }
        let deleted = Set(changes.filter { $0.code.hasPrefix("D") }.map(\.path))
        let toStage = try files.filter {
            if !deleted.contains($0) { return true }
            return try entryExists($0)
        }
        let paths = Array(Set(files + originals)).sorted()
        if !toStage.isEmpty { _ = try run(["--literal-pathspecs", "add", "--"] + toStage) }
        _ = try run(["--literal-pathspecs", "commit", "--only", "-m", message, "--"] + paths)
    }
    func entryExists(_ file: String) throws -> Bool {
        let fullPath = URL(fileURLWithPath: path).appendingPathComponent(file).path
        do {
            // lstat-style attributes include dangling symlinks.
            _ = try FileManager.default.attributesOfItem(atPath: fullPath)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
    func failure(_ message: String) -> NSError { NSError(domain: "GitNebula", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var repository: GitRepository?
    @Published var changes: [Change] = []
    @Published var selected = Set<String>()
    @Published var branch = "未接続"
    @Published var diff = "ファイルを選択すると差分を表示します。"
    @Published var message = ""
    @Published var status = "準備完了"
    @Published var busy = false
    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T, apply: @escaping (T) -> Void) {
        guard !busy else { return }; busy = true; status = "処理中…"
        Task {
            do { let result = try await Task.detached(priority: .userInitiated) { try work() }.value; apply(result); status = "準備完了" }
            catch { status = error.localizedDescription }
            busy = false
        }
    }
    func refresh(_ repo: GitRepository) {
        perform({ (try repo.changes(), (try? repo.run(["symbolic-ref", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "detached HEAD") }) { result in
            self.repository = repo; self.changes = result.0; self.branch = result.1; self.selected.removeAll(); self.diff = "ファイルを選択すると差分を表示します。"
        }
    }
    func open() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            let candidate = GitRepository(path: url.path)
            perform({ GitRepository(path: try candidate.run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)) }) { repo in
                self.repository = repo
                // Schedule after the current operation has released its busy state.
                DispatchQueue.main.async { self.refresh(repo) }
            }
        }
    }
    func commit() {
        guard let repo = repository else { return }
        let paths = Array(selected), text = message
        perform({ try repo.commit(paths, text); return try repo.changes() }) { changes in
            self.changes = changes; self.selected.removeAll(); self.message = ""; self.diff = "コミットしました。"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Workspace()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) { Text("✧ GitNebula").font(.largeTitle.bold()).foregroundStyle(Color(red: 0.70, green: 0.62, blue: 1)); Text("YOUR CODE, IN ORBIT").font(.caption).tracking(3).foregroundStyle(.secondary) }
                Spacer(); Button("リポジトリを開く", action: model.open)
                Button("更新") { if let repo = model.repository { model.refresh(repo) } }.disabled(model.repository == nil)
            }
            Text("\(model.repository?.path ?? "コードの軌跡を、ひとつの星図に。")  ·  \(model.branch)").font(.caption).textSelection(.enabled)
            HSplitView {
                List(model.changes) { change in
                    HStack {
                        Toggle("", isOn: Binding(get: { model.selected.contains(change.path) }, set: { if $0 { model.selected.insert(change.path) } else { model.selected.remove(change.path) } })).labelsHidden()
                        Button("\(change.code)  \(change.path)") {
                            if let repo = model.repository { model.perform({ try repo.diff(change.path) }) { model.diff = $0 } }
                        }.buttonStyle(.plain)
                    }
                }.frame(minWidth: 300)
                ScrollView([.horizontal, .vertical]) { Text(model.diff).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding() }.frame(minWidth: 400)
            }
            TextField("コミットメッセージ", text: $model.message).textFieldStyle(.roundedBorder)
            Button("✧ 選択した変更をコミット", action: model.commit).disabled(model.selected.isEmpty || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(model.status).font(.caption).textSelection(.enabled)
        }.padding(24).frame(minWidth: 900, minHeight: 650).background(Color(red: 0.035, green: 0.05, blue: 0.11)).disabled(model.busy).preferredColorScheme(.dark)
    }
}

@main
struct GitNebulaApp: App {
    var body: some Scene { WindowGroup { ContentView() }.windowStyle(.titleBar) }
}
