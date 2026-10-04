"""Context-menu requests must preserve paths and bound the commit selection."""
import ast
import pathlib
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Linux'))
from actions import ACTIONS, LaunchRequest

class ActionTests(unittest.TestCase):
    def test_parse_and_scope(self):
        request = LaunchRequest.parse(['--action', 'commit', '--', '/repo/星 雲.txt', '/repo/src'])
        self.assertEqual(request.action, 'commit')
        self.assertTrue(request.includes('星 雲.txt', '/repo'))
        self.assertTrue(request.includes('src/nested/file', '/repo'))
        self.assertFalse(request.includes('src-other/file', '/repo'))
        self.assertFalse(request.includes('other', '/repo'))
        self.assertEqual(LaunchRequest.parse(['--open', '/repo']).paths, ('/repo',))
        self.assertEqual(LaunchRequest.parse(['/repo']).action, 'open')
        self.assertEqual(LaunchRequest.parse(['--action', 'diff', '--path', '/repo/-a']).paths, ('/repo/-a',))

    def test_invalid_action_is_rejected(self):
        import contextlib
        import io
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            LaunchRequest.parse(['--action', 'reset', '--path', '/repo'])

    def test_install_upgrade_and_uninstall(self):
        installer = pathlib.Path(__file__).resolve().parents[1] / 'Linux/install.py'
        with tempfile.TemporaryDirectory(prefix='nebula install ') as temporary:
            prefix = pathlib.Path(temporary) / "space '星 $folder"
            def install(*args):
                subprocess.run([sys.executable, str(installer), '--prefix', str(prefix), *args], check=True, capture_output=True)
            install(); install()
            provider = prefix / 'share/nautilus-python/extensions/gitnebula.py'
            tree = ast.parse(provider.read_text())
            assignments = {node.targets[0].id: ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)}
            self.assertEqual(assignments['LAUNCHER'], str(prefix / 'bin/gitnebula'))
            self.assertEqual({a for a, _ in assignments['ACTIONS']}, set(ACTIONS) - {'open'})
            service = (prefix / 'share/kio/servicemenus/gitnebula.desktop').read_text()
            for action in set(ACTIONS) - {'open'}:
                self.assertIn(f'--action {action} -- %F', service)
            self.assertIn('MimeType=all/allfiles;inode/directory;', service)
            launcher = prefix / 'bin/gitnebula'
            result = subprocess.run([str(launcher), '--help'], capture_output=True)
            # Argument parsing must work even if GTK is not installed (see main.py).
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            (prefix / 'share/gitnebula/user-note').write_text('keep')
            install('--uninstall')
            self.assertFalse(provider.exists()); self.assertFalse(launcher.exists())
            self.assertTrue((prefix / 'share/gitnebula/user-note').exists())

if __name__ == '__main__': unittest.main()
