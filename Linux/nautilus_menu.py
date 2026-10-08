"""Installed with its launcher path substituted by install.py."""

from gi.repository import GObject, Nautilus, Gio
import subprocess

LAUNCHER = "__GITNEBULA_LAUNCHER__"
ACTIONS = __GITNEBULA_ACTIONS__


class GitNebulaMenu(GObject.GObject, Nautilus.MenuProvider):
    def items(self, files, background=False):
        if not files or any(file.get_uri_scheme() != "file" for file in files):
            return []
        paths = [Gio.File.new_for_uri(file.get_uri()).get_path() for file in files]
        if any(path is None for path in paths):
            return []
        root = Nautilus.MenuItem(
            name="GitNebula::menu", label="GitNebula", tip="Git 操作"
        )
        root.connect(
            "activate",
            lambda _: subprocess.Popen(
                [LAUNCHER, "--action", "menu", "--", *paths], start_new_session=True
            ),
        )
        functions = Nautilus.MenuItem(
            name="GitNebula::functions", label="GitNebula の機能", tip="Git 操作"
        )
        menu = Nautilus.Menu()
        functions.set_submenu(menu)
        for action, label in ACTIONS:
            item = Nautilus.MenuItem(
                name="GitNebula::" + action, label=label + "…", tip=label
            )

            def launch(_item, action=action, paths=paths):
                from pathlib import Path

                selected = (
                    paths
                    if action != "clone" or background
                    else [str(Path(paths[0]).parent)]
                )
                arguments = [LAUNCHER, "--action", action, "--", *selected]
                subprocess.Popen(arguments, start_new_session=True)

            item.connect("activate", launch)
            menu.append_item(item)
        return [root, functions]

    def get_file_items(self, *args):
        return self.items(args[-1])

    def get_background_items(self, *args):
        return self.items([args[-1]], background=True)
