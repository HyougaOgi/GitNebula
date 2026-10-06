import Foundation

struct Change: Identifiable, Sendable, Equatable {
    var id: String { path }
    let code: String
    let path: String
    let original: String?
    var label: String {
        if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(code) { return "競合" }
        if code == "??" { return "新規" }
        if code.contains("R") { return "名前変更" }
        if code.contains("D") { return "削除" }
        if code.contains("A") { return "追加" }
        return "変更"
    }
}

struct GitRepository: Sendable {
    let path: String
    func run(_ args: [String]) throws -> String {
        String(decoding: try runData(args), as: UTF8.self)
    }
    func runData(_ args: [String], accepting statuses: Set<Int32> = [0]) throws -> Data {
        try GitProcess.run(in: path, arguments: args, accepting: statuses)
    }

    func configuration(_ key: String) throws -> String? {
        let text = String(decoding: try runData(["config", "--get", key], accepting: [0, 1]), as: UTF8.self).trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }
    func currentBranch() throws -> String {
        let text = String(decoding: try runData(["symbolic-ref", "--quiet", "--short", "HEAD"], accepting: [0, 1]), as: UTF8.self).trimmingCharacters(in: .newlines)
        return text.isEmpty ? "detached HEAD" : text
    }
    func headRevision() throws -> String? {
        let text = String(decoding: try runData(["rev-parse", "--verify", "--quiet", "HEAD"], accepting: [0, 1]), as: UTF8.self).trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }
    func changes() throws -> [Change] {
        let entries = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).split(separator: "\0", omittingEmptySubsequences: false)
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
        let changes = try changes()
        guard changes.contains(where: { $0.path == file }) else { throw failure("変更一覧にないファイルです") }
        if changes.contains(where: { $0.path == file && $0.code == "??" }) { return try readFile(file) }
        if try headRevision() == nil {
            return try run(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--cached", "--", file])
        }
        let text = try run(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", file])
        return text.isEmpty ? "未追跡ファイル、またはテキスト差分のない変更です。" : text
    }
    func commit(_ files: [String], _ message: String) throws {
        try requireIdle()
        guard try conflicts().isEmpty, try !mergeInProgress() else { throw failure("競合を解決し、「マージ完了」を使ってください") }
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

    static func open(_ path: String) throws -> GitRepository {
        let candidate = GitRepository(path: path)
        var root = try candidate.run(["rev-parse", "--show-toplevel"])
        if root.hasSuffix("\n") { root.removeLast() }
        return GitRepository(path: root)
    }
    static func clone(_ source: String, _ destination: String) throws -> GitRepository {
        let target = URL(fileURLWithPath: NSString(string: destination).expandingTildeInPath)
        let runner = GitRepository(path: target.deletingLastPathComponent().path)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw runner.failure("取得元と作成先フォルダを指定してください。") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty else {
                throw runner.failure("作成先 \(target.path) は既に使われています。別の保存先を指定してください。")
            }
        }
        _ = try runner.run(["clone", "--", source, target.path])
        return try open(target.path)
    }
    func graph() throws -> String {
        guard !(try run(["rev-list", "--all", "--max-count=1"])).isEmpty else { return "まだコミットはありません。" }
        return try run(["log", "--graph", "--all", "--decorate", "--oneline", "-100", "--no-color"])
    }
    func branches() throws -> [String] { try run(["for-each-ref", "--format=%(refname:short)", "refs/heads"]).split(separator: "\n").map(String.init) }
    func remotes() throws -> [String] { try run(["remote"]).split(separator: "\n").map(String.init) }
    func validateBranch(_ name: String) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw failure("有効なブランチ名を指定してください") }
        _ = try run(["check-ref-format", "--branch", name]); return name
    }
    func remote(_ name: String) throws -> String {
        guard try remotes().contains(name), !name.hasPrefix("-") else { throw failure("登録済みのリモートを指定してください") }
        return name
    }
    func requireClean() throws {
        try requireIdle()
        guard try changes().isEmpty, try !mergeInProgress() else { throw failure("変更をコミットし、進行中のマージを完了してください") }
    }
    func fetch(_ name: String) throws { _ = try run(["fetch", "--prune", remote(name)]) }
    func preferredRemote() throws -> String {
        let branch = try currentBranch()
        let configured = try configuration("branch.\(branch).remote") ?? ""
        let names = try remotes()
        return names.contains(configured) ? configured : names.contains("origin") ? "origin" : names.first ?? ""
    }
    func remoteBranch(_ name: String) throws -> String {
        let branch = try currentBranch()
        guard branch != "detached HEAD" else { throw failure("送受信するブランチを選んでください（現在は detached HEAD）。") }
        _ = try validateBranch(branch)
        let configured = try configuration("branch.\(branch).remote")
        if configured == name, let merge = try configuration("branch.\(branch).merge"), merge.hasPrefix("refs/heads/") {
            _ = try run(["check-ref-format", merge]); return merge
        }
        return "refs/heads/\(branch)"
    }
    func pull(_ name: String) throws {
        try requireClean()
        _ = try run(["pull", "--ff-only", remote(name), remoteBranch(name)])
    }
    func push(_ name: String) throws {
        guard try headRevision() != nil else { throw failure("Push する前に最初のコミットを作成してください。") }
        _ = try run(["push", "--set-upstream", remote(name), "HEAD:" + remoteBranch(name)])
    }
    func createBranch(_ name: String) throws { try requireClean(); _ = try run(["switch", "-c", validateBranch(name)]) }
    func switchBranch(_ name: String) throws {
        try requireClean()
        guard try branches().contains(name) else { throw failure("ローカルブランチを選択してください") }
        _ = try run(["switch", "--", validateBranch(name)])
    }
    func renameBranch(_ old: String, _ new: String) throws { try requireIdle(); _ = try run(["branch", "-m", validateBranch(old), validateBranch(new)]) }
    func deleteBranch(_ name: String) throws { try requireIdle(); _ = try run(["branch", "-d", "--", validateBranch(name)]) }
    func merge(_ name: String) throws { try requireClean(); _ = try run(["merge", "--no-edit", "--", validateBranch(name)]) }
    func conflicts() throws -> [String] { try run(["diff", "--name-only", "--diff-filter=U", "-z"]).split(separator: "\0").map(String.init) }
    func mergeInProgress() throws -> Bool {
        var file = try run(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"])
        if file.hasSuffix("\n") { file.removeLast() }
        return FileManager.default.fileExists(atPath: file)
    }
    func fileURL(_ file: String) throws -> URL {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { throw failure("リポジトリ内のファイルを指定してください") }
        let url = root.appendingPathComponent(file)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root.path || parent.hasPrefix(root.path + "/") else { throw failure("リポジトリ外のファイルは操作できません") }
        return url
    }
    func readFile(_ file: String, editable: Bool = false) throws -> String {
        let url = try fileURL(file)
        guard try entryExists(file) else { return "" }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            guard !editable else { throw failure("シンボリックリンクは外部で解決してください") }
            return "シンボリックリンク → " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
        if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 1024 * 1024 {
            if editable { throw failure("1 MiB を超えるファイルは外部で解決してください") }
            return "プレビュー上限の 1 MiB を超えています。"
        }
        let data = try Data(contentsOf: url)
        if data.contains(0) {
            if editable { throw failure("バイナリファイルは外部で解決してください") }
            return "バイナリファイルです。"
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if editable { throw failure("UTF-8 以外のファイルは外部で解決してください") }
        return "注意: UTF-8 で読めない文字を置き換えて表示しています。\n\n" + String(decoding: data, as: UTF8.self)
    }
    func conflictText(_ file: String) throws -> String {
        guard try conflicts().contains(file) else { throw failure("競合中のファイルを選択してください") }
        return try readFile(file, editable: true)
    }
    func saveResolution(_ file: String, _ text: String) throws {
        _ = try conflictText(file)
        guard !text.components(separatedBy: "\n").contains(where: { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix("=======") || $0.hasPrefix(">>>>>>> ") }) else { throw failure("競合マーカーを取り除いてください") }
        let url = try fileURL(file)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mode = attributes?[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        try markResolved(file)
    }
    func markResolved(_ file: String) throws {
        guard try conflicts().contains(file) else { throw failure("競合中のファイルを選択してください") }
        _ = try run(["--literal-pathspecs", "add", "-A", "--", file])
    }
    func finishMerge(_ message: String) throws {
        guard try mergeInProgress(), try conflicts().isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("競合を解決し、コミットメッセージを入力してください") }
        _ = try run(["commit", "-m", message])
    }
    func abortMerge() throws {
        guard try mergeInProgress() else { throw failure("進行中のマージはありません") }
        _ = try run(["merge", "--abort"])
    }
}
