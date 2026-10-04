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
        self.clone_button = Gtk.Button(label='Clone')
        self.clone_button.connect('clicked', lambda *_: self.prompt('リポジトリを複製', [('取得元 URL / パス', ''), ('新しいフォルダのパス', '')], self.clone))
        toolbar.append(self.open_button); toolbar.append(self.clone_button); toolbar.append(self.refresh_button); box.append(toolbar)
        remote_bar = Gtk.Box(spacing=8)
        self.remote_choice = Gtk.ComboBoxText(); remote_bar.append(self.remote_choice)
        self.repo_buttons = []
        for label, method in [('Fetch', 'fetch'), ('Pull (FF)', 'pull'), ('Push', 'push')]:
            button = Gtk.Button(label=label)
            button.connect('clicked', lambda _, name=method: self.chosen_operation(name, self.remote_choice))
            remote_bar.append(button); self.repo_buttons.append(button)
        box.append(remote_bar)
        branch_bar = Gtk.Box(spacing=8)
        self.branch_choice = Gtk.ComboBoxText(); branch_bar.append(self.branch_choice)
        for label, callback in [
            ('切替', lambda: self.chosen_operation('switch_branch', self.branch_choice)),
            ('作成', lambda: self.prompt('ブランチを作成して切替', [('名前', '')], lambda values: self.operate(lambda: self.repo.create_branch(values[0])))),
            ('名前変更', self.rename_branch),
            ('削除', lambda: self.confirm('選択したマージ済みブランチを削除します。', lambda: self.chosen_operation('delete_branch', self.branch_choice))),
            ('マージ', lambda: self.chosen_operation('merge', self.branch_choice)),
        ]:
            button = Gtk.Button(label=label); button.connect('clicked', lambda _, fn=callback: fn())
            branch_bar.append(button); self.repo_buttons.append(button)
        box.append(branch_bar)
        self.location = Gtk.Label(label='コードの軌跡を、ひとつの星図に。', xalign=0, wrap=True); box.append(self.location)
        columns = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL); columns.set_vexpand(True); columns.set_position(380)
        self.files = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        left = Gtk.ScrolledWindow(); left.set_child(self.files); left.set_min_content_width(300)
        self.diff_view = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        right = Gtk.ScrolledWindow(); right.set_child(self.diff_view)
        columns.set_start_child(left); columns.set_end_child(right)
        tabs = Gtk.Notebook(); tabs.set_vexpand(True)
        tabs.append_page(columns, Gtk.Label(label='変更 / 差分'))
        self.history = Gtk.TextView(editable=False, monospace=True)
        history_scroll = Gtk.ScrolledWindow(); history_scroll.set_child(self.history)
        tabs.append_page(history_scroll, Gtk.Label(label='履歴グラフ'))
        box.append(tabs)
        conflict_bar = Gtk.Box(spacing=8)
        self.conflict_choice = Gtk.ComboBoxText(); conflict_bar.append(self.conflict_choice)
        for label, callback in [
            ('競合を編集', self.edit_conflict),
            ('外部で解決済み', lambda: self.confirm('選択ファイルの現在の内容（削除を含む）を解決済みとしてステージします。', lambda: self.chosen_operation('mark_resolved', self.conflict_choice))),
            ('マージ完了', lambda: self.confirm('ステージ済みの全変更をマージコミットに含めます。', self.finish_merge)),
            ('マージ中止', lambda: self.confirm('現在の競合解決作業を破棄してマージを中止します。', lambda: self.operate(self.repo.abort_merge))),
        ]:
            button = Gtk.Button(label=label); button.connect('clicked', lambda _, fn=callback: fn())
            conflict_bar.append(button); self.repo_buttons.append(button)
        box.append(conflict_bar)
        self.message = Gtk.Entry(placeholder_text='コミットメッセージ'); box.append(self.message)
        self.commit_button = Gtk.Button(label='✧ 選択した変更をコミット')
        self.commit_button.connect('clicked', self.commit); box.append(self.commit_button)
        self.status = Gtk.Label(label='準備完了', xalign=0, wrap=True); box.append(self.status)
        self.controls()

    def controls(self):
        self.open_button.set_sensitive(not self.busy)
        self.clone_button.set_sensitive(not self.busy)
        self.refresh_button.set_sensitive(not self.busy and self.repo is not None)
        self.commit_button.set_sensitive(not self.busy and self.repo is not None)
        self.files.set_sensitive(not self.busy)
        for button in self.repo_buttons: button.set_sensitive(not self.busy and self.repo is not None)
        for choice in [self.remote_choice, self.branch_choice, self.conflict_choice]: choice.set_sensitive(not self.busy)

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
                self.open_repository(path)
            dialog.destroy()
        chooser.connect('response', response); chooser.show()

    def snapshot(self):
        return self.state(self.repo)

    def state(self, repo):
        return repo, repo.branch(), repo.changes(), repo.graph(), repo.branches(), repo.remotes(), repo.conflicts()

    def open_repository(self, path):
        if path and Path(path).is_file(): path = str(Path(path).parent)
        self.task(lambda: self.state(Repository(path)), self.render)

    def clone(self, values):
        self.task(lambda: self.state(Repository.clone(*values)), self.render)

    def operate(self, operation):
        def work():
            error = None
            try: operation()
            except Exception as caught: error = caught
            return self.snapshot(), error
        def done(result):
            state, error = result
            self.render(state)
            if error: raise error
        self.task(work, done)

    def chosen_operation(self, name, choice):
        value = choice.get_active_text() or ''
        self.operate(lambda: getattr(self.repo, name)(value))

    def rename_branch(self):
        old = self.branch_choice.get_active_text() or ''
        self.prompt('ブランチ名を変更', [('新しい名前', '')], lambda values: self.operate(lambda: self.repo.rename_branch(old, values[0])))

    def finish_merge(self):
        text = self.message.get_text()
        self.operate(lambda: self.repo.finish_merge(text))

    def prompt(self, title, fields, callback):
        dialog = Gtk.Dialog(title=title, transient_for=self, modal=True)
        dialog.add_button('キャンセル', Gtk.ResponseType.CANCEL); dialog.add_button('実行', Gtk.ResponseType.OK)
        entries = []
        for label, value in fields:
            dialog.get_content_area().append(Gtk.Label(label=label, xalign=0))
            entry = Gtk.Entry(text=value); entry.set_width_chars(55)
            dialog.get_content_area().append(entry); entries.append(entry)
        def response(widget, answer):
            values = [entry.get_text() for entry in entries]; widget.destroy()
            if answer == Gtk.ResponseType.OK: callback(values)
        dialog.connect('response', response); dialog.present()

    def confirm(self, message, callback):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, text=message, buttons=Gtk.ButtonsType.OK_CANCEL)
        def response(widget, answer):
            widget.destroy()
            if answer == Gtk.ResponseType.OK: callback()
        dialog.connect('response', response); dialog.present()

    def edit_conflict(self):
        path = self.conflict_choice.get_active_text() or ''
        def show(text):
            dialog = Gtk.Dialog(title=path, transient_for=self, modal=True)
            dialog.set_default_size(850, 550)
            dialog.add_button('キャンセル', Gtk.ResponseType.CANCEL); dialog.add_button('保存して解決', Gtk.ResponseType.OK)
            editor = Gtk.TextView(monospace=True); editor.get_buffer().set_text(text)
            scroll = Gtk.ScrolledWindow(vexpand=True); scroll.set_child(editor); dialog.get_content_area().append(scroll)
            def response(widget, answer):
                buffer = editor.get_buffer(); value = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
                widget.destroy()
                if answer == Gtk.ResponseType.OK: self.operate(lambda: self.repo.save_resolution(path, value))
            dialog.connect('response', response); dialog.present()
        self.task(lambda: self.repo.conflict_text(path), show)

    def render(self, snapshot):
        self.repo, branch, changes, graph, branches, remotes, conflicts = snapshot
        self.history.get_buffer().set_text(graph)
        for choice, values, preferred in [(self.branch_choice, branches, branch), (self.remote_choice, remotes, self.remote_choice.get_active_text() or 'origin'), (self.conflict_choice, conflicts, '')]:
            choice.remove_all()
            for value in values: choice.append_text(value)
            if values: choice.set_active(values.index(preferred) if preferred in values else 0)
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
    def __init__(self): super().__init__(application_id='dev.gitnebula.desktop', flags=Gio.ApplicationFlags.HANDLES_OPEN)
    def do_open(self, files, count, hint):
        self.do_activate()
        if files: self.get_active_window().open_repository(files[0].get_path())
    def do_activate(self):
        window = self.get_active_window() or Window(self)
        window.present()
        if '--smoke' in sys.argv:
            def verify():
                if window.get_title() != 'GitNebula': raise RuntimeError('Unexpected title')
                print('GitNebula GTK window created successfully', flush=True)
                self.quit(); return False
            GLib.timeout_add(300, verify)


if __name__ == '__main__': App().run([arg for arg in sys.argv if arg != '--smoke'])
