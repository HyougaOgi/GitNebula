"""Native GTK callbacks, clipboard, scrolling, routing and actual Git operations."""

import os
import pathlib
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "Linux"))

with tempfile.TemporaryDirectory(prefix="nebula-gtk-") as directory:
    base = pathlib.Path(directory).resolve()
    root = base / "repository"
    root.mkdir()
    os.environ["GITNEBULA_SETTINGS_PATH"] = str(base / "app-settings.json")
    from main import App, Window, GLib, Gtk, buffer_text
    from actions import LaunchRequest, MENU_GROUPS
    from git_backend import Repository
    from git_records import CommitRecord
    from tray import MENU_XML, ITEM_XML, Tray

    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args]).decode()

    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.invalid")
    file = root / "orbit.txt"
    file.write_text("initial\n")
    repo = Repository(str(root))
    repo.commit(["orbit.txt"], "Initial\n\nFull body\n\nTrailer: value")
    file.write_text("updated\n")
    (root / "other.txt").write_text("unselected\n")
    app = App()
    app.settings.values.update(language="ja", keep_running=False)
    app.register(None)
    window = Window(app, LaunchRequest("commit", (str(file),)))
    window.present()
    window.open_repository(str(file))

    def pump():
        context = GLib.MainContext.default()
        for _ in range(30):
            if not context.pending():
                break
            context.iteration(False)

    def wait(error=False):
        deadline = time.monotonic() + 20
        while window.busy and time.monotonic() < deadline:
            pump()
            time.sleep(0.01)
        pump()
        assert not window.busy, "operation timed out"
        if not error:
            assert not window.status.has_css_class("error"), window.status.get_text()

    wait()
    assert window.selected == {"orbit.txt"}
    assert window.commit_button.get_visible()
    assert window.pages.get_visible_child_name() == "files"
    row = window.files.get_first_child().get_child()
    row.get_first_child().get_next_sibling().emit("clicked")
    wait()
    assert "+updated" in buffer_text(window.diff_view)
    assert window.working_comparison.document.rows[0].old == "initial"
    assert window.working_comparison.document.rows[0].new == "updated"
    window.message.get_buffer().set_text(
        "Native commit\n\nFull multiline body\n\nReviewed-by: GTK"
    )
    assert window.commit_button.get_sensitive()
    window.commit_button.emit("clicked")
    wait()
    assert (
        repo.history()[0].message
        == "Native commit\n\nFull multiline body\n\nReviewed-by: GTK\n"
    )
    assert [c.path for c in repo.changes()] == ["other.txt"]
    assert window.push_button.get_visible()
    window.back_button.emit("clicked")
    wait()
    assert window.action == "menu"
    window.navigate("log")
    wait()
    record = window.commit_details.record
    assert record.id == repo.head()
    assert record.message == repo.history()[0].message
    values = []
    for id, expected in [
        ("id", record.id),
        ("message", record.message),
        ("all", record.details_text),
    ]:
        window.commit_details.copy_buttons[id].emit("clicked")
        clipboard = window.get_display().get_clipboard()
        read = []
        clipboard.read_text_async(
            None, lambda cb, result: read.append(cb.read_text_finish(result))
        )
        deadline = time.monotonic() + 5
        while not read and time.monotonic() < deadline:
            pump()
            time.sleep(0.01)
        assert read == [expected], (id, read, expected)
    if os.environ.get("GITNEBULA_GTK_PREVIEW"):
        from gi.repository import Gsk, Graphene

        def capture(widget, name):
            snapshot = Gtk.Snapshot.new()
            paintable = Gtk.WidgetPaintable.new(widget)
            paintable.snapshot(snapshot, widget.get_width(), widget.get_height())
            node = snapshot.to_node()
            if node is None:
                print("Preview unavailable for", name)
                return
            renderer = Gsk.CairoRenderer.new()
            renderer.realize(None)
            try:
                rectangle = Graphene.Rect().init(
                    0, 0, widget.get_width(), widget.get_height()
                )
                texture = renderer.render_texture(node, rectangle)
                destination = pathlib.Path(os.environ["GITNEBULA_GTK_PREVIEW"]) / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                assert texture.save_to_png(str(destination))
            finally:
                renderer.unrealize()

        for _ in range(30):
            pump()
            time.sleep(0.01)
        capture(window.commit_details, "commit-details.png")
    first = window.commit_list.get_first_child()
    window.commit_list.select_row(first.get_next_sibling())
    wait()
    assert window.commit_details.record.id != record.id
    window.set_default_size(850, 600)
    long = CommitRecord(
        record.id,
        record.author,
        record.date,
        "Long",
        "\n".join(f"Line {i}" for i in range(100)),
        record.parents,
        record.decorations,
        record.email,
        record.committer,
        record.committer_email,
        record.commit_date,
        record.tree,
    )
    # Exercise a short native inspector without relying on a desktop compositor
    # to acknowledge a main-window resize (the Broadway backend has no host).
    from gtk_widgets import CommitDetails

    inspector = CommitDetails(window.L)
    inspector_window = Gtk.Window(transient_for=window)
    inspector_window.set_default_size(820, 260)
    inspector_window.set_child(inspector)
    inspector.set_record(long)
    inspector_window.present()
    for _ in range(30):
        pump()
        time.sleep(0.01)
    inspector.allocate(820, 260, -1, None)
    scroll = inspector.scroll
    adjustment = scroll.get_vadjustment()
    assert adjustment.get_upper() > adjustment.get_page_size(), (
        adjustment.get_upper(),
        adjustment.get_page_size(),
        inspector.record.message,
        inspector.get_visible(),
        inspector.get_height(),
        inspector.body.get_height(),
        window.pages.get_visible_child_name(),
    )
    adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())
    pump()
    assert adjustment.get_value() > 0
    if os.environ.get("GITNEBULA_GTK_PREVIEW"):
        capture(inspector, "commit-details-small.png")
    inspector_window.destroy()
    # Exercise the entire workspace as well as the inspector. Long operation
    # output and paths must not consume the viewport, even after a large resize.
    for action, mode in [("log", None), ("graph", "normal"), ("graph", "4d")]:
        window.navigate(action)
        wait()
        if mode:
            window.graph_mode.set_active_id(mode)
        details = window.commit_details if action == "log" else window.graph_details
        details.set_record(long)
        window.status.set_text("\n".join("Long result " + str(i) for i in range(100)))
        window.location.set_text("/".join(["long repository directory"] * 30))
        for width, height in [(1100, 900), (850, 600), (1000, 700), (850, 600)]:
            minimum, *_ = window.root.measure(Gtk.Orientation.VERTICAL, width)
            assert minimum <= height, (action, mode, width, height, minimum)
            window.root.allocate(width, height, -1, None)
            ok, frame = details.compute_bounds(window.root)
            assert ok
            assert frame.get_x() >= -1 and frame.get_y() >= -1
            assert frame.get_x() + frame.get_width() <= width + 1
            assert frame.get_y() + frame.get_height() <= height + 1
            assert details.scroll.get_height() >= 24, (
                action,
                width,
                height,
                details.scroll.get_height(),
            )
            adjustment = details.scroll.get_vadjustment()
            adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())
            assert adjustment.get_value() > 0
    window.navigate("stash")
    wait()
    window.stash_message.set_text("native stash")
    window.operate(lambda: repo.save_stash("native stash", True))
    wait()
    assert not repo.changes()
    id = window.stash_choice.get_active_id()
    assert id
    window.operate(lambda: repo.apply_stash(id, True))
    wait()
    assert (root / "other.txt").read_text() == "unselected\n"
    repo.commit(["other.txt"], "other")
    repo.create_branch("incoming")
    file.write_text("incoming\n")
    repo.commit(["orbit.txt"], "incoming")
    repo.switch_branch("main")
    file.write_text("current\n")
    repo.commit(["orbit.txt"], "current")
    window.navigate("merge")
    wait()
    window.operate(lambda: repo.merge("incoming"))
    wait(error=True)
    assert window.sequence == "merge"
    assert window.conflict_choice.get_active_text() == "orbit.txt"
    window.navigate("conflicts")
    wait()
    window.operate(lambda: repo.save_resolution("orbit.txt", "resolved\n"))
    wait()
    window.operate(lambda: repo.finish_merge("Merge"))
    wait()
    assert repo.sequence() is None
    for _, names in MENU_GROUPS:
        for action in names:
            window.navigate(action)
            wait()
            expected = (
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
            assert window.pages.get_visible_child_name() == expected, (
                action,
                window.pages.get_visible_child_name(),
            )
    window.navigate("graph")
    wait()
    window.graph_mode.set_active_id("4d")
    pump()
    assert window.graph_stack.get_visible_child_name() == "4d"
    assert window.nebula.branches
    before = window.nebula.camera.distance
    window.nebula.scrolled(None, 0, -1000)
    window.nebula.scrolled(None, 0, 1000)
    assert window.nebula.camera.distance == before
    window.navigate("commit")
    wait()
    window.message.get_buffer().set_text("draft to keep")
    window.navigate("settings")
    wait()
    window.back()
    wait()
    assert buffer_text(window.message) == "draft to keep"
    second = root / "second"
    second.mkdir()
    subprocess.run(["git", "init", "-q", str(second)], check=True)
    app.show_request(LaunchRequest("log", (str(second),)))
    pump()
    assert (
        window in app.get_windows() and buffer_text(window.message) == "draft to keep"
    )
    assert len(app.get_windows()) >= 2
    deadline = time.monotonic() + 20
    while any(w.busy for w in app.get_windows()) and time.monotonic() < deadline:
        pump()
        time.sleep(0.01)
    assert not any(w.busy for w in app.get_windows())

    def wait_windows():
        deadline = time.monotonic() + 20
        while any(w.busy for w in app.get_windows()) and time.monotonic() < deadline:
            pump()
            time.sleep(0.01)
        pump()
        assert not any(w.busy for w in app.get_windows())

    app.show_request(LaunchRequest("log", (str(root),)))
    wait_windows()
    history_window = next(
        w
        for w in app.get_windows()
        if w.window_purpose == "log" and w.repo.path == repo.path
    )
    history_window.navigate("graph")
    wait_windows()
    graph_window = next(
        w
        for w in app.get_windows()
        if w.window_purpose == "graph" and w.repo.path == repo.path
    )
    assert history_window is not graph_window and history_window.action == "log"
    graph_window.graph_mode.set_active_id("4d")
    graph_window.root.measure(Gtk.Orientation.VERTICAL, 1000)
    graph_window.root.allocate(1000, 700, -1, None)
    graph_window.nebula.camera.zoom(-2)
    graph_window.nebula.camera.rotate(40, 20)
    camera = graph_window.nebula.camera
    before = (camera.yaw, camera.pitch, camera.scroll, camera.target, camera.distance)
    size = (graph_window.nebula.get_width(), graph_window.nebula.get_height())
    assert min(size) > 0
    history_window.set_default_size(920, 650)
    history_window.root.measure(Gtk.Orientation.VERTICAL, 920)
    history_window.root.allocate(920, 650, -1, None)
    assert (graph_window.nebula.get_width(), graph_window.nebula.get_height()) == size
    assert (
        camera.yaw,
        camera.pitch,
        camera.scroll,
        camera.target,
        camera.distance,
    ) == before
    number = len(app.get_windows())
    history_window.navigate("graph")
    wait_windows()
    assert len(app.get_windows()) == number
    assert (
        camera.yaw,
        camera.pitch,
        camera.scroll,
        camera.target,
        camera.distance,
    ) == before
    graph_window.navigate("log")
    wait_windows()
    assert len(app.get_windows()) == number and graph_window.action == "graph"
    assert window.action == "commit" and buffer_text(window.message) == "draft to keep"
    assert all("分岐 " not in b.title for b in graph_window.nebula.branches)
    # Validate native D-Bus variants even without a desktop tray host.
    Gio = __import__("gi.repository", fromlist=["Gio"]).Gio
    assert Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces
    assert Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces
    if app.resident:
        layout = app.resident.layout_data(0)
        variant = GLib.Variant("(u(ia{sv}av))", (1, layout))
        assert variant.unpack()[0] == 1
    for item in list(app.get_windows()):
        item.close()
    app.quit_safely()
    print(
        "PASS: GTK native input/commit, copy values and clipboard, selection, short-window scroll, all action screens, merge recovery, 4D branch names, Back/draft, independent history/graph windows and camera"
    )
