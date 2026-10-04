"""The file-manager/CLI contract; independent of GTK so launchers can reuse it."""
import argparse
import os
from dataclasses import dataclass
from pathlib import Path

ACTIONS = {
    'open': ('Git 操作を選択', 'ファイルマネージャーの右クリックから、必要な操作を直接開けます。'),
    'commit': ('変更をコミット', 'ファイルを確認して、メッセージを入力するだけ。'),
    'diff': ('差分を確認', 'ファイルを選ぶと変更内容が表示されます。'),
    'log': ('履歴を表示', 'コミット・ブランチ・タグの履歴を確認できます。'),
    'pull': ('変更を受信（Pull）', '現在のブランチを更新します（fast-forward のみ）。'),
    'push': ('変更を送信（Push）', '現在のブランチのコミットをリモートに送信します。'),
    'fetch': ('リモートを更新（Fetch）', '最新情報を取得します。作業ファイルは変更しません。'),
    'switch': ('ブランチを切り替え', '切り替え先を選んで実行します。'),
    'clone': ('リポジトリを複製（Clone）', '取得元と、新しく作るフォルダを指定してください。'),
    'workspace': ('詳細操作', 'ブランチ管理とマージの操作。'),
}

@dataclass(frozen=True)
class LaunchRequest:
    action: str = 'open'
    paths: tuple[str, ...] = ()

    @classmethod
    def parse(cls, arguments):
        parser = argparse.ArgumentParser(description='GitNebula: right-click Git actions')
        parser.add_argument('--action', choices=ACTIONS, default='open')
        parser.add_argument('--path', '--open', action='append', default=[])
        parser.add_argument('paths', nargs='*')
        args = parser.parse_args(arguments)
        return cls(args.action, tuple(os.path.abspath(p) for p in args.path + args.paths))

    def includes(self, file, root):
        # Resolve ancestor aliases (e.g. /tmp on macOS), not a tracked symlink itself.
        def normalize(path):
            absolute = os.path.abspath(path)
            return os.path.join(os.path.realpath(os.path.dirname(absolute)), os.path.basename(absolute))
        target = normalize(os.path.join(root, file))
        return not self.paths or any(target == p or target.startswith(p.rstrip(os.sep) + os.sep)
                                     for p in map(normalize, self.paths))

    @staticmethod
    def directory(path):
        return str(Path(path).parent) if Path(path).is_file() or Path(path).is_symlink() else path
