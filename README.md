# GitNebula

A space-inspired, open-source Git desktop client with a native application for **macOS, Linux, and Windows**.

GitNebula shares a visual language across platforms while using each operating system's own UI toolkit and process APIs.

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
- Open repositories from Finder, Nautilus, KDE/Dolphin, or Explorer context menus.
- Build platform-specific packages, with optional code signing and verification.

GitNebula is in active development. Native build and integration-test commands are included for every platform. Release signing requires the maintainer's own signing identity; unsigned development packages are not notarized or trusted release artifacts.

## Getting started

Clone the repository, install the requirements for your platform, then run from the repository root:

```sh
# macOS
swift run --package-path Mac

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

## Working with repositories

Choose **Open repository** or **Clone**, select changed files, inspect their diffs, and enter a commit message. The remote selector controls Fetch, Pull, and Push; the branch selector controls local branch operations. UI labels currently use Japanese with familiar Git command names.

Pull accepts fast-forward updates only. Branch deletion uses Git's merged-branch check. Branch switching and merging require a clean working tree. Git hooks run normally.

When a merge conflicts, select a conflicted file and edit its resolution, or resolve it in another editor and mark it resolved. Completing a merge includes **all staged changes**. Aborting a merge discards the current resolution work after confirmation. Rebase and cherry-pick continuation are not supported.

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
