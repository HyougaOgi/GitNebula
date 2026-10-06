using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
namespace GitNebula;

public static class SSHCredentialStore
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public uint BlobSize;
        public IntPtr Blob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Write(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ReadNative(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Delete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr credential);
    private static string Target(string key) => "GitNebula/SSH/" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(key).ToUpperInvariant())));
    public static string? Read(string key)
    {
        if (!ReadNative(Target(key), 1, 0, out var pointer)) {
            if (Marshal.GetLastWin32Error() == 1168) return null;
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SSH パスフレーズを資格情報マネージャーから読み込めません。");
        }
        try { var credential = Marshal.PtrToStructure<Credential>(pointer); return Marshal.PtrToStringUni(credential.Blob, (int)credential.BlobSize / 2); }
        finally { CredFree(pointer); }
    }
    public static void Save(string key, string passphrase)
    {
        var bytes = Encoding.Unicode.GetBytes(passphrase);
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        try {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
            var credential = new Credential { Type = 1, TargetName = Target(key), BlobSize = (uint)bytes.Length, Blob = pointer, Persist = 2, UserName = Environment.UserName };
            if (!Write(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SSH パスフレーズを資格情報マネージャーに保存できません。");
        } finally { Array.Clear(bytes); for (var index = 0; index < bytes.Length; index++) Marshal.WriteByte(pointer, index, 0); Marshal.FreeHGlobal(pointer); }
    }
    public static void Remove(string key)
    {
        if (!Delete(Target(key), 1, 0) && Marshal.GetLastWin32Error() != 1168) throw new Win32Exception(Marshal.GetLastWin32Error(), "保存した SSH パスフレーズを削除できません。");
    }
}

public sealed class SSHConfiguration : IDisposable
{
    private string? directory;
    public static bool IsKeyPassphrasePrompt(string prompt, string key)
    {
        prompt = prompt.Replace('\\', '/').Trim(); key = key.Replace('\\', '/');
        return prompt == $"Enter passphrase for key '{key}':" || prompt == $"Enter passphrase for '{key}':" || prompt == $"Enter passphrase for {key}:";
    }
    public string[] Configure(ProcessStartInfo info, string key, string? helperPath = null)
    {
        if (key.Length == 0) return [];
        directory = Path.Combine(Path.GetTempPath(), "gitnebula-ssh-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        var wrapper = Path.Combine(directory, "ssh.sh");
        File.WriteAllText(wrapper, "#!/bin/sh\nexec \"$GITNEBULA_SSH_EXECUTABLE\" -i \"$GITNEBULA_SSH_KEY\" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o NumberOfPasswordPrompts=1 \"$@\"\n", new UTF8Encoding(false));
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(wrapper, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var gitDirectory = Path.GetDirectoryName(GitProcess.Executable) ?? "";
        var candidates = new[] { Path.GetFullPath(Path.Combine(gitDirectory.Length > 0 ? gitDirectory : ".", "../usr/bin/ssh.exe")), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH/ssh.exe") };
        info.Environment.Remove("GIT_SSH_COMMAND");
        info.Environment["GIT_SSH"] = wrapper.Replace('\\', '/'); info.Environment["GIT_SSH_VARIANT"] = "ssh";
        info.Environment["GITNEBULA_SSH_EXECUTABLE"] = (OperatingSystem.IsWindows() ? candidates.FirstOrDefault(File.Exists) ?? "ssh.exe" : "/usr/bin/ssh").Replace('\\', '/');
        info.Environment["GITNEBULA_SSH_KEY"] = key.Replace('\\', '/');
        info.Environment["SSH_ASKPASS"] = (helperPath ?? Environment.ProcessPath ?? "GitNebula.exe").Replace('\\', '/');
        info.Environment["SSH_ASKPASS_REQUIRE"] = "force"; info.Environment["LC_ALL"] = "C";
        if (!info.Environment.ContainsKey("DISPLAY")) info.Environment["DISPLAY"] = "gitnebula";
        return ["-c", "core.sshCommand='" + wrapper.Replace('\\', '/').Replace("'", "'\\''") + "'"];
    }
    public void Dispose() { if (directory != null) Directory.Delete(directory, true); }
}
