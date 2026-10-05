# GitNebula for macOS

Native SwiftUI application and Finder Sync extension. Requires macOS 13 or newer and Xcode Command Line Tools (`xcode-select --install`). Git is invoked through `/usr/bin/git`.

From the repository root:

```sh
swift run --package-path Mac
swift test --package-path Mac
bash Mac/install.sh
```

`install.sh` builds the app and Finder extension, installs `~/Applications/GitNebula.app`, registers it with LaunchServices and PlugInKit, requests that the extension be enabled, restarts the GitNebula extension, and opens the app. Existing versions are retained under `~/Applications/.gitnebula-backups/`. To reinstall an already built package, run `bash Mac/install.sh --no-build`; add `--no-open` to leave the app closed. An alternate installation directory can be passed with `--destination`.

For packaging only, run `bash Mac/package.sh --unsigned`. The package is written to `dist/mac/GitNebula-unsigned.zip`. Development packages use an ad-hoc signature, not a trusted Developer ID signature.

## Opening a repository

Type or paste an absolute path, `~/Projects/my-repo`, or a local `file://` URL into **リポジトリのパス**, then press Enter or **開く**. **参照…** opens the native folder picker. Quoted paths containing spaces are accepted. The path remains editable after a failed attempt. The app activates as a regular macOS application even when started with `swift run`.

To create a repository in an existing folder, choose **リポジトリを作成（Init）**. The new Stash, Tag, remote/identity settings, history editing, Blame, patch, Worktree and Submodule tools are described in the [feature matrix](../shared/FEATURES.md).

## Diff and history windows

**差分を確認** opens a file list and a side-by-side comparison: HEAD on the left, the working file on the right. Both panes show line numbers and the full file, align inserted/deleted lines with empty cells, highlight changes, and scroll vertically together. Use the arrow buttons to move between changes. The file list can be filtered by path. The same comparison is available beside the file checkboxes in **変更をコミット**.

**履歴を表示** opens a selectable commit table with message, author, date, ID, branch and tag labels. Selecting a commit loads its message and changed files; selecting a file compares that commit with its parent. Merge commits offer a parent selector, and the first commit is compared with an empty tree. Search filters the loaded commits by message, author, email, ID or decoration. The initial page contains up to 200 commits; **さらに 200 件読み込む** extends the list. The branch selector limits the history to a branch or HEAD.

These viewers are read-only. Binary files and files larger than 1 MiB show an explanation instead of rendering their bytes. Missing final newlines are marked above each pane; invalid UTF-8 is replaced for display without changing the file. Added, deleted, renamed and newly staged files before the initial commit are supported.

Stash and Tag windows pair their selectable lists with the same comparison viewer. A Stash containing untracked files has a separate **未追跡ファイル** tab. The branch-switch window lists branches and their latest commits. Pull, Push and Fetch show the remote URL, tracking branch and ahead/behind counts from local tracking data; opening these windows does not run a network operation. Remote settings list registered remotes and load the selected URL for editing. Advanced tools use commit/file comparison views and tables for Blame, Reflog, Worktrees and Submodules.

GUI tests exercise commit selection and synchronized diff scrolling. To also save rendered previews:

```sh
GITNEBULA_PREVIEW_DIR=/tmp/gitnebula-previews swift test --package-path Mac --filter BrowserTests
```

## Finder integration

The packaged app contains `GitNebulaFinder.appex`. The launch screen shows its enabled state; **Finder 拡張の設定を開く** opens macOS extension settings. If the menu does not appear after installation, enable **GitNebula Finder** there and click **状態を更新** in the app. macOS may require the user's confirmation to enable an extension. Right-click a repository folder, a file, or the folder background, then choose the icon-marked **GitNebula** submenu. It provides the usual Git actions and the new Stash, Tag, remote and history tools. Each item opens its own focused dialog. Files and folder descendants are preselected for Commit; several selected files must belong to the same repository. The extension covers `/Users`, `/Volumes`, `/private/tmp`, and `/opt`.

Finder opens the requested operation through `gitnebula://commit?path=…` (and the corresponding action name), addressed to the app that contains the running extension. Paths are URL-encoded; multiple selections use repeated `path` parameters. Menu actions use integer tags to recover their selection because Finder copies menu items across processes without preserving `representedObject`. Launch failures display an error instead of silently returning. A new Finder action preserves any existing dialog and its draft. For command-line use:

```sh
open -na GitNebula --args --action commit --path /path/to/repository
open -na GitNebula --args --action diff --path "/path/to/repository/file.txt"
open -na GitNebula --args --action clone --path /path/to/parent
```

After upgrading, quit the previous app, run the installer again, and toggle the Finder extension off and on if Finder still shows the old menu. A GitNebula toolbar button is also available from Finder's toolbar customization.

Disable the extension in System Settings before removing the application. `swift run` runs the development executable and does not install the Finder extension.

## Signed release

Install your Developer ID Application certificate and private key in the macOS keychain. Store App Store Connect/notarization credentials using `xcrun notarytool store-credentials` and use its profile name. Do not add certificates or passwords to this repository.

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-keychain-profile'
bash Mac/package.sh --signed
```

The script signs the extension and application, verifies their signatures, submits the app for notarization, staples and validates the ticket, and creates a ZIP with a SHA-256 checksum. Signing and notarization need your own credentials and network access to Apple's services. Build on each intended CPU architecture; the script packages the host architecture.
