"""Run on Linux with GTK 4 and DISPLAY set; exercises actual UI callbacks."""
import pathlib
import subprocess
import sys
import tempfile
import time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Linux'))
from main import App, Window, GLib
from actions import LaunchRequest
from git_backend import Repository

with tempfile.TemporaryDirectory(prefix='gitnebula-ui-') as directory:
    root = pathlib.Path(directory)
    def git(*args): return subprocess.check_output(['git', '-C', directory, *args]).decode()
    git('init', '-q'); git('config', 'user.name', 'UI Test'); git('config', 'user.email', 'ui@example.invalid')
    file = root / 'orbit.txt'; file.write_text('first\n')
    repo = Repository(directory); repo.commit(['orbit.txt'], 'initial')
    file.write_text('second\n')
    app = App(); app.register(None)
    window = Window(app, LaunchRequest('commit', (directory,))); window.present()
    def wait():
        deadline = time.monotonic() + 10
        context = GLib.MainContext.default()
        while window.busy and time.monotonic() < deadline:
            while context.pending(): context.iteration(False)
            time.sleep(.01)
        assert not window.busy, 'GUI operation timed out'
        assert not window.status.has_css_class('error'), window.status.get_text()
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
    file.write_text('second\n')
    window.task(window.snapshot, window.render); wait()
    assert 'UI commit' in window.history.get_buffer().get_text(window.history.get_buffer().get_start_iter(), window.history.get_buffer().get_end_iter(), False)
    base = repo.branch()
    window.operate(lambda: repo.create_branch('incoming')); wait()
    file.write_text('incoming\n'); repo.commit(['orbit.txt'], 'incoming')
    repo.switch_branch(base); file.write_text('current\n'); repo.commit(['orbit.txt'], 'current')
    # A failed merge must refresh the conflict controls before displaying its error.
    window.operate(lambda: repo.merge('incoming'))
    deadline = time.monotonic() + 10
    context = GLib.MainContext.default()
    while window.busy and time.monotonic() < deadline:
        while context.pending(): context.iteration(False)
        time.sleep(.01)
    assert not window.busy
    assert window.conflict_choice.get_active_text() == 'orbit.txt'
    window.operate(lambda: repo.save_resolution('orbit.txt', 'resolved\n')); wait()
    window.message.set_text('GUI merge')
    window.finish_merge(); wait()
    assert not repo.merge_in_progress()
    assert git('log', '-1', '--format=%s').strip() == 'GUI merge'
    window.set_action('log')
    assert window.history_scroll.get_visible() and not window.commit_box.get_visible()
    window.set_action('pull')
    assert window.remote_bar.get_visible() and not window.file_panel.get_visible()
    window.close()
    file.write_text('scoped commit\n')
    unrelated = root / 'unrelated.txt'; unrelated.write_text('keep outside commit\n')
    window = Window(app, LaunchRequest('commit', (str(file),))); window.present()
    window.open_repository(str(file)); wait()
    assert window.selected == {'orbit.txt'}
    assert window.commit_box.get_visible() and not window.branch_bar.get_visible()
    assert not window.history_scroll.get_visible()
    window.set_action('workspace')
    assert len(window.changes) == 2
    window.set_action('commit')
    assert window.selected == {'orbit.txt'} and len(window.changes) == 1
    window.message.set_text('right-click commit'); window.commit_button.emit('clicked'); wait()
    assert [c.path for c in repo.changes()] == ['unrelated.txt']
    assert git('log', '-1', '--format=%s').strip() == 'right-click commit'
    window.set_action('clone')
    assert window.clone_box.get_visible() and not window.commit_box.get_visible()
    window.close(); app.quit()
    print('PASS: GTK window, selection, diff, commit, preview, history, branches, conflict refresh and merge completion')
