"""Installed with its launcher path substituted by install.py."""
from gi.repository import GObject, Nautilus, Gio
import subprocess

LAUNCHER = '__GITNEBULA_LAUNCHER__'
ACTIONS = __GITNEBULA_ACTIONS__

class GitNebulaMenu(GObject.GObject, Nautilus.MenuProvider):
    def items(self, files):
        if not files or any(file.get_uri_scheme() != 'file' for file in files): return []
        paths = [Gio.File.new_for_uri(file.get_uri()).get_path() for file in files]
        if any(path is None for path in paths): return []
        root = Nautilus.MenuItem(name='GitNebula::menu', label='✧ GitNebula', tip='Git 操作')
        menu = Nautilus.Menu(); root.set_submenu(menu)
        for action, label in ACTIONS:
            item = Nautilus.MenuItem(name='GitNebula::' + action, label=label + '…', tip=label)
            def launch(_item, action=action, paths=paths):
                arguments = [LAUNCHER, '--action', action, '--', *paths]
                subprocess.Popen(arguments, start_new_session=True)
            item.connect('activate', launch); menu.append_item(item)
        return [root]
    def get_file_items(self, *args): return self.items(args[-1])
    def get_background_items(self, *args): return self.items([args[-1]])
