# GitNebula for Linux

Native GTK 4 application using the distribution's Python and PyGObject bindings.

```sh
# Debian / Ubuntu
sudo apt-get install python3-gi gir1.2-gtk-4.0 git
/usr/bin/python3 Linux/main.py

# Open the commit dialog directly
/usr/bin/python3 Linux/main.py --action commit --path /path/to/repository
# Review one file
/usr/bin/python3 Linux/main.py --action diff --path "/path/to/repository/file.txt"
```

Requires Python 3.10+, Git 2.29+, and an X11 or Wayland desktop.

## Install and file-manager menus

```sh
python3 Linux/install.py
```

This copies the application into `~/.local/share/gitnebula`, creates `~/.local/bin/gitnebula`, registers a desktop launcher, and installs:

- A Nautilus Python extension. Install your distribution's `python3-nautilus` package and restart Nautilus.
- A KDE/Dolphin service menu. Restart the file manager if the action does not appear immediately.

Right-click a local file, folder, or folder background and choose **GitNebula → 変更をコミット / 差分を確認 / 履歴を表示 / Pull / Push / Fetch / ブランチを切り替え / Clone**. Commit and Diff use the selected files or folder descendants. Multiple selections must belong to one repository. Clone starts with the clicked location as its destination parent. Each invocation has a separate window, preserving existing drafts.

For other file managers, configure a custom action such as `gitnebula --action commit --path /path/to/repository`. The old `gitnebula /path/to/repository` form opens an operation chooser. Re-run the installer after upgrading and restart the file manager to reload the menu. Installing menus does not run Git operations.

```sh
# Remove only GitNebula's installed files and menu entries
python3 Linux/install.py --uninstall
```

An alternate installation root is available through `--prefix`. Keep that prefix the same when uninstalling.

## Tests

```sh
python3 -m unittest discover -s tests -v
sudo apt-get install xvfb xauth
xvfb-run -a /usr/bin/python3 tests/gtk_smoke.py
```

## Packages and signatures

```sh
sh Linux/package.sh --unsigned
# With an existing signing key in your GPG keyring:
GPG_KEY_ID=your-key-fingerprint sh Linux/package.sh --signed
```

Packages are written to `dist/linux/`. The tarball contains source files and uses the distribution's GTK/Python dependencies. Signed builds include an ASCII-armored detached signature and a SHA-256 checksum.

Verify using the maintainer's public key obtained through a trusted channel:

```sh
gpg --verify GitNebula-linux.tar.gz.asc GitNebula-linux.tar.gz
sha256sum GitNebula-linux.tar.gz
```
