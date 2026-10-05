import Foundation

struct StashEntry: Identifiable, Sendable {
    let reference: String
    let id: String
    let title: String
}

enum GitSequence: String, Sendable {
    case merge, rebase, cherryPick = "cherry-pick", revert
    var title: String { rawValue }
}

extension GitRepository {
    static func initialize(_ input: String) throws -> GitRepository {
        let path = try LaunchRequest.inputPath(input)
        let candidate = GitRepository(path: path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw candidate.failure("先にフォルダを作成し、そのパスを指定してください。")
        }
        guard (try? open(path)) == nil else { throw candidate.failure("この場所はすでに Git リポジトリ内です。開く操作を使ってください。") }
        _ = try candidate.run(["init", "--initial-branch=main"])
        return try open(path)
    }
    func gitPath(_ name: String) throws -> String {
        var value = try run(["rev-parse", "--path-format=absolute", "--git-path", name])
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }
    func sequence() throws -> GitSequence? {
        for (marker, operation) in [("rebase-merge", GitSequence.rebase), ("rebase-apply", .rebase), ("CHERRY_PICK_HEAD", .cherryPick), ("REVERT_HEAD", .revert), ("MERGE_HEAD", .merge)] {
            if FileManager.default.fileExists(atPath: try gitPath(marker)) { return operation }
        }
        return nil
    }
    func requireIdle() throws {
        guard try sequence() == nil, try conflicts().isEmpty else { throw failure("競合を解決し、進行中の操作を完了または中止してください。") }
    }
    func revision(_ input: String) throws -> String {
        guard !input.isEmpty, !input.contains("\0") else { throw failure("コミット・ブランチ・タグを指定してください。") }
        return try run(["rev-parse", "--verify", "--end-of-options", input + "^{commit}"]).trimmingCharacters(in: .newlines)
    }
    func stashes() throws -> [StashEntry] {
        try run(["stash", "list", "--format=%gd%x00%H%x00%gs"]).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return fields.count == 3 ? StashEntry(reference: fields[0], id: fields[1], title: fields[2]) : nil
        }
    }
    func saveStash(_ message: String, includeUntracked: Bool) throws {
        try requireIdle()
        let changes = try changes()
        guard changes.contains(where: { includeUntracked || $0.code != "??" }) else {
            throw failure("退避する変更がありません。未追跡ファイルを退避する場合はチェックを入れてください。")
        }
        guard try headRevision() != nil else { throw failure("Stash を使う前に最初のコミットを作成してください。") }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        args += ["-m", message.isEmpty ? "GitNebula" : message]
        _ = try run(args)
    }
    func stashReference(_ id: String) throws -> String {
        guard let entry = try stashes().first(where: { $0.id == id }) else { throw failure("退避データが見つかりません。一覧を更新してください。") }
        return entry.reference
    }
    func applyStash(_ id: String, pop: Bool = false) throws {
        try requireClean()
        _ = try run(["stash", pop ? "pop" : "apply", "--index", stashReference(id)])
    }
    func dropStash(_ id: String) throws { try requireIdle(); _ = try run(["stash", "drop", stashReference(id)]) }
    func showStash(_ id: String) throws -> String { try run(["stash", "show", "--include-untracked", "--no-ext-diff", "--no-textconv", "--patch", stashReference(id)]) }
    func tags() throws -> [String] { try run(["tag", "--list", "--sort=-creatordate"]).split(separator: "\n").map(String.init) }
    func validateTag(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw failure("タグ名を入力してください。") }
        _ = try run(["check-ref-format", "refs/tags/" + name])
    }
    func createTag(_ name: String, at reference: String, message: String) throws {
        try validateTag(name)
        let commit = try revision(reference)
        let args = message.isEmpty ? ["tag", "--", name, commit] : ["tag", "-a", "-m", message, "--", name, commit]
        _ = try run(args)
    }
    func deleteTag(_ name: String) throws { try validateTag(name); _ = try run(["tag", "-d", "--", name]) }
    func pushTag(_ name: String, to destination: String) throws {
        try validateTag(name)
        guard try tags().contains(name) else { throw failure("ローカルのタグを選択してください。") }
        _ = try run(["push", remote(destination), "refs/tags/\(name):refs/tags/\(name)"])
    }
    func remoteDetails() throws -> String { try run(["remote", "-v"]) }
    func setRemote(_ name: String, url: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !url.isEmpty, !url.hasPrefix("-"), !url.contains("\0") else { throw failure("リモート名と URL を入力してください。") }
        _ = try run(["check-ref-format", "refs/remotes/\(name)/probe"])
        _ = try run(["remote", try remotes().contains(name) ? "set-url" : "add", name, url])
    }
    func removeRemote(_ name: String) throws { _ = try run(["remote", "remove", remote(name)]) }
    func identity() throws -> String {
        let name = try configuration("user.name") ?? "未設定"
        let email = try configuration("user.email") ?? "未設定"
        return "\(name) <\(email)>"
    }
    func setIdentity(name: String, email: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("名前とメールアドレスを入力してください。") }
        _ = try run(["config", "--local", "user.name", name]); _ = try run(["config", "--local", "user.email", email])
    }
    func selectedChanges(_ files: [String]) throws -> [Change] {
        let changes = try changes()
        guard !files.isEmpty, files.allSatisfy({ file in changes.contains(where: { $0.path == file }) }) else { throw failure("現在の変更一覧からファイルを選択してください。") }
        return changes.filter { files.contains($0.path) }
    }
    func stage(_ files: [String]) throws {
        let changes = try selectedChanges(files)
        for original in changes.compactMap(\.original) where !files.contains(original) {
            if try entryExists(original) { throw failure("名前変更の元の場所に未選択のファイルがあります。ステージする場合は、そのファイルも選択してください。") }
        }
        _ = try run(["--literal-pathspecs", "add", "-A", "--"] + files + changes.compactMap(\.original))
    }
    func unstage(_ files: [String]) throws {
        try requireIdle()
        let changes = try selectedChanges(files).filter { $0.code.first != " " && $0.code.first != "?" }
        guard !changes.isEmpty else { throw failure("選択したファイルにステージ済みの変更はありません。") }
        let args = try headRevision() == nil ? ["rm", "--cached", "-f"] : ["restore", "--staged"]
        _ = try run(["--literal-pathspecs"] + args + ["--"] + changes.map(\.path) + changes.compactMap(\.original))
    }
    func discard(_ files: [String]) throws {
        try requireIdle()
        let changes = try selectedChanges(files)
        guard changes.allSatisfy({ $0.code != "??" && $0.original == nil && !$0.code.contains("A") }) else {
            throw failure("新規・追加・名前変更ファイルは除外してください。既存ファイルの変更のみを元に戻せます。")
        }
        _ = try run(["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--"] + files)
    }
    func ignore(_ files: [String]) throws {
        let changes = try selectedChanges(files)
        guard changes.allSatisfy({ $0.code == "??" && $0.path != ".gitignore" && !$0.path.contains("\n") && !$0.path.contains("\r") }) else {
            throw failure("無視対象にする未追跡ファイルのみを選択してください。")
        }
        let url = try fileURL(".gitignore")
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type != .typeRegular {
            throw failure(".gitignore が通常のファイルではありません。")
        }
        var content = try entryExists(".gitignore") ? String(contentsOf: url, encoding: .utf8) : ""
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        for file in files {
            let escaped = file.map { "\\!#*?[] ".contains($0) ? "\\" + String($0) : String($0) }.joined()
            content += "/" + escaped + "\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
    func showCommit(_ reference: String) throws -> String { try run(["show", "--no-ext-diff", "--no-color", "--stat", "--patch", revision(reference), "--"]) }
    func compare(_ from: String, _ to: String) throws -> String { try run(["diff", "--no-ext-diff", "--no-color", revision(from), revision(to), "--"]) }
    func blame(_ file: String, at reference: String) throws -> String {
        _ = try fileURL(file)
        return try run(["--literal-pathspecs", "blame", "--date=short", revision(reference), "--", file])
    }
    func fileHistory(_ file: String) throws -> String {
        _ = try fileURL(file)
        return try run(["--literal-pathspecs", "log", "--follow", "--stat", "--oneline", "-100", "--", file])
    }
    func cherryPick(_ reference: String) throws { try requireClean(); _ = try run(["cherry-pick", revision(reference)]) }
    func revert(_ reference: String) throws { try requireClean(); _ = try run(["revert", "--no-edit", revision(reference)]) }
    func rebase(onto reference: String) throws { try requireClean(); _ = try run(["-c", "core.editor=true", "rebase", revision(reference)]) }
    func reset(_ reference: String, mode: String) throws {
        try requireClean()
        guard ["soft", "mixed", "hard"].contains(mode) else { throw failure("Reset の方法が不正です。") }
        _ = try run(["reset", "--" + mode, revision(reference), "--"])
    }
    func continueSequence() throws {
        guard let operation = try sequence(), operation != .merge, try conflicts().isEmpty else { throw failure("競合を解決してから再開してください。") }
        _ = try run(["-c", "core.editor=true", operation.rawValue, "--continue"])
    }
    func abortSequence() throws {
        guard let operation = try sequence() else { throw failure("進行中の操作はありません。") }
        _ = try run([operation.rawValue, "--abort"])
    }
    func reflog() throws -> String { try run(["reflog", "--date=iso", "-100"]) }
    func exportPatch(to input: String) throws {
        let output = try LaunchRequest.inputPath(input)
        guard !FileManager.default.fileExists(atPath: output) else { throw failure("保存先ファイルはすでに存在します。別の名前を指定してください。") }
        _ = try revision("HEAD")
        _ = try run(["diff", "--no-ext-diff", "--binary", "--output=" + output, "HEAD", "--"])
    }
    func applyPatch(_ input: String, checkOnly: Bool) throws {
        try requireIdle()
        let file = try LaunchRequest.inputPath(input)
        _ = try run(["apply", "--check", "--", file])
        if !checkOnly { _ = try run(["apply", "--", file]) }
    }
    func worktrees() throws -> String { try run(["worktree", "list", "--porcelain"]) }
    func addWorktree(at input: String, branch: String) throws {
        try requireIdle()
        let target = try LaunchRequest.inputPath(input)
        guard !FileManager.default.fileExists(atPath: target) else { throw failure("作成先には、存在しないフォルダを指定してください。") }
        _ = try run(["worktree", "add", "-b", validateBranch(branch), "--", target, "HEAD"])
    }
    func submodules() throws -> String { try run(["submodule", "status", "--recursive"]) }
    func addSubmodule(source: String, destination: String) throws {
        try requireClean()
        guard !source.isEmpty, !source.hasPrefix("-"), !destination.isEmpty else { throw failure("取得元とリポジトリ内の作成先を指定してください。") }
        _ = try fileURL(destination)
        _ = try run(["submodule", "add", "--", source, destination])
    }
    func updateSubmodules() throws { try requireClean(); _ = try run(["submodule", "update", "--init", "--recursive"]) }
}
