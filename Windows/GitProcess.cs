using System.ComponentModel;
using System.Diagnostics;
using System.Text;
namespace GitNebula;

public static class GitProcess
{
    public static string Executable
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(AppSettings.Current.GitExecutable)) return AppSettings.Current.GitExecutable;
            // Explorer's inherited PATH may predate a Git installation.
            var names = OperatingSystem.IsWindows() ? new[] { "git.exe" } : new[] { "git" };
            foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(System.IO.Path.PathSeparator))
                foreach (var name in names)
                {
                    var candidate = System.IO.Path.Combine(directory.Trim('"'), name);
                    if (System.IO.File.Exists(candidate)) return candidate;
                }
            foreach (var directory in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) })
                foreach (var suffix in new[] { "Git/cmd/git.exe", "Programs/Git/cmd/git.exe" })
                {
                    var candidate = System.IO.Path.Combine(directory, suffix);
                    if (System.IO.File.Exists(candidate)) return candidate;
                }
            return "git";
        }
    }
    public static string[] Lines(string output) => output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.TrimEnd('\r')).Where(line => line.Length > 0).ToArray();
    public static Task<string> Run(string path, params string[] arguments) => RunAccepting(path, arguments, [0]);
    public static async Task<string> RunAccepting(string path, string[] arguments, int[] accepting) => (await RunWithOutput(path, arguments, accepting)).Output;
    public static async Task<(string Output, string Diagnostics)> RunWithOutput(string path, string[] arguments, int[] accepting, Action<TransferProgress>? progress = null)
    {
        var info = new ProcessStartInfo(Executable) {
            UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true, CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = path
        };
        info.Environment["GIT_TERMINAL_PROMPT"] = "0";
        info.Environment["GIT_EDITOR"] = "true";
        info.Environment["GIT_SEQUENCE_EDITOR"] = "true";
        using var ssh = new SSHConfiguration();
        var sshArguments = ssh.Configure(info, AppSettings.Current.SshKeyPath);
        foreach (var arg in new[] { "--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=false" }.Concat(sshArguments).Concat(new[] { "-C", path }).Concat(arguments)) info.ArgumentList.Add(arg);
        using var process = new Process { StartInfo = info };
        try { process.Start(); }
        catch (Win32Exception error) { throw new InvalidOperationException(Localization.Format($"Git を起動できません（{Executable}）。設定で Git の実行ファイルを確認してください。\n{error.Message}"), error); }
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync();
        async Task<string> ReadDiagnostics() {
            var diagnostics = new StringBuilder(); var buffer = new char[4096];
            var parser = progress == null ? null : new TransferProgressParser(progress);
            int count;
            while ((count = await process.StandardError.ReadAsync(buffer.AsMemory())) > 0) {
                var chunk = new string(buffer, 0, count); diagnostics.Append(chunk); parser?.Feed(chunk);
            }
            parser?.Finish(); return diagnostics.ToString();
        }
        var errorOutput = ReadDiagnostics();
        await process.WaitForExitAsync();
        var stdout = await output; var stderr = await errorOutput;
        if (!accepting.Contains(process.ExitCode)) {
            var hint = stderr.Contains("Permission denied (publickey)") || stderr.Contains("Load key") || stderr.Contains("Host key verification failed") ? Localization.Text("\n詳細設定の「SSH 認証」で秘密鍵とパスフレーズを確認してください。") : "";
            throw new InvalidOperationException(Localization.Format($"git {arguments.FirstOrDefault()} が失敗しました（終了コード {process.ExitCode}）。\n{stdout}{stderr}{hint}"));
        }
        return (stdout, stderr);
    }
}
