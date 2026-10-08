import Foundation

struct RemoteOperationReport: Sendable {
    let action: GitAction
    let remote, branch: String
    let before, after: String?
    let commits: Int
    let changedFiles: [String]
    let output: String
    var summary: String {
        switch action {
        case .pull: return before == after ? L("Pull 完了。最新のため変更はありません。") : L("Pull 完了。\(commits) コミット、\(changedFiles.count) ファイルを更新しました。")
        case .push: return L("Push 完了。\(branch) を \(remote) に送信しました。")
        default: return L("Fetch 完了。リモートの追跡情報を更新しました。")
        }
    }
}
extension GitRepository {
    func transfer(_ action: GitAction, remote name: String, progress: (@Sendable (GitTransferProgress) -> Void)? = nil) throws -> RemoteOperationReport {
        let name = try remote(name), branch = try currentBranch(), before = try headRevision()
        let arguments: [String]
        switch action {
        case .pull:
            try requireClean(); arguments = ["pull", "--progress", "--ff-only", name, try remoteBranch(name)]
        case .push:
            guard before != nil else { throw failure(L("Push する前に最初のコミットを作成してください。")) }
            arguments = ["push", "--progress", "--set-upstream", name, "HEAD:" + (try remoteBranch(name))]
        case .fetch: arguments = ["fetch", "--progress", "--prune", name]
        default: throw failure(L("送受信の操作を選択してください。"))
        }
        let result = try GitProcess.runWithOutput(in: path, arguments: arguments, progress: progress)
        progress?(.checking)
        let after = try headRevision()
        let changed = action == .pull && before != after && before != nil && after != nil
        let commits = changed ? Int(try run(["rev-list", "--count", before! + ".." + after!, "--"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        let files = changed ? try run(["diff", "--name-only", "-z", before!, after!, "--"]).split(separator: "\0").map(String.init) : []
        return RemoteOperationReport(action: action, remote: name, branch: branch, before: before, after: after, commits: commits, changedFiles: files, output: (String(decoding: result.data, as: UTF8.self) + result.diagnostics).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .newlines))
    }
}
