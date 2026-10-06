using System.IO;
namespace GitNebula;

public record StashEntry(string Reference, string Id, string Title);
public record CommitRecord(string Id, string Author, string Date, string Subject, string Message, string[] Parents, string Decorations = "")
{
    public string ShortId => Id[..Math.Min(8, Id.Length)];
}
public sealed partial class GitRepository
{
    public async Task<string?> Sequence()
    {
        foreach (var (marker, operation) in new[] { ("rebase-merge", "rebase"), ("rebase-apply", "rebase"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"), ("MERGE_HEAD", "merge") })
        {
            var file = (await Run("rev-parse", "--path-format=absolute", "--git-path", marker)).TrimEnd('\r', '\n');
            if (File.Exists(file) || Directory.Exists(file)) return operation;
        }
        return null;
    }
    private async Task RequireIdle()
    {
        if (await Sequence() != null || (await Conflicts()).Length > 0)
            throw new InvalidOperationException(Localization.Text("競合を解決し、進行中の操作を完了または中止してください。"));
    }
    public async Task<string> Revision(string reference)
    {
        if (string.IsNullOrWhiteSpace(reference) || reference.Contains('\0')) throw new InvalidOperationException(Localization.Text("コミット・ブランチ・タグを指定してください。"));
        return (await Run("rev-parse", "--verify", "--end-of-options", reference + "^{commit}")).TrimEnd('\r', '\n');
    }
    public async Task<StashEntry[]> Stashes() => GitProcess.Lines(await Run("stash", "list", "--format=%gd%x00%H%x00%gs")).Select(line => line.Split('\0', 3)).Where(f => f.Length == 3).Select(f => new StashEntry(f[0], f[1], f[2])).ToArray();
    public async Task SaveStash(string message, bool includeUntracked)
    {
        await RequireIdle();
        if (!(await Changes()).Any(c => includeUntracked || c.Code != "??")) throw new InvalidOperationException(Localization.Text("退避する変更がありません。未追跡ファイルを含める場合はチェックを入れてください。"));
        if (await HeadRevision() == null) throw new InvalidOperationException(Localization.Text("Stash を使う前に最初のコミットを作成してください。"));
        var args = new List<string> { "stash", "push" };
        if (includeUntracked) args.Add("--include-untracked");
        args.AddRange(new[] { "-m", string.IsNullOrEmpty(message) ? "GitNebula" : message });
        await Run(args.ToArray());
    }
    private async Task<string> StashReference(string id) => (await Stashes()).FirstOrDefault(s => s.Id == id)?.Reference ?? throw new InvalidOperationException(Localization.Text("退避データが見つかりません。一覧を更新してください。"));
    public async Task ApplyStash(string id, bool pop = false)
    {
        await RequireClean(); await Run("stash", pop ? "pop" : "apply", "--index", await StashReference(id));
    }
    public async Task DropStash(string id) { await RequireIdle(); await Run("stash", "drop", await StashReference(id)); }
    public async Task<string> ShowStash(string id) => await Run("stash", "show", "--include-untracked", "--no-ext-diff", "--no-textconv", "--patch", await StashReference(id));
    public async Task<CommitRecord[]> History(bool topological = false, int limit = 200)
    {
        if (string.IsNullOrWhiteSpace(await Run("rev-list", "--all", "--max-count=1"))) return [];
        var output = await Run("log", "--all", topological ? "--topo-order" : "--date-order", "-z", "-" + limit, "--format=%H%x00%an%x00%aI%x00%s%x00%B%x00%P%x00%D");
        var fields = output.Split('\0');
        var records = new List<CommitRecord>();
        for (var i = 0; i + 6 < fields.Length; i += 7)
            records.Add(new(fields[i].TrimStart('\r', '\n'), fields[i + 1], fields[i + 2], fields[i + 3], fields[i + 4], fields[i + 5].Split(' ', StringSplitOptions.RemoveEmptyEntries), fields[i + 6]));
        return records.ToArray();
    }
    public async Task<string> ShowCommit(string id) => await Run("show", "--no-ext-diff", "--no-textconv", "--no-color", "--stat", "--patch", await Revision(id), "--");
    public async Task CherryPick(string id) { await RequireClean(); await Run("cherry-pick", await Revision(id)); }
    public async Task Revert(string id) { await RequireClean(); await Run("revert", "--no-edit", await Revision(id)); }
    public async Task Rebase(string branch) { await RequireClean(); await Run("rebase", await Revision(branch)); }
    public async Task ContinueSequence()
    {
        var operation = await Sequence();
        if (operation == null || operation == "merge" || (await Conflicts()).Length > 0) throw new InvalidOperationException(Localization.Text("競合を解決してから再開してください。"));
        await Run(operation, "--continue");
    }
    public async Task AbortSequence()
    {
        var operation = await Sequence() ?? throw new InvalidOperationException(Localization.Text("進行中の操作はありません。"));
        await Run(operation, "--abort");
    }
    public async Task Stage(string[] files)
    {
        var changes = await Changes();
        if (files.Length == 0 || files.Any(f => !changes.Any(c => c.Path == f))) throw new InvalidOperationException(Localization.Text("変更ファイルを選択してください。"));
        var originals = changes.Where(c => files.Contains(c.Path) && c.Original != null).Select(c => c.Original!).ToArray();
        if (originals.Any(f => !files.Contains(f) && EntryExists(f))) throw new InvalidOperationException(Localization.Text("名前変更元に未選択のファイルがあります。そのファイルも選択してください。"));
        await Run(new[] { "--literal-pathspecs", "add", "-A", "--" }.Concat(files).Concat(originals).ToArray());
    }
    public async Task Unstage(string[] files)
    {
        await RequireIdle();
        var changes = await Changes();
        if (files.Length == 0 || files.Any(f => !changes.Any(c => c.Path == f))) throw new InvalidOperationException(Localization.Text("変更ファイルを選択してください。"));
        var staged = changes.Where(c => files.Contains(c.Path) && c.Code[0] is not (' ' or '?')).ToArray();
        if (staged.Length == 0) throw new InvalidOperationException(Localization.Text("選択したファイルにステージ済みの変更はありません。"));
        var paths = staged.Select(c => c.Path).Concat(staged.Where(c => c.Original != null).Select(c => c.Original!)).Distinct();
        var unborn = await HeadRevision() == null;
        await Run(new[] { "--literal-pathspecs" }.Concat(unborn ? new[] { "rm", "--cached", "-f" } : new[] { "restore", "--staged" }).Concat(new[] { "--" }).Concat(paths).ToArray());
    }
    public async Task<string[]> Tags() => GitProcess.Lines(await Run("tag", "--list", "--sort=-creatordate"));
    private async Task ValidateTag(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.StartsWith('-')) throw new InvalidOperationException(Localization.Text("タグ名を指定してください。"));
        await Run("check-ref-format", "refs/tags/" + name);
    }
    public async Task CreateTag(string name, string reference, string message)
    {
        await ValidateTag(name); var id = await Revision(reference);
        await Run(string.IsNullOrEmpty(message) ? new[] { "tag", "--", name, id } : new[] { "tag", "-a", "-m", message, "--", name, id });
    }
    public async Task DeleteTag(string name) { await ValidateTag(name); await Run("tag", "-d", "--", name); }
    public async Task PushTag(string name, string remote)
    {
        await ValidateTag(name);
        if (!(await Tags()).Contains(name)) throw new InvalidOperationException(Localization.Text("ローカルのタグを選択してください。"));
        await Run("push", await Remote(remote), $"refs/tags/{name}:refs/tags/{name}");
    }
    public async Task SetRemote(string name, string url)
    {
        if (string.IsNullOrWhiteSpace(name) || name.StartsWith('-') || string.IsNullOrWhiteSpace(url) || url.StartsWith('-') || url.Contains('\0')) throw new InvalidOperationException(Localization.Text("リモート名と URL を指定してください。"));
        await Run("check-ref-format", $"refs/remotes/{name}/probe");
        await Run("remote", (await Remotes()).Contains(name) ? "set-url" : "add", name, url);
    }
    public async Task RemoveRemote(string name) => await Run("remote", "remove", await Remote(name));
    public async Task SetIdentity(string name, string email)
    {
        if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(email)) throw new InvalidOperationException(Localization.Text("名前とメールアドレスを入力してください。"));
        await Run("config", "--local", "user.name", name); await Run("config", "--local", "user.email", email);
    }
}
