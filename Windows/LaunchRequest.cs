using System.IO;
namespace GitNebula;

public sealed record LaunchRequest(string Action, string[] Paths)
{
    public static Dictionary<string, (string Title, string Hint)> Actions => new()
    {
        ["open"] = ("GitNebula", Localization.Text("アプリの設定を管理します。")),
        ["menu"] = (Localization.Text("Git 操作"), Localization.Text("このリポジトリで行う操作を選んでください。")),
        ["init"] = (Localization.Text("リポジトリを作成（Init）"), Localization.Text("このフォルダに Git リポジトリを作成します。")),
        ["commit"] = ("Commit", Localization.Text("ファイルを確認して、メッセージを入力するだけ。")),
        ["diff"] = (Localization.Text("差分一覧"), Localization.Text("ファイルを選ぶと変更内容が表示されます。")),
        ["graph"] = (Localization.Text("Git グラフ"), Localization.Text("ブランチの分岐・合流とコミットを表示します。")),
        ["log"] = (Localization.Text("履歴"), Localization.Text("コミット・ブランチ・タグの履歴を確認できます。")),
        ["cherry-pick"] = ("Cherry-pick", Localization.Text("履歴からコミットを選び、現在のブランチに変更を取り込みます。")),
        ["revert"] = ("Revert", Localization.Text("履歴からコミットを選び、変更を打ち消す新しいコミットを作ります。")),
        ["pull"] = ("Pull", Localization.Text("現在のブランチを更新します（fast-forward のみ）。")),
        ["push"] = ("Push", Localization.Text("現在のブランチのコミットをリモートに送信します。")),
        ["fetch"] = ("Fetch", Localization.Text("最新情報を取得します。作業ファイルは変更しません。")),
        ["switch"] = (Localization.Text("ブランチを切り替え"), Localization.Text("切り替え先を選んで実行します。")),
        ["clone"] = ("Clone", Localization.Text("保存先の中に、リポジトリ名のフォルダを作って複製します。")),
        ["workspace"] = (Localization.Text("リポジトリの管理"), Localization.Text("作業ファイル、ブランチ、設定を開きます。")),
        ["files"] = (Localization.Text("作業ファイルの管理"), Localization.Text("選択したファイルをステージ、またはステージ解除します。")),
        ["branches"] = (Localization.Text("ブランチの管理"), Localization.Text("ブランチを作成、切替、名前変更、削除できます。")),
        ["conflicts"] = (Localization.Text("競合の解決"), Localization.Text("競合ファイルを解決し、進行中の操作を再開または中止します。")),
        ["merge"] = ("Merge", Localization.Text("選択したブランチを現在のブランチにマージします。")),
        ["rebase"] = ("Rebase", Localization.Text("現在のブランチのコミットを新しい起点につなぎ直します。コミット ID が変わります。")),
        ["stash"] = ("Stash", Localization.Text("変更を一時保存し、後で戻します。")),
        ["tags"] = (Localization.Text("タグを管理"), Localization.Text("リリースなどの目印をコミットに付けます。")),
        ["remotes"] = (Localization.Text("リモートを設定"), Localization.Text("送受信先の URL を登録、変更、削除します。")),
        ["identity"] = (Localization.Text("コミット作成者の設定"), Localization.Text("このリポジトリで使う名前とメールアドレスを設定します。")),
        ["compare"] = (Localization.Text("コミットを比較"), Localization.Text("二つのコミットの変更を比較します。")),
        ["file-history"] = (Localization.Text("ファイルの履歴"), Localization.Text("ファイルの変更履歴を確認します。")),
        ["blame"] = (Localization.Text("Blame"), Localization.Text("各行を変更したコミットを表示します。")),
        ["reflog"] = (Localization.Text("Reflog"), Localization.Text("ブランチと HEAD の移動履歴を表示します。")),
        ["reset"] = (Localization.Text("Reset"), Localization.Text("現在のブランチを指定したコミットへ移動します。")),
        ["patch"] = (Localization.Text("パッチ"), Localization.Text("作業中の変更を保存、確認、適用します。")),
        ["worktrees"] = (Localization.Text("Worktree"), Localization.Text("同じリポジトリを別の作業フォルダで開きます。")),
        ["submodules"] = (Localization.Text("Submodule"), Localization.Text("リポジトリ内に別のリポジトリを追加、更新します。")),
        ["settings"] = (Localization.Text("詳細設定"), Localization.Text("SSH 認証、常駐、Git の実行ファイルを設定します。")),
    };
    public static (string Title, string[] Actions)[] MenuGroups => [
        (Localization.Text("変更"), ["commit", "diff", "stash", "files"]),
        (Localization.Text("履歴"), ["log", "graph", "compare", "file-history", "blame", "reflog", "cherry-pick", "revert", "reset", "patch"]),
        (Localization.Text("ブランチ"), ["switch", "merge", "rebase", "branches", "conflicts", "tags"]),
        (Localization.Text("リモート"), ["fetch", "pull", "push", "remotes"]),
        (Localization.Text("リポジトリ"), ["clone", "init", "workspace", "identity", "worktrees", "submodules"])
    ];
    public static LaunchRequest Parse(string[] arguments)
    {
        var action = "open"; var paths = new List<string>();
        for (var i = 0; i < arguments.Length; i++)
        {
            var value = arguments[i];
            if (value == "--") { paths.AddRange(arguments.Skip(i + 1)); break; }
            if (++i >= arguments.Length) throw new ArgumentException(Localization.Text("起動引数に値がありません。"));
            if (value == "--action" && Actions.ContainsKey(arguments[i])) action = arguments[i];
            else if (value is "--path" or "--open") paths.Add(arguments[i]);
            else throw new ArgumentException(Localization.Text("起動引数が不正です。--action commit --path C:\\repo の形式で指定してください。"));
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
        if (!System.IO.Path.IsPathFullyQualified(path)) throw new ArgumentException(Localization.Text("フォルダの絶対パスを入力してください。"));
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
