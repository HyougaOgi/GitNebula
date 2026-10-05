using System.IO;
namespace GitNebula;

public sealed record LaunchRequest(string Action, string[] Paths)
{
    public static readonly Dictionary<string, (string Title, string Hint)> Actions = new()
    {
        ["open"] = ("ようこそ", "リポジトリを開き、メニューから使いたい機能を選んでください。"),
        ["commit"] = ("変更をコミット", "ファイルを確認して、メッセージを入力するだけ。"),
        ["diff"] = ("差分を確認", "ファイルを選ぶと変更内容が表示されます。"),
        ["log"] = ("履歴を表示", "コミット・ブランチ・タグの履歴を確認できます。"),
        ["cherry-pick"] = ("コミットを取り込む（Cherry-pick）", "履歴からコミットを選び、現在のブランチに変更を取り込みます。"),
        ["revert"] = ("コミットを取り消す（Revert）", "履歴からコミットを選び、変更を打ち消す新しいコミットを作ります。"),
        ["pull"] = ("変更を受信（Pull）", "現在のブランチを更新します（fast-forward のみ）。"),
        ["push"] = ("変更を送信（Push）", "現在のブランチのコミットをリモートに送信します。"),
        ["fetch"] = ("リモートを更新（Fetch）", "最新情報を取得します。作業ファイルは変更しません。"),
        ["switch"] = ("ブランチを切り替え", "切り替え先を選んで実行します。"),
        ["clone"] = ("リポジトリを複製（Clone）", "取得元と、新しく作るフォルダを指定してください。"),
        ["workspace"] = ("リポジトリの管理", "作業ファイル、ブランチ、設定を開きます。"),
        ["files"] = ("作業ファイルの管理", "選択したファイルをステージ、またはステージ解除します。"),
        ["branches"] = ("ブランチの管理", "ブランチを作成、切替、名前変更、削除できます。"),
        ["conflicts"] = ("競合の解決", "競合ファイルを解決し、進行中の操作を再開または中止します。"),
        ["merge"] = ("ブランチの変更を取り込む（Merge）", "選択したブランチを現在のブランチにマージします。"),
        ["rebase"] = ("ブランチの起点を移す（Rebase）", "現在のブランチのコミットを新しい起点につなぎ直します。コミット ID が変わります。"),
        ["stash"] = ("変更を一時退避する（Stash）", "変更を一時保存し、後で戻します。"),
        ["tags"] = ("タグを管理", "リリースなどの目印をコミットに付けます。"),
        ["remotes"] = ("リモートを設定", "送受信先の URL を登録、変更、削除します。"),
        ["identity"] = ("コミット作成者の設定", "このリポジトリで使う名前とメールアドレスを設定します。"),
        ["settings"] = ("アプリの設定", "常駐と Git の実行ファイルを設定します。"),
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
