#!/usr/bin/env python3
"""Install user-local launchers and optional Nautilus/KDE context menus."""
import argparse
import pathlib
import shlex
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--prefix', type=pathlib.Path, default=pathlib.Path.home() / '.local')
parser.add_argument('--uninstall', action='store_true')
args = parser.parse_args()
prefix = args.prefix.expanduser().resolve()
source = pathlib.Path(__file__).resolve().parent
application = prefix / 'share/gitnebula'
launcher = prefix / 'bin/gitnebula'
desktop = prefix / 'share/applications/dev.gitnebula.desktop'
nautilus = prefix / 'share/nautilus-python/extensions/gitnebula.py'
kde = prefix / 'share/kio/servicemenus/gitnebula.desktop'
owned = [launcher, desktop, nautilus, kde, application / 'main.py', application / 'git_backend.py']
if args.uninstall:
    for file in owned:
        if file.exists() or file.is_symlink(): file.unlink()
    if application.is_dir() and not any(application.iterdir()): application.rmdir()
    print('Removed GitNebula user integration.'); raise SystemExit(0)
for file in owned: file.parent.mkdir(parents=True, exist_ok=True)
for name in ['main.py', 'git_backend.py']: shutil.copy2(source / name, application / name)
launcher.write_text('#!/bin/sh\nexec /usr/bin/python3 ' + shlex.quote(str(application / 'main.py')) + ' "$@"\n')
launcher.chmod(0o755)
def desktop_quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'
executable = desktop_quote(launcher)
desktop.write_text('[Desktop Entry]\nType=Application\nName=GitNebula\nComment=Native Git client\nCategories=Development;RevisionControl;\nTerminal=false\nExec=' + executable + ' %f\nMimeType=inode/directory;\n')
kde.write_text('[Desktop Entry]\nType=Service\nMimeType=inode/directory;\nX-KDE-ServiceTypes=KonqPopupMenu/Plugin\nActions=OpenGitNebula;\n\n[Desktop Action OpenGitNebula]\nName=Open in GitNebula\nExec=' + executable + ' %f\n')
kde.chmod(0o755)
nautilus.write_text('''from gi.repository import GObject, Nautilus
import subprocess

class GitNebulaMenu(GObject.GObject, Nautilus.MenuProvider):
    def item(self, folder):
        if folder.get_uri_scheme() != 'file' or not folder.is_directory(): return []
        from gi.repository import Gio
        path = Gio.File.new_for_uri(folder.get_uri()).get_path()
        item = Nautilus.MenuItem(name='GitNebula::open', label='Open in GitNebula', tip='Open repository')
        item.connect('activate', lambda *_: subprocess.Popen([LAUNCHER, path], start_new_session=True))
        return [item]
    def get_file_items(self, *args):
        files = args[-1]
        return self.item(files[0]) if len(files) == 1 else []
    def get_background_items(self, *args): return self.item(args[-1])
'''.replace('LAUNCHER', repr(str(launcher))))
print('Installed:', launcher)
print('Nautilus requires python3-nautilus; restart the file manager to load its menu. KDE uses a service menu.')
