#!/usr/bin/env python3
"""Install user-local launchers and optional Nautilus/KDE context menus."""
import argparse
import pathlib
import shlex
import shutil
from actions import ACTIONS, MENU_GROUPS

parser = argparse.ArgumentParser()
parser.add_argument(
    "--prefix", type=pathlib.Path, default=pathlib.Path.home() / ".local"
)
parser.add_argument("--uninstall", action="store_true")
args = parser.parse_args()
prefix = args.prefix.expanduser().resolve()
source = pathlib.Path(__file__).resolve().parent
application = prefix / "share/gitnebula"
launcher = prefix / "bin/gitnebula"
desktop = prefix / "share/applications/dev.gitnebula.desktop"
nautilus = prefix / "share/nautilus-python/extensions/gitnebula.py"
kde = prefix / "share/kio/servicemenus/gitnebula.desktop"
application_files = [
    "main.py",
    "advanced.py",
    "advanced_views.py",
    "file_diff.py",
    "diff_widgets.py",
    "git_backend.py",
    "git_records.py",
    "actions.py",
    "settings.py",
    "transfer.py",
    "graph.py",
    "gtk_widgets.py",
    "tray.py",
    "en.json",
    "gitnebula.png",
]
icon = prefix / "share/icons/hicolor/256x256/apps/gitnebula.png"
owned = [
    launcher,
    desktop,
    nautilus,
    kde,
    icon,
    *(application / name for name in application_files),
]
if args.uninstall:
    for file in owned:
        if file.exists() or file.is_symlink():
            file.unlink()
    if application.is_dir() and not any(application.iterdir()):
        application.rmdir()
    print("Removed GitNebula user integration.")
    raise SystemExit(0)
for file in owned:
    file.parent.mkdir(parents=True, exist_ok=True)
for name in application_files:
    shutil.copy2(source / name, application / name)
shutil.copy2(source / "gitnebula.png", icon)
launcher.write_text(
    "#!/bin/sh\nexec /usr/bin/python3 "
    + shlex.quote(str(application / "main.py"))
    + ' "$@"\n'
)
launcher.chmod(0o755)


def desktop_quote(value):
    return (
        '"'
        + str(value)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("`", "\\`")
        .replace("$", "\\$")
        .replace("%", "%%")
        + '"'
    )


executable = desktop_quote(launcher)
desktop.write_text(
    "[Desktop Entry]\nType=Application\nName=GitNebula\nComment=Native Git client\nCategories=Development;RevisionControl;\nTerminal=false\nIcon=gitnebula\nExec="
    + executable
    + " %f\nMimeType=inode/directory;\n"
)
menu_actions = [("menu", "Git 操作を選択")] + [
    (name, ACTIONS[name][0]) for _, names in MENU_GROUPS for name in names
]
kde_actions = []
for name, title in menu_actions:
    if name == "clone":
        kde_actions.extend(
            [(name, "この階層に Clone"), ("clone-inside", "選択フォルダ内に Clone")]
        )
    else:
        kde_actions.append((name, title))
service = (
    "[Desktop Entry]\nType=Service\nMimeType=all/allfiles;inode/directory;\nX-KDE-ServiceTypes=KonqPopupMenu/Plugin\nX-KDE-Submenu=GitNebula\nX-KDE-Protocols=file\nActions="
    + ";".join(name for name, _ in kde_actions)
    + ";\n"
)
for name, title in kde_actions:
    arguments = (
        "clone --clone-parent"
        if name == "clone"
        else "clone" if name == "clone-inside" else name
    )
    service += (
        "\n[Desktop Action "
        + name
        + "]\nName="
        + title
        + "…\nExec="
        + executable
        + " --action "
        + arguments
        + " -- %F\n"
    )
kde.write_text(service)
kde.chmod(0o755)
provider = (source / "nautilus_menu.py").read_text()
provider = provider.replace('"__GITNEBULA_LAUNCHER__"', repr(str(launcher))).replace(
    "__GITNEBULA_ACTIONS__", repr(menu_actions)
)
nautilus.write_text(provider)
print("Installed:", launcher)
print(
    "Nautilus requires python3-nautilus; restart the file manager to load its menu. KDE uses a service menu."
)
