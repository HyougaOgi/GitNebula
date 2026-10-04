using System.IO;
namespace GitNebula;

public sealed record LaunchRequest(string Action, string[] Paths)
{
    public static readonly Dictionary<string, (string Title, string Hint)> Actions = new()
    {
        ["open"] = ("Git 操作を選択", "エクスプローラーの右クリックから、必要な操作を直接開けます。"),
        ["commit"] = ("変更をコミット", "ファイルを確認して、メッセージを入力するだけ。"),
        ["diff"] = ("差分を確認", "ファイルを選ぶと変更内容が表示されます。"),
        ["log"] = ("履歴を表示", "コミット・ブランチ・タグの履歴を確認できます。"),
        ["pull"] = ("変更を受信（Pull）", "現在のブランチを更新します（fast-forward のみ）。"),
        ["push"] = ("変更を送信（Push）", "現在のブランチのコミットをリモートに送信します。"),
        ["fetch"] = ("リモートを更新（Fetch）", "最新情報を取得します。作業ファイルは変更しません。"),
        ["switch"] = ("ブランチを切り替え", "切り替え先を選んで実行します。"),
        ["clone"] = ("リポジトリを複製（Clone）", "取得元と、新しく作るフォルダを指定してください。"),
        ["workspace"] = ("詳細操作", "ブランチ管理とマージの操作。"),
    };
    public static LaunchRequest Parse(string[] arguments)
    {
        var action = "open"; var paths = new List<string>();
        for (var i = 0; i < arguments.Length; i++)
        {
            var value = arguments[i];
            if (value == "--") { paths.AddRange(arguments.Skip(i + 1)); break; }
            if (++i >= arguments.Length) throw new ArgumentException("起動引数に値がありません。");
            if (value == "--action" && Actions.ContainsKey(arguments[i])) action = arguments[i];
            else if (value is "--path" or "--open") paths.Add(arguments[i]);
            else throw new ArgumentException("起動引数が不正です。--action commit --path C:\\repo の形式で指定してください。");
        }
        return new(action, paths.Select(Path.GetFullPath).ToArray());
    }
    public static string DirectoryFor(string path) => File.Exists(path) ? Path.GetDirectoryName(path)! : path;
    public static string InputPath(string input)
    {
        var path = input.Trim();
        if (path.Length >= 2 && path[0] == path[^1] && path[0] is '\"' or '\'') path = path[1..^1];
        if (Uri.TryCreate(path, UriKind.Absolute, out var uri) && uri.IsFile) path = uri.LocalPath;
        if (path == "~" || path.StartsWith("~/") || path.StartsWith("~\\"))
            path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + path[1..];
        if (!System.IO.Path.IsPathFullyQualified(path)) throw new ArgumentException("フォルダの絶対パスを入力してください。");
        return System.IO.Path.GetFullPath(path);
    }
    public bool Includes(string file, string root)
    {
        var target = Path.GetFullPath(Path.Combine(root, file));
        return Paths.Length == 0 || Paths.Any(value => {
            var path = Path.GetFullPath(value);
            return target.Equals(path, StringComparison.OrdinalIgnoreCase) || target.StartsWith(Path.TrimEndingDirectorySeparator(path) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        });
    }
}
