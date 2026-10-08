import math
import time
import cairo
from copy import copy
from concurrent.futures import ThreadPoolExecutor
from gi.repository import Gtk, Gdk, GLib, Pango
from graph import OrbitCamera, branch_logs, branch_links, volume_pixels, PALETTE

render_pool = ThreadPoolExecutor(max_workers=2)


def button(title, callback):
    widget = Gtk.Button(label=title)
    widget.connect("clicked", lambda *_: callback())
    return widget


def label(text, mono=False):
    widget = Gtk.Label(label=text, xalign=0, wrap=True, selectable=True)
    widget.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    widget.set_width_chars(1)
    widget.set_hexpand(True)
    if mono:
        widget.add_css_class("monospace")
    return widget


class CommitDetails(Gtk.Box):
    def __init__(self, text=lambda s: s):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.text = text
        self.record = None
        self.feedback = Gtk.Label(xalign=0)
        toolbar = Gtk.Box(spacing=4)
        self.copy_buttons = {}
        for id, title in [
            ("id", "コミット ID をコピー"),
            ("message", "メッセージをコピー"),
            ("all", "全体をコピー"),
        ]:
            control = button(text(title), lambda id=id: self.copy(id))
            control.add_css_class("commit-copy-button")
            control.set_hexpand(True)
            caption = control.get_child()
            caption.set_wrap(True)
            caption.set_width_chars(1)
            control.set_name("copyCommit:" + id)
            toolbar.append(control)
            self.copy_buttons[id] = control
        self.append(toolbar)
        self.append(self.feedback)
        self.hash = label("", True)
        self.hash.set_name("commitField:id")
        self.hash.add_css_class("commit-id")
        self.append(self.hash)
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.scroll = Gtk.ScrolledWindow(vexpand=True, hexpand=True)
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scroll.set_child(self.body)
        self.append(self.scroll)
        self.values = {}

    def set_record(self, record):
        self.record = record
        self.feedback.set_text("")
        self.hash.set_text(record.id if record else "")
        self.values.clear()
        while self.body.get_first_child():
            self.body.remove(self.body.get_first_child())
        if record:
            self.values.update(
                {field.id: field.value for field in record.detail_fields}
            )
            self.values["all"] = "\n\n".join(
                self.text(f.title) + ":\n" + f.value for f in record.detail_fields
            )
            for field in record.detail_fields:
                if field.id == "id":
                    continue
                heading = Gtk.Box(spacing=8)
                heading.append(
                    Gtk.Label(label=self.text(field.title), xalign=0, hexpand=True)
                )
                control = button(self.text("コピー"), lambda id=field.id: self.copy(id))
                control.set_name("copyCommitField:" + field.id)
                heading.append(control)
                self.body.append(heading)
                value = label(field.value, field.id in ("parents", "tree"))
                value.set_name("commitField:" + field.id)
                value.add_css_class(
                    "commit-message" if field.id == "message" else "commit-value"
                )
                self.body.append(value)
        self.scroll.get_vadjustment().set_value(0)
        for id, control in self.copy_buttons.items():
            title = {
                "id": "コミット ID をコピー",
                "message": "メッセージをコピー",
                "all": "全体をコピー",
            }[id]
            control.set_label(self.text(title))
            control.set_sensitive(record is not None)

    def copy(self, id):
        if id not in self.values:
            return
        Gdk.Display.get_default().get_clipboard().set(self.values[id])
        self.feedback.set_text(self.text("コピーしました"))


