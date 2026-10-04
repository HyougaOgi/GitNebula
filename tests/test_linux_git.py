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
                self.assertEqual(repo.path, str(root))
                self.assertEqual(repo.changes(), [])


if __name__ == '__main__': unittest.main()
