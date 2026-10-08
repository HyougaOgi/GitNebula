using System.IO;
namespace GitNebula;

public sealed partial class GitRepository
{
    private async Task<Change[]> SelectedChanges(string[] files) {
        var changes = await Changes();
        if (files.Length == 0 || files.Any(f => !changes.Any(c => c.Path == f))) throw new InvalidOperationException(Localization.Text("変更ファイルを選択してください。"));
        return changes.Where(c => files.Contains(c.Path)).ToArray();
    }
    public async Task Discard(string[] files) {
        await RequireIdle(); var changes = await SelectedChanges(files);
        if (changes.Any(c => c.Code == "??" || c.Original != null || c.Code.Contains('A'))) throw new InvalidOperationException(Localization.Text("新規・追加・名前変更ファイルは除外してください。既存ファイルの変更のみを元に戻せます。"));
        await Run(new[] { "--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--" }.Concat(files).ToArray());
    }
    public async Task Ignore(string[] files) {
        var changes = await SelectedChanges(files);
        if (changes.Any(c => c.Code != "??" || c.Path == ".gitignore" || c.Path.Contains('\n') || c.Path.Contains('\r'))) throw new InvalidOperationException(Localization.Text("無視対象にする未追跡ファイルのみを選択してください。"));
        var target = FilePath(".gitignore");
        if (EntryExists(".gitignore") && (!File.Exists(target) || (File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0)) throw new InvalidOperationException(Localization.Text(".gitignore が通常のファイルではありません。"));
        var content = File.Exists(target) ? await File.ReadAllTextAsync(target) : "";
        if (content.Length > 0 && !content.EndsWith('\n')) content += "\n";
        content += string.Concat(files.Select(file => "/" + string.Concat(file.Select(c => "\\!#*?[] ".Contains(c) ? "\\" + c : c.ToString())) + "\n"));
        await File.WriteAllTextAsync(target, content);
    }
    public async Task<string> Compare(string first, string second) => await Run("diff", "--no-ext-diff", "--no-textconv", await Revision(first), await Revision(second), "--");
    public async Task<string> Blame(string file, string reference) { FilePath(file); return await Run("--literal-pathspecs", "blame", "--date=iso", await Revision(reference), "--", file); }
    public async Task<string> FileHistory(string file) { FilePath(file); return await Run("--literal-pathspecs", "log", "--follow", "--stat", "--format=%H%n%B", "-100", "--", file); }
    public async Task<string> Reflog() => await Run("reflog", "--date=iso", "--format=%H %gd %gs", "-100");
    public async Task Reset(string reference, string mode) {
        await RequireClean(); if (mode is not ("soft" or "mixed" or "hard")) throw new InvalidOperationException(Localization.Text("Reset の方法が不正です。"));
        await Run("reset", "--" + mode, await Revision(reference), "--");
    }
    public async Task ExportPatch(string path) {
        var target = LaunchRequest.InputPath(path); await Revision("HEAD");
        using (new FileStream(target, FileMode.CreateNew, FileAccess.Write)) { }
        try { await Run("diff", "--no-ext-diff", "--no-textconv", "--binary", "--output=" + target, "HEAD", "--"); }
        catch { File.Delete(target); throw; }
    }
    public async Task ApplyPatch(string path, bool checkOnly = false) {
        await RequireIdle(); var target = LaunchRequest.InputPath(path); await Run("apply", "--check", "--", target);
        if (!checkOnly) await Run("apply", "--", target);
    }
    public async Task<string> Worktrees() => await Run("worktree", "list", "--porcelain");
    public async Task AddWorktree(string path, string branch) {
        await RequireIdle(); var target = LaunchRequest.InputPath(path);
        if (File.Exists(target) || Directory.Exists(target)) throw new InvalidOperationException(Localization.Text("作成先には、存在しないフォルダを指定してください。"));
        await Run("worktree", "add", "-b", await ValidateBranch(branch), "--", target, "HEAD");
    }
    public async Task<string> Submodules() => await Run("submodule", "status", "--recursive");
    public async Task AddSubmodule(string source, string destination) {
        await RequireClean(); FilePath(destination);
        if (string.IsNullOrWhiteSpace(source) || source.StartsWith('-') || string.IsNullOrWhiteSpace(destination)) throw new InvalidOperationException(Localization.Text("取得元とリポジトリ内の作成先を指定してください。"));
        await Run("submodule", "add", "--", source, destination);
    }
    public async Task UpdateSubmodules() { await RequireClean(); await Run("submodule", "update", "--init", "--recursive"); }
}
