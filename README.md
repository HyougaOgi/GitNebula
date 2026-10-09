# GitNebula

A space-inspired, open-source Git client for **macOS, Linux, and Windows**, built around file-manager context menus.

Right-click a file or folder, choose **GitNebula → Commit / Diff / Log / Pull / Push**, and go straight to that operation. Each platform uses its own native UI toolkit, with a shared nebula palette and focused dialogs.

| Platform | Application | Requirements |
| --- | --- | --- |
| macOS | SwiftUI / Swift | macOS 13+, Xcode Command Line Tools |
| Linux | GTK 4 / Python | Python 3.10+, PyGObject, GTK 4, Git 2.29+, X11 or Wayland |
| Windows | WPF / C# | Windows 10/11 (x64 / ARM64), .NET 8 SDK for source builds, Git for Windows 2.29+ |

## Features

- Open local repositories and clone into a new directory.
- Inspect working-tree changes, tracked-file diffs, and untracked-file previews.
- Commit selected files while retaining unrelated staged changes.
- Browse a commit graph with branch and tag decorations.
- Fetch, fast-forward pull, and push with upstream tracking.
- Create, switch, rename, merge, and safely delete local branches.
- Edit text conflicts, mark externally resolved files, complete or abort a merge.
- Launch operation-specific dialogs directly from Finder, Nautilus, KDE/Dolphin, or Explorer.
- Carry the selected file/folder into the commit and diff dialogs, with changes preselected.
- Keep drafts and running operations separate when opening another context-menu action.
- Build platform-specific packages, with optional code signing and verification.

GitNebula is in active development. Native build and integration-test commands are included for every platform. Release signing requires the maintainer's own signing identity; unsigned development packages are not notarized or trusted release artifacts.

All three platforms include full commit information with field/message/all copy, searchable history, 2D and spatial 4D graphs, and aligned file comparisons with line numbers and synchronized scrolling. Stash and Tag windows also preview changes, and branch/remote operations have dedicated forms and lists. Each platform also supports Init, remote/identity settings, Stage/Unstage/Ignore/Discard, history editing, Blame, patches, Worktree and Submodule operations. See the [feature matrix and remaining TortoiseGit differences](shared/FEATURES.md) for exact platform coverage.

## Getting started

事前にGitを用意してください。`GitNebula` フォルダがまだない作業ディレクトリで、使用するOSのコマンドをまとめて貼り付けます。

### macOS

macOS 13以降。ターミナルで実行してください。

```sh
git clone https://github.com/HyougaOgi/GitNebula.git &&
cd GitNebula &&
bash Mac/install.sh
```

`~/Applications/GitNebula.app` にインストールし、メニューバーで起動します。ビルド用のCommand Line Toolsがなければ、インストーラーが準備を案内します。

### Windows

Windows 10/11（x64／ARM64）。PowerShellで実行してください。.NET SDKは必要な場合だけ自動でインストールします。

```powershell
git clone https://github.com/HyougaOgi/GitNebula.git
if ($LASTEXITCODE -eq 0) {
    cd GitNebula
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows\Install.ps1
}
```

アプリ配置・スタートメニュー・右クリックメニューの登録まで行い、トレイで起動します。

### Linux（Ubuntu / Debian）

Ubuntu 22.04以降／Debian 12以降。ターミナルで実行してください。GTKなどの必要パッケージはインストーラーが準備します。

```sh
git clone https://github.com/HyougaOgi/GitNebula.git &&
cd GitNebula &&
bash Linux/install.sh
```

アプリメニューとNautilus／Dolphinの右クリックメニューを登録して起動します。パッケージのインストール時に `sudo` のパスワードを入力します。

Configure your Git name and email before committing. Network operations use your existing Git credential helper or SSH agent. Configure SSH keys and passphrases in Settings, or use the existing SSH agent/configuration. Passphrases are held in macOS Keychain, Windows Credential Manager or Linux Secret Service; HTTPS uses Git's credential helper. GitNebula does not change global Git configuration.

See the platform guides for installation, file-manager integration, and packaging:

- [macOS](Mac/README.md)
- [Linux](Linux/README.md)
- [Windows](Windows/README.md)

## Everyday workflow

