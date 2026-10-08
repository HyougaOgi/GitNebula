"""One StatusNotifierItem per application; Git actions belong to file-manager windows."""

from pathlib import Path
from gi.repository import Gio, GLib
from actions import LaunchRequest

ITEM_XML = """<node><interface name="org.kde.StatusNotifierItem">
<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="IconName" type="s" access="read"/><property name="IconThemePath" type="s" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
<property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
<signal name="NewIcon"/><signal name="NewToolTip"/>
</interface></node>"""

MENU_XML = """<node><interface name="com.canonical.dbusmenu">
<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
<method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>"""


class Tray:
    def __init__(self, app):
        self.app = app
        self.available = False
        self.revision = 1
        self.connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.item_info = Gio.DBusNodeInfo.new_for_xml(ITEM_XML)
        self.menu_info = Gio.DBusNodeInfo.new_for_xml(MENU_XML)
        self.item_registration = self.connection.register_object(
            "/StatusNotifierItem",
            self.item_info.interfaces[0],
            self.item_method,
            self.item_property,
            None,
        )
        self.menu_registration = self.connection.register_object(
            "/MenuBar",
            self.menu_info.interfaces[0],
            self.menu_method,
            self.menu_property,
            None,
        )
        self.watchers = []
        for service in (
            "org.kde.StatusNotifierWatcher",
            "org.freedesktop.StatusNotifierWatcher",
        ):
            owner = self.connection.call_sync(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "NameHasOwner",
                GLib.Variant("(s)", (service,)),
                GLib.VariantType.new("(b)"),
                Gio.DBusCallFlags.NONE,
                2000,
                None,
            )
            if owner.unpack()[0]:
                self.register(service)
            self.watchers.append(
                Gio.bus_watch_name_on_connection(
                    self.connection,
                    service,
                    Gio.BusNameWatcherFlags.NONE,
                    lambda connection, name, owner: self.register(name),
                    lambda *_: None,
                )
            )

    def register(self, service):
        interface = (
            "org.kde.StatusNotifierWatcher"
            if service.startswith("org.kde")
            else "org.freedesktop.StatusNotifierWatcher"
        )
        try:
            self.connection.call_sync(
                service,
                "/StatusNotifierWatcher",
                interface,
                "RegisterStatusNotifierItem",
                GLib.Variant("(s)", (self.connection.get_unique_name(),)),
                None,
                Gio.DBusCallFlags.NONE,
                2000,
                None,
            )
            self.available = True
            self.app.tray_available = True
        except GLib.Error:
            pass

    def item_property(self, connection, sender, path, interface, name):
        properties = {
            "Category": ("s", "ApplicationStatus"),
            "Id": ("s", "GitNebula"),
            "Title": ("s", "GitNebula"),
            "Status": ("s", "Active"),
            "IconName": ("s", "gitnebula"),
            "IconThemePath": ("s", str(Path(__file__).parent)),
            "ItemIsMenu": ("b", False),
            "Menu": ("o", "/MenuBar"),
            "ToolTip": ("(sa(iiay)ss)", ("gitnebula", [], "GitNebula", "")),
        }
        return GLib.Variant(*properties[name])

    def item_method(
        self, connection, sender, path, interface, method, parameters, invocation
    ):
        if method in ("Activate", "SecondaryActivate", "ContextMenu"):
            self.app.show_request(LaunchRequest())
        invocation.return_value(None)

    def properties(self, id):
        L = self.app.settings.text
        title = {
            0: "",
            1: "GitNebula",
            2: L("詳細設定"),
            3: L("起動オプション"),
            4: L("起動時にアプリ画面を開く"),
            5: L("終了"),
            6: L("ログイン時に自動起動"),
        }.get(id, "")
        properties = {
            "label": GLib.Variant("s", title),
            "enabled": GLib.Variant("b", True),
            "visible": GLib.Variant("b", True),
        }
        if id in (0, 3):
            properties["children-display"] = GLib.Variant("s", "submenu")
        if id in (4, 6):
            properties.update(
                {
                    "toggle-type": GLib.Variant("s", "checkmark"),
                    "toggle-state": GLib.Variant(
                        "i",
                        int(
                            self.app.settings.values["show_home"]
                            if id == 4
                            else self.app.settings.autostart_path.exists()
                        ),
                    ),
                }
            )
        return properties

    def layout(self, id):
        children = [1, 2, 3, 5] if id == 0 else [4, 6] if id == 3 else []
        return GLib.Variant(
            "(ia{sv}av)",
            (id, self.properties(id), [self.layout(child) for child in children]),
        )

    def layout_data(self, id):
        children = [1, 2, 3, 5] if id == 0 else [4, 6] if id == 3 else []
        return (id, self.properties(id), [self.layout(child) for child in children])

    def menu_property(self, connection, sender, path, interface, name):
        return GLib.Variant(
            *{
                "Version": ("u", 3),
                "TextDirection": ("s", "ltr"),
                "Status": ("s", "normal"),
                "IconThemePath": ("as", [str(Path(__file__).parent)]),
            }[name]
        )

    def event(self, id, event):
        if event != "clicked":
            return
        if id == 1:
            self.app.show_request(LaunchRequest())
        elif id == 2:
            self.app.show_request(LaunchRequest("settings"))
        elif id == 4:
            self.app.settings.values["show_home"] = not self.app.settings.values[
                "show_home"
            ]
            self.app.settings.save()
            self.refresh()
        elif id == 5:
            self.app.quit_safely()
        elif id == 6:
            try:
                self.app.settings.set_autostart(
                    not self.app.settings.autostart_path.exists()
                )
                self.refresh()
            except OSError as error:
                self.app.show_request(LaunchRequest("settings"))
                for window in self.app.get_windows():
                    if window.action == "settings":
                        window.status.set_text(str(error))

    def menu_method(
        self, connection, sender, path, interface, method, parameters, invocation
    ):
        args = parameters.unpack()
        if method == "GetLayout":
            invocation.return_value(
                GLib.Variant(
                    "(u(ia{sv}av))", (self.revision, self.layout_data(args[0]))
                )
            )
        elif method == "GetGroupProperties":
            invocation.return_value(
                GLib.Variant(
                    "(a(ia{sv}))", ([(id, self.properties(id)) for id in args[0]],)
                )
            )
        elif method == "GetProperty":
            invocation.return_value(
                GLib.Variant("(v)", (self.properties(args[0])[args[1]],))
            )
        elif method == "Event":
            self.event(args[0], args[1])
            invocation.return_value(None)
        elif method == "EventGroup":
            for id, event, data, timestamp in args[0]:
                self.event(id, event)
            invocation.return_value(GLib.Variant("(ai)", ([],)))
        elif method == "AboutToShow":
            invocation.return_value(GLib.Variant("(b)", (False,)))
        elif method == "AboutToShowGroup":
            invocation.return_value(GLib.Variant("(aiai)", ([], [])))

    def refresh(self):
        self.revision += 1
        self.connection.emit_signal(
            None,
            "/MenuBar",
            "com.canonical.dbusmenu",
            "LayoutUpdated",
            GLib.Variant("(ui)", (self.revision, 0)),
        )
