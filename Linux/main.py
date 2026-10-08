#!/usr/bin/env python3
"""GTK 4 screens and one resident application, with repository-specific windows."""
import os
from pathlib import Path
import sys
from actions import ACTIONS, MENU_GROUPS, LaunchRequest
from settings import Settings, SecretStore, clone_destination, is_key_prompt

# CLI help, argument validation and saved credentials work without loading GTK.
askpass_key = os.environ.get("GITNEBULA_SSH_KEY", "")
askpass_prompt = (
    sys.argv[1]
    if __name__ == "__main__" and askpass_key and len(sys.argv) == 2
    else None
)
if __name__ == "__main__" and askpass_prompt is None:
    launch_request = LaunchRequest.parse(sys.argv[1:])
if askpass_prompt is not None and is_key_prompt(askpass_prompt, askpass_key):
    try:
        saved = SecretStore.read(askpass_key)
    except Exception:
        saved = None
    if saved is not None:
        sys.stdout.write(saved + "\n")
        raise SystemExit(0)

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Gio, GLib, Gdk, Pango
from concurrent.futures import ThreadPoolExecutor
from git_backend import Repository
from transfer import TransferProgress
from gtk_widgets import CommitDetails, NebulaView, label
from graph import graph_rows, PALETTE
from advanced_views import AdvancedViews
from diff_widgets import DiffComparison, RevisionBrowser


def buffer_text(view):
    buffer = view.get_buffer()
    return buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)


def window_purpose(action):
    return action if action in ("log", "graph") else "workspace"