Install the file-manager integration from your [platform guide](#getting-started), then:

1. Right-click a repository folder or a changed file.
2. Choose **GitNebula → 変更をコミット…**.
3. Review the preselected changes, enter a message, and click **コミット**.
4. Read the result and close the dialog.

**差分一覧** (macOS; **差分を確認** on other platforms) and **履歴を表示** open their own views. On macOS, lists contain no inline comparison: open a file to see its read-only comparison, then use **戻る** to return with selection, scroll and drafts preserved. **Pull / Push / Fetch** show the repository, current branch and remote, then run when you click the action button. **ブランチを切り替え** only asks for the target branch. **Clone** starts directly at its source/destination form. Clone creates a repository-named child directory inside the chosen parent, which may already contain files. The form only asks for the source and parent directory; the repository name is automatic, and the final destination is shown for confirmation. Finder offers **この階層にリポジトリを複製（Clone）** for the containing directory and **選択フォルダ内に Clone** for an intentionally selected folder; right-clicking a row in list view does not silently use that row as the parent. An occupied repository destination is rejected without overwriting it.

Commit and diff are scoped to the selected files or folder descendants. History and remote operations apply to the repository. Finder and Linux accept multiple selections within one repository; Explorer uses one selected file/folder per dialog. A folder selection includes its descendants. **リポジトリの管理** and the operation chooser open dedicated working-file, branch, conflict and identity screens on every platform.

Normal startup keeps GitNebula in the macOS menu bar or the Windows/Linux tray. Clicking its icon opens a simple nebula screen with Settings. Repository operations are opened from a file-manager context menu; the direct GitNebula entry opens the repository operation chooser, and dedicated menu entries open the selected function. Startup options control automatic login launch and opening the app screen at startup (off by default). Linux requires a StatusNotifier-compatible tray host and shows Home when no host is available. Each repository retains separate work, History and Graph windows with their own sizes and drafts. Reopening a function reuses its matching window; resizing History preserves the Graph size and 4D camera. Back follows the actual previous screen; a direct repository operation returns to its chooser. Theme, opacity, language and SSH settings are available on all platforms. See [the interaction specification](shared/DESIGN.md).

4D graph labels use branch names, excluding tags and symbolic HEAD aliases. A merged log whose original branch ref was deleted uses the nearest surviving branch containing its tip. A log with no reachable branch ref shows its full commit ID. Spatial positions, merge edges, log sizes and the time dimension remain based on the commit graph.

Pull accepts fast-forward updates only. Pull and Push respect an existing upstream branch even when its name differs from the local branch; the configured remote is preselected. Branch deletion uses Git's merged-branch check. Branch switching and merging require a clean working tree. Git hooks run normally.

When a merge conflicts, select a conflicted file and edit its resolution, or resolve it in another editor and mark it resolved. Completing a merge includes **all staged changes**. Aborting a merge discards the current resolution work after confirmation. All platforms support continuing or aborting Rebase, Cherry-pick and Revert.

If a renamed file's original path has been recreated, explicitly select that path too or move it aside before committing the rename. This prevents unselected replacement content from being included. A failed commit may leave selected files staged.

Untracked previews are limited to 1 MiB. Binary files are identified without rendering their contents. Invalid UTF-8 is replaced for display; the original bytes are unchanged. The built-in conflict editor accepts UTF-8 text; use an external tool for other encodings, binaries, and symlinks.

## Development and tests

```sh
# Linux backend integration tests
python3 -m unittest discover -s tests -v

# Linux GUI integration test (requires GTK 4 and xvfb)
dbus-run-session -- xvfb-run -a /usr/bin/python3 tests/gtk_smoke.py

# macOS native build and backend tests
swift test --package-path Mac
```

```powershell
# Windows native build and backend tests
dotnet build Windows/GitNebula.csproj
dotnet run --project tests/windows/GitNebula.BackendTests.csproj
dotnet run --project tests/windows-ui/GitNebula.UiTests.csproj
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows/Test-Install.ps1
```

Tests create temporary repositories and local bare remotes. They do not push to a hosted repository. [CI](.github/workflows/ci.yml) runs on macOS and Linux. The Windows job is temporarily disabled with its steps retained for easy restoration. See [investigation and validation](shared/VALIDATION.md).

## Project layout

- `Mac/` — SwiftUI application, Finder Sync extension, macOS packaging.
- `Linux/` — GTK application, file-manager integration, Linux packaging.
- `Windows/` — WPF application, Explorer integration, Windows packaging.
- `shared/` — visual and behavioral specifications.
- `tests/` — Git and GUI integration tests.

## Contributing

Bug reports, platform testing, accessibility improvements, and translations are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Never include repository credentials or private source code in an issue.

## License

GNU General Public License, version 2. See [LICENSE](LICENSE).
