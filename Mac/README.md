# GitNebula for macOS

Native SwiftUI application and Finder Sync extension. Requires macOS 13 or newer and Xcode Command Line Tools (`xcode-select --install`). Git is discovered automatically (Homebrew or `/usr/bin/git`), or selected in **アプリの設定**.

From the repository root:

```sh
swift run --package-path Mac
swift test --package-path Mac
bash Mac/install.sh
```

`install.sh` builds the app and Finder extension, installs `~/Applications/GitNebula.app`, registers it with LaunchServices and PlugInKit, requests that the extension be enabled, restarts the GitNebula extension, and opens the app. Existing versions are retained under `~/Applications/.gitnebula-backups/`. To reinstall an already built package, run `bash Mac/install.sh --no-build`; add `--no-open` to leave the app closed. An alternate installation directory can be passed with `--destination`.

For packaging only, run `bash Mac/package.sh --unsigned`. The package is written to `dist/mac/GitNebula-unsigned.zip`. Development packages use an ad-hoc signature, not a trusted Developer ID signature.

## Welcome and residence

Normal startup and reopening the app keep it in the menu bar with no Dock icon or window. The icon menu contains **ようこそを開く**, **詳細設定…**, **起動オプション** and **GitNebula を終了**. Startup options include **ログイン時に自動起動** (using macOS login items) and **起動時にようこそ画面を開く** (off by default). Login-item registration errors and required system approval are displayed; opening login-item settings is available from both the menu and detailed settings.

**ようこそを開く** shows repository selection, Clone, Init, recent repositories and settings. After choosing a repository, **このリポジトリで操作する** opens its Git operations. The resident menu contains no Git operations without a folder context. Finder context-menu actions open their dedicated screen even when the app has no window. Close hides the window by default. **前の作業画面に戻る** restores the previous route, including its commit draft.

Cherry-pick and Revert each open a dedicated commit selector with an execute button and confirmation. Rebase and Merge each open a dedicated branch selector. These screens contain no working-file diff list. A welcome or Finder request during a Git operation waits for completion before changing screens. Unstage accepts mixed selections and removes only staged changes, preserving working and untracked files. Push explains when an initial commit or branch selection is required.

## Opening a repository

Type or paste an absolute path, `~/Projects/my-repo`, or a local `file://` URL into **リポジトリのパス**, then press Enter or **開く**. **参照…** opens the native folder picker. Quoted paths containing spaces are accepted. The path remains editable after a failed attempt. The app activates as a regular macOS application even when started with `swift run`.

To create a repository in an existing folder, choose **リポジトリを作成（Init）**. The new Stash, Tag, remote/identity settings, history editing, Blame, patch, Worktree and Submodule tools are described in the [feature matrix](../shared/FEATURES.md).

## Lists, comparison and navigation

**差分一覧** opens only a changed-files table, with relative paths, change status and staging status. Filter by path or click a column heading to sort. A single click selects a row. Double-click, press Enter, or choose **差分を開く** to navigate to the selected file's read-only comparison in the same window. This also applies when Finder selects just one file.

