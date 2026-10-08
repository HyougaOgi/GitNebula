# GitNebula for macOS

履歴・グラフ・Cherry-pick / Revert の一覧と詳細は通常ウィンドウの表示領域へ追従します。外側と内側の最小サイズは 850×600 に統一し、拡大してから戻した場合もフル ID とコピー操作、全情報のスクロールを保持します。

Native SwiftUI application and Finder Sync extension. Requires macOS 13 or newer and Xcode Command Line Tools (`xcode-select --install`). Git is discovered automatically (Homebrew or `/usr/bin/git`), or selected in **アプリの設定**.

From the repository root:

```sh
swift run --package-path Mac
swift test --package-path Mac
bash Mac/install.sh
```

`install.sh` builds the app and Finder extension, installs `~/Applications/GitNebula.app`, registers it with LaunchServices and PlugInKit, requests that the extension be enabled, restarts the GitNebula extension, and opens the app. Existing versions are retained under `~/Applications/.gitnebula-backups/`. To reinstall an already built package, run `bash Mac/install.sh --no-build`; add `--no-open` to leave the app closed. An alternate installation directory can be passed with `--destination`.

For packaging only, run `bash Mac/package.sh --unsigned`. The package is written to `dist/mac/GitNebula-unsigned.zip`. Development packages use an ad-hoc signature, not a trusted Developer ID signature.

The app icon is a still frame of the startup screen's nebula, exported to `Assets/GitNebula.png`. Packaging uses this image and works without a Metal device. To regenerate it after changing the nebula renderer, run the following on a Mac with Metal support:

```sh
cd Mac
xcrun swiftc -parse-as-library make-icon.swift Sources/GitNebula/NebulaRenderer.swift -o /tmp/gitnebula-make-icon
/tmp/gitnebula-make-icon /tmp/GitNebula.iconset --render
cp /tmp/GitNebula.iconset/icon_512x512@2x.png Assets/GitNebula.png
```

## App screen and residence

The menu-bar item uses the app's colored Nebula icon at the standard menu-bar size.

Normal startup and reopening the app keep it in the menu bar with no Dock icon or window. The icon menu contains **GitNebula を開く**, **詳細設定…**, **起動オプション** and **GitNebula を終了**. Startup options include **ログイン時に自動起動** (using macOS login items) and **起動時にアプリ画面を開く** (off by default). Login-item registration errors and required system approval are displayed; opening login-item settings is available from both the menu and detailed settings.

**GitNebula を開く** shows a simple app screen with the detailed-settings entry. Repository selection, Clone, Init and recent repositories are not shown there. The resident menu contains no Git operations without a folder context. Clicking **GitNebula** itself in the Finder context menu opens the folder's categorized action chooser. **GitNebula の機能** retains the direct submenu actions, including both Clone destinations. These open their dedicated screen even when the app has no window. Each repository retains separate work, History and Graph windows with their own sizes and navigation. Reopening a function reuses its matching window; resizing History preserves the Graph window and its camera. Opening another repository preserves the previous screen, selection and drafts. Close hides the window by default. Git operations are grouped in the same order in Finder and the app: changes, history, branches, remotes, repository.

Detailed settings include **SSH 認証**: select a readable private key (not its `.pub` file), enter its passphrase if encrypted, and click **SSH 設定を保存**. The path is saved in app preferences; the passphrase is saved by Apple's `/usr/bin/ssh-add --apple-use-keychain` and used directly by `/usr/bin/ssh -o UseKeychain=yes` for Clone/Fetch/Pull/Push. GitNebula does not read Apple's protected passphrase store. Saving validates the entered value first, then checks persistence with a new isolated agent; it never changes the user's running agent. Selected keys use `IdentityAgent=none` so removal and storage checks cannot be hidden by a cached key. Saved passphrases stay filled and masked when settings reopen. Clearing the field alone preserves its saved value; **保存したパスフレーズを削除** removes it. A blank key path uses existing SSH configuration/agent. Unsaved passphrases can be entered and saved at connection time. A new host still requires confirmation of the displayed SSH fingerprint. HTTPS continues using Git's credential helper.

After a Finder operation, **戻る** opens that repository's action chooser when the previous screen would have been the app screen. The chooser follows the same categories and order as the Finder menu. Its actions use the repository root, including when Finder originally selected a file. Back from details, settings, or another operation still follows the screen history and preserves drafts.

Cherry-pick and Revert each open a dedicated commit selector with an execute button and confirmation. Rebase and Merge each open a dedicated branch selector. These screens contain no working-file diff list. Requests for a busy repository wait for its operation; other repositories can open independently. Unstage accepts mixed selections and removes only staged changes, preserving working and untracked files. Push explains when an initial commit or branch selection is required.

Branch switching lists local branches and fetched remote branches, omitting remote HEAD aliases and remote entries already tracked locally. Selecting a remote branch creates a local tracking branch. **リモートから更新** fetches all heads without leaving the switch screen, including for a single-branch clone. Switching adds the selected branch's fetch mapping when required for future Pull/Fetch, while retaining the existing mappings. Dirty work and existing local names are protected. Merge and Rebase continue to list local branches only.

