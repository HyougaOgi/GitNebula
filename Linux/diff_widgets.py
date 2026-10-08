from gi.repository import Gtk
from gtk_widgets import label, button


class DiffComparison(Gtk.Box):
    def __init__(self, text=lambda s: s):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6, vexpand=True)
        self.text = text
        self.title = label("")
        self.notice = label("")
        self.append(self.title)
        bar = Gtk.Box(spacing=6)
        bar.append(button(text("前の変更"), lambda: self.jump(-1)))
        bar.append(button(text("次の変更"), lambda: self.jump(1)))
        self.append(bar)
        self.append(self.notice)
        self.views, self.scrolls = [], []
        self.hunks, self.hunk, self.syncing = (), -1, False
        columns = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, vexpand=True)
        columns.set_wide_handle(True)
        for before in (True, False):
            view = Gtk.TextView(
                editable=False, monospace=True, wrap_mode=Gtk.WrapMode.NONE
            )
            view.get_buffer().create_tag(
                "removed", background="#552d38", foreground="#ffffff"
            )
            view.get_buffer().create_tag(
                "added", background="#214734", foreground="#ffffff"
            )
            scroll = Gtk.ScrolledWindow(vexpand=True, hexpand=True)
            scroll.set_child(view)
            self.views.append(view)
            self.scrolls.append(scroll)
            (columns.set_start_child if before else columns.set_end_child)(scroll)
        self.append(columns)
        for index, scroll in enumerate(self.scrolls):
            scroll.get_vadjustment().connect(
                "value-changed",
                lambda adjustment, index=index: self.sync(
                    index, adjustment.get_value()
                ),
            )

    def set_document(self, document):
        self.document = document
        self.hunks, self.hunk = document.hunks, -1
        self.title.set_text(
            document.path
            + "\n"
            + self.text(document.old_title)
            + "  →  "
            + self.text(document.new_title)
        )
        self.notice.set_text(self.text(document.notice))
        for index, view in enumerate(self.views):
            before = index == 0
            buffer = view.get_buffer()
            buffer.set_text(
                "\n".join(
                    f'{str(row.old_number if before else row.new_number) if (row.old_number if before else row.new_number) else "":>6}  {row.old if before else row.new}'
                    for row in document.rows
                )
            )
            for number, row in enumerate(document.rows):
                if row.kind == "unchanged":
                    continue
                start = buffer.get_iter_at_line(number)[1]
                end = start.copy()
                end.forward_line()
                buffer.apply_tag_by_name("removed" if before else "added", start, end)
            self.scrolls[index].get_vadjustment().set_value(0)

    def sync(self, source, value):
        if self.syncing:
            return
        self.syncing = True
        self.scrolls[1 - source].get_vadjustment().set_value(value)
        self.syncing = False

    def jump(self, direction):
        if not self.hunks:
            return
        self.hunk = max(0, min(len(self.hunks) - 1, self.hunk + direction))
        iterator = self.views[0].get_buffer().get_iter_at_line(self.hunks[self.hunk])[1]
        self.scrolls[0].get_vadjustment().set_value(
            self.views[0].get_iter_location(iterator).y
        )


class RevisionBrowser(Gtk.Box):
    def __init__(self, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6, vexpand=True)
        self.window = window
        self.record = None
        self.loading = False
        self.parents = Gtk.ComboBoxText()
        self.parents.connect("changed", self.parent_changed)
        self.append(self.parents)
        columns = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL, vexpand=True)
        self.files = Gtk.ListBox()
        self.files.connect("row-selected", self.file_selected)
        scroll = Gtk.ScrolledWindow()
        scroll.set_child(self.files)
        columns.set_start_child(scroll)
        self.comparison = DiffComparison(window.L)
        columns.set_end_child(self.comparison)
        self.append(columns)
        self.connect("map", lambda *_: self.load_if_needed())

    def set_commit(self, record, files=None):
        if self.record and record and self.record.id == record.id and files is None:
            return
        self.record = record
        self.loading = True
        self.parents.remove_all()
        if record:
            for parent in record.parents:
                self.parents.append(parent, parent)
            self.parents.set_active(0)
        self.parents.set_visible(record is not None and len(record.parents) > 1)
        self.set_files(files or [])
        self.loaded = files is not None
        self.loading = False

    def set_files(self, files):
        while self.files.get_first_child():
            self.files.remove(self.files.get_first_child())
        for item in files:
            row = Gtk.ListBoxRow()
            row.file = item
            row.set_child(label(item[0] + "  " + item[1]))
            self.files.append(row)

    def load_if_needed(self):
        if self.record and not self.loaded and not self.window.busy:
            self.parent_changed(self.parents)

    def parent_changed(self, choice):
        if self.loading or not self.record or self.window.busy:
            return
        record, parent = self.record, choice.get_active_id()

        def done(files):
            self.set_files(files)
            self.loaded = True

        self.window.task(
            lambda: self.window.repo.revision_files(record.id, parent), done
        )

    def file_selected(self, _, row):
        if self.loading or not row or not self.record or self.window.busy:
            return
        _, path, original = row.file
        record, parent = self.record, self.parents.get_active_id()
        self.window.task(
            lambda: self.window.repo.file_comparison(path, record.id, parent, original),
            self.comparison.set_document,
        )
