#!/usr/bin/env python3
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
from actions import ACTIONS, LaunchRequest

# Parse help and reject invalid requests before loading the native GUI.
if __name__ == '__main__':
    launch_request = LaunchRequest.parse(sys.argv[1:])

import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk, Gio, GLib, Gdk, Pango
from git_backend import Repository


class Window(Gtk.ApplicationWindow):
    def __init__(self, app, request=None):
        super().__init__(application=app, title='GitNebula')
        self.request = request or LaunchRequest()
        self.action = self.request.action
        self.repo = None
        self.selected = set()
        self.changes = []
        self.initial_selection = True
        self.merging = False
        self.succeeded = False
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.connect('close-request', self.close_requested)
        self.busy = False
        css = Gtk.CssProvider()
        css.load_from_data(b"""
            window { background: radial-gradient(circle at 8% 4%, #8d91b5 0, #8d91b5 1px, transparent 2px),
                     radial-gradient(circle at 79% 12%, #8d91b5 0, #8d91b5 1px, transparent 2px),
                     radial-gradient(circle at 93% 87%, #8d91b5 0, #8d91b5 1px, transparent 2px),
                     radial-gradient(circle at 19% 79%, #8d91b5 0, #8d91b5 1px, transparent 2px),
                     radial-gradient(ellipse at top right, #302052, transparent),
                     radial-gradient(ellipse at bottom left, #102a3d, transparent), #090d1d; color: #e9eafa; }
            textview, textview text, list, entry { background: #12182c; color: #e9eafa; }
            button { padding: 10px 16px; border-radius: 8px; background: #24243e; color: #e9eafa; }
            button:hover { background: #37304f; }
            button:disabled { opacity: 0.45; }
            button.suggested-action { background: #b39dff; color: #131024; font-weight: bold; }
            .brand { font-size: 22px; font-weight: bold; color: #b39dff; }
            .title { font-size: 26px; font-weight: bold; }
            .muted { color: #a5b1cf; }
            .panel { background: #12182c; border: 1px solid #30304c; border-radius: 12px; padding: 12px; }
            .error { color: #ffbe90; }
        """)
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        for setter in [box.set_margin_top, box.set_margin_bottom, box.set_margin_start, box.set_margin_end]: setter(24)
        self.set_child(box)
        brand = Gtk.Box(spacing=12)
        title = Gtk.Label(label='✧ GitNebula', xalign=0, hexpand=True); title.add_css_class('brand')
        stars = Gtk.Label(label='·  ✦  ·    YOUR CODE, IN ORBIT    ·  ✧'); stars.add_css_class('muted')
        brand.append(title); brand.append(stars); box.append(brand)
        self.heading = Gtk.Label(xalign=0); self.heading.add_css_class('title'); box.append(self.heading)
        self.hint = Gtk.Label(xalign=0, wrap=True); self.hint.add_css_class('muted'); box.append(self.hint)
        self.location = Gtk.Label(label='リポジトリを選択してください。', xalign=0, wrap=True, selectable=True); box.append(self.location)
        toolbar = Gtk.Box(spacing=8)
        self.open_button = Gtk.Button(label='フォルダを選択'); self.open_button.connect('clicked', self.choose)
        self.refresh_button = Gtk.Button(label='更新'); self.refresh_button.connect('clicked', lambda *_: self.task(self.snapshot, self.render))
        toolbar.append(self.open_button); toolbar.append(self.refresh_button); box.append(toolbar)
        self.launcher = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, max_children_per_line=2, min_children_per_line=2, row_spacing=8, column_spacing=8)
        self.launch_buttons = {}
        for name, (label, _) in ACTIONS.items():
            if name in ('open', 'workspace'): continue
            button = Gtk.Button(label=label, hexpand=True)
            button.connect('clicked', lambda _, name=name: self.set_action(name))
            self.launcher.insert(button, -1); self.launch_buttons[name] = button
        box.append(self.launcher)
        self.remote_bar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12); self.remote_bar.add_css_class('panel')
        self.remote_bar.append(Gtk.Label(label='リモート', xalign=0))
        self.remote_choice = Gtk.ComboBoxText(); self.remote_bar.append(self.remote_choice)
        self.remote_notice = Gtk.Label(label='リモートが未設定です。取得元がある場合は Clone から始めてください。', wrap=True, xalign=0)
        self.remote_bar.append(self.remote_notice)
        self.execute_button = Gtk.Button(); self.execute_button.add_css_class('suggested-action')
        self.execute_button.connect('clicked', self.execute_action); self.remote_bar.append(self.execute_button); box.append(self.remote_bar)
        self.branch_bar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.branch_choice = Gtk.ComboBoxText(); self.branch_bar.append(self.branch_choice)
        self.switch_button = Gtk.Button(label='選択したブランチに切り替え')
        self.switch_button.connect('clicked', lambda *_: self.chosen_operation('switch_branch', self.branch_choice)); self.branch_bar.append(self.switch_button)
        self.advanced_branches = Gtk.Box(spacing=8)
        for label, callback in [
            ('作成', lambda: self.prompt('ブランチを作成して切替', [('名前', '')], lambda values: self.operate(lambda: self.repo.create_branch(values[0])))),
            ('名前変更', self.rename_branch),
            ('削除', lambda: self.confirm('選択したマージ済みブランチを削除します。', lambda: self.chosen_operation('delete_branch', self.branch_choice))),
            ('マージ', lambda: self.chosen_operation('merge', self.branch_choice)),
        ]:
            button = Gtk.Button(label=label); button.connect('clicked', lambda _, fn=callback: fn()); self.advanced_branches.append(button)
        self.branch_bar.append(self.advanced_branches); box.append(self.branch_bar)
        self.file_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, vexpand=True); self.file_panel.add_css_class('panel')
        select_bar = Gtk.Box(spacing=8)
        self.count = Gtk.Label(xalign=0, hexpand=True); select_bar.append(self.count)
        self.select_all = Gtk.Button(label='すべて選択'); self.select_all.connect('clicked', lambda *_: self.select_files(True)); select_bar.append(self.select_all)
        self.select_none = Gtk.Button(label='選択解除'); self.select_none.connect('clicked', lambda *_: self.select_files(False)); select_bar.append(self.select_none)
        self.file_panel.append(select_bar)
        columns = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, vexpand=True); columns.set_position(280)
        self.files = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        left = Gtk.ScrolledWindow(); left.set_child(self.files); left.set_min_content_width(220)
        self.diff_view = Gtk.TextView(editable=False, monospace=True)
        right = Gtk.ScrolledWindow(); right.set_child(self.diff_view)
        columns.set_start_child(left); columns.set_end_child(right); self.file_panel.append(columns); box.append(self.file_panel)
        self.history = Gtk.TextView(editable=False, monospace=True)
        self.history_scroll = Gtk.ScrolledWindow(vexpand=True); self.history_scroll.set_child(self.history); box.append(self.history_scroll)
        self.conflict_bar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.conflict_bar.append(Gtk.Label(label='マージの解決と完了', xalign=0))
        self.conflict_choice = Gtk.ComboBoxText(); self.conflict_bar.append(self.conflict_choice)
        self.conflict_buttons = Gtk.Box(spacing=8)
        for label, callback in [
            ('競合を編集', self.edit_conflict),
            ('外部で解決済み', lambda: self.confirm('現在の内容（削除を含む）を解決済みとしてステージします。', lambda: self.chosen_operation('mark_resolved', self.conflict_choice))),
            ('マージ完了', lambda: self.prompt('マージ完了（ステージ済みの全変更を含みます）', [('コミットメッセージ', '')], lambda values: self.operate(lambda: self.repo.finish_merge(values[0])))),
            ('マージ中止', lambda: self.confirm('競合解決作業を破棄してマージを中止します。', lambda: self.operate(self.repo.abort_merge))),
        ]:
            button = Gtk.Button(label=label); button.connect('clicked', lambda _, fn=callback: fn()); self.conflict_buttons.append(button)
        self.conflict_bar.append(self.conflict_buttons); box.append(self.conflict_bar)
        self.commit_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.commit_box.append(Gtk.Label(label='コミットメッセージ', xalign=0))
        self.message = Gtk.Entry(placeholder_text='変更内容を短く説明してください'); self.message.connect('activate', lambda *_: self.commit() if self.commit_button.get_sensitive() else None); self.message.connect('changed', lambda *_: self.controls()); self.commit_box.append(self.message)
        self.commit_button = Gtk.Button(label='コミット'); self.commit_button.add_css_class('suggested-action')
        self.commit_button.connect('clicked', self.commit); self.commit_box.append(self.commit_button); box.append(self.commit_box)
        self.clone_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.clone_source = Gtk.Entry(placeholder_text='https://… / ローカルのパス')
        self.clone_destination = Gtk.Entry(placeholder_text='新しく作るフォルダのパス')
        for label, entry in [('取得元 URL / パス', self.clone_source), ('作成先（新しいフォルダ）', self.clone_destination)]:
            self.clone_box.append(Gtk.Label(label=label, xalign=0)); self.clone_box.append(entry); entry.connect('changed', lambda *_: self.controls())
        parent = Gtk.Button(label='親フォルダを選択…'); parent.connect('clicked', self.choose_clone_parent); self.clone_box.append(parent)
        self.clone_button = Gtk.Button(label='Clone'); self.clone_button.add_css_class('suggested-action')
        self.clone_button.connect('clicked', lambda *_: self.clone([self.clone_source.get_text(), self.clone_destination.get_text()]))
        self.clone_box.append(self.clone_button); box.append(self.clone_box)
        self.status = Gtk.Label(label='準備完了', xalign=0, wrap=True, selectable=True); box.append(self.status)
        footer = Gtk.Box(spacing=8)
        self.spinner = Gtk.Spinner(); footer.append(self.spinner)
        self.other = Gtk.ComboBoxText(hexpand=True)
        self.other.append('placeholder', 'その他の操作…')
        for name, (label, _) in ACTIONS.items(): self.other.append(name, label)
        self.other.set_active_id('placeholder'); self.other.connect('changed', self.other_action); footer.append(self.other)
        close = Gtk.Button(label='閉じる'); close.connect('clicked', lambda *_: self.close()); footer.append(close); box.append(footer)
        self.branch_choice.connect('changed', lambda *_: self.controls())
        self.set_action(self.action)

    def close_requested(self, *_):
        if self.busy: return True
        self.executor.shutdown(wait=False)
        return False

    def other_action(self, choice):
        name = choice.get_active_id()
        if name and name != 'placeholder':
            self.set_action(name); choice.set_active_id('placeholder')

    def set_action(self, action):
        self.action = action; self.succeeded = False
        if hasattr(self, 'last_snapshot'): self.render(self.last_snapshot)
        self.heading.set_text(ACTIONS[action][0]); self.hint.set_text(ACTIONS[action][1])
        self.set_title(ACTIONS[action][0] + ' — GitNebula')
        self.set_default_size(900 if action in ('commit', 'diff', 'log', 'workspace') else 700,
                              680 if action in ('commit', 'diff', 'log', 'workspace') else 480)
        if action == 'clone' and not self.clone_destination.get_text():
            path = self.request.paths[0] if self.request.paths else str(Path.home())
            self.clone_destination.set_text(str(Path(LaunchRequest.directory(path)) / 'new-repository'))
        if hasattr(self, 'status'): self.status.set_text('準備完了')
        row = self.files.get_first_child()
        while row:
            child = row.get_child()
            if isinstance(child, Gtk.Box): child.get_first_child().set_visible(action != 'diff')
            row = row.get_next_sibling()
        self.controls()

    def controls(self):
        if not hasattr(self, 'other'): return
        ready = not self.busy and self.repo is not None
        self.open_button.set_visible(self.action != 'clone'); self.refresh_button.set_visible(self.action != 'clone'); self.location.set_visible(self.action != 'clone')
        self.open_button.set_sensitive(not self.busy)
        self.refresh_button.set_sensitive(ready)
        self.other.set_sensitive(not self.busy)
        self.clone_button.set_sensitive(not self.busy and not self.succeeded and bool(self.clone_source.get_text().strip()) and bool(self.clone_destination.get_text().strip()))
        self.commit_button.set_sensitive(ready and bool(self.selected) and bool(self.message.get_text().strip()) and not self.merging)
        self.commit_button.set_label(f'選択した {len(self.selected)} ファイルをコミット')
        self.files.set_sensitive(ready)
        self.message.set_sensitive(not self.busy)
        self.clone_box.set_sensitive(not self.busy)
        self.branch_bar.set_sensitive(ready)
        self.switch_button.set_sensitive(ready and bool(self.branch_choice.get_active_text()) and self.branch_choice.get_active_text() != getattr(self, 'branch', ''))
        self.remote_bar.set_sensitive(ready)
        self.remote_notice.set_visible(self.repo is not None and self.remote_choice.get_active_text() is None)
        self.execute_button.set_label(ACTIONS[self.action][0])
        self.execute_button.set_sensitive(ready and self.remote_choice.get_active_text() is not None and not self.succeeded)
        self.conflict_bar.set_sensitive(ready)
        for name, button in self.launch_buttons.items(): button.set_sensitive(not self.busy and (ready or name == 'clone'))
        self.launcher.set_visible(self.action == 'open')
        self.remote_bar.set_visible(self.action in ('pull', 'push', 'fetch') and self.repo is not None)
        self.branch_bar.set_visible(self.action in ('switch', 'workspace') and self.repo is not None)
        self.advanced_branches.set_visible(self.action == 'workspace')
        self.file_panel.set_visible(self.action in ('commit', 'diff', 'workspace') and self.repo is not None)
        self.select_all.set_visible(self.action != 'diff'); self.select_none.set_visible(self.action != 'diff')
        self.commit_box.set_visible(self.action in ('commit', 'workspace') and self.repo is not None)
        self.history_scroll.set_visible(self.action == 'log' and self.repo is not None)
        self.conflict_bar.set_visible(self.action not in ('open', 'clone') and (self.merging or bool(self.conflict_choice.get_active_text())))
        self.clone_box.set_visible(self.action == 'clone')
        self.select_all.set_sensitive(ready); self.select_none.set_sensitive(ready)
        self.spinner.set_spinning(self.busy)

    def select_files(self, active):
        row = self.files.get_first_child()
        while row:
            check = row.get_child().get_first_child()
            if isinstance(check, Gtk.CheckButton): check.set_active(active)
            row = row.get_next_sibling()

    def execute_action(self, *_):
        self.chosen_operation(self.action, self.remote_choice)

    def choose_clone_parent(self, *_):
        chooser = Gtk.FileChooserNative(title='Clone の親フォルダを選択', transient_for=self, action=Gtk.FileChooserAction.SELECT_FOLDER)
        def response(dialog, answer):
            if answer == Gtk.ResponseType.ACCEPT:
                self.clone_destination.set_text(str(Path(dialog.get_file().get_path()) / 'new-repository'))
            dialog.destroy()
        chooser.connect('response', response); chooser.show()

    def task(self, work, done, success="準備完了"):
        if self.busy: return
        self.busy = True; self.succeeded = False; self.controls(); self.status.remove_css_class('error'); self.status.set_text('処理中…')
        future = self.executor.submit(work)
        def finish():
            try:
                done(future.result()); self.status.set_text(success); self.succeeded = success != '準備完了'
            except Exception as error:
                self.status.set_text(str(error)); self.status.add_css_class('error')
            finally: self.busy = False; self.controls()
            return False
        future.add_done_callback(lambda _: GLib.idle_add(finish))

    def choose(self, *_):
        chooser = Gtk.FileChooserNative(title='Git リポジトリを選択', transient_for=self, action=Gtk.FileChooserAction.SELECT_FOLDER)
        def response(dialog, result):
            if result == Gtk.ResponseType.ACCEPT:
                path = dialog.get_file().get_path()
                self.request = LaunchRequest(self.action, (path,)); self.initial_selection = True
                self.repo = None; self.selected.clear(); self.message.set_text(''); self.merging = False
                if hasattr(self, 'last_snapshot'): del self.last_snapshot
                self.remote_choice.remove_all(); self.branch_choice.remove_all(); self.conflict_choice.remove_all()
                self.open_repository(path)
            dialog.destroy()
        chooser.connect('response', response); chooser.show()

    def snapshot(self):
        return self.state(self.repo)

    def state(self, repo):
        return repo, repo.branch(), repo.changes(), repo.graph(), repo.branches(), repo.remotes(), repo.conflicts(), repo.merge_in_progress(), repo.preferred_remote()

    def open_repository(self, path):
        def work():
            repo = Repository(LaunchRequest.directory(path))
            for selected in self.request.paths:
                if Repository(LaunchRequest.directory(selected)).path != repo.path:
                    raise ValueError('同じリポジトリ内のファイルを選択してください。')
            state = self.state(repo)
            first = next((c for c in state[2] if self.request.includes(c.path, repo.path)), None)
            preview = repo.diff(first.path) if first and self.action in ('commit', 'diff') else ''
            return state, preview
        def done(result):
            self.render(result[0]); self.diff_view.get_buffer().set_text(result[1])
        self.task(work, done)

    def clone(self, values):
        def done(state):
            self.request = LaunchRequest('clone'); self.initial_selection = True; self.render(state)
        self.task(lambda: self.state(Repository.clone(*values)), done, "Clone が完了しました。閉じて作業を始められます。")

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
        self.task(work, done, "完了しました。閉じて作業に戻れます。")

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
        self.last_snapshot = snapshot
        self.repo, self.branch, changes, graph, branches, remotes, conflicts, self.merging, preferred_remote = snapshot
        self.changes = [c for c in changes if self.action == 'workspace' or self.request.includes(c.path, self.repo.path)]
        self.history.get_buffer().set_text(graph)
        for choice, values, preferred in [(self.branch_choice, branches, self.branch_choice.get_active_text() or next((b for b in branches if b != self.branch), self.branch)), (self.remote_choice, remotes, self.remote_choice.get_active_text() or preferred_remote), (self.conflict_choice, conflicts, '')]:
            choice.remove_all()
            for value in values: choice.append_text(value)
            if values: choice.set_active(values.index(preferred) if preferred in values else 0)
        available = {c.path for c in self.changes}
        self.selected = available if self.initial_selection else self.selected & available
        self.initial_selection = False
        self.location.set_text(f'{self.repo.path}  ·  {self.branch}')
        self.count.set_text(f'対象の変更 · {len(self.changes)} ファイル')
        while self.files.get_first_child(): self.files.remove(self.files.get_first_child())
        self.diff_view.get_buffer().set_text('ファイルをクリックすると差分を表示します。')
        for change in self.changes:
            row = Gtk.Box(spacing=8)
            check = Gtk.CheckButton(active=change.path in self.selected)
            def toggled(button, path=change.path):
                if button.get_active(): self.selected.add(path)
                else: self.selected.discard(path)
                self.controls()
            check.connect('toggled', toggled)
            check.set_visible(self.action != 'diff')
            button = Gtk.Button(label=f'{change.label}  {os.fsencode(change.path).decode("utf-8", errors="replace")}', hexpand=True)
            button.get_child().set_ellipsize(Pango.EllipsizeMode.MIDDLE)
            button.get_child().set_max_width_chars(36)
            button.get_child().set_xalign(0)
            button.connect('clicked', lambda _, path=change.path: self.task(lambda: self.repo.diff(path), lambda text: self.diff_view.get_buffer().set_text(text)))
            row.append(check); row.append(button); self.files.append(row)
        if not self.changes: self.files.append(Gtk.Label(label='対象に未コミットの変更はありません。'))
        self.controls()

    def commit(self, *_):
        paths = list(self.selected); message = self.message.get_text()
        def work():
            self.repo.commit(paths, message)
            return self.snapshot()
        def done(state): self.message.set_text(''); self.render(state)
        self.task(work, done, 'コミットしました。閉じて作業に戻れます。')


class App(Gtk.Application):
    def __init__(self, request=None):
        super().__init__(application_id='dev.gitnebula.desktop', flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.request = request or LaunchRequest()
    def do_activate(self):
        window = self.get_active_window()
        if window is None:
            window = Window(self, self.request)
            if self.request.paths and self.request.action != 'clone': window.open_repository(self.request.paths[0])
        window.present()


if __name__ == '__main__':
    App(launch_request).run([sys.argv[0]])