Detailed settings also include a **Transparency** slider (0–80%), **System / Light / Dark** appearance, and **Japanese / English** language. Changes apply immediately and persist. The macOS slider changes the actual background alpha, exposing the windows behind it while keeping text and controls opaque. System appearance follows macOS changes immediately. Home renders translucent nebula gas with GPU turbulence, flowing filaments, dark dust and independently twinkling stars. Its GitNebula title slowly flows through matching cyan, violet and rose colors, with darker shades in light appearance. Animation pauses while the window is hidden and respects Reduce Motion.

**履歴 → Git グラフ** shows colored branch lanes, merge parents, commit IDs, messages and branch/tag labels. Select a commit and use **コミットを開く**, or double-click it, to view changed files. More history can be loaded in pages of 200.

Selecting a commit in history, the standard or 4D graph, or the Cherry-pick / Revert list displays **コミット情報** immediately. It shows the full commit ID and message, author and committer names/emails, their complete timestamps (including time zones), full parent IDs, branch/tag labels and tree ID. The list itself shows full commit IDs. The detail header provides **コミット ID をコピー**, **メッセージをコピー** and **全体をコピー**; each populated field also has its own copy button. The whole-information button includes labels with all displayed values. Message-only copying preserves the complete message and its line breaks. The full ID stays above the message. A native selectable message area uses 15-point text. The message and metadata share one scrollable body beneath the pinned full ID and copy controls, so every field is reachable in a normal-sized window. History separates commit information from changed files into tabs; the graph's detail pane can be resized without leaving the graph.

Switch the graph to **4D** to explore branch logs as stars surrounded by volumetric nebula gas. Each star grows with its loaded commit count, and lines retain the real fork and merge relationships. Select a star to see its grouped log and choose a commit. The gas is ray-marched through 3D turbulence and remains visible from inside. Drag to orbit, scroll to approach, or double-click a star to focus it. Zoom follows a fixed anchor and reversing the same scroll amount returns to the same camera position, including at distance limits. Use the timeline or **履歴を再生** to reveal the history; **全体を表示** resets the camera. Playback pauses while hidden and respects Reduce Motion. Folders without Git metadata explain that a cloned repository is required to display history; GitNebula never creates or invents history there.

The graph remembers the selected **通常 / 4D** display when opened again or after restarting the app. 4D opens with all loaded history visible. Switching one graph leaves other open graph windows in their current display.

The 4D nebula extends 1.5 times farther across each of its three axes while preserving the camera and branch layout.

Pull reports whether it updated the repository or was already current, including commit/file counts and before/after HEAD. Fetch and Push also retain their result and Git output. Pull, Push, Fetch and Clone display a live progress bar and the percentage Git reports for the current stage (counting, compressing, receiving, sending or resolving). Connection and final verification show indeterminate progress. These percentages describe each Git stage; successful completion appears only after the operation and repository refresh finish, while failures are marked separately. **戻る** follows the screens actually opened, including Settings and Home, and preserves commit drafts.

## Opening a repository

Type or paste an absolute path, `~/Projects/my-repo`, or a local `file://` URL into **リポジトリのパス**, then press Enter or **開く**. **参照…** opens the native folder picker. Quoted paths containing spaces are accepted. The path remains editable after a failed attempt. The app stays a menu-bar application when started with `swift run`.

To create a repository in an existing folder, choose **リポジトリを作成（Init）**. The new Stash, Tag, remote/identity settings, history editing, Blame, patch, Worktree and Submodule tools are described in the [feature matrix](../shared/FEATURES.md).

## Lists, comparison and navigation

**差分一覧** opens only a changed-files table, with relative paths, change status and staging status. Filter by path or click a column heading to sort. A single click selects a row. Double-click, press Enter, or choose **差分を開く** to navigate to the selected file's read-only comparison in the same window. This also applies when Finder selects just one file.

