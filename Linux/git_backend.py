"""Linux-native Git operations. No shell interpolation or global Git changes."""
import os
import subprocess
from pathlib import Path
import tempfile
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
        entries = iter(self.run('status', '--porcelain=v1', '-z', '--untracked-files=all').split('\0'))
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
        changes = self.changes()
        if path not in [item.path for item in changes]:
            raise ValueError('変更一覧にないファイルです')
        if any(item.path == path and item.code == '??' for item in changes):
            return self.read_file(path)
        try:
            self.run('rev-parse', '--verify', 'HEAD')
        except RuntimeError:
            return self.run('--literal-pathspecs', 'diff', '--cached', '--', path, for_display=True) or '初回コミット前のファイルです。'
        return self.run('--literal-pathspecs', 'diff', 'HEAD', '--', path, for_display=True) or '未追跡ファイル、またはテキスト差分のない変更です。'

    def commit(self, paths, message):
        if self.conflicts() or self.merge_in_progress():
            raise ValueError('競合を解決し、「マージ完了」を使ってください')
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

    @classmethod
    def clone(cls, source, destination):
        if not source.strip() or not destination.strip():
            raise ValueError('取得元と作成先を指定してください')
        target = Path(destination).expanduser().absolute()
        if target.exists():
            raise ValueError('作成先には存在しないフォルダを指定してください')
        # git clone creates only the requested directory, never overwrites a checkout.
        runner = cls.__new__(cls)
        runner.path = str(target.parent)
        runner.run('clone', '--', source, str(target))
        return cls(str(target))

    def graph(self):
        if not self.run('rev-list', '--all', '--max-count=1').strip():
            return 'まだコミットはありません。'
        return self.run('log', '--graph', '--all', '--decorate', '--oneline', '-100',
                        '--no-color', for_display=True)

    def branches(self):
        return self.run('for-each-ref', '--format=%(refname:short)', 'refs/heads').splitlines()

    def remotes(self):
        return self.run('remote').splitlines()

    def remote(self, name):
        if name not in self.remotes() or name.startswith('-'):
            raise ValueError('登録済みのリモートを指定してください')
        return name

    def validate_branch(self, name):
        if not name or name.startswith('-'):
            raise ValueError('有効なブランチ名を指定してください')
        self.run('check-ref-format', '--branch', name)
        return name

    def require_clean(self):
        if self.changes() or self.merge_in_progress():
            raise ValueError('変更をコミットし、進行中のマージを完了してから操作してください')

    def fetch(self, remote):
        return self.run('fetch', '--prune', self.remote(remote))

    def pull(self, remote):
        self.require_clean()
        branch = self.run('symbolic-ref', '--short', 'HEAD').strip()
        return self.run('pull', '--ff-only', self.remote(remote), self.validate_branch(branch))

    def push(self, remote):
        branch = self.run('symbolic-ref', '--short', 'HEAD').strip()
        self.validate_branch(branch)
        return self.run('push', '--set-upstream', self.remote(remote), f'HEAD:refs/heads/{branch}')

    def create_branch(self, name):
        self.require_clean()
        return self.run('switch', '-c', self.validate_branch(name))

    def switch_branch(self, name):
        self.require_clean()
        if name not in self.branches(): raise ValueError('ローカルブランチを選択してください')
        return self.run('switch', '--', self.validate_branch(name))

    def rename_branch(self, old, new):
        return self.run('branch', '-m', self.validate_branch(old), self.validate_branch(new))

    def delete_branch(self, name):
        return self.run('branch', '-d', '--', self.validate_branch(name))

    def merge(self, name):
        self.require_clean()
        return self.run('merge', '--no-edit', '--', self.validate_branch(name))

    def merge_in_progress(self):
        file = self.run('rev-parse', '--path-format=absolute', '--git-path', 'MERGE_HEAD').removesuffix('\n')
        return Path(file).is_file()

    def conflicts(self):
        return [p for p in self.run('diff', '--name-only', '--diff-filter=U', '-z').split('\0') if p]

    def file_path(self, path):
        root = Path(self.path).resolve()
        file = root / path
        if Path(path).is_absolute() or '..' in Path(path).parts:
            raise ValueError('リポジトリ内のファイルを指定してください')
        # Do not follow a directory symlink out of the checkout.
        file.parent.resolve().relative_to(root)
        return file

    def read_file(self, path, editable=False):
        file = self.file_path(path)
        if file.is_symlink():
            if editable: raise ValueError('シンボリックリンクは外部で解決してください')
            return 'シンボリックリンク → ' + os.readlink(file)
        if not file.exists(): return ''
        if file.stat().st_size > 1024 * 1024:
            if editable: raise ValueError('1 MiB を超えるファイルは外部エディタで解決してください')
            return 'プレビュー上限の 1 MiB を超えています。'
        data = file.read_bytes()
        if b'\0' in data:
            if editable: raise ValueError('バイナリファイルは外部で解決してください')
            return 'バイナリファイルです。'
        try: return data.decode('utf-8')
        except UnicodeDecodeError:
            if editable: raise ValueError('UTF-8 以外のファイルは外部エディタで解決してください')
            return '注意: UTF-8 で読めない文字を � に置き換えて表示しています。\n\n' + data.decode('utf-8', errors='replace')

    def conflict_text(self, path):
        if path not in self.conflicts(): raise ValueError('競合中のファイルを選択してください')
        return self.read_file(path, editable=True)

    def save_resolution(self, path, text):
        self.conflict_text(path)
        if any(line.startswith(('<<<<<<< ', '=======', '>>>>>>> ')) for line in text.splitlines()):
            raise ValueError('競合マーカーを取り除いてください')
        file = self.file_path(path)
        mode = file.stat().st_mode if file.exists() else 0o644
        fd, temporary = tempfile.mkstemp(dir=file.parent, prefix='.gitnebula-')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', newline='') as stream: stream.write(text)
            os.chmod(temporary, mode)
            os.replace(temporary, file)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
        self.mark_resolved(path)

    def mark_resolved(self, path):
        if path not in self.conflicts(): raise ValueError('競合中のファイルを選択してください')
        return self.run('--literal-pathspecs', 'add', '-A', '--', path)

    def finish_merge(self, message):
        if not self.merge_in_progress() or self.conflicts():
            raise ValueError('マージ中のすべての競合を解決してください')
        if not message.strip(): raise ValueError('コミットメッセージを入力してください')
        return self.run('commit', '-m', message)

    def abort_merge(self):
        if not self.merge_in_progress(): raise ValueError('進行中のマージはありません')
        return self.run('merge', '--abort')
