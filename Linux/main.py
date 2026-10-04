#!/usr/bin/env python3
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gio, GLib, Gdk
from git_backend import Repository


class Window(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title='GitNebula')
        self.set_default_size(1100, 740)
        self.repo = None
        self.selected = set()
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.connect('close-request', lambda *_: self.executor.shutdown(wait=False))
        self.busy = False
        css = Gtk.CssProvider()
        css.load_from_data(b'window { background: #090d1d; color: #e9eafa; } textview, textview text, list { background: #151b31; color: #e9eafa; } button { padding: 10px; } .title { font-size: 30px; font-weight: bold; color: #b39dff; }')
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        for setter in [box.set_margin_top, box.set_margin_bottom, box.set_margin_start, box.set_margin_end]: setter(24)
        self.set_child(box)
        title = Gtk.Label(label='✧ GitNebula  /  MISSION CONTROL', xalign=0)
        title.add_css_class('title'); box.append(title)
        toolbar = Gtk.Box(spacing=12)
        self.open_button = Gtk.Button(label='リポジトリを開く')
        self.open_button.connect('clicked', self.choose)
        self.refresh_button = Gtk.Button(label='更新')
        self.refresh_button.connect('clicked', lambda *_: self.task(self.snapshot, self.render))
        toolbar.append(self.open_button); toolbar.append(self.refresh_button); box.append(toolbar)
        self.location = Gtk.Label(label='コードの軌跡を、ひとつの星図に。', xalign=0, wrap=True); box.append(self.location)
        columns = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL); columns.set_vexpand(True); columns.set_position(380)
        self.files = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        left = Gtk.ScrolledWindow(); left.set_child(self.files); left.set_min_content_width(300)
        self.diff_view = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        right = Gtk.ScrolledWindow(); right.set_child(self.diff_view)
        columns.set_start_child(left); columns.set_end_child(right); box.append(columns)
        self.message = Gtk.Entry(placeholder_text='コミットメッセージ'); box.append(self.message)
        self.commit_button = Gtk.Button(label='✧ 選択した変更をコミット')
        self.commit_button.connect('clicked', self.commit); box.append(self.commit_button)
        self.status = Gtk.Label(label='準備完了', xalign=0, wrap=True); box.append(self.status)
        self.controls()

    def controls(self):
        self.open_button.set_sensitive(not self.busy)
        self.refresh_button.set_sensitive(not self.busy and self.repo is not None)
        self.commit_button.set_sensitive(not self.busy and self.repo is not None)
        self.files.set_sensitive(not self.busy)

    def task(self, work, done):
        if self.busy: return
        self.busy = True; self.controls(); self.status.set_text('処理中…')
        future = self.executor.submit(work)
        def finish():
            try: done(future.result()); self.status.set_text('準備完了')
            except Exception as error: self.status.set_text(str(error))
            finally: self.busy = False; self.controls()
            return False
        future.add_done_callback(lambda _: GLib.idle_add(finish))

    def choose(self, *_):
        chooser = Gtk.FileChooserNative(title='Git リポジトリを選択', transient_for=self, action=Gtk.FileChooserAction.SELECT_FOLDER)
        def response(dialog, result):
            if result == Gtk.ResponseType.ACCEPT:
                path = dialog.get_file().get_path()
                def work():
                    repo = Repository(path)
                    return repo, repo.branch(), repo.changes()
                self.task(work, self.render)
            dialog.destroy()
        chooser.connect('response', response); chooser.show()

    def snapshot(self):
        return self.repo, self.repo.branch(), self.repo.changes()

    def render(self, snapshot):
        self.repo, branch, changes = snapshot
        self.selected.clear(); self.location.set_text(f'{self.repo.path}  ·  {branch}  ·  {len(changes)} changes')
        while self.files.get_first_child(): self.files.remove(self.files.get_first_child())
        self.diff_view.get_buffer().set_text('ファイルをクリックすると差分を表示します。')
        for change in changes:
            row = Gtk.Box(spacing=8)
            check = Gtk.CheckButton()
            check.connect('toggled', lambda button, path=change.path: self.selected.add(path) if button.get_active() else self.selected.discard(path))
            button = Gtk.Button(label=f'{change.code}  {change.path}')
            button.set_hexpand(True)
            button.connect('clicked', lambda _, path=change.path: self.task(lambda: self.repo.diff(path), lambda text: self.diff_view.get_buffer().set_text(text)))
            row.append(check); row.append(button); self.files.append(row)
        if not changes: self.files.append(Gtk.Label(label='作業ツリーはクリーンです。'))

    def commit(self, *_):
        paths = list(self.selected); message = self.message.get_text()
        def work():
            self.repo.commit(paths, message)
            return self.snapshot()
        def done(state): self.message.set_text(''); self.render(state)
        self.task(work, done)


class App(Gtk.Application):
    def __init__(self): super().__init__(application_id='dev.gitnebula.desktop', flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
    def do_activate(self):
        window = self.get_active_window() or Window(self)
        window.present()
        if '--smoke' in sys.argv:
            def verify():
                if window.get_title() != 'GitNebula': raise RuntimeError('Unexpected title')
                print('GitNebula GTK window created successfully', flush=True)
                self.quit(); return False
            GLib.timeout_add(300, verify)


if __name__ == '__main__': App().run([sys.argv[0]])
