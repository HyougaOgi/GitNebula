namespace GitNebula;
public record RemoteOperationReport(string Action, string Remote, string Branch, string? Before, string? After, int Commits, string[] ChangedFiles, string Output)
{
    public string Summary => Action switch {
        "pull" when Before == After => Localization.Text("Pull 完了。最新のため変更はありません。"),
        "pull" => Localization.Format($"Pull 完了。{Commits} コミット、{ChangedFiles.Length} ファイルを更新しました。"),
        "push" => Localization.Format($"Push 完了。{Branch} を {Remote} に送信しました。"),
        _ => Localization.Text("Fetch 完了。リモートの追跡情報を更新しました。")
    };
}
public sealed partial class GitRepository
{
    public async Task<RemoteOperationReport> Transfer(string action, string remote)
    {
        remote = await Remote(remote); var branch = await Branch(); var before = await HeadRevision(); string[] arguments;
        switch (action) {
            case "pull": await RequireClean(); arguments = ["pull", "--ff-only", remote, await RemoteBranch(remote)]; break;
            case "push":
                if (before == null) throw new InvalidOperationException(Localization.Text("Push する前に最初のコミットを作成してください。"));
                arguments = ["push", "--set-upstream", remote, "HEAD:" + await RemoteBranch(remote)]; break;
            case "fetch": arguments = ["fetch", "--prune", remote]; break;
            default: throw new ArgumentException("Unknown transfer action", nameof(action));
        }
        var result = await GitProcess.RunWithOutput(Path, arguments, [0]); var after = await HeadRevision();
        var changed = action == "pull" && before != after && before != null && after != null;
        var count = changed ? int.Parse((await Run("rev-list", "--count", before + ".." + after, "--")).Trim()) : 0;
        var files = changed ? (await Run("diff", "--name-only", "-z", before!, after!, "--")).Split('\0', StringSplitOptions.RemoveEmptyEntries) : [];
        return new(action, remote, branch, before, after, count, files, (result.Output + result.Diagnostics).Trim());
    }
}