The **ファイル差分** screen contains only the two versions of that file: HEAD on the left and the working file on the right for uncommitted changes. Both panes show line numbers, aligned insertions/deletions, change colors and synchronized vertical scrolling. The arrows jump between changes. **戻る** (⌘[) returns to the retained list, preserving its selection, filter and scroll position. **変更をコミット** contains only file checkboxes, a message and the commit action; navigating to a comparison preserves those drafts.

**履歴を表示** opens a selectable commit table with message, author, date, ID, branch and tag labels. Selecting a commit loads its message and changed files; opening a file navigates to a comparison of that commit with its parent. The history screen itself contains the commit table, message and changed-files table, without inline file contents. Merge commits offer a parent selector, and the first commit is compared with an empty tree. Search filters the loaded commits by message, author, email, ID or decoration. The initial page contains up to 200 commits; **さらに 200 件読み込む** extends the list. The branch selector limits the history to a branch or HEAD.

File comparisons are read-only. The history inspector also offers **この変更を取り込む（Cherry-pick）** and **このコミットを取り消す（Revert）** for the selected non-merge commit, with a confirmation showing the target and current branch. Binary files and files larger than 1 MiB show an explanation instead of rendering their bytes. Missing final newlines are marked above each pane; invalid UTF-8 is replaced for display without changing the file. Added, deleted, renamed and newly staged files before the initial commit are supported.

Stash and Tag screens contain their own lists and operations. Choose **変更ファイル一覧**, then open a file to inspect its comparison; each level has **戻る**. A Stash containing untracked files has a separate **未追跡ファイル** tab on its changed-files screen. The branch-switch window lists branches and their latest commits. Pull, Push and Fetch show the remote URL, tracking branch and ahead/behind counts from local tracking data; opening these windows does not run a network operation. Remote settings list registered remotes and load the selected URL for editing. The **その他の機能** launcher opens individual screens for commit comparison, history editing, Blame, Reflog, patches, Worktrees and Submodules. **リポジトリの管理** opens separate screens for working-file actions (Stage/Unstage/Ignore/Discard), branches, conflict resolution, and commit identity. Conflict notices link to resolution instead of inserting an editor into unrelated screens. Remote settings contain only remotes. Existing `tools` and `workspace` launch arguments remain valid.

GUI tests exercise list → comparison → back, native table/scroll retention, filtering, commit drafts, refresh after a related operation, commit selection, and synchronized diff scrolling. To also save rendered previews:

```sh
GITNEBULA_PREVIEW_DIR=/tmp/gitnebula-previews swift test --package-path Mac --filter BrowserTests
```

## Finder integration

The packaged app contains `GitNebulaFinder.appex`. The app settings screen shows its enabled state; **Finder 拡張の設定を開く** opens macOS extension settings. If the menu does not appear after installation, enable **GitNebula Finder** there and click **状態を更新** in the app. macOS may require the user's confirmation to enable an extension. Right-click a repository folder, a file, or the folder background, then choose the icon-marked **GitNebula** submenu. It provides the usual Git actions and the new Stash, Tag, remote and history tools. Each item opens its focused screen in the existing app window. Files and folder descendants are preselected for Commit; several selected files must belong to the same repository. The extension covers `/Users`, `/Volumes`, `/private/tmp`, and `/opt`.

Finder opens the requested operation through `gitnebula://commit?path=…` (and the corresponding action name), addressed to the app that contains the running extension. Paths are URL-encoded; multiple selections use repeated `path` parameters. Menu actions use integer tags to recover their selection because Finder copies menu items across processes without preserving `representedObject`. Launch failures display an error instead of silently returning. A new Finder action preserves the previous route and its draft in the same window; requests arriving during Git operations are queued. For command-line use:

```sh
open -a GitNebula --args --action commit --path /path/to/repository
open -a GitNebula --args --action diff --path "/path/to/repository/file.txt"
open -a GitNebula --args --action clone --path /path/to/parent-folder
```

After upgrading, quit the previous app, run the installer again, and toggle the Finder extension off and on if Finder still shows the old menu. A GitNebula toolbar button is also available from Finder's toolbar customization.

Clone uses a parent directory and creates a child folder named after the source repository. Existing files in the parent are preserved. The form only asks for the source and parent directory; the repository name is automatic, and the complete destination is shown for confirmation. Finder’s **この階層にリポジトリを複製（Clone）…** uses the directory containing the clicked row, so list-view clicks do not redirect Clone into an unrelated folder. **選択フォルダ内に Clone…** explicitly uses the selected folder. Background and sidebar menus use their targeted folder. The picker opens at the current parent. An occupied child destination is rejected without overwriting it.

Disable the extension in System Settings before removing the application. `swift run` runs the development executable and does not install the Finder extension.

## Signed release

Install your Developer ID Application certificate and private key in the macOS keychain. Store App Store Connect/notarization credentials using `xcrun notarytool store-credentials` and use its profile name. Do not add certificates or passwords to this repository.

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-keychain-profile'
bash Mac/package.sh --signed
```

The script signs the extension and application, verifies their signatures, submits the app for notarization, staples and validates the ticket, and creates a ZIP with a SHA-256 checksum. Signing and notarization need your own credentials and network access to Apple's services. Build on each intended CPU architecture; the script packages the host architecture.
