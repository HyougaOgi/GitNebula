# GitNebula for Linux

Native GTK 4 application using the distribution's Python and PyGObject bindings.

## インストール

Gitを用意して、`GitNebula` フォルダがまだない作業ディレクトリで実行してください。

Ubuntu 22.04以降／Debian 12以降。ターミナルで実行してください。GTKなどの必要パッケージはインストーラーが準備します。

```sh
git clone https://github.com/HyougaOgi/GitNebula.git &&
cd GitNebula &&
bash Linux/install.sh
```

アプリメニューとNautilus／Dolphinの右クリックメニューを登録して起動します。パッケージのインストール時に `sudo` のパスワードを入力します。

Gitがない場合は `sudo apt-get install -y git` で準備してください。Nautilusのメニューが出なければ `nautilus -q` で開き直してください。GNOMEのトレイ常駐にはAppIndicator対応の拡張が必要です。

Requires Python 3.10+, Git 2.29+, and an X11 or Wayland desktop.

History and both graph modes reserve space for commit information when the window shrinks. Paths stay on one line, navigation and history search share rows, and long operation results scroll within a bounded area. Every commit field remains reachable without maximizing.

## Install and file-manager menus

```sh
/usr/bin/python3 Linux/install.py
```

This copies the application into `~/.local/share/gitnebula`, creates `~/.local/bin/gitnebula`, registers a desktop launcher, and installs:

- A Nautilus Python extension. Install your distribution's `python3-nautilus` package and restart Nautilus.
- A KDE/Dolphin service menu. Restart the file manager if the action does not appear immediately.

Right-click **GitNebula** to open the repository operation chooser, or select a dedicated operation under **GitNebula の機能**. Actions follow Changes / History / Branches / Remotes / Repository order. Commit and Diff preselect the clicked file or folder descendants. Multiple selections must belong to one repository. In Nautilus, Clone from a folder row uses its containing directory, and Clone from the background uses that directory itself; the repository name is automatic. Each repository retains separate work, History and Graph windows with independent sizes; matching requests reuse their window and preserve the graph camera. Different repositories preserve windows and drafts. Back returns to the repository chooser when opened directly from a file manager.

For other file managers, configure a custom action such as `gitnebula --action commit --path /path/to/repository`. The old `gitnebula /path/to/repository` form opens an operation chooser. Re-run the installer after upgrading and restart the file manager to reload the menu. Installing menus does not run Git operations.

Dolphin provides explicit **この階層に Clone** and **選択フォルダ内に Clone** entries. The first uses the clicked folder's parent, preserving existing files in both directories; the second uses the selected directory itself. Nautilus background Clone uses the current directory.

```sh
# Remove only GitNebula's installed files and menu entries
/usr/bin/python3 Linux/install.py --uninstall
```

An alternate installation root is available through `--prefix`. Keep that prefix the same when uninstalling.


## Application and Git screens

Normal startup registers one [StatusNotifierItem](https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-item.html) and leaves repository operations to file-manager windows. Clicking the tray icon opens a simple nebula screen with Settings. The tray menu contains Home, Settings, startup options and Quit. Closing a window keeps the app running by default. A tray host is required: KDE and compatible desktops provide one; GNOME needs a compatible AppIndicator/StatusNotifier extension. Without a tray host, startup displays Home so the application remains accessible.

Settings include System / Light / Dark, actual window opacity, Japanese / English, Git executable, SSH key and a masked passphrase. System appearance follows the desktop portal or GTK preferences. Passphrases are stored through Secret Service using `secret-tool`, separate from JSON settings, and used only for the configured key. HTTPS uses Git's credential helper. Autostart and opening Home at startup are configurable. Nebula gas, stars and the title animate while visible and pause when motion is disabled.

History and the 2D / 4D graph show full commit IDs. Selecting a commit displays its complete message, author/committer emails and dates, parents, references and tree. Full ID, message, each field and all information have separate native copy buttons. One scrollable body keeps all details reachable in small windows. The Changed Files tab supports parent selection for merges and aligned full-file comparisons with line numbers, change colors, synchronized scrolling and change navigation. Working files use the same comparison view.

4D groups first-parent logs by branch, sizes nodes by loaded commit count and connects actual fork/merge parents. The nebula is a time-varying XYZ density volume. Drag to orbit, scroll to zoom, double-click to focus and use the timeline to replay history. Equal reverse scrolling restores the same camera position, including beyond zoom limits. Rendering runs outside GTK callbacks so input remains responsive.

Commit has a multiline message editor, Ctrl+Enter and a Push button after success. Remote operations and Clone display Git's current-stage percentage and progress bar; connection/verification stages are indeterminate. Completion is shown after Git and refresh finish, and output/result summaries remain available.

Dedicated screens provide Stash save/preview/Apply/Pop/Drop; Cherry-pick, Revert and Rebase with conflict Continue/Abort; branch creation/rename/deletion; Stage/Unstage/Ignore/Discard; tags; remotes; identity; Init; commit comparison; file history; Blame; Reflog; Soft/Mixed/Hard Reset; binary patch export/check/application; Worktree creation/listing; and Submodule registration/update. Existing destination files and dirty worktrees are protected as appropriate. Back retains commit drafts and selection. See the [feature matrix](../shared/FEATURES.md) and [verified coverage](../shared/VALIDATION.md).

## Development and tests

The source application can be run directly from an existing checkout without installing launchers:

```sh
/usr/bin/python3 Linux/main.py
/usr/bin/python3 Linux/main.py --action commit --path /path/to/repository
/usr/bin/python3 Linux/main.py --action diff --path "/path/to/repository/file.txt"
```

```sh
python3 -m unittest discover -s tests -v
sudo apt-get install xvfb xauth dbus-x11
dbus-run-session -- xvfb-run -a /usr/bin/python3 tests/gtk_smoke.py
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
