# GitNebula

A space-inspired, open-source Git client for **macOS, Linux, and Windows**, built around file-manager context menus.

Right-click a file or folder, choose **GitNebula → Commit / Diff / Log / Pull / Push**, and go straight to that operation. Each platform uses its own native UI toolkit, with a shared nebula palette and focused dialogs.

| Platform | Application | Requirements |
| --- | --- | --- |
| macOS | SwiftUI / Swift | macOS 13+, Xcode Command Line Tools |
| Linux | GTK 4 / Python | Python 3.10+, PyGObject, GTK 4, Git 2.29+, X11 or Wayland |
| Windows | WPF / C# | Windows 10/11, .NET 8 SDK for development, Git for Windows 2.29+ |

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

macOS includes a side-by-side diff viewer with line numbers, aligned changes and synchronized scrolling, plus a searchable commit table with file-level comparisons. Stash and Tag windows also preview changes, and branch/remote operations have dedicated forms and lists. It additionally supports Init, remote/identity settings, staging, ignore rules, history editing, Blame, patches, Worktree, and Submodule operations. See the [feature matrix and remaining TortoiseGit differences](shared/FEATURES.md) for exact platform coverage.

## Getting started

Clone the repository, install the requirements for your platform, then run from the repository root:

```sh
# macOS: install the application and Finder context menu
bash Mac/install.sh
# Development UI only (does not install Finder integration):
# swift run --package-path Mac

# Debian / Ubuntu Linux
sudo apt-get install python3-gi gir1.2-gtk-4.0 git
/usr/bin/python3 Linux/main.py
```

```powershell
# Windows
dotnet run --project Windows/GitNebula.csproj
```

Configure your Git name and email before committing. Network operations use your existing Git credential helper or SSH agent. GitNebula does not store passwords or change global Git configuration. Terminal prompts are disabled; configure authentication outside the application before using private remotes.

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

**差分を確認** and **履歴を表示** open their own views. **Pull / Push / Fetch** show the repository, current branch and remote, then run when you click the action button. **ブランチを切り替え** only asks for the target branch. **Clone** starts directly at its source/destination form and uses the clicked location as the parent folder.

Commit and diff are scoped to the selected files or folder descendants. History and remote operations apply to the repository. Finder and Linux accept multiple selections within one repository; Explorer uses one selected file/folder per dialog. A folder selection includes its descendants. Advanced branch and merge tools are under **詳細操作**; conflict controls appear only when needed.

Launching the application normally shows an editable repository path and an operation chooser. Type/paste a path and press Enter, or use the folder picker. **その他の操作** switches between dialogs. UI labels use Japanese descriptions alongside standard Git terms. See [the interaction specification](shared/DESIGN.md).

Pull accepts fast-forward updates only. Pull and Push respect an existing upstream branch even when its name differs from the local branch; the configured remote is preselected. Branch deletion uses Git's merged-branch check. Branch switching and merging require a clean working tree. Git hooks run normally.

When a merge conflicts, select a conflicted file and edit its resolution, or resolve it in another editor and mark it resolved. Completing a merge includes **all staged changes**. Aborting a merge discards the current resolution work after confirmation. macOS also supports continuing or aborting Rebase, Cherry-pick and Revert; Windows and Linux currently support merge completion only.

If a renamed file's original path has been recreated, explicitly select that path too or move it aside before committing the rename. This prevents unselected replacement content from being included. A failed commit may leave selected files staged.

Untracked previews are limited to 1 MiB. Binary files are identified without rendering their contents. Invalid UTF-8 is replaced for display; the original bytes are unchanged. The built-in conflict editor accepts UTF-8 text; use an external tool for other encodings, binaries, and symlinks.

## Development and tests

```sh
# Linux backend integration tests
python3 -m unittest discover -s tests -v

# Linux GUI integration test (requires GTK 4 and xvfb)
xvfb-run -a /usr/bin/python3 tests/gtk_smoke.py

# macOS native build and backend tests
swift test --package-path Mac
```

```powershell
# Windows native build and backend tests
dotnet build Windows/GitNebula.csproj
dotnet run --project tests/windows/GitNebula.BackendTests.csproj
dotnet run --project tests/windows-ui/GitNebula.UiTests.csproj
```

Tests create temporary repositories and local bare remotes. They do not push to a hosted repository. [CI](.github/workflows/ci.yml) runs on all three operating systems.

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
