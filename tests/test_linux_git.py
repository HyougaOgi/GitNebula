import pathlib
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Linux'))
from git_backend import Repository


class GitTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='gitnebula-')
        self.root = pathlib.Path(self.directory.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.repo = Repository(str(self.root))

    def tearDown(self): self.directory.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args]).decode()

    def test_selected_commit_excludes_already_staged_files(self):
        (self.root / 'space 日本語.txt').write_text('first\n')
        (self.root / 'other.txt').write_text('other\n')
        self.git('add', 'other.txt')
        self.repo.commit(['space 日本語.txt'], 'First orbit')
        self.assertEqual(self.git('-c', 'core.quotepath=false', 'show', '--format=', '--name-only', 'HEAD').strip(), 'space 日本語.txt')
        self.assertIn('other.txt', self.git('diff', '--cached', '--name-only'))
        (self.root / 'space 日本語.txt').write_text('second\n')
        self.assertIn('+second', self.repo.diff('space 日本語.txt'))

    def test_rename_delete_and_literal_pathspec(self):
        for name in ['old.txt', '[abc].txt', 'a.txt']:
            (self.root / name).write_text(name)
        self.repo.commit(['old.txt', '[abc].txt', 'a.txt'], 'initial')
        self.git('mv', 'old.txt', 'new.txt')
        changes = self.repo.changes()
        self.assertEqual(changes[0].path, 'new.txt')
        self.repo.commit(['new.txt'], 'rename')
        self.assertNotIn('old.txt', self.git('ls-tree', '--name-only', 'HEAD'))
        self.assertEqual(self.repo.changes(), [])
        (self.root / '[abc].txt').write_text('new literal content')
        (self.root / 'a.txt').write_text('must stay')
        self.repo.commit(['[abc].txt'], 'literal path')
        self.assertEqual(self.git('show', '--format=', '--name-only', 'HEAD').strip(), '[abc].txt')
        (self.root / 'new.txt').unlink()
        self.repo.commit(['new.txt'], 'delete')
        self.assertFalse(any(item.path == 'new.txt' for item in self.repo.changes()))

    def test_validation_and_non_repository(self):
        self.assertEqual(self.repo.changes(), [])
        with self.assertRaises(ValueError): self.repo.commit([], 'no files')
        with self.assertRaises(ValueError): self.repo.commit(['missing'], 'message')
        with self.assertRaises(ValueError): self.repo.diff('missing')
        with tempfile.TemporaryDirectory() as other:
            with self.assertRaises(RuntimeError): Repository(other)

    def test_staged_deletion_preserves_unselected_staged_file(self):
        (self.root / 'deleted.txt').write_text('delete me\n')
        (self.root / 'other.txt').write_text('original\n')
        self.repo.commit(['deleted.txt', 'other.txt'], 'initial')
        self.git('rm', 'deleted.txt')
        (self.root / 'other.txt').write_text('unselected staged change\n')
        self.git('add', 'other.txt')
        self.repo.commit(['deleted.txt'], 'staged deletion')
        self.assertEqual(self.git('show', '--format=', '--name-status', 'HEAD').strip(), 'D\tdeleted.txt')
        self.assertEqual(self.git('show', 'HEAD:other.txt'), 'original\n')
        self.assertEqual(self.git('diff', '--cached', '--name-only').strip(), 'other.txt')

    def test_recreated_rename_source_requires_selection_before_any_mutation(self):
        (self.root / 'old.txt').write_text('original\n')
        self.repo.commit(['old.txt'], 'initial')
        self.git('mv', 'old.txt', 'new.txt')
        (self.root / 'old.txt').write_text('unselected content\n')
        (self.root / 'new.txt').write_text('selected modification\n')
        before = (self.git('rev-parse', 'HEAD'), self.git('write-tree'), self.repo.changes())
        with self.assertRaisesRegex(ValueError, '未選択'):
            self.repo.commit(['new.txt'], 'rename only')
        self.assertEqual(before, (self.git('rev-parse', 'HEAD'), self.git('write-tree'), self.repo.changes()))
        self.assertEqual((self.root / 'old.txt').read_text(), 'unselected content\n')
        self.repo.commit(['new.txt', 'old.txt'], 'explicitly include both')
        self.assertEqual(self.git('show', 'HEAD:old.txt'), 'unselected content\n')
        self.assertEqual(self.git('show', 'HEAD:new.txt'), 'selected modification\n')
        self.assertEqual(self.repo.changes(), [])

    def test_dangling_symlink_at_rename_source_is_not_silently_committed(self):
        (self.root / 'old.txt').write_text('original\n')
        self.repo.commit(['old.txt'], 'initial')
        self.git('mv', 'old.txt', 'new.txt')
        (self.root / 'old.txt').symlink_to('missing-target')
        head, index = self.git('rev-parse', 'HEAD'), self.git('write-tree')
        with self.assertRaisesRegex(ValueError, '未選択'):
            self.repo.commit(['new.txt'], 'rename only')
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)
        self.assertEqual(self.git('write-tree'), index)
        self.assertEqual(os.readlink(self.root / 'old.txt'), 'missing-target')

    def test_legacy_diff_is_displayable_without_changing_file_bytes(self):
        file = self.root / 'legacy.txt'
        file.write_bytes(b'caf\xe9\n')
        self.repo.commit(['legacy.txt'], 'initial')
        file.write_bytes(b'caf\xe9 updated\n')
        diff = self.repo.diff('legacy.txt')
        self.assertIn('UTF-8', diff)
        self.assertIn('+caf\ufffd updated', diff)
        diff.encode('utf-8', errors='strict')
        self.assertEqual(file.read_bytes(), b'caf\xe9 updated\n')

    def test_legacy_diff_before_first_commit_is_displayable(self):
        (self.root / 'legacy.txt').write_bytes(b'caf\xe9\n')
        self.git('add', 'legacy.txt')
        self.assertIn('+caf\ufffd', self.repo.diff('legacy.txt'))

    def test_repository_path_preserves_trailing_whitespace(self):
        for suffix in [' ', '\t', '\n']:
            with self.subTest(suffix=repr(suffix)):
                root = self.root / ('project' + suffix)
                root.mkdir()
                subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
                repo = Repository(str(root))
                self.assertEqual(repo.path, str(root.resolve()))
                self.assertEqual(repo.changes(), [])

    def initial(self):
        (self.root / 'orbit.txt').write_text('base\n')
        self.repo.commit(['orbit.txt'], 'initial')
        return self.repo.branch()

    def test_untracked_preview_binary_limit_and_symlink(self):
        (self.root / 'nested').mkdir()
        (self.root / 'nested' / '日本語.txt').write_text('Hello 星雲\n')
        self.assertIn('Hello 星雲', self.repo.diff('nested/日本語.txt'))
        (self.root / 'binary').write_bytes(b'a\0b')
        self.assertIn('バイナリ', self.repo.diff('binary'))
        (self.root / 'large').write_bytes(b'x' * (1024 * 1024 + 1))
        self.assertIn('1 MiB', self.repo.diff('large'))
        (self.root / 'link').symlink_to('/nonexistent/external')
        self.assertIn('シンボリックリンク', self.repo.diff('link'))

    def test_branch_lifecycle_and_graph(self):
        self.assertIn('ありません', self.repo.graph())
        base = self.initial()
        self.repo.create_branch('feature/orbit')
        self.assertEqual(self.repo.branch(), 'feature/orbit')
        self.repo.rename_branch('feature/orbit', 'feature/stars')
        self.repo.switch_branch(base)
        self.repo.delete_branch('feature/stars')
        self.assertEqual(self.repo.branches(), [base])
        self.assertIn('initial', self.repo.graph())
        (self.root / 'orbit.txt').write_text('dirty\n')
        with self.assertRaises(ValueError): self.repo.create_branch('blocked')
        with self.assertRaises(ValueError): self.repo.switch_branch(base)
        with self.assertRaises(ValueError): self.repo.validate_branch('--help')

    def test_clone_fetch_push_pull_against_local_remote(self):
        base = self.initial()
        with tempfile.TemporaryDirectory(prefix='gitnebula-remotes-') as temporary:
            remote = pathlib.Path(temporary) / 'remote.git'
            subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
            subprocess.run(['git', '-C', str(remote), 'symbolic-ref', 'HEAD', 'refs/heads/' + base], check=True)
            self.git('remote', 'add', 'origin', str(remote))
            self.repo.push('origin')
            clone = Repository.clone(str(remote), str(pathlib.Path(temporary) / 'clone with spaces'))
            self.assertEqual(clone.branches(), [base])
            clone.run('config', 'user.name', 'Test'); clone.run('config', 'user.email', 'test@example.invalid')
            (pathlib.Path(clone.path) / 'orbit.txt').write_text('from clone\n')
            clone.commit(['orbit.txt'], 'remote update'); clone.push('origin')
            self.repo.fetch('origin'); self.repo.pull('origin')
            self.assertEqual((self.root / 'orbit.txt').read_text(), 'from clone\n')
            self.assertIn('remote update', self.repo.graph())
            with self.assertRaises(ValueError): self.repo.fetch('--all')
            with self.assertRaises(ValueError): Repository.clone(str(remote), clone.path)
            # Divergence must be reported without creating a merge or discarding work.
            (self.root / 'orbit.txt').write_text('local divergence\n'); self.repo.commit(['orbit.txt'], 'local')
            (pathlib.Path(clone.path) / 'orbit.txt').write_text('remote divergence\n'); clone.commit(['orbit.txt'], 'remote'); clone.push('origin')
            head = self.git('rev-parse', 'HEAD')
            with self.assertRaises(RuntimeError): self.repo.pull('origin')
            self.assertEqual(self.git('rev-parse', 'HEAD'), head)

    def test_quick_sync_uses_tracking_branch_and_remote(self):
        base = self.initial()
        with tempfile.TemporaryDirectory() as directory:
            remote = pathlib.Path(directory) / 'remote.git'
            subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
            subprocess.run(['git', '-C', str(remote), 'symbolic-ref', 'HEAD', 'refs/heads/' + base], check=True)
            self.git('remote', 'add', 'team', str(remote)); self.repo.push('team')
            self.repo.rename_branch(base, 'local-work')
            self.git('remote', 'add', 'origin', str(remote))
            self.assertEqual(self.repo.preferred_remote(), 'team')
            clone = Repository.clone(str(remote), str(pathlib.Path(directory) / 'clone'))
            clone.run('config', 'user.name', 'Test'); clone.run('config', 'user.email', 'test@example.invalid')
            (pathlib.Path(clone.path) / 'orbit.txt').write_text('upstream\n')
            clone.commit(['orbit.txt'], 'upstream'); clone.push('origin')
            self.repo.pull('team')
            self.assertEqual((self.root / 'orbit.txt').read_text(), 'upstream\n')
            (self.root / 'orbit.txt').write_text('local reply\n'); self.repo.commit(['orbit.txt'], 'reply'); self.repo.push('team')
            clone.pull('origin')
            self.assertEqual((pathlib.Path(clone.path) / 'orbit.txt').read_text(), 'local reply\n')
            self.assertNotIn('local-work', subprocess.check_output(['git', '-C', str(remote), 'branch']).decode())

    def make_conflict(self):
        base = self.initial()
        self.repo.create_branch('incoming')
        (self.root / 'orbit.txt').write_text('incoming\n'); self.repo.commit(['orbit.txt'], 'incoming')
        self.repo.switch_branch(base)
        (self.root / 'orbit.txt').write_text('current\n'); self.repo.commit(['orbit.txt'], 'current')
        with self.assertRaises(RuntimeError): self.repo.merge('incoming')
        self.assertEqual(self.repo.conflicts(), ['orbit.txt'])

    def test_conflict_edit_stage_and_finish_merge(self):
        self.make_conflict()
        self.assertTrue(self.repo.merge_in_progress())
        text = self.repo.conflict_text('orbit.txt')
        self.assertIn('<<<<<<<', text)
        with self.assertRaises(ValueError): self.repo.save_resolution('orbit.txt', text)
        with self.assertRaises(ValueError): self.repo.commit(['orbit.txt'], 'not a merge')
        self.repo.save_resolution('orbit.txt', 'resolved\n')
        self.assertEqual(self.repo.conflicts(), [])
        self.repo.finish_merge('merge resolved')
        self.assertFalse(self.repo.merge_in_progress())
        self.assertEqual(len(self.git('rev-list', '--parents', '-1', 'HEAD').split()), 3)
        self.assertEqual((self.root / 'orbit.txt').read_text(), 'resolved\n')
        self.assertIn('incoming', self.repo.graph())

    def test_conflict_external_deletion_and_abort(self):
        self.make_conflict(); self.repo.abort_merge()
        self.assertEqual((self.root / 'orbit.txt').read_text(), 'current\n')
        with self.assertRaises(RuntimeError): self.repo.merge('incoming')
        (self.root / 'orbit.txt').unlink(); self.repo.mark_resolved('orbit.txt')
        self.repo.finish_merge('resolved by deletion')
        self.assertFalse((self.root / 'orbit.txt').exists())


if __name__ == '__main__': unittest.main()