class Window(Gtk.ApplicationWindow, AdvancedViews):
    def __init__(self, app, request=None):
        super().__init__(application=app, title="GitNebula")
        self.settings = app.settings
        self.L = self.settings.text
        self.request = request or LaunchRequest()
        self.action = self.request.action
        self.window_purpose = window_purpose(self.action)
        self.route_request = None
        self.repo = None
        self.selected = set()
        self.changes = []
        self.all_changes = []
        self.initial_selection = True
        self.busy = False
        self.merging = False
        self.sequence = None
        self.succeeded = False
        self.commit_completed = False
        self.routes = []
        self.records = []
        self.limit = 200
        self.history_filter_ref = None
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.connect("close-request", self.close_requested)
        self.set_default_size(1000, 700)
        self.css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), self.css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for setter in [
            self.root.set_margin_top,
            self.root.set_margin_bottom,
            self.root.set_margin_start,
            self.root.set_margin_end,
        ]:
            setter(12)
        self.set_child(self.root)
        self.nav = Gtk.Box(spacing=8)
        self.back_button = self.button("戻る", self.back)
        self.nav.append(self.back_button)
        self.nav.append(self.button("GitNebula", lambda: self.navigate("open")))
        self.root.append(self.nav)
        self.heading = Gtk.Label(xalign=0)
        self.heading.add_css_class("title")
        self.heading.set_hexpand(True)
        self.nav.append(self.heading)
        self.hint = label("")
        self.root.append(self.hint)
        self.location = label("")
        self.location.set_wrap(False)
        self.location.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        self.root.append(self.location)
        self.path_bar = Gtk.Box(spacing=8)
        self.repository_path = Gtk.Entry(
            hexpand=True, placeholder_text=self.L("リポジトリのパス")
        )
        self.repository_path.connect("activate", self.open_entered_path)
        self.path_bar.append(self.repository_path)
        self.open_button = self.button(
            "フォルダを選択",
            lambda: self.choose(self.repository_path, self.open_entered_path),
        )
        self.path_bar.append(self.open_button)
        self.refresh_button = self.button(
            "更新", lambda: self.task(self.snapshot, self.render)
        )
        self.path_bar.append(self.refresh_button)
        self.root.append(self.path_bar)
        self.pages = Gtk.Stack(vexpand=True, hexpand=True)
        self.pages.set_hhomogeneous(False)
        self.pages.set_vhomogeneous(False)
        self.pages.set_transition_type(Gtk.StackTransitionType.NONE)
        self.root.append(self.pages)
        self.home = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=16,
            halign=Gtk.Align.CENTER,
            valign=Gtk.Align.CENTER,
        )
        self.home_nebula = NebulaView(home=True)
        self.home_nebula.set_size_request(500, 300)
        self.home.append(self.home_nebula)
        brand = Gtk.Label(label="GitNebula")
        brand.add_css_class("brand")
        self.home.append(brand)
        self.home.append(self.button("詳細設定", lambda: self.navigate("settings")))
        self.pages.add_named(self.home, "open")
        self.launcher_buttons = []
        self.launcher = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        for title, names in MENU_GROUPS:
            self.launcher.append(label(self.L(title)))
            row = Gtk.FlowBox(
                selection_mode=Gtk.SelectionMode.NONE,
                max_children_per_line=4,
                min_children_per_line=1,
                row_spacing=6,
                column_spacing=6,
            )
            for name in names:
                control = self.button(
                    ACTIONS[name][0], lambda name=name: self.navigate(name)
                )
                self.launcher_buttons.append((name, control))
                row.insert(control, -1)
            self.launcher.append(row)
        self.add_page("menu", self.launcher, True)
        # File browser / commit / stage screens share the browser, never the history screen.
        self.file_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        bar = Gtk.Box(spacing=8)
        self.count = Gtk.Label(xalign=0, hexpand=True)
        bar.append(self.count)
        self.select_all = self.button("すべて選択", lambda: self.select_files(True))
        self.select_none = self.button("選択解除", lambda: self.select_files(False))
        bar.append(self.select_all)
        bar.append(self.select_none)
        self.file_page.append(bar)
        self.stage_bar = Gtk.Box(spacing=8)
        self.stage_bar.append(
            self.button(
                "ステージ（Add）",
                lambda: self.operate(lambda: self.repo.stage(list(self.selected))),
            )
        )
        self.stage_bar.append(
            self.button(
                "ステージ解除",
                lambda: self.operate(lambda: self.repo.unstage(list(self.selected))),
            )
        )
        self.stage_bar.append(self.button("無視（Ignore）", self.ignore_selected))
        self.stage_bar.append(self.button("変更を破棄", self.discard_selected))
        self.file_page.append(self.stage_bar)
        columns = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, vexpand=True)
        columns.set_position(280)
        self.files = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        left = Gtk.ScrolledWindow()
        left.set_child(self.files)
        self.diff_view = Gtk.TextView(editable=False, monospace=True)
        right = Gtk.ScrolledWindow()
        right.set_child(self.diff_view)
        columns.set_start_child(left)
        comparisons = Gtk.Notebook()
        self.working_comparison = DiffComparison(self.L)
        comparisons.append_page(
            self.working_comparison, Gtk.Label(label=self.L("ファイル比較"))
        )
        comparisons.append_page(right, Gtk.Label(label=self.L("Git 出力")))
        columns.set_end_child(comparisons)
        self.file_page.append(columns)
        self.file_panel = self.file_page
        self.commit_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.commit_box.append(label(self.L("コミットメッセージ")))
        self.message = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.message.get_buffer().connect("changed", lambda *_: self.controls())
        message_scroll = Gtk.ScrolledWindow()
        message_scroll.set_min_content_height(76)
        message_scroll.set_max_content_height(90)
        message_scroll.set_child(self.message)
        self.commit_box.append(message_scroll)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self.message_key)
        self.message.add_controller(keys)
        self.commit_button = self.button("コミット", self.commit)
        self.commit_button.add_css_class("suggested-action")
        self.commit_box.append(self.commit_button)
        self.file_page.append(self.commit_box)
        self.pages.add_named(self.file_page, "files")
        # A list and detail tabs with one scrollable information body.
        self.history_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.search = Gtk.SearchEntry(
            placeholder_text=self.L("コミット ID・メッセージ・作成者を検索")
        )
        self.search.connect("search-changed", lambda *_: self.render_commits())
        self.history_filter = Gtk.ComboBoxText()
        self.history_filter.append("all", self.L("すべてのブランチ"))
        self.history_filter.set_active_id("all")
        self.history_filter.connect("changed", self.history_branch_changed)
        for cell in self.history_filter.get_cells():
            if cell.find_property("ellipsize"):
                cell.set_property("ellipsize", Pango.EllipsizeMode.MIDDLE)
            if cell.find_property("max-width-chars"):
                cell.set_property("max-width-chars", 20)
        filters = Gtk.Box(spacing=8)
        filters.append(self.history_filter)
        self.search.set_hexpand(True)
        filters.append(self.search)
        self.history_page.append(filters)
        split = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL, vexpand=True)
        split.set_position(135)
        split.set_shrink_start_child(False)
        split.set_shrink_end_child(False)
        split.set_resize_start_child(True)
        split.set_resize_end_child(True)
        self.commit_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.commit_list.connect("row-selected", self.commit_selected)
        listing = Gtk.ScrolledWindow()
        listing.set_min_content_height(56)
        listing.set_child(self.commit_list)
        split.set_start_child(listing)
        self.commit_details = CommitDetails(self.L)
        self.history = Gtk.TextView(editable=False, monospace=True)
        self.history_scroll = Gtk.ScrolledWindow()
        self.history_scroll.set_child(self.history)
        tabs = Gtk.Notebook()
        tabs.set_size_request(-1, 180)
        tabs.append_page(self.commit_details, Gtk.Label(label=self.L("コミット情報")))
        self.history_files = RevisionBrowser(self)
        tabs.append_page(self.history_files, Gtk.Label(label=self.L("変更ファイル")))
        tabs.append_page(self.history_scroll, Gtk.Label(label=self.L("Git 出力")))
        split.set_end_child(tabs)
        self.history_page.append(split)
        bar = Gtk.Box(spacing=8)
        bar.append(self.button("さらに 200 件読み込む", self.more_history))
        self.cherry_button = self.button(
            "この変更を取り込む（Cherry-pick）",
            lambda: self.history_operation("cherry_pick"),
        )
        self.revert_button = self.button(
            "このコミットを取り消す（Revert）", lambda: self.history_operation("revert")
        )
        bar.append(self.cherry_button)
        bar.append(self.revert_button)
        self.history_page.append(bar)
        self.pages.add_named(self.history_page, "log")
        # Branch choices use stable IDs and include remote branches only for switching.
        self.branch_bar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.branch_choice = Gtk.ComboBoxText()
        self.branch_choice.connect("changed", lambda *_: self.controls())
        self.branch_bar.append(self.branch_choice)
        self.fetch_branches = self.button("リモートから更新", self.refresh_branches)
        self.branch_bar.append(self.fetch_branches)
        self.branch_notice = label("")
        self.branch_bar.append(self.branch_notice)
        self.switch_button = self.button(
            "選択したブランチに切り替え",
            lambda: self.operate(
                lambda: self.repo.switch_branch(self.branch_choice.get_active_id())
            ),
        )
        self.branch_bar.append(self.switch_button)
        self.integrate_button = self.button("実行", self.integrate)
        self.branch_bar.append(self.integrate_button)
        self.advanced_branches = Gtk.Box(spacing=8)
        self.advanced_branches.append(
            self.button(
                "作成",
                lambda: self.prompt(
                    "ブランチを作成して切替",
                    [("名前", "")],
                    lambda v: self.operate(lambda: self.repo.create_branch(v[0])),
                ),
            )
        )
        self.advanced_branches.append(
            self.button(
                "名前変更",
                lambda: self.prompt(
                    "ブランチ名を変更",
                    [("新しい名前", "")],
                    lambda v: self.operate(
                        lambda: self.repo.rename_branch(
                            self.branch_choice.get_active_id(), v[0]
                        )
                    ),
                ),
            )
        )
        self.advanced_branches.append(
            self.button(
                "削除",
                lambda: self.confirm(
                    "選択したマージ済みブランチを削除します。",
                    lambda: self.operate(
                        lambda: self.repo.delete_branch(
                            self.branch_choice.get_active_id()
                        )
                    ),
                ),
            )
        )
        self.branch_bar.append(self.advanced_branches)
        self.add_page("switch", self.branch_bar, True)
        self.remote_bar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.remote_choice = Gtk.ComboBoxText()
        self.remote_bar.append(self.remote_choice)
        self.remote_notice = label("")
        self.remote_bar.append(self.remote_notice)
        self.remote_result = label("")
        self.remote_bar.append(self.remote_result)
        self.execute_button = self.button("実行", self.transfer)
        self.remote_bar.append(self.execute_button)
        self.remote_output = Gtk.TextView(editable=False, monospace=True)
        output_scroll = Gtk.ScrolledWindow()
        output_scroll.set_min_content_height(120)
        output_scroll.set_child(self.remote_output)
        expander = Gtk.Expander(label=self.L("Git 出力"))
        expander.set_child(output_scroll)
        self.remote_bar.append(expander)
        self.add_page("remote", self.remote_bar, True)
        self.clone_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.clone_source = self.entry(self.clone_box, "取得元 URL / パス")
        self.clone_destination = self.entry(self.clone_box, "保存先（親フォルダ）")
        self.clone_target = label("")
        self.clone_box.append(self.clone_target)
        self.clone_box.append(
            self.button("保存先を選択…", lambda: self.choose(self.clone_destination))
        )
        self.clone_button = self.button("Clone", self.clone)
        self.clone_box.append(self.clone_button)
        self.clone_source.connect("changed", lambda *_: self.controls())
        self.clone_destination.connect("changed", lambda *_: self.controls())
        self.add_page("clone", self.clone_box, True)
        self.conflict_bar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.conflict_notice = label("")
        self.conflict_bar.append(self.conflict_notice)
        self.conflict_choice = Gtk.ComboBoxText()
        self.conflict_bar.append(self.conflict_choice)
        self.conflict_bar.append(self.button("競合を編集", self.edit_conflict))
        self.conflict_bar.append(
            self.button(
                "外部で解決済み",
                lambda: self.operate(
                    lambda: self.repo.mark_resolved(
                        self.conflict_choice.get_active_text()
                    )
                ),
            )
        )
        self.finish_button = self.button(
            "マージ完了",
            lambda: self.prompt(
                "マージ完了",
                [("コミットメッセージ", "")],
                lambda v: self.operate(lambda: self.repo.finish_merge(v[0])),
            ),
        )
        self.conflict_bar.append(self.finish_button)
        self.continue_button = self.button(
            "操作を再開", lambda: self.operate(self.repo.continue_sequence)
        )
        self.conflict_bar.append(self.continue_button)
        self.abort_button = self.button(
            "操作を中止",
            lambda: self.confirm(
                "進行中の操作を中止して開始前に戻します。",
                lambda: self.operate(self.repo.abort_sequence),
            ),
        )
        self.conflict_bar.append(self.abort_button)
        self.add_page("conflicts", self.conflict_bar, True)
        self.stash_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.stash_message = self.entry(self.stash_panel, "退避メモ")
        self.include_untracked = Gtk.CheckButton(
            label=self.L("未追跡ファイルも退避する（無視ファイルは含めない）"),
            active=True,
        )
        self.stash_panel.append(self.include_untracked)
        self.stash_panel.append(
            self.button(
                "現在の変更を退避（Stash）",
                lambda: self.operate(
                    lambda: self.repo.save_stash(
                        self.stash_message.get_text(),
                        self.include_untracked.get_active(),
                    )
                ),
            )
        )
        self.stash_choice = Gtk.ComboBoxText()
        self.stash_choice.connect("changed", self.stash_selected)
        self.stash_panel.append(self.stash_choice)
        for title, fn in [
            (
                "適用（Apply・退避を残す）",
                lambda: self.repo.apply_stash(self.stash_choice.get_active_id()),
            ),
            (
                "取り出す（Pop）",
                lambda: self.repo.apply_stash(self.stash_choice.get_active_id(), True),
            ),
            (
                "退避を削除（Drop）",
                lambda: self.repo.drop_stash(self.stash_choice.get_active_id()),
            ),
        ]:
            self.stash_panel.append(
                self.button(
                    title,
                    lambda fn=fn, title=title: self.confirm(
                        title, lambda: self.operate(fn)
                    ),
                )
            )
        self.stash_preview = Gtk.TextView(editable=False, monospace=True)
        preview = Gtk.ScrolledWindow(vexpand=True)
        preview.set_min_content_height(160)
        preview.set_child(self.stash_preview)
        self.stash_panel.append(preview)
        self.add_page("stash", self.stash_panel, True)
        self.tag_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.tag_choice = Gtk.ComboBoxText()
        self.tag_panel.append(self.tag_choice)
        self.tag_panel.append(
            self.button(
                "タグを作成",
                lambda: self.prompt(
                    "タグを作成",
                    [
                        ("タグ名", ""),
                        ("対象コミット / ブランチ（例: HEAD）", "HEAD"),
                        ("注釈（空欄なら軽量タグ）", ""),
                    ],
                    lambda v: self.operate(lambda: self.repo.create_tag(*v)),
                ),
            )
        )
        self.tag_panel.append(
            self.button(
                "タグを削除",
                lambda: self.confirm(
                    "ローカルのタグを削除します。",
                    lambda: self.operate(
                        lambda: self.repo.delete_tag(self.tag_choice.get_active_text())
                    ),
                ),
            )
        )
        self.tag_panel.append(
            self.button(
                "タグを送信",
                lambda: self.prompt(
                    "タグの送信先を指定",
                    [("リモート", "origin")],
                    lambda v: self.operate(
                        lambda: self.repo.push_tag(
                            self.tag_choice.get_active_text(), v[0]
                        )
                    ),
                ),
            )
        )
        self.add_page("tags", self.tag_panel, True)
        self.remotes_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.remote_settings_choice = Gtk.ComboBoxText()
        self.remote_settings_choice.connect("changed", self.remote_selected)
        self.remotes_panel.append(self.remote_settings_choice)
        self.remote_name = self.entry(self.remotes_panel, "リモート名")
        self.remote_url = self.entry(self.remotes_panel, "URL")
        self.remotes_panel.append(
            self.button(
                "保存",
                lambda: self.operate(
                    lambda: self.repo.set_remote(
                        self.remote_name.get_text(), self.remote_url.get_text()
                    )
                ),
            )
        )
        self.remotes_panel.append(
            self.button(
                "削除",
                lambda: self.confirm(
                    "リモートの登録と追跡参照を削除します。",
                    lambda: self.operate(
                        lambda: self.repo.remove_remote(self.remote_name.get_text())
                    ),
                ),
            )
        )
        self.add_page("remotes", self.remotes_panel, True)
        self.identity_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.identity_name = self.entry(self.identity_panel, "名前")
        self.identity_email = self.entry(self.identity_panel, "メールアドレス")
        self.identity_panel.append(
            self.button(
                "保存",
                lambda: self.operate(
                    lambda: self.repo.set_identity(
                        self.identity_name.get_text(), self.identity_email.get_text()
                    )
                ),
            )
        )
        self.add_page("identity", self.identity_panel, True)
        self.init_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.init_panel.append(
            label(self.L("作成済みフォルダに Git リポジトリを作成します。"))
        )
        self.init_panel.append(
            self.button("このフォルダにリポジトリを作成", self.initialize)
        )
        self.add_page("init", self.init_panel, True)
        self.build_advanced()
        self.build_settings()
        self.build_graph()
        self.sequence_bar = Gtk.Box(spacing=8)
        self.sequence_bar.append(
            label(self.L("競合または進行中の Git 操作があります。"))
        )
        self.sequence_bar.append(
            self.button("競合の解決を開く", lambda: self.navigate("conflicts"))
        )
        self.root.append(self.sequence_bar)
        self.progress = Gtk.ProgressBar(show_text=True)
        self.root.append(self.progress)
        self.status = label(self.L("準備完了"))
        self.status_scroll = Gtk.ScrolledWindow()
        self.status_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.status_scroll.set_propagate_natural_height(True)
        self.status_scroll.set_min_content_height(22)
        self.status_scroll.set_max_content_height(48)
        self.status_scroll.set_child(self.status)
        self.root.append(self.status_scroll)
        footer = Gtk.Box(spacing=8)
        self.other = Gtk.ComboBoxText(hexpand=True)
        self.other.append("placeholder", self.L("機能を選ぶ…"))
        for title, names in MENU_GROUPS:
            for name in names:
                self.other.append(
                    name, self.L(title) + " / " + self.L(ACTIONS[name][0])
                )
        self.other.set_active_id("placeholder")
        self.other.connect("changed", self.other_action)
        footer.append(self.other)
        self.push_button = self.button("Push", lambda: self.navigate("push"))
        footer.append(self.push_button)
        footer.append(self.button("閉じる", self.close))
        self.root.append(footer)
        self.static_labels = []
        self.capture_static_labels()
        self.set_action(self.action)
        self.apply_appearance()

    def button(self, title, callback):
        widget = Gtk.Button(label=self.L(title))
        widget.source_title = title
        widget.connect("clicked", lambda *_: callback())
        return widget

    def capture_static_labels(self):
        from settings import translations

        catalogue = translations()
        reverse = {value: key for key, value in catalogue.items()}
        excluded = {
            self.commit_details,
            self.graph_details,
            self.commit_list,
            self.graph_list,
            self.branch_logs,
            self.history,
            self.diff_view,
            self.remote_output,
            self.stash_preview,
            self.heading,
            self.hint,
            self.location,
            self.status,
            self.count,
            self.remote_notice,
            self.remote_result,
            self.clone_target,
            self.branch_notice,
            self.conflict_notice,
        }

        def capture(widget):
            if widget in excluded:
                return
            if isinstance(widget, Gtk.Label):
                source = widget.get_text()
                if source in catalogue or source in reverse:
                    self.static_labels.append(
                        (widget, source if source in catalogue else reverse[source])
                    )
            if isinstance(widget, Gtk.CheckButton) and widget.get_label():
                source = widget.get_label()
                self.static_labels.append(
                    (
                        widget,
                        source if source in catalogue else reverse.get(source, source),
                    )
                )
            child = widget.get_first_child()
            while child:
                capture(child)
                child = child.get_next_sibling()

        capture(self.root)

    def refresh_language(self):
        for widget, source in self.static_labels:
            widget.set_label(self.L(source))
        self.heading.set_text(self.L(ACTIONS[self.action][0]))
        self.hint.set_text(self.L(ACTIONS[self.action][1]))
        self.commit_details.set_record(self.commit_details.record)
        self.graph_details.set_record(self.graph_details.record)
        self.other.remove_all()
        self.other.append("placeholder", self.L("機能を選ぶ…"))
        for title, names in MENU_GROUPS:
            for name in names:
                self.other.append(
                    name, self.L(title) + " / " + self.L(ACTIONS[name][0])
                )
        self.other.set_active_id("placeholder")
        selected = self.theme_choice.get_active_id()
        self.theme_choice.remove_all()
        for id, title in [
            ("system", "システム"),
            ("light", "ライト"),
            ("dark", "ダーク"),
        ]:
            self.theme_choice.append(id, self.L(title))
        self.theme_choice.set_active_id(selected)
        self.controls()
        self.apply_appearance()

    def entry(self, box, title, value=""):
        heading = label(self.L(title))
        heading.source_title = title
        box.append(heading)
        widget = Gtk.Entry(text=value, hexpand=True)
        box.append(widget)
        return widget

    def add_page(self, name, widget, scroll=False):
        if scroll:
            container = Gtk.ScrolledWindow(vexpand=True)
            container.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
            container.set_child(widget)
            self.pages.add_named(container, name)
        else:
            self.pages.add_named(widget, name)

    def close_requested(self, *_):
        if self.busy:
            return True
        if (
            self.settings.values["keep_running"]
            and self.get_application().tray_available
        ):
            self.set_visible(False)
            return True
        self.executor.shutdown(wait=False)
        app = self.get_application()

        def finish_close():
            if not app.get_windows():
                app.quit_safely()
            return False

        GLib.idle_add(finish_close)
        return False

    def message_key(self, _, key, code, state):
        if (
            key == Gdk.KEY_Return
            and state & Gdk.ModifierType.CONTROL_MASK
            and self.commit_button.get_sensitive()
        ):
            self.commit()
            return True
        return False

    def other_action(self, choice):
        name = choice.get_active_id()
        if name and name != "placeholder":
            self.navigate(name)
            choice.set_active_id("placeholder")

    def navigate(self, action):
        if self.busy or action == self.action:
            return
        if self.route_request and window_purpose(action) != self.window_purpose:
            paths = (self.repo.path,) if self.repo else self.request.paths
            self.route_request(LaunchRequest(action, paths))
            return
        self.routes.append(
            (
                self.action,
                self.request,
                buffer_text(self.message),
                set(self.selected),
                self.commit_completed,
                self.status.get_text(),
            )
        )
        if self.action in ("menu", "workspace") and self.repo:
            self.request = LaunchRequest(action, (self.repo.path,))
        self.set_action(action)
        if self.repo and action not in ("open", "settings", "clone", "init"):
            self.task(self.snapshot, self.render)

    def back(self):
        if self.busy or not self.routes:
            return
        action, request, message, selection, completed, status = self.routes.pop()
        self.request = request
        self.selected = selection
        self.message.get_buffer().set_text(message)
        self.set_action(action)
        self.commit_completed = completed
        self.status.set_text(status)
        self.controls()
        if self.repo and action not in ("open", "settings", "clone", "init"):
            self.task(self.snapshot, self.render, status)

    def set_action(self, action):
        self.action = action
        self.succeeded = False
        self.commit_completed = False
        self.heading.set_text(self.L(ACTIONS[action][0]))
        self.hint.set_text(self.L(ACTIONS[action][1]))
        self.set_title(self.L(ACTIONS[action][0]) + " — GitNebula")
        page = (
            "files"
            if action in ("commit", "diff", "files")
            else (
                "log"
                if action in ("log", "cherry-pick", "revert")
                else (
                    "switch"
                    if action in ("switch", "merge", "rebase", "branches")
                    else (
                        "remote"
                        if action in ("pull", "push", "fetch")
                        else "menu" if action == "workspace" else action
                    )
                )
            )
        )
        self.pages.set_visible_child_name(page)
        if action == "clone" and not self.clone_destination.get_text():
            self.clone_destination.set_text(
                LaunchRequest.directory(self.request.paths[0])
                if self.request.paths
                else str(Path.home())
            )
        if action == "settings":
            self.load_settings()
        if self.repo:
            self.render_files()
        self.controls()

    def controls(self):
        if not hasattr(self, "status"):
            return
        ready = self.repo is not None and not self.busy
        idle = not self.sequence and not getattr(self, "conflicts", [])
        for name, control in self.launcher_buttons:
            control.set_sensitive(
                not self.busy and (self.repo is not None or name in ("clone", "init"))
            )
        self.pages.set_sensitive(not self.busy)
        self.nav.set_sensitive(not self.busy)
        self.other.set_sensitive(not self.busy)
        self.back_button.set_visible(bool(self.routes))
        self.path_bar.set_visible(self.action not in ("open", "settings", "clone"))
        self.heading.set_visible(self.action != "open")
        self.hint.set_visible(
            self.action not in ("open", "log", "graph", "cherry-pick", "revert")
            and bool(ACTIONS[self.action][1])
        )
        self.location.set_visible(
            self.repo is not None and self.action not in ("open", "settings", "clone")
        )
        self.refresh_button.set_sensitive(ready)
        self.commit_box.set_visible(self.action == "commit")
        self.select_all.set_visible(self.action != "diff")
        self.select_none.set_visible(self.action != "diff")
        self.stage_bar.set_visible(self.action == "files")
        self.commit_button.set_sensitive(
            ready
            and idle
            and bool(self.selected)
            and bool(buffer_text(self.message).strip())
        )
        self.cherry_button.set_visible(self.action in ("log", "cherry-pick"))
        self.revert_button.set_visible(self.action in ("log", "revert"))
        record = self.commit_details.record
        can_history = (
            ready
            and idle
            and not self.all_changes
            and record is not None
            and len(record.parents) <= 1
        )
        self.cherry_button.set_sensitive(can_history)
        self.revert_button.set_sensitive(can_history)
        chosen = self.branch_choice.get_active_id()
        self.switch_button.set_visible(self.action in ("switch", "branches"))
        self.switch_button.set_sensitive(
            ready
            and idle
            and not self.all_changes
            and bool(chosen)
            and chosen != getattr(self, "branch", "")
        )
        self.fetch_branches.set_visible(self.action in ("switch", "branches"))
        self.fetch_branches.set_sensitive(
            ready and bool(self.remote_choice.get_active_text())
        )
        self.advanced_branches.set_visible(self.action == "branches")
        self.integrate_button.set_visible(self.action in ("merge", "rebase"))
        self.integrate_button.set_label(self.L(ACTIONS[self.action][0]))
        self.integrate_button.set_sensitive(
            ready
            and idle
            and not self.all_changes
            and bool(chosen)
            and chosen != getattr(self, "branch", "")
        )
        self.execute_button.set_label(self.L(ACTIONS[self.action][0]))
        self.execute_button.set_sensitive(
            ready
            and bool(self.remote_choice.get_active_text())
            and (
                self.action == "fetch"
                or getattr(self, "head", None) is not None
                and getattr(self, "branch", "") != "detached HEAD"
                and (self.action != "pull" or idle and not self.all_changes)
            )
        )
        self.finish_button.set_visible(self.sequence == "merge")
        self.finish_button.set_sensitive(ready and not getattr(self, "conflicts", []))
        self.continue_button.set_visible(
            self.sequence in ("rebase", "cherry-pick", "revert")
        )
        self.continue_button.set_sensitive(ready and not getattr(self, "conflicts", []))
        self.abort_button.set_sensitive(ready and self.sequence is not None)
        self.sequence_bar.set_visible(
            self.action not in ("open", "settings", "clone", "conflicts") and not idle
        )
        self.push_button.set_visible(self.action == "commit" and self.commit_completed)
        self.other.set_visible(self.action not in ("open", "settings"))
        self.progress.set_visible(
            self.busy
            or self.succeeded
            and self.action in ("pull", "push", "fetch", "clone", "switch")
        )
        self.status_scroll.set_visible(self.action != "open")
        try:
            target = clone_destination(
                self.clone_destination.get_text(), self.clone_source.get_text()
            )
            self.clone_target.set_text(self.L("実際の作成先: ") + target)
        except ValueError:
            target = ""
            self.clone_target.set_text("")
        self.clone_button.set_sensitive(
            not self.busy
            and bool(target)
            and bool(self.clone_destination.get_text().strip())
        )

    def task(self, work, done, success="準備完了"):
        if self.busy:
            return
        self.snapshot_stash_id = self.stash_choice.get_active_id()
        self.snapshot_remote_id = self.remote_settings_choice.get_active_id()
        self.busy = True
        self.succeeded = False
        self.progress.set_fraction(0)
        self.progress.set_text(self.L("処理中…"))
        self.status.remove_css_class("error")
        self.status.set_text(self.L("処理中…"))
        self.controls()
        future = self.executor.submit(work)

        def finish():
            try:
                done(future.result())
                self.status.set_text(self.L(success))
                self.succeeded = success != "準備完了"
            except Exception as error:
                self.status.set_text(self.L(str(error)))
                self.status.add_css_class("error")
                self.succeeded = False
            finally:
                self.busy = False
                self.controls()
            return False

        future.add_done_callback(lambda _: GLib.idle_add(finish))

    def state(self, repo):
        commits = (
            repo.history(
                self.limit,
                self.action == "graph",
                self.history_filter_ref if self.action != "graph" else None,
            )
            if self.action in ("log", "cherry-pick", "revert", "graph")
            else []
        )
        selected = self.commit_details.record.id if self.commit_details.record else None
        record = next(
            (c for c in commits if c.id == selected), commits[0] if commits else None
        )
        stashes = repo.stashes() if self.action == "stash" else []
        stash = next(
            (s for s in stashes if s.id == self.snapshot_stash_id),
            stashes[0] if stashes else None,
        )
        remotes = repo.remotes()
        remote = self.snapshot_remote_id or (remotes[0] if remotes else "")
        return dict(
            advanced_output=(
                getattr(repo, self.action)()
                if self.action in ("reflog", "worktrees", "submodules")
                else ""
            ),
            preview=(
                (repo.show_commit(record.id), repo.revision_files(record.id))
                if record and self.action != "graph"
                else ("", [])
            ),
            stash_preview=repo.show_stash(stash.id) if stash else "",
            remote_name=remote,
            remote_url=(
                repo.run("remote", "get-url", remote).strip()
                if remote and self.action == "remotes"
                else ""
            ),
            repo=repo,
            branch=repo.branch(),
            changes=repo.changes(),
            branches=repo.branch_records(
                self.action in ("switch", "branches", "log", "cherry-pick", "revert")
            ),
            remotes=repo.remotes(),
            preferred=repo.preferred_remote(),
            conflicts=repo.conflicts(),
            sequence=repo.sequence(),
            head=repo.head(),
            commits=commits,
            stashes=stashes,
            tags=repo.tags() if self.action == "tags" else [],
            name=repo.configuration("user.name") if self.action == "identity" else "",
            email=repo.configuration("user.email") if self.action == "identity" else "",
        )

    def snapshot(self):
        return self.state(self.repo)

    def open_repository(self, path):
        self.repository_path.set_text(path)

        def work():
            repo = Repository(LaunchRequest.directory(path))
            for selected in self.request.paths:
                if Repository(LaunchRequest.directory(selected)).path != repo.path:
                    raise ValueError("同じリポジトリ内のファイルを選択してください。")
            return self.state(repo)

        self.task(work, self.render)

    def open_entered_path(self, *_):
        if self.busy:
            return
        path = self.repository_path.get_text().strip().strip("\"'")
        path = os.path.expanduser(path)
        if not os.path.isabs(path):
            self.status.set_text(self.L("フォルダの絶対パスを入力してください。"))
            return
        if (
            self.repo
            and os.path.realpath(LaunchRequest.directory(path)) != self.repo.path
        ):
            self.get_application().show_request(LaunchRequest(self.action, (path,)))
            return
        self.request = LaunchRequest(self.action, (path,))
        self.initial_selection = True
        self.open_repository(path)

    def choose(self, entry, callback=None):
        chooser = Gtk.FileChooserNative(
            title=self.L("フォルダを選択"),
            transient_for=self,
            action=Gtk.FileChooserAction.SELECT_FOLDER,
        )

        def response(dialog, answer):
            if answer == Gtk.ResponseType.ACCEPT:
                entry.set_text(dialog.get_file().get_path())
                callback and callback()
            dialog.destroy()

        chooser.connect("response", response)
        chooser.show()

    def render(self, state):
        if self.action in self.advanced_outputs:
            self.advanced_outputs[self.action].get_buffer().set_text(
                state["advanced_output"]
            )
        self.repo = state["repo"]
        self.branch = state["branch"]
        self.all_changes = state["changes"]
        self.sequence = state["sequence"]
        self.merging = self.sequence == "merge"
        self.conflicts = state["conflicts"]
        self.head = state["head"]
        if (
            not self.routes
            and self.request.paths
            and self.action
            not in ("open", "settings", "menu", "workspace", "clone", "init")
        ):
            self.routes.append(
                (
                    "menu",
                    LaunchRequest("menu", (self.repo.path,)),
                    "",
                    set(),
                    False,
                    self.L("準備完了"),
                )
            )
        self.location.set_text(self.repo.path + "  ·  " + self.branch)
        self.location.set_tooltip_text(self.location.get_text())
        self.render_files()
        for choice, records, preferred in [
            (
                self.branch_choice,
                [
                    (b.id, b.name + ("  · " + self.L("リモート") if b.remote else ""))
                    for b in state["branches"]
                ],
                self.branch_choice.get_active_id(),
            ),
            (
                self.remote_choice,
                [(r, r) for r in state["remotes"]],
                self.remote_choice.get_active_id() or state["preferred"],
            ),
            (
                self.conflict_choice,
                [(r, r) for r in state["conflicts"]],
                self.conflict_choice.get_active_id(),
            ),
            (
                self.stash_choice,
                [(s.id, s.title) for s in state["stashes"]],
                self.stash_choice.get_active_id(),
            ),
            (
                self.tag_choice,
                [(r, r) for r in state["tags"]],
                self.tag_choice.get_active_id(),
            ),
            (
                self.remote_settings_choice,
                [(r, r) for r in state["remotes"]],
                self.remote_settings_choice.get_active_id(),
            ),
        ]:
            choice.remove_all()
            for id, title in records:
                choice.append(id, title)
            ids = [r[0] for r in records]
            if ids:
                choice.set_active_id(
                    preferred
                    if preferred in ids
                    else next((id for id in ids if id != self.branch), ids[0])
                )
        self.branch_notice.set_text(
            self.L(
                "切り替え・Merge・Rebase の前に、変更をコミットまたは Stash してください。"
            )
            if self.all_changes
            else self.L("操作するブランチを選んでください。")
        )
        self.conflict_notice.set_text(
            (self.sequence or "")
            + " "
            + self.L("競合を解決して再開、または中止してください。")
            if self.sequence
            else self.L("解決が必要な競合や進行中の操作はありません。")
        )
        self.remote_notice.set_text(
            self.L("送受信先を選択してください。")
            if not state["remotes"]
            else self.branch + " ↔ " + (self.remote_choice.get_active_text() or "")
        )
        if self.action in ("log", "cherry-pick", "revert"):
            previous = self.history_filter_ref or "all"
            self.history_filter.remove_all()
            self.history_filter.append("all", self.L("すべてのブランチ"))
            self.history_filter.append("HEAD", "HEAD")
            for branch in state["branches"]:
                self.history_filter.append(branch.id, branch.name)
            self.history_filter.set_active_id(previous)
            if self.history_filter.get_active_id() is None:
                self.history_filter.set_active_id("all")
        if self.action in ("log", "cherry-pick", "revert", "graph"):
            self.records = state["commits"]
            self.render_commits()
            self.render_graph()
        if self.action == "identity":
            self.identity_name.set_text(state["name"])
            self.identity_email.set_text(state["email"])
        if self.action == "stash":
            self.stash_preview.get_buffer().set_text(state["stash_preview"])
        if self.action in ("log", "cherry-pick", "revert"):
            self.history.get_buffer().set_text(state["preview"][0])
            self.history_files.set_commit(
                self.commit_details.record, state["preview"][1]
            )
        if self.action == "remotes":
            self.remote_name.set_text(state["remote_name"])
            self.remote_url.set_text(state["remote_url"])
        self.controls()

    def preview_working_file(self, path):
        def done(result):
            output, document = result
            self.diff_view.get_buffer().set_text(output)
            self.working_comparison.set_document(document)

        self.task(lambda: (self.repo.diff(path), self.repo.file_comparison(path)), done)

    def render_files(self):
        self.changes = [
            c
            for c in self.all_changes
            if self.action == "files" or self.request.includes(c.path, self.repo.path)
        ]
        available = {c.path for c in self.changes}
        self.selected = (
            available if self.initial_selection else self.selected & available
        )
        self.initial_selection = False
        self.count.set_text(str(len(self.changes)) + " " + self.L("ファイル"))
        while self.files.get_first_child():
            self.files.remove(self.files.get_first_child())
        for change in self.changes:
            row = Gtk.Box(spacing=8)
            check = Gtk.CheckButton(active=change.path in self.selected)
            check.set_visible(self.action != "diff")
            check.connect(
                "toggled",
                lambda widget, path=change.path: self.toggle(path, widget.get_active()),
            )
            row.append(check)
            row.append(
                self.button(
                    change.label + "  " + change.path,
                    lambda path=change.path: self.preview_working_file(path),
                )
            )
            self.files.append(row)
        if not self.changes:
            self.files.append(label(self.L("対象に未コミットの変更はありません。")))

    def toggle(self, path, active):
        self.selected.add(path) if active else self.selected.discard(path)
        self.controls()

    def select_files(self, active):
        row = self.files.get_first_child()
        while row:
            child = row.get_child()
            if isinstance(child, Gtk.Box):
                child.get_first_child().set_active(active)
            row = row.get_next_sibling()

    def operate(self, operation):
        def work():
            error = None
            try:
                operation()
            except Exception as caught:
                error = caught
            return self.snapshot(), error

        def done(result):
            self.render(result[0])
            if result[1]:
                raise result[1]

        self.task(work, done, "完了しました。")

    def commit(self, *_):
        paths = list(self.selected)
        message = buffer_text(self.message)

        def work():
            self.repo.commit(paths, message)
            return self.snapshot()

        def done(state):
            self.message.get_buffer().set_text("")
            self.render(state)
            self.commit_completed = True

        self.task(work, done, "コミットしました。")

    def update_progress(self, progress):
        def update():
            self.progress.set_text(
                self.L(progress.stage)
                + (f"  {progress.percent}%" if progress.percent is not None else "")
            )
            if progress.percent is None:
                self.progress.pulse()
            else:
                self.progress.set_fraction(progress.percent / 100)
            return False

        GLib.idle_add(update)

    def transfer(self):
        remote = self.remote_choice.get_active_text()
        action = self.action

        def work():
            report = self.repo.transfer(action, remote, self.update_progress)
            return self.snapshot(), report

        def done(result):
            self.render(result[0])
            self.remote_result.set_text(result[1].summary)
            self.remote_output.get_buffer().set_text(result[1].output)
            self.status.set_text(result[1].summary)
            self.update_progress(TransferProgress("完了", 100, True))

        self.task(work, done, "完了しました。")

    def refresh_branches(self):
        def work():
            self.repo.transfer(
                "fetch",
                self.remote_choice.get_active_text(),
                self.update_progress,
                all_branches=True,
            )
            return self.snapshot()

        def done(state):
            self.render(state)
            self.update_progress(TransferProgress("完了", 100, True))

        self.task(work, done, "リモートのブランチ一覧を更新しました。")

    def clone(self):
        source = self.clone_source.get_text()
        destination = clone_destination(self.clone_destination.get_text(), source)

        def work():
            return self.state(
                Repository.clone(source, destination, self.update_progress)
            )

        def done(state):
            self.request = LaunchRequest("clone", (state["repo"].path,))
            self.render(state)
            self.update_progress(TransferProgress("完了", 100, True))

        self.task(work, done, "Clone が完了しました。")

    def initialize(self):
        path = self.repository_path.get_text() or (
            self.request.paths[0] if self.request.paths else ""
        )
        self.task(
            lambda: self.state(Repository.initialize(path)),
            self.render,
            "リポジトリを作成しました。",
        )

    def render_commits(self):
        selected = self.commit_details.record.id if self.commit_details.record else None
        query = self.search.get_text().casefold()
        while self.commit_list.get_first_child():
            self.commit_list.remove(self.commit_list.get_first_child())
        chosen = None
        for commit in self.records:
            if (
                query
                and query
                not in (
                    commit.id
                    + " "
                    + commit.message
                    + " "
                    + commit.author
                    + " "
                    + commit.decorations
                ).casefold()
            ):
                continue
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            box.append(label(commit.subject))
            box.append(label(commit.id, True))
            box.append(label(commit.author + "  ·  " + commit.date))
            row = Gtk.ListBoxRow()
            row.record = commit
            row.set_child(box)
            self.commit_list.append(row)
            if commit.id == selected:
                chosen = row
        self.commit_list.select_row(chosen or self.commit_list.get_first_child())

    def commit_selected(self, _, row):
        record = row.record if row else None
        self.commit_details.set_record(record)
        self.controls()
        if record and not self.busy:
            self.task(
                lambda: (
                    self.repo.show_commit(record.id),
                    self.repo.revision_files(record.id),
                ),
                lambda result: (
                    self.history.get_buffer().set_text(result[0]),
                    self.history_files.set_commit(record, result[1]),
                ),
            )
        elif not record:
            self.history.get_buffer().set_text("")

    def history_branch_changed(self, choice):
        if self.busy:
            return
        id = choice.get_active_id()
        self.history_filter_ref = id if id and id != "all" else None
        if self.repo:
            self.task(self.snapshot, self.render)

    def more_history(self):
        self.limit += 200
        self.task(self.snapshot, self.render)

    def history_operation(self, name):
        record = self.commit_details.record
        if record:
            self.confirm(
                record.id + "\n" + record.subject,
                lambda: self.operate(lambda: getattr(self.repo, name)(record.id)),
            )

    def integrate(self):
        branch = self.branch_choice.get_active_id()
        name = self.action
        self.confirm(
            self.branch + " ← " + str(branch) + " (" + name + ")",
            lambda: self.operate(lambda: getattr(self.repo, name)(branch)),
        )

    def stash_selected(self, choice):
        id = choice.get_active_id()
        if not self.busy and self.repo and id:
            self.task(
                lambda: self.repo.show_stash(id),
                lambda text: self.stash_preview.get_buffer().set_text(text),
            )

    def remote_selected(self, choice):
        name = choice.get_active_text()
        if not self.busy and self.repo and name:
            self.task(
                lambda: self.repo.run("remote", "get-url", name).strip(),
                lambda url: (
                    self.remote_name.set_text(name),
                    self.remote_url.set_text(url),
                ),
            )

    def prompt(self, title, fields, callback):
        dialog = Gtk.Dialog(title=self.L(title), transient_for=self, modal=True)
        dialog.add_button(self.L("キャンセル"), Gtk.ResponseType.CANCEL)
        dialog.add_button(self.L("実行"), Gtk.ResponseType.OK)
        entries = [
            self.entry(dialog.get_content_area(), title, value)
            for title, value in fields
        ]

        def response(widget, answer):
            values = [entry.get_text() for entry in entries]
            widget.destroy()
            if answer == Gtk.ResponseType.OK:
                callback(values)

        dialog.connect("response", response)
        dialog.present()

    def confirm(self, message, callback):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            text=self.L(message),
            buttons=Gtk.ButtonsType.OK_CANCEL,
        )

        def response(widget, answer):
            widget.destroy()
            callback() if answer == Gtk.ResponseType.OK else None

        dialog.connect("response", response)
        dialog.present()

    def edit_conflict(self):
        path = self.conflict_choice.get_active_text()

        def show(text):
            dialog = Gtk.Dialog(title=path, transient_for=self, modal=True)
            dialog.set_default_size(850, 550)
            dialog.add_button(self.L("キャンセル"), Gtk.ResponseType.CANCEL)
            dialog.add_button(self.L("保存して解決"), Gtk.ResponseType.OK)
            editor = Gtk.TextView(monospace=True)
            editor.get_buffer().set_text(text)
            scroll = Gtk.ScrolledWindow(vexpand=True)
            scroll.set_child(editor)
            dialog.get_content_area().append(scroll)

            def response(widget, answer):
                value = buffer_text(editor)
                widget.destroy()
                if answer == Gtk.ResponseType.OK:
                    self.operate(lambda: self.repo.save_resolution(path, value))

            dialog.connect("response", response)
            dialog.present()

        self.task(lambda: self.repo.conflict_text(path), show)

    def build_settings(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.theme_choice = Gtk.ComboBoxText()
        for id, title in [
            ("system", "システム"),
            ("light", "ライト"),
            ("dark", "ダーク"),
        ]:
            self.theme_choice.append(id, self.L(title))
        box.append(label(self.L("テーマ")))
        box.append(self.theme_choice)
        self.language_choice = Gtk.ComboBoxText()
        self.language_choice.append("ja", "日本語")
        self.language_choice.append("en", "English")
        box.append(label(self.L("言語")))
        box.append(self.language_choice)
        self.transparency = Gtk.Scale.new_with_range(
            Gtk.Orientation.HORIZONTAL, 0, 80, 1
        )
        self.transparency.set_draw_value(True)
        box.append(label(self.L("透明度")))
        box.append(self.transparency)
        self.keep_running = Gtk.CheckButton(
            label=self.L("ウィンドウを閉じても常駐する")
        )
        box.append(self.keep_running)
        self.show_home = Gtk.CheckButton(label=self.L("起動時にアプリ画面を開く"))
        box.append(self.show_home)
        self.autostart = Gtk.CheckButton(label=self.L("ログイン時に自動起動"))
        box.append(self.autostart)
        self.git_executable = self.entry(box, "Git の実行ファイル")
        self.ssh_key = self.entry(box, "SSH 秘密鍵")
        box.append(self.button("秘密鍵を選択…", self.choose_key))
        self.ssh_phrase = self.entry(box, "パスフレーズ")
        self.ssh_phrase.set_visibility(False)
        self.ssh_phrase.set_input_purpose(Gtk.InputPurpose.PASSWORD)
        box.append(
            self.button(
                "保存したパスフレーズを削除",
                lambda: self.task(
                    lambda: SecretStore.remove(self.ssh_key.get_text()),
                    lambda _: self.ssh_phrase.set_text(""),
                    "保存したパスフレーズを削除しました。",
                ),
            )
        )
        box.append(self.button("保存", self.save_settings))
        self.add_page("settings", box, True)
        self.system_settings = Gtk.Settings.get_default()
        self.system_settings.connect(
            "notify::gtk-application-prefer-dark-theme",
            lambda *_: (
                self.apply_appearance()
                if self.settings.values["theme"] == "system"
                else None
            ),
        )
        self.system_settings.connect(
            "notify::gtk-theme-name",
            lambda *_: (
                self.apply_appearance()
                if self.settings.values["theme"] == "system"
                else None
            ),
        )

        self.portal_dark = None
        try:
            self.appearance_portal = Gio.DBusProxy.new_for_bus_sync(
                Gio.BusType.SESSION,
                Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                None,
                "org.freedesktop.portal.Desktop",
                "/org/freedesktop/portal/desktop",
                "org.freedesktop.portal.Settings",
                None,
            )
            value = self.appearance_portal.call_sync(
                "Read",
                GLib.Variant("(ss)", ("org.freedesktop.appearance", "color-scheme")),
                Gio.DBusCallFlags.NONE,
                1000,
                None,
            ).get_child_value(0)
            while value.get_type_string() == "v":
                value = value.get_variant()
            scheme = value.unpack()
            self.portal_dark = scheme == 1 if scheme in (1, 2) else None
            self.appearance_portal.connect("g-signal", self.portal_appearance_changed)
        except GLib.Error:
            self.appearance_portal = None

    def portal_appearance_changed(self, proxy, sender, signal, parameters):
        if signal != "SettingChanged":
            return
        namespace, key, value = parameters.unpack()
        if namespace == "org.freedesktop.appearance" and key == "color-scheme":
            self.portal_dark = value == 1 if value in (1, 2) else None
            if self.settings.values["theme"] == "system":
                self.apply_appearance()

    @property
    def autostart_path(self):
        return self.settings.autostart_path

    def load_settings(self):
        values = self.settings.values
        self.theme_choice.set_active_id(values["theme"])
        self.language_choice.set_active_id(values["language"])
        self.transparency.set_value(values["transparency"] * 100)
        self.keep_running.set_active(values["keep_running"])
        self.show_home.set_active(values["show_home"])
        self.autostart.set_active(self.autostart_path.exists())
        self.git_executable.set_text(values["git_executable"])
        self.ssh_key.set_text(values["ssh_key"])
        try:
            self.ssh_phrase.set_text(
                SecretStore.read(values["ssh_key"]) or "" if values["ssh_key"] else ""
            )
        except Exception as error:
            self.ssh_phrase.set_text("")
            self.status.set_text(self.L(str(error)))

    def choose_key(self):
        chooser = Gtk.FileChooserNative(
            title=self.L("SSH 秘密鍵を選択"),
            transient_for=self,
            action=Gtk.FileChooserAction.OPEN,
        )

        def response(widget, answer):
            if answer == Gtk.ResponseType.ACCEPT:
                self.ssh_key.set_text(widget.get_file().get_path())
            widget.destroy()

        chooser.connect("response", response)
        chooser.show()

    def save_settings(self):
        values = dict(
            theme=self.theme_choice.get_active_id(),
            language=self.language_choice.get_active_id(),
            transparency=self.transparency.get_value() / 100,
            keep_running=self.keep_running.get_active(),
            show_home=self.show_home.get_active(),
            git_executable=self.git_executable.get_text().strip(),
            ssh_key=self.ssh_key.get_text().strip(),
        )
        phrase = self.ssh_phrase.get_text()
        startup = self.autostart.get_active()

        def work():
            key = values["ssh_key"]
            if key:
                key = str(Path(key).expanduser().absolute())
                values["ssh_key"] = key
                if not Path(key).is_file() or key.endswith(".pub"):
                    raise ValueError(
                        "読み込み可能な秘密鍵を選択してください。公開鍵（.pub）は使用できません。"
                    )
                if phrase:
                    SecretStore.save(key, phrase)
            elif phrase:
                raise ValueError("パスフレーズを保存する秘密鍵を選択してください。")
            self.settings.values.update(values)
            self.settings.save()
            self.settings.set_autostart(startup)

        def done(_):
            self.apply_appearance()
            self.get_application().refresh_languages()
            self.load_settings()

        self.task(work, done, "アプリの設定を保存しました。")

    def apply_appearance(self):
        theme = self.settings.values["theme"]
        system = (
            self.system_settings
            if hasattr(self, "system_settings")
            else Gtk.Settings.get_default()
        )
        system_dark = (
            self.portal_dark
            if getattr(self, "portal_dark", None) is not None
            else (
                system.get_property("gtk-application-prefer-dark-theme")
                or "dark" in system.get_property("gtk-theme-name").lower()
            )
        )
        dark = theme == "dark" or theme == "system" and system_dark
        background, foreground, surface, control = (
            ("#090d1d", "#e9eafa", "#12182c", "#28253f")
            if dark
            else ("#f4f4fa", "#202035", "#ffffff", "#e8e4f5")
        )
        self.css.load_from_data(
            f"window {{background:{background};color:{foreground};}} textview,textview text,entry,list {{background:{surface};color:{foreground};}} button {{padding:7px 12px;background:{control};color:{foreground};}} .title {{font-size:24px;font-weight:bold;}} .brand {{font-size:38px;font-weight:bold;color:#9970dd;animation:nebulaTitle 10s ease-in-out infinite;}} @keyframes nebulaTitle {{0% {{color:#4fa3f5;}} 50% {{color:#d96aaa;}} 100% {{color:#9970dd;}}}} .commit-message,.commit-value {{font-size:15px;}} .commit-id {{font-size:14px;font-weight:bold;}} .monospace {{font-family:monospace;}} .error {{color:#db782a;}} .commit-copy-button {{padding:6px 8px;font-size:13px;}}".encode()
        )
        self.set_opacity(1 - max(0, min(0.8, self.settings.values["transparency"])))

    def build_graph(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        bar = Gtk.Box(spacing=8)
        self.graph_mode = Gtk.ComboBoxText()
        self.graph_mode.append("normal", self.L("通常"))
        self.graph_mode.append("4d", "4D")
        self.graph_mode.set_active_id(self.settings.values["graph_mode"])
        self.graph_mode.connect("changed", self.graph_mode_changed)
        bar.append(self.graph_mode)
        bar.append(self.button("さらに 200 件読み込む", self.more_history))
        bar.append(self.button("全体を表示", lambda: self.nebula.reset()))
        box.append(bar)
        split = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL, vexpand=True)
        split.set_position(240)
        split.set_shrink_start_child(False)
        split.set_shrink_end_child(False)
        split.set_resize_start_child(True)
        split.set_resize_end_child(True)
        self.graph_stack = Gtk.Stack(vexpand=True)
        self.graph_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.graph_list.connect("row-selected", self.graph_selected)
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(80)
        scroll.set_child(self.graph_list)
        self.graph_stack.add_named(scroll, "normal")
        self.space = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        self.nebula = NebulaView(select=self.branch_selected)
        self.space.set_start_child(self.nebula)
        self.branch_logs = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.branch_logs.connect("row-selected", self.graph_selected)
        logs = Gtk.ScrolledWindow()
        logs.set_size_request(240, -1)
        logs.set_child(self.branch_logs)
        self.space.set_end_child(logs)
        self.graph_stack.add_named(self.space, "4d")
        split.set_start_child(self.graph_stack)
        self.graph_details = CommitDetails(self.L)
        graph_tabs = Gtk.Notebook()
        graph_tabs.set_size_request(-1, 180)
        graph_tabs.append_page(
            self.graph_details, Gtk.Label(label=self.L("コミット情報"))
        )
        self.graph_files = RevisionBrowser(self)
        graph_tabs.append_page(
            self.graph_files, Gtk.Label(label=self.L("変更ファイル"))
        )
        split.set_end_child(graph_tabs)
        box.append(split)
        timeline = Gtk.Box(spacing=8)
        self.timeline_bar = timeline
        self.playing = False
        self.play_timer = None
        timeline.append(self.button("履歴を再生", self.play_timeline))
        self.timeline = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 1, 2, 1)
        self.timeline.set_hexpand(True)
        self.timeline.connect("value-changed", self.timeline_changed)
        timeline.append(self.timeline)
        self.timeline_label = Gtk.Label()
        timeline.append(self.timeline_label)
        box.append(timeline)
        self.pages.add_named(box, "graph")
        self.graph_stack.set_visible_child_name(self.settings.values["graph_mode"])
        self.timeline_bar.set_visible(self.settings.values["graph_mode"] == "4d")

    def graph_mode_changed(self, choice):
        mode = choice.get_active_id()
        if mode not in ("normal", "4d"):
            return
        self.graph_stack.set_visible_child_name(mode)
        self.timeline_bar.set_visible(mode == "4d")
        self.settings.values["graph_mode"] = mode
        self.settings.save()

    def render_graph(self):
        if self.action != "graph":
            return
        selected = self.graph_details.record.id if self.graph_details.record else None
        while self.graph_list.get_first_child():
            self.graph_list.remove(self.graph_list.get_first_child())
        chosen = None
        for row in graph_rows(self.records):
            box = Gtk.Box(spacing=8)
            area = Gtk.DrawingArea()
            area.set_content_width(max(40, row.width * 20 + 20))
            area.set_content_height(48)

            def draw(_, ctx, width, height, row=row):
                for start, end, color in row.incoming:
                    ctx.set_source_rgb(*PALETTE[color % len(PALETTE)])
                    ctx.set_line_width(2)
                    ctx.move_to(start * 20 + 14, 0)
                    ctx.line_to(end * 20 + 14, 24)
                    ctx.stroke()
                for start, end, color in row.outgoing:
                    ctx.set_source_rgb(*PALETTE[color % len(PALETTE)])
                    ctx.move_to(start * 20 + 14, 24)
                    ctx.curve_to(
                        start * 20 + 14, 34, end * 20 + 14, 38, end * 20 + 14, 48
                    )
                    ctx.stroke()
                ctx.set_source_rgb(*PALETTE[row.color % len(PALETTE)])
                ctx.arc(row.lane * 20 + 14, 24, 5, 0, 6.28318)
                ctx.fill()

            area.set_draw_func(draw)
            box.append(area)
            text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            text.append(label(row.commit.subject))
            text.append(label(row.commit.id, True))
            box.append(text)
            item = Gtk.ListBoxRow()
            item.record = row.commit
            item.set_child(box)
            self.graph_list.append(item)
            if row.commit.id == selected:
                chosen = item
        self.graph_list.select_row(chosen or self.graph_list.get_first_child())
        self.nebula.set_commits(self.records)
        self.timeline.set_range(1, max(2, len(self.records)))
        self.timeline.set_value(max(1, len(self.records)))
        if self.nebula.branches:
            self.branch_selected(self.nebula.branches[0])

    def graph_selected(self, _, row):
        record = row.record if row else None
        self.graph_details.set_record(record)
        self.graph_files.set_commit(record)
        self.nebula.selection = record.id if record else None
        self.nebula.queue_draw()

    def branch_selected(self, branch):
        while self.branch_logs.get_first_child():
            self.branch_logs.remove(self.branch_logs.get_first_child())
        visible = {c.id for c in self.records[-self.nebula.visible_count :]}
        for commit in branch.commits:
            if commit.id not in visible:
                continue
            row = Gtk.ListBoxRow()
            row.record = commit
            row.set_child(label(commit.subject + "\n" + commit.id))
            self.branch_logs.append(row)
        self.branch_logs.select_row(self.branch_logs.get_first_child())

    def timeline_changed(self, scale):
        self.nebula.visible_count = min(len(self.records), int(scale.get_value()))
        self.timeline_label.set_text(
            str(self.nebula.visible_count) + " / " + str(len(self.records))
        )
        self.nebula.queue_draw()
        if self.nebula.branches:
            branch = next(
                (
                    b
                    for b in self.nebula.branches
                    if any(c.id == self.nebula.selection for c in b.commits)
                ),
                self.nebula.branches[0],
            )
            self.branch_selected(branch)

    def play_timeline(self):
        if not self.system_settings.get_property("gtk-enable-animations"):
            return
        if self.play_timer is not None:
            GLib.source_remove(self.play_timer)
            self.play_timer = None
        self.playing = not self.playing
        if self.playing and self.timeline.get_value() >= len(self.records):
            self.timeline.set_value(1)

        def step():
            if not self.playing or not self.get_visible() or self.action != "graph":
                self.playing = False
                self.play_timer = None
                return False
            self.timeline.set_value(
                min(
                    len(self.records),
                    self.timeline.get_value() + max(1, len(self.records) // 80),
                )
            )
            if self.timeline.get_value() >= len(self.records):
                self.playing = False
            if not self.playing:
                self.play_timer = None
            return self.playing

        if self.playing:
            self.play_timer = GLib.timeout_add(450, step)


class App(Gtk.Application):
    def __init__(self, request=None):
        super().__init__(
            application_id="dev.gitnebula.desktop",
            flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE,
        )
        self.request = request or LaunchRequest()
        self.settings = Settings()
        self.tray_available = False
        self.started = False
        self.resident = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()
        try:
            from tray import Tray

            self.resident = Tray(self)
            self.tray_available = self.resident.available
        except GLib.Error:
            self.tray_available = False

    def do_command_line(self, command_line):
        request = LaunchRequest.parse(command_line.get_arguments()[1:])
        was_started = self.started
        self.started = True
        if request.paths or request.action != "open":
            self.show_request(request)
        elif (
            was_started or self.settings.values["show_home"] or not self.tray_available
        ):
            self.show_request(LaunchRequest())
        return 0

    def do_activate(self):
        self.show_request(self.request)

    def show_request(self, request):
        root = None
        if request.paths and request.action not in (
            "clone",
            "init",
            "open",
            "settings",
        ):
            try:
                root = Repository(LaunchRequest.directory(request.paths[0])).path
            except RuntimeError:
                pass
        window = next(
            (
                w
                for w in self.get_windows()
                if isinstance(w, Window)
                and root
                and w.repo
                and w.repo.path == root
                and w.window_purpose == window_purpose(request.action)
            ),
            None,
        )
        if window:
            if window.busy:

                def retry():
                    if window.busy:
                        return True
                    self.show_request(request)
                    return False

                GLib.timeout_add(100, retry)
                return
            # Capture the previous scope before replacing it, then refresh even when
            # the action is unchanged and only the right-click selection differs.
            if request.action != window.action:
                window.routes.append(
                    (
                        window.action,
                        window.request,
                        buffer_text(window.message),
                        set(window.selected),
                        window.commit_completed,
                        window.status.get_text(),
                    )
                )
            window.request = request
            if request.paths and request.action in ("commit", "diff"):
                window.initial_selection = True
                window.selected.clear()
            window.set_action(request.action)
            if window.repo and request.action not in (
                "open",
                "settings",
                "clone",
                "init",
            ):
                window.task(window.snapshot, window.render)
        else:
            window = Window(self, request)
            if request.paths:
                window.repository_path.set_text(
                    LaunchRequest.directory(request.paths[0])
                )
                if request.action not in ("clone", "init", "open", "settings"):
                    window.open_repository(request.paths[0])
        window.route_request = self.show_request
        window.present()

    def refresh_languages(self):
        for window in self.get_windows():
            if isinstance(window, Window):
                window.refresh_language()
        if self.resident:
            self.resident.refresh()

    def quit_safely(self):
        if any(isinstance(w, Window) and w.busy for w in self.get_windows()):
            return
        for window in self.get_windows():
            if isinstance(window, Window):
                window.executor.shutdown(wait=False)
        self.quit()


def askpass():
    confirm = (
        os.environ.get("SSH_ASKPASS_PROMPT") == "confirm"
        or "Are you sure you want to continue connecting" in askpass_prompt
    )
    if not confirm and not is_key_prompt(askpass_prompt, askpass_key):
        return 1
    Gtk.init()
    loop = GLib.MainLoop()
    result = []
    dialog = Gtk.Dialog(title="GitNebula SSH", modal=True)
    dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
    dialog.add_button("Connect", Gtk.ResponseType.OK)
    dialog.get_content_area().append(label(askpass_prompt))
    field = Gtk.Entry(visibility=False)
    if not confirm:
        dialog.get_content_area().append(field)

    def response(widget, answer):
        if answer == Gtk.ResponseType.OK:
            result.append("yes" if confirm else field.get_text())
        widget.destroy()
        loop.quit()

    dialog.connect("response", response)
    dialog.present()
    loop.run()
    if result:
        sys.stdout.write(result[0] + "\n")
        return 0
    return 1


if __name__ == "__main__":
    if askpass_prompt is not None:
        raise SystemExit(askpass())
    raise SystemExit(App(launch_request).run(sys.argv))
