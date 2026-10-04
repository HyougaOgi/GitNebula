using System.Diagnostics;
using System.IO;
namespace GitNebula;
public record Change(string Code, string Path, string? Original);
public sealed class GitRepository(string path)
{
    public string Path { get; private set; } = path;
    public async Task<string> Run(params string[] args)
    {
        var info = new ProcessStartInfo("git") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true, StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8 };
        info.Environment["GIT_TERMINAL_PROMPT"] = "0";
        info.ArgumentList.Add("-C"); info.ArgumentList.Add(Path);
        foreach (var arg in args) info.ArgumentList.Add(arg);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Git を起動できません。");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var stderr = await error; var stdout = await output;
        if (process.ExitCode != 0) throw new InvalidOperationException(stderr.Trim());
        return stdout;
    }
    public async Task Open() => Path = (await Run("rev-parse", "--show-toplevel")).TrimEnd('\r', '\n');
    public async Task<List<Change>> Changes()
    {
        var entries = (await Run("status", "--porcelain=v1", "-z")).Split('\0');
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
    public async Task<string> Branch()
    {
        try { return (await Run("symbolic-ref", "--short", "HEAD")).Trim(); }
        catch (InvalidOperationException) { return "detached HEAD"; }
    }
    public async Task<string> Diff(string file)
    {
        if (!(await Changes()).Any(item => item.Path == file)) throw new InvalidOperationException("変更一覧にないファイルです。");
        try { await Run("rev-parse", "--verify", "HEAD"); }
        catch (InvalidOperationException) { return "初回コミット前のファイルです。"; }
        var text = await Run("--literal-pathspecs", "diff", "HEAD", "--", file);
        return text.Length == 0 ? "未追跡ファイル、またはテキスト差分のない変更です。" : text;
    }
    public async Task Commit(string[] paths, string message)
    {
        var changes = await Changes();
        var available = changes.Select(item => item.Path).ToHashSet();
        if (paths.Length == 0 || paths.Any(path => !available.Contains(path)) || string.IsNullOrWhiteSpace(message)) throw new InvalidOperationException("変更ファイルとメッセージを指定してください。");
        paths = paths.Distinct().ToArray();
        var originals = changes.Where(item => paths.Contains(item.Path) && item.Code.Contains('R') && item.Original != null).Select(item => item.Original!).ToArray();
        foreach (var original in originals)
            if (!paths.Contains(original) && EntryExists(original))
                throw new InvalidOperationException($"リネーム元に未選択のファイルがあります: {original}。そのファイルも含める場合は選択してください。含めない場合は元の場所から移して再実行してください。");
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
}