class NebulaView(Gtk.DrawingArea):
    def __init__(self, select=lambda _: None, home=False):
        super().__init__(hexpand=True, vexpand=True)
        self.camera = OrbitCamera()
        self.branches = ()
        self.links = {}
        self.commits = []
        self.visible_count = 0
        self.selection = None
        self.select = select
        self.home = home
        self.elapsed = 0.0
        self.surface = None
        self.pixels = None
        self.last_render = 0.0
        self.rendering = False
        self.revision = 0
        self.render_size = None
        self.set_draw_func(self.draw_scene)
        scroll = Gtk.EventControllerScroll.new(Gtk.EventControllerScrollFlags.VERTICAL)
        scroll.connect("scroll", self.scrolled)
        self.add_controller(scroll)
        drag = Gtk.GestureDrag()
        drag.connect("drag-begin", self.drag_begin)
        drag.connect("drag-update", self.drag_update)
        self.add_controller(drag)
        click = Gtk.GestureClick()
        click.connect("released", self.clicked)
        self.add_controller(click)
        self.add_tick_callback(self.tick)

    def set_commits(self, commits):
        first_dataset = not self.commits
        self.commits = commits
        self.branches = branch_logs(commits)
        if first_dataset and self.branches:
            self.camera.base_distance = max(
                32,
                max(
                    math.sqrt(sum(v * v for v in b.position)) + b.radius
                    for b in self.branches
                )
                * 3,
            )
        self.links = branch_links(self.branches)
        self.visible_count = len(commits)
        self.queue_draw()

    def scrolled(self, _, dx, dy):
        self.camera.zoom(dy)
        self.revision += 1
        self.queue_draw()
        return True

    def drag_begin(self, *_):
        self.drag_previous = (0.0, 0.0)

    def drag_update(self, _, dx, dy):
        previous = self.drag_previous
        self.camera.rotate(dx - previous[0], dy - previous[1])
        self.drag_previous = (dx, dy)
        self.revision += 1
        self.queue_draw()

    def reset(self):
        self.camera.reset()
        self.revision += 1
        self.queue_draw()

    def clicked(self, _, count, x, y):
        width, height = self.get_width(), self.get_height()
        candidates = []
        visible = (
            {c.id for c in self.commits[-self.visible_count :]}
            if self.visible_count
            else set()
        )
        for branch in self.branches:
            logs = [c for c in branch.commits if c.id in visible]
            point = self.camera.project(branch.position, width, height)
            if (
                logs
                and point
                and math.hypot(x - point[0], y - point[1])
                < max(12, branch.radius * point[2])
            ):
                candidates.append((point[2], branch, logs))
        if not candidates:
            return
        _, branch, logs = max(candidates, key=lambda item: item[0])
        self.selection = logs[0].id
        self.select(branch)
        if count == 2:
            self.camera.target = branch.position
            self.camera.scroll = -10
            self.revision += 1
        self.queue_draw()

    def tick(self, _, clock):
        settings = Gtk.Settings.get_default()
        if not self.get_mapped() or not settings.get_property("gtk-enable-animations"):
            return True
        now = clock.get_frame_time() / 1e6
        if now - self.last_render > 0.6:
            self.elapsed = now
            self.request_volume(self.get_width(), self.get_height())
            self.queue_draw()
            self.last_render = now
        return True

    def request_volume(self, width, height):
        if self.rendering or width < 1 or height < 1:
            return
        self.rendering = True
        camera, revision, elapsed = copy(self.camera), self.revision, self.elapsed
        future = render_pool.submit(
            volume_pixels, camera, 96, 64, elapsed, width / height
        )

        def finish():
            self.rendering = False
            try:
                if revision == self.revision:
                    self.pixels = future.result()
                    self.surface = cairo.ImageSurface.create_for_data(
                        self.pixels, cairo.FORMAT_ARGB32, 96, 64
                    )
                    self.render_size = (width, height, revision)
                    self.queue_draw()
                elif self.get_mapped():
                    self.request_volume(self.get_width(), self.get_height())
            except Exception:
                self.surface = None
            return False

        future.add_done_callback(lambda _: GLib.idle_add(finish))

    def draw_scene(self, _, context, width, height):
        if width < 1 or height < 1:
            return
        context.set_source_rgb(0.02, 0.03, 0.06)
        context.paint()
        if self.render_size != (width, height, self.revision):
            self.request_volume(width, height)
        if self.surface is not None:
            context.save()
            context.scale(width / 96, height / 64)
            context.set_source_surface(self.surface)
            context.get_source().set_filter(cairo.FILTER_BILINEAR)
            context.paint()
            context.restore()
        for i in range(70):
            x = ((i * 137 + 31) % 997) / 997 * width
            y = ((i * 251 + 73) % 991) / 991 * height
            context.set_source_rgba(
                1,
                1,
                1,
                0.2 + 0.45 * (0.5 + 0.5 * math.sin(self.elapsed * 0.7 + i * 1.73)),
            )
            context.arc(x, y, 1 if i % 7 else 1.8, 0, math.tau)
            context.fill()
        if self.home:
            return
        visible = (
            {c.id for c in self.commits[-self.visible_count :]}
            if self.visible_count
            else set()
        )
        projected = {
            b.id: self.camera.project(b.position, width, height) for b in self.branches
        }
        for (a, b), relations in self.links.items():
            if not any(
                child in visible and parent in visible for child, parent in relations
            ):
                continue
            start, end = projected[a], projected[b]
            if start and end:
                context.set_source_rgba(0.6, 0.6, 1, 0.7)
                context.set_line_width(1.5)
                context.move_to(*start[:2])
                context.line_to(*end[:2])
                context.stroke()
        for branch in sorted(
            self.branches, key=lambda b: projected[b.id][2] if projected[b.id] else -1
        ):
            logs = [c for c in branch.commits if c.id in visible]
            point = projected[branch.id]
            if not logs or not point:
                continue
            x, y, scale = point
            radius = max(3, (0.22 + 0.16 * math.sqrt(len(logs))) * scale)
            color = PALETTE[branch.id % len(PALETTE)]
            glow = cairo.RadialGradient(x, y, 0, x, y, radius * 2.5)
            glow.add_color_stop_rgba(0, *color, 0.8)
            glow.add_color_stop_rgba(1, *color, 0)
            context.set_source(glow)
            context.arc(x, y, radius * 2.5, 0, math.tau)
            context.fill()
            sphere = cairo.RadialGradient(
                x - radius * 0.3, y - radius * 0.3, 0, x, y, radius
            )
            sphere.add_color_stop_rgb(0, 1, 1, 1)
            sphere.add_color_stop_rgb(0.45, *color)
            sphere.add_color_stop_rgb(1, *(v * 0.2 for v in color))
            context.set_source(sphere)
            context.arc(x, y, radius, 0, math.tau)
            context.fill()
            if any(c.id == self.selection for c in logs):
                context.set_source_rgba(1, 1, 1, 0.8)
                context.arc(x, y, radius + 3, 0, math.tau)
                context.stroke()
            context.set_source_rgb(0.9, 0.9, 1)
            context.move_to(x + radius + 5, y)
            context.set_font_size(12)
            context.show_text(branch.title)
