"""Linux-native Git operations. No shell interpolation or global Git changes."""
import os
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class Change:
    code: str
    path: str
    original: str | None = None


class Repository:
    def __init__(self, path):
        self.path = path
        self.path = self.run('rev-parse', '--show-toplevel').removesuffix('\n')

    def run(self, *args, for_display=False):
        result = subprocess.run(['git', '-C', self.path, *args], capture_output=True,
                                env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'})
        if result.returncode:
            raise RuntimeError(result.stderr.decode('utf-8', errors='replace').strip())
        if for_display:
            try:
                return result.stdout.decode('utf-8')
            except UnicodeDecodeError:
                return ('注意: UTF-8 で読めない文字を � に置き換えて表示しています。\n\n'
                        + result.stdout.decode('utf-8', errors='replace'))
        # Preserve undecodable filename bytes when passing paths back to Git.
        return result.stdout.decode('utf-8', errors='surrogateescape')

    def changes(self):
        entries = iter(self.run('status', '--porcelain=v1', '-z').split('\0'))
        changes = []
        for entry in entries:
            if not entry:
                continue
            code = entry[:2]
            original = None
            if 'R' in code or 'C' in code:
                original = next(entries, None)
            changes.append(Change(code, entry[3:], original))
        return changes

    def branch(self):
        try:
            return self.run('symbolic-ref', '--short', 'HEAD').strip()
        except RuntimeError:
            return 'detached HEAD'

    def diff(self, path):
        if path not in [item.path for item in self.changes()]:
            raise ValueError('変更一覧にないファイルです')
        try:
            self.run('rev-parse', '--verify', 'HEAD')
        except RuntimeError:
            return self.run('--literal-pathspecs', 'diff', '--cached', '--', path, for_display=True) or '初回コミット前のファイルです。'
        return self.run('--literal-pathspecs', 'diff', 'HEAD', '--', path, for_display=True) or '未追跡ファイル、またはテキスト差分のない変更です。'

    def commit(self, paths, message):
        if not message.strip():
            raise ValueError('コミットメッセージを入力してください')
        changes = self.changes()
        available = {item.path for item in changes}
        if not paths or any(path not in available for path in paths):
            raise ValueError('変更ファイルを選択してください')
        paths = list(dict.fromkeys(paths))
        originals = [item.original for item in changes
                     if item.path in paths and item.original and 'R' in item.code]
        for original in originals:
            if original not in paths and os.path.lexists(os.path.join(self.path, original)):
                raise ValueError(f'リネーム元に未選択のファイルがあります: {original}。'
                                 'そのファイルも含める場合は選択してください。'
                                 '含めない場合は元の場所から移して再実行してください。')
        # Already staged deletions are absent from both the index and worktree.
        # They can be committed directly, but git add rejects their pathspecs.
        deleted = {item.path for item in changes if item.code[0] == 'D'}
        to_stage = [path for path in paths
                    if path not in deleted or os.path.lexists(os.path.join(self.path, path))]
        if to_stage:
            self.run('--literal-pathspecs', 'add', '--', *to_stage)
        commit_paths = list(dict.fromkeys(paths + originals))
        return self.run('--literal-pathspecs', 'commit', '--only', '-m', message, '--', *commit_paths)
