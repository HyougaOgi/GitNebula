using System.Diagnostics;
using System.IO;
namespace GitNebula;
public record Change(string Code, string Path, string? Original)
{
    public string Label => Code is "DD" or "AU" or "UD" or "UA" or "DU" or "AA" or "UU" ? Localization.Text("競合") :
        Code == "??" ? Localization.Text("新規") : Code.Contains('R') ? Localization.Text("名前変更") : Code.Contains('D') ? Localization.Text("削除") : Code.Contains('A') ? Localization.Text("追加") : Localization.Text("変更");
}
public sealed partial class GitRepository(string path)
{
    public string Path { get; private set; } = path;
    public Task<string> Run(params string[] args) => GitProcess.Run(Path, args);
    public async Task Open()
    {
        try { Path = (await Run("rev-parse", "--show-toplevel")).TrimEnd('\r', '\n'); }
        catch (InvalidOperationException error) when (error.Message.Contains("not a git repository", StringComparison.Ordinal)) {
            throw new InvalidOperationException(Localization.Text("このフォルダは Git リポジトリではありません。\n履歴を表示するには、取得元を Clone するか、Git リポジトリのフォルダを選択してください。"), error);
        }
    }
    public async Task<List<Change>> Changes()
    {
        var entries = (await Run("status", "--porcelain=v1", "-z", "--untracked-files=all")).Split('\0');
        var result = new List<Change>();
        for (var i = 0; i < entries.Length; i++)
        {
            if (entries[i].Length < 3) continue;
            var code = entries[i][..2];
            var original = (code.Contains('R') || code.Contains('C')) && i + 1 < entries.Length ? entries[i + 1] : null;
            result.Add(new(code, entries[i][3..], original));
            if (code.Contains('R') || code.Contains('C')) i++;
        }
        return result;
    }
    public async Task<string?> Configuration(string key)
    {
        var text = (await GitProcess.RunAccepting(Path, ["config", "--get", key], [0, 1])).TrimEnd('\r', '\n');
        return text.Length == 0 ? null : text;
    }
    public async Task<string> Branch()
    {
        var text = (await GitProcess.RunAccepting(Path, ["symbolic-ref", "--quiet", "--short", "HEAD"], [0, 1])).TrimEnd('\r', '\n');
        return text.Length == 0 ? "detached HEAD" : text;
    }
    public async Task<string?> HeadRevision()
    {
        var text = (await GitProcess.RunAccepting(Path, ["rev-parse", "--verify", "--quiet", "HEAD"], [0, 1])).TrimEnd('\r', '\n');
        return text.Length == 0 ? null : text;
    }
    public async Task<string> Diff(string file)
    {
        var changes = await Changes();
        if (!changes.Any(item => item.Path == file)) throw new InvalidOperationException(Localization.Text("変更一覧にないファイルです。"));
        if (changes.Any(item => item.Path == file && item.Code == "??")) return ReadFile(file);
        if (await HeadRevision() == null) return await Run("--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--cached", "--", file);
        var text = await Run("--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", file);
        return text.Length == 0 ? Localization.Text("未追跡ファイル、またはテキスト差分のない変更です。") : text;
    }
    public async Task Commit(string[] paths, string message)
    {
        await RequireIdle();
        if ((await Conflicts()).Length > 0 || await MergeInProgress()) throw new InvalidOperationException(Localization.Text("競合を解決し、「マージ完了」を使ってください。"));
        var changes = await Changes();
        var available = changes.Select(item => item.Path).ToHashSet();
        if (paths.Length == 0 || paths.Any(path => !available.Contains(path)) || string.IsNullOrWhiteSpace(message)) throw new InvalidOperationException(Localization.Text("変更ファイルとメッセージを指定してください。"));
        paths = paths.Distinct().ToArray();
        var originals = changes.Where(item => paths.Contains(item.Path) && item.Code.Contains('R') && item.Original != null).Select(item => item.Original!).ToArray();
        foreach (var original in originals)
            if (!paths.Contains(original) && EntryExists(original))
                throw new InvalidOperationException(Localization.Format($"リネーム元に未選択のファイルがあります: {original}。そのファイルも含める場合は選択してください。含めない場合は元の場所から移して再実行してください。"));
        var deleted = changes.Where(item => item.Code.StartsWith('D')).Select(item => item.Path).ToHashSet();
        var toStage = paths.Where(path => !deleted.Contains(path) || EntryExists(path)).ToArray();
        if (toStage.Length > 0) await Run(new[] { "--literal-pathspecs", "add", "--" }.Concat(toStage).ToArray());
        paths = paths.Concat(originals).Distinct().ToArray();
        await Run(new[] { "--literal-pathspecs", "commit", "--only", "-m", message, "--" }.Concat(paths).ToArray());
    }
    private bool EntryExists(string file)
    {
        try { _ = File.GetAttributes(System.IO.Path.Combine(Path, file)); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }
    public static async Task<GitRepository> Clone(string source, string destination)
    {
        if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(destination)) throw new InvalidOperationException(Localization.Text("取得元と作成先を指定してください。"));
        var target = System.IO.Path.GetFullPath(destination);
        if (File.Exists(target) || Directory.Exists(target) && Directory.EnumerateFileSystemEntries(target).Any())
            throw new InvalidOperationException(Localization.Format($"作成先 {target} は既に使われています。別の保存先を指定してください。"));
        var runner = new GitRepository(System.IO.Path.GetDirectoryName(target)!);
        await runner.Run("clone", "--", source, target);
        var repo = new GitRepository(target); await repo.Open(); return repo;
    }
    public async Task<string> Graph() => string.IsNullOrWhiteSpace(await Run("rev-list", "--all", "--max-count=1")) ? Localization.Text("まだコミットはありません。") : await Run("log", "--graph", "--all", "--decorate", "--oneline", "-100", "--no-color");
    public async Task<string[]> Branches() => GitProcess.Lines(await Run("for-each-ref", "--format=%(refname:short)", "refs/heads"));
    public async Task<string[]> Remotes() => GitProcess.Lines(await Run("remote"));
    private async Task<string> Remote(string name)
    {
        if (name.StartsWith('-') || !(await Remotes()).Contains(name)) throw new InvalidOperationException(Localization.Text("登録済みのリモートを指定してください。"));
        return name;
    }
    private async Task<string> ValidateBranch(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.StartsWith('-')) throw new InvalidOperationException(Localization.Text("有効なブランチ名を指定してください。"));
        await Run("check-ref-format", "--branch", name); return name;
    }
    private async Task RequireClean()
    {
        await RequireIdle();
        if ((await Changes()).Count > 0 || await MergeInProgress()) throw new InvalidOperationException(Localization.Text("変更をコミットし、進行中のマージを完了してください。"));
    }
    public async Task Fetch(string remote) => await Run("fetch", "--prune", await Remote(remote));
    public async Task<string> PreferredRemote()
    {
        var branch = await Branch(); var configured = await Configuration($"branch.{branch}.remote") ?? "";
        var names = await Remotes();
        return names.Contains(configured) ? configured : names.Contains("origin") ? "origin" : names.FirstOrDefault() ?? "";
    }
    public async Task<string> RemoteBranch(string remote)
    {
        var branch = await Branch();
        if (branch == "detached HEAD") throw new InvalidOperationException(Localization.Text("送受信するブランチを選んでください（現在は detached HEAD）。"));
        await ValidateBranch(branch);
        var configured = await Configuration($"branch.{branch}.remote");
        var merge = await Configuration($"branch.{branch}.merge");
        if (configured == remote && merge != null && merge.StartsWith("refs/heads/", StringComparison.Ordinal)) {
            await Run("check-ref-format", merge); return merge;
        }
        return $"refs/heads/{branch}";
    }
    public async Task Pull(string remote)
    {
        await RequireClean(); await Run("pull", "--ff-only", await Remote(remote), await RemoteBranch(remote));
    }
    public async Task Push(string remote)
    {
        if (await HeadRevision() == null) throw new InvalidOperationException(Localization.Text("Push する前に最初のコミットを作成してください。"));
        await Run("push", "--set-upstream", await Remote(remote), "HEAD:" + await RemoteBranch(remote));
    }
    public async Task CreateBranch(string name) { await RequireClean(); await Run("switch", "-c", await ValidateBranch(name)); }
    public async Task SwitchBranch(string name)
    {
        await RequireClean(); if (!(await Branches()).Contains(name)) throw new InvalidOperationException(Localization.Text("ローカルブランチを選択してください。"));
        await Run("switch", "--", await ValidateBranch(name));
    }
    public async Task RenameBranch(string oldName, string newName) { await RequireIdle(); await Run("branch", "-m", await ValidateBranch(oldName), await ValidateBranch(newName)); }
    public async Task DeleteBranch(string name) { await RequireIdle(); await Run("branch", "-d", "--", await ValidateBranch(name)); }
    public async Task Merge(string name) { await RequireClean(); await Run("merge", "--no-edit", "--", await ValidateBranch(name)); }
    public async Task<string[]> Conflicts() => (await Run("diff", "--name-only", "--diff-filter=U", "-z")).Split('\0', StringSplitOptions.RemoveEmptyEntries);
    public async Task<bool> MergeInProgress() => File.Exists((await Run("rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD")).TrimEnd('\r', '\n'));
    private string FilePath(string file)
    {
        var root = System.IO.Path.GetFullPath(Path).TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
        var target = System.IO.Path.GetFullPath(System.IO.Path.Combine(root, file));
        if (System.IO.Path.IsPathRooted(file) || !target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException(Localization.Text("リポジトリ内のファイルを指定してください。"));
        for (var parent = System.IO.Path.GetDirectoryName(target); parent != null && parent.Length >= root.Length; parent = System.IO.Path.GetDirectoryName(parent))
            if (Directory.Exists(parent) && (File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException(Localization.Text("リンク先のファイルは外部で操作してください。"));
        return target;
    }
    public string ReadFile(string file, bool editable = false)
    {
        var target = FilePath(file);
        if (!EntryExists(file)) return "";
        if ((File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0)
        {
            if (editable) throw new InvalidOperationException(Localization.Text("リンクは外部で解決してください。"));
            return Localization.Text("シンボリックリンク → ") + new FileInfo(target).LinkTarget;
        }
        if (new FileInfo(target).Length > 1024 * 1024)
        {
            if (editable) throw new InvalidOperationException(Localization.Text("1 MiB を超えるファイルは外部で解決してください。"));
            return Localization.Text("プレビュー上限の 1 MiB を超えています。");
        }
        var bytes = File.ReadAllBytes(target);
        if (bytes.Contains((byte)0))
        {
            if (editable) throw new InvalidOperationException(Localization.Text("バイナリファイルは外部で解決してください。"));
            return Localization.Text("バイナリファイルです。");
        }
        try { return new System.Text.UTF8Encoding(false, true).GetString(bytes); }
        catch (System.Text.DecoderFallbackException)
        {
            if (editable) throw new InvalidOperationException(Localization.Text("UTF-8 以外のファイルは外部で解決してください。"));
            return Localization.Text("注意: UTF-8 で読めない文字を置き換えて表示しています。\n\n") + System.Text.Encoding.UTF8.GetString(bytes);
        }
    }
    public async Task<string> ConflictText(string file)
    {
        if (!(await Conflicts()).Contains(file)) throw new InvalidOperationException(Localization.Text("競合中のファイルを選択してください。"));
        return ReadFile(file, true);
    }
    public async Task SaveResolution(string file, string text)
    {
        await ConflictText(file);
        if (text.Split('\n').Any(line => line.StartsWith("<<<<<<< ") || line.StartsWith("=======") || line.StartsWith(">>>>>>> "))) throw new InvalidOperationException(Localization.Text("競合マーカーを取り除いてください。"));
        var target = FilePath(file); var temporary = target + ".gitnebula-" + Guid.NewGuid();
        try { await File.WriteAllTextAsync(temporary, text, new System.Text.UTF8Encoding(false)); File.Move(temporary, target, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        await MarkResolved(file);
    }
    public async Task MarkResolved(string file)
    {
        if (!(await Conflicts()).Contains(file)) throw new InvalidOperationException(Localization.Text("競合中のファイルを選択してください。"));
        await Run("--literal-pathspecs", "add", "-A", "--", file);
    }
    public async Task FinishMerge(string message)
    {
        if (!await MergeInProgress() || (await Conflicts()).Length > 0 || string.IsNullOrWhiteSpace(message)) throw new InvalidOperationException(Localization.Text("競合を解決し、コミットメッセージを入力してください。"));
        await Run("commit", "-m", message);
    }
    public async Task AbortMerge()
    {
        if (!await MergeInProgress()) throw new InvalidOperationException(Localization.Text("進行中のマージはありません。"));
        await Run("merge", "--abort");
    }
}
