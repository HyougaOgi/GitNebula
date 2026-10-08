"""The file-manager/CLI contract; independent of GTK so launchers can reuse it."""

import argparse
import os
from dataclasses import dataclass
from pathlib import Path

ACTIONS = {
    "open": ("GitNebula", ""),
    "menu": ("Git 操作", "このリポジトリで行う操作を選んでください。"),
    "commit": ("変更をコミット", "ファイルを確認して、メッセージを入力するだけ。"),
    "diff": ("差分を確認", "ファイルを選ぶと変更内容が表示されます。"),
    "log": ("履歴を表示", "コミット・ブランチ・タグの履歴を確認できます。"),
    "pull": ("変更を受信（Pull）", "現在のブランチを更新します（fast-forward のみ）。"),
    "push": ("変更を送信（Push）", "現在のブランチのコミットをリモートに送信します。"),
    "fetch": (
        "リモートを更新（Fetch）",
        "最新情報を取得します。作業ファイルは変更しません。",
    ),
    "switch": ("ブランチを切り替え", "切り替え先を選んで実行します。"),
    "clone": ("Clone", "保存先の中に、リポジトリ名のフォルダを作って複製します。"),
    "workspace": ("リポジトリの管理", "作業ファイル、ブランチ、設定を開きます。"),
    "graph": ("Git グラフ", "ブランチの分岐・合流とコミットを表示します。"),
    "cherry-pick": (
        "Cherry-pick",
        "履歴からコミットを選び、現在のブランチに変更を取り込みます。",
    ),
    "revert": (
        "Revert",
        "履歴からコミットを選び、変更を打ち消す新しいコミットを作ります。",
    ),
    "merge": ("Merge", "選択したブランチを現在のブランチにマージします。"),
    "rebase": (
        "Rebase",
        "現在のブランチのコミットを新しい起点につなぎ直します。コミット ID が変わります。",
    ),
    "stash": ("Stash", "変更を一時保存し、後で戻します。"),
    "files": (
        "作業ファイルの管理",
        "選択したファイルをステージ、またはステージ解除します。",
    ),
    "branches": ("ブランチの管理", "ブランチを作成、切替、名前変更、削除できます。"),
    "conflicts": (
        "競合の解決",
        "競合ファイルを解決し、進行中の操作を再開または中止します。",
    ),
    "tags": ("タグを管理", "リリースなどの目印をコミットに付けます。"),
    "remotes": ("リモートを設定", "送受信先の URL を登録、変更、削除します。"),
    "identity": (
        "コミット作成者の設定",
        "このリポジトリで使う名前とメールアドレスを設定します。",
    ),
    "init": ("リポジトリを作成（Init）", "このフォルダに Git リポジトリを作成します。"),
    "compare": ("コミットを比較", "二つのコミットの変更を比較します。"),
    "file-history": ("ファイルの履歴", "ファイルの変更履歴を確認します。"),
    "blame": ("Blame", "各行を変更したコミットを表示します。"),
    "reflog": ("Reflog", "ブランチと HEAD の移動履歴を表示します。"),
    "reset": ("Reset", "現在のブランチを指定したコミットへ移動します。"),
    "patch": ("パッチ", "作業中の変更を保存、確認、適用します。"),
    "worktrees": ("Worktree", "同じリポジトリを別の作業フォルダで開きます。"),
    "submodules": ("Submodule", "リポジトリ内に別のリポジトリを追加、更新します。"),
    "settings": ("詳細設定", "SSH 認証、表示、言語、起動オプションを設定します。"),
}
MENU_GROUPS = (
    ("変更", ("commit", "diff", "stash", "files")),
    (
        "履歴",
        (
            "log",
            "graph",
            "compare",
            "file-history",
            "blame",
            "reflog",
            "cherry-pick",
            "revert",
            "reset",
            "patch",
        ),
    ),
    ("ブランチ", ("switch", "merge", "rebase", "branches", "conflicts", "tags")),
    ("リモート", ("fetch", "pull", "push", "remotes")),
    (
        "リポジトリ",
        ("clone", "init", "workspace", "identity", "worktrees", "submodules"),
    ),
)


@dataclass(frozen=True)
class LaunchRequest:
    action: str = "open"
    paths: tuple[str, ...] = ()

    @classmethod
    def parse(cls, arguments):
        parser = argparse.ArgumentParser(
            description="GitNebula: right-click Git actions"
        )
        parser.add_argument("--action", choices=ACTIONS, default="open")
        parser.add_argument("--path", "--open", action="append", default=[])
        parser.add_argument("--clone-parent", action="store_true")
        parser.add_argument("paths", nargs="*")
        args = parser.parse_args(arguments)
        paths = tuple(os.path.abspath(p) for p in args.path + args.paths)
        if args.clone_parent and args.action == "clone":
            paths = tuple(str(Path(path).parent) for path in paths)
        action = "menu" if args.action == "open" and paths else args.action
        return cls(action, paths)

    def includes(self, file, root):
        # Resolve ancestor aliases (e.g. /tmp on macOS), not a tracked symlink itself.
        def normalize(path):
            absolute = os.path.abspath(path)
            return os.path.join(
                os.path.realpath(os.path.dirname(absolute)), os.path.basename(absolute)
            )

        target = normalize(os.path.join(root, file))
        return not self.paths or any(
            target == p or target.startswith(p.rstrip(os.sep) + os.sep)
            for p in map(normalize, self.paths)
        )

    @staticmethod
    def directory(path):
        return (
            str(Path(path).parent)
            if Path(path).is_file() or Path(path).is_symlink()
            else path
        )
