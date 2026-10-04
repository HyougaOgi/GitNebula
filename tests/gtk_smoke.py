"""Run on Linux with GTK 4 and DISPLAY set; exercises actual UI callbacks."""
import pathlib
import subprocess
import sys
import tempfile
import time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Linux'))
from main import App, Window, GLib
from git_backend import Repository

with tempfile.TemporaryDirectory(prefix='gitnebula-ui-') as directory:
    root = pathlib.Path(directory)
    def git(*args): return subprocess.check_output(['git', '-C', directory, *args]).decode()
    git('init', '-q'); git('config', 'user.name', 'UI Test'); git('config', 'user.email', 'ui@example.invalid')
    file = root / 'orbit.txt'; file.write_text('first\n')
    repo = Repository(directory); repo.commit(['orbit.txt'], 'initial')
    file.write_text('second\n')
    app = App(); app.register(None)
    window = Window(app); window.present()
    def wait():
        deadline = time.monotonic() + 10
        context = GLib.MainContext.default()
        while window.busy and time.monotonic() < deadline:
            while context.pending(): context.iteration(False)
            time.sleep(.01)
        assert not window.busy, 'GUI operation timed out'
        assert window.status.get_text() == '準備完了', window.status.get_text()
    window.repo = repo
    window.task(window.snapshot, window.render); wait()
    row = window.files.get_first_child().get_child()
    check = row.get_first_child(); button = check.get_next_sibling()
    button.emit('clicked'); wait()
    buffer = window.diff_view.get_buffer()
    assert '+second' in buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
    check.set_active(True); window.message.set_text('UI commit'); window.commit(); wait()
    assert git('log', '-1', '--format=%s').strip() == 'UI commit'
    assert repo.changes() == []
    file.write_bytes(b'caf\xe9 updated\n')
    window.task(window.snapshot, window.render); wait()
    row = window.files.get_first_child().get_child()
    row.get_first_child().get_next_sibling().emit('clicked'); wait()
    text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
    assert 'UTF-8' in text and '+caf\ufffd updated' in text
    assert file.read_bytes() == b'caf\xe9 updated\n'
    window.close(); app.quit()
    print('PASS: GTK window, selection, diff, commit, refresh, non-UTF-8 diff')
