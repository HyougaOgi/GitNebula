using System.IO;
namespace GitNebula;

public static class CloneLocation
{
    public static string RepositoryName(string source)
    {
        var path = source.Trim().Replace('\\', '/');
        if (path.Contains("://") && Uri.TryCreate(path, UriKind.Absolute, out var url)) path = Uri.UnescapeDataString(url.AbsolutePath);
        var name = path.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        if (!path.Contains('/') && name.LastIndexOf(':') is var colon && colon >= 0) name = name[(colon + 1)..];
        if (name.EndsWith(".git", StringComparison.Ordinal)) name = name[..^4];
        return name is "." or ".." ? "" : name;
    }

    public static string Destination(string parent, string source)
    {
        var folder = RepositoryName(source);
        if (folder.Length == 0 || folder is "." or ".." || folder.IndexOfAny("<>:\"/\\|?*\0".ToCharArray()) >= 0 || folder.EndsWith('.') || folder.Any(char.IsControl))
            throw new ArgumentException(Localization.Text("取得元からリポジトリ名を取得できません。取得元の URL / パスを確認してください。"));
        if (string.IsNullOrWhiteSpace(parent) || !Path.IsPathFullyQualified(parent)) throw new ArgumentException(Localization.Text("保存先に絶対パスを指定してください。"));
        return Path.Combine(Path.GetFullPath(parent), folder);
    }
}