The **ファイル差分** screen contains only the two versions of that file: HEAD on the left and the working file on the right for uncommitted changes. Both panes show line numbers, aligned insertions/deletions, change colors and synchronized vertical scrolling. The arrows jump between changes. **戻る** (⌘[) returns to the retained list, preserving its selection, filter and scroll position. **Commit** is directly available in the working-screen header and first in the Changes menu. It contains only file checkboxes, a native multiline message editor and the native commit action (⌘Return); navigating to a comparison preserves those drafts. A successful commit displays **Push** next to its result. This opens the repository's Push screen for choosing a remote and sending; returning keeps the completed commit screen available.

**履歴を表示** opens a selectable commit table with message, author, date, ID, branch and tag labels. Selecting a commit loads its message and changed files; opening a file navigates to a comparison of that commit with its parent. The history screen itself contains the commit table, message and changed-files table, without inline file contents. Merge commits offer a parent selector, and the first commit is compared with an empty tree. Search filters the loaded commits by message, author, email, ID or decoration. The initial page contains up to 200 commits; **さらに 200 件読み込む** extends the list. The branch selector limits the history to a branch or HEAD.

File comparisons are read-only. The history inspector also offers **この変更を取り込む（Cherry-pick）** and **このコミットを取り消す（Revert）** for the selected non-merge commit, with a confirmation showing the target and current branch. Binary files and files larger than 1 MiB show an explanation instead of rendering their bytes. Missing final newlines are marked above each pane; invalid UTF-8 is replaced for display without changing the file. Added, deleted, renamed and newly staged files before the initial commit are supported.

Stash and Tag screens contain their own lists and operations. Choose **変更ファイル一覧**, then open a file to inspect its comparison; each level has **戻る**. A Stash containing untracked files has a separate **未追跡ファイル** tab on its changed-files screen. The branch-switch window lists branches and their latest commits. Pull, Push and Fetch show the remote URL, tracking branch and ahead/behind counts from local tracking data; opening these windows does not run a network operation. Remote settings list registered remotes and load the selected URL for editing. The **その他の機能** launcher opens individual screens for commit comparison, history editing, Blame, Reflog, patches, Worktrees and Submodules. **リポジトリの管理** opens separate screens for working-file actions (Stage/Unstage/Ignore/Discard), branches, conflict resolution, and commit identity. Conflict notices link to resolution instead of inserting an editor into unrelated screens. Remote settings contain only remotes. Existing `tools` and `workspace` launch arguments remain valid.

GUI tests exercise list → comparison → back, native table/scroll retention, filtering, commit drafts, refresh after a related operation, commit selection, and synchronized diff scrolling. To also save rendered previews:

```sh
GITNEBULA_PREVIEW_DIR=/tmp/gitnebula-previews swift test --package-path Mac --filter BrowserTests
```

## Finder integration

The packaged app contains `GitNebulaFinder.appex`. The app settings screen shows its enabled state; **Finder 拡張の設定を開く** opens macOS extension settings. If the menu does not appear after installation, enable **GitNebula Finder** there and click **状態を更新** in the app. macOS may require the user's confirmation to enable an extension. Right-click a repository folder, a file, or the folder background, then choose the icon-marked **GitNebula** submenu. It provides the usual Git actions and the new Stash, Tag, remote and history tools. Each item opens its focused screen in the matching repository work, History or Graph window. Files and folder descendants are preselected for Commit; several selected files must belong to the same repository. The extension covers `/Users`, `/Volumes`, `/private/tmp`, and `/opt`.

Finder opens the requested operation through `gitnebula://commit?path=…` (and the corresponding action name), addressed to the app that contains the running extension. Paths are URL-encoded; multiple selections use repeated `path` parameters. Menu actions use integer tags to recover their selection because Finder copies menu items across processes without preserving `representedObject`. Launch failures display an error instead of silently returning. A new Finder action preserves the previous route and its draft in the same window; requests arriving during Git operations are queued. For command-line use:

```sh
open -a GitNebula --args --action commit --path /path/to/repository
open -a GitNebula --args --action diff --path "/path/to/repository/file.txt"
open -a GitNebula --args --action clone --path /path/to/parent-folder
```

After upgrading, quit the previous app, run the installer again, and toggle the Finder extension off and on if Finder still shows the old menu. A GitNebula toolbar button is also available from Finder's toolbar customization.

Clone uses a parent directory and creates a child folder named after the source repository. Existing files in the parent are preserved. The form only asks for the source and parent directory; the repository name is automatic, and the complete destination is shown for confirmation. Finder’s **この階層に Clone…** uses the directory containing the clicked row, so list-view clicks do not redirect Clone into an unrelated folder. **選択フォルダ内に Clone…** explicitly uses the selected folder. Background and sidebar menus use their targeted folder. The picker opens at the current parent. An occupied child destination is rejected without overwriting it.

Disable the extension in System Settings before removing the application. `swift run` runs the development executable and does not install the Finder extension.

## Signed release

Install your Developer ID Application certificate and private key in the macOS keychain. Store App Store Connect/notarization credentials using `xcrun notarytool store-credentials` and use its profile name. Do not add certificates or passwords to this repository.

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-keychain-profile'
bash Mac/package.sh --signed
```

The script signs the extension and application, verifies their signatures, submits the app for notarization, staples and validates the ticket, and creates a ZIP with a SHA-256 checksum. Signing and notarization need your own credentials and network access to Apple's services. Build on each intended CPU architecture; the script packages the host architecture.

Opening detailed settings only checks whether a passphrase is saved; it never retrieves the protected value or requests Keychain authentication. A saved value appears masked. Typing replaces the mask through the native macOS secure text editor; Shift letters and symbols are entered once. Apple's signed SSH tools read the saved value during authentication, independently of GitNebula's changing development signature. Legacy app-owned entries are read only with authentication UI disabled: accessible entries migrate on connection, while entries protected by an older signature require entering and saving the SSH key's passphrase once. GitNebula never requests the macOS login password to read or migrate a legacy entry. The legacy item is preserved until explicit deletion.
