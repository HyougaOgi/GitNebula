import SwiftUI
import AppKit
import Foundation

struct Snapshot: Sendable {
    let repo: GitRepository
    let changes: [Change]
    let branch: String
    let graph: String
    let branches: [String]
    let remotes: [String]
    let conflicts: [String]
    init(_ repo: GitRepository) throws {
        self.repo = repo; changes = try repo.changes()
        branch = (try? repo.run(["symbolic-ref", "--short", "HEAD"]))?.trimmingCharacters(in: .newlines) ?? "detached HEAD"
        graph = try repo.graph(); branches = try repo.branches(); remotes = try repo.remotes(); conflicts = try repo.conflicts()
    }
}

@MainActor
final class Workspace: ObservableObject {
    @Published var repository: GitRepository?
    @Published var changes: [Change] = []
    @Published var selected = Set<String>()
    @Published var branch = "未接続"
    @Published var graph = ""
    @Published var branches: [String] = []
    @Published var remotes: [String] = []
    @Published var conflicts: [String] = []
    @Published var chosenBranch = ""
    @Published var chosenRemote = ""
    @Published var chosenConflict = ""
    @Published var diff = "ファイルを選択すると差分を表示します。"
    @Published var message = ""
    @Published var status = "準備完了"
    @Published var busy = false
    func apply(_ state: Snapshot) {
        repository = state.repo; changes = state.changes; branch = state.branch; graph = state.graph
        branches = state.branches; remotes = state.remotes; conflicts = state.conflicts
        chosenBranch = branches.contains(branch) ? branch : branches.first ?? ""
        if !remotes.contains(chosenRemote) { chosenRemote = remotes.first ?? "" }
        if !conflicts.contains(chosenConflict) { chosenConflict = conflicts.first ?? "" }
        selected.removeAll(); diff = "ファイルを選択すると差分を表示します。"
    }
    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T, apply: @escaping (T) -> Void) {
        guard !busy else { return }; busy = true; status = "処理中…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try work() }.value
                apply(result); status = "準備完了"
            } catch {
                let message = error.localizedDescription
                // Merge failures may leave conflicts that must immediately appear in the UI.
                if let repo = repository, let state = try? await Task.detached(operation: { try Snapshot(repo) }).value { self.apply(state) }
                status = message
            }
            busy = false
        }
    }
    func openPath(_ path: String) { perform({ try Snapshot(GitRepository.open(path)) }, apply: apply) }
    func open() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { openPath(url.path) }
    }
    func operation(_ work: @escaping @Sendable (GitRepository) throws -> Void) {
        guard let repo = repository else { return }
        perform({ try work(repo); return try Snapshot(repo) }, apply: apply)
    }
    func refresh() { operation { _ in } }
    func commit() {
        let paths = Array(selected), text = message
        guard let repo = repository else { return }
        perform({ try repo.commit(paths, text); return try Snapshot(repo) }) { state in self.apply(state); self.message = "" }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var model: Workspace
    @State private var showEditor = false
    @State private var editPath = ""
    @State private var resolution = ""
    func prompt(_ title: String, _ labels: [String], done: ([String]) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: "実行"); alert.addButton(withTitle: "キャンセル")
        let stack = NSStackView(); stack.orientation = .vertical
        let fields = labels.map { label -> NSTextField in
            let field = NSTextField(string: ""); field.placeholderString = label; field.frame.size = NSSize(width: 450, height: 24)
            field.widthAnchor.constraint(equalToConstant: 450).isActive = true
            stack.addArrangedSubview(field); return field
        }
        stack.frame = NSRect(x: 0, y: 0, width: 450, height: labels.count * 34)
        alert.accessoryView = stack
        if alert.runModal() == .alertFirstButtonReturn { done(fields.map(\.stringValue)) }
    }
    func confirm(_ text: String, done: () -> Void) {
        let alert = NSAlert(); alert.messageText = text; alert.alertStyle = .warning
        alert.addButton(withTitle: "実行"); alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn { done() }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("✧ GitNebula").font(.largeTitle.bold()).foregroundStyle(Color(red: 0.70, green: 0.62, blue: 1))
                    Text("YOUR CODE, IN ORBIT").font(.caption).tracking(3).foregroundStyle(.secondary)
                }
                Spacer(); Button("リポジトリを開く", action: model.open)
                Button("Clone") { prompt("リポジトリを複製", ["取得元 URL / パス", "新しいフォルダの絶対パス"]) { values in
                    model.perform({ try Snapshot(GitRepository.clone(values[0], values[1])) }, apply: model.apply)
                } }
                Button("更新", action: model.refresh).disabled(model.repository == nil)
            }
            HStack {
                Picker("リモート", selection: $model.chosenRemote) { ForEach(model.remotes, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 240)
                Button("Fetch") { let remote = model.chosenRemote; model.operation { try $0.fetch(remote) } }
                Button("Pull (FF)") { let remote = model.chosenRemote; model.operation { try $0.pull(remote) } }
                Button("Push") { let remote = model.chosenRemote; model.operation { try $0.push(remote) } }
            }.disabled(model.repository == nil)
            HStack {
                Picker("ブランチ", selection: $model.chosenBranch) { ForEach(model.branches, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 260)
                Button("切替") { let name = model.chosenBranch; model.operation { try $0.switchBranch(name) } }
                Button("作成") { prompt("ブランチを作成して切替", ["新しい名前"]) { values in model.operation { try $0.createBranch(values[0]) } } }
                Button("名前変更") { let old = model.chosenBranch; prompt("ブランチ名を変更", ["新しい名前"]) { values in model.operation { try $0.renameBranch(old, values[0]) } } }
                Button("削除") { let name = model.chosenBranch; confirm("選択したマージ済みブランチを削除します。") { model.operation { try $0.deleteBranch(name) } } }
                Button("マージ") { let name = model.chosenBranch; model.operation { try $0.merge(name) } }
            }.disabled(model.repository == nil)
            Text("\(model.repository?.path ?? "コードの軌跡を、ひとつの星図に。")  ·  \(model.branch)").font(.caption).textSelection(.enabled)
            TabView {
                HSplitView {
                    List(model.changes) { change in
                        HStack {
                            Toggle("", isOn: Binding(get: { model.selected.contains(change.path) }, set: { if $0 { model.selected.insert(change.path) } else { model.selected.remove(change.path) } })).labelsHidden()
                            Button("\(change.code)  \(change.path)") {
                                if let repo = model.repository { model.perform({ try repo.diff(change.path) }) { model.diff = $0 } }
                            }.buttonStyle(.plain)
                        }
                    }.frame(minWidth: 280)
                    ScrollView([.horizontal, .vertical]) { Text(model.diff).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding() }.frame(minWidth: 400)
                }.tabItem { Text("変更 / 差分") }
                ScrollView([.horizontal, .vertical]) { Text(model.graph).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding() }.tabItem { Text("履歴グラフ") }
            }
            HStack {
                Picker("競合", selection: $model.chosenConflict) { ForEach(model.conflicts, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 260)
                Button("競合を編集") {
                    let file = model.chosenConflict
                    if let repo = model.repository { model.perform({ try repo.conflictText(file) }) { resolution = $0; editPath = file; showEditor = true } }
                }.disabled(model.chosenConflict.isEmpty)
                Button("外部で解決済み") { let file = model.chosenConflict; confirm("現在の内容（削除を含む）を解決済みとしてステージします。") { model.operation { try $0.markResolved(file) } } }
                Button("マージ完了") { let text = model.message; confirm("ステージ済みの全変更をマージコミットに含めます。") { model.operation { try $0.finishMerge(text) } } }
                Button("マージ中止") { confirm("競合解決作業を破棄してマージを中止します。") { model.operation { try $0.abortMerge() } } }
            }.disabled(model.repository == nil)
            TextField("コミットメッセージ", text: $model.message).textFieldStyle(.roundedBorder)
            Button("✧ 選択した変更をコミット", action: model.commit).disabled(model.selected.isEmpty || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(model.status).font(.caption).textSelection(.enabled)
        }.padding(24).frame(minWidth: 1040, minHeight: 760).background(Color(red: 0.035, green: 0.05, blue: 0.11)).disabled(model.busy).preferredColorScheme(.dark)
        .sheet(isPresented: $showEditor) {
            VStack {
                Text(editPath).font(.headline)
                TextEditor(text: $resolution).font(.system(.body, design: .monospaced))
                HStack {
                    Button("キャンセル") { showEditor = false }
                    Button("保存して解決") { let file = editPath, text = resolution; showEditor = false; model.operation { try $0.saveResolution(file, text) } }
                }
            }.padding().frame(width: 850, height: 550)
        }
    }
}

@main
struct GitNebulaApp: App {
    @StateObject private var model = Workspace()
    @State private var handledArguments = false
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in
                    guard url.scheme == "gitnebula", url.host == "open", let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value else { return }
                    model.openPath(path)
                }
                .onAppear {
                    guard !handledArguments else { return }; handledArguments = true
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--open"), index + 1 < args.count { model.openPath(args[index + 1]) }
                }
        }.windowStyle(.titleBar)
    }
}
