# GitNebula for Windows

Native WPF application. Install .NET 8 SDK and Git for Windows, Git is found on PATH or in standard Git for Windows installation directories; its path can also be set in **アプリの設定**.

```powershell
dotnet build Windows/GitNebula.csproj
dotnet run --project Windows/GitNebula.csproj
dotnet run --project tests/windows/GitNebula.BackendTests.csproj
dotnet run --project tests/windows-ui/GitNebula.UiTests.csproj
```

## App screen, residence and Git tools

Normal startup stays in the system tray without a window. Clicking the tray icon opens the **GitNebula** app screen with **詳細設定**. Startup options control opening Home on launch and launching at login. Git work is opened from the Explorer context menu; the tray only contains app/settings/quit. Closing hides the window by default. Git functions in Explorer and the app are grouped in the same order: changes, history, branches, remotes, repository.

**詳細設定 → SSH 認証** accepts a private-key path and masked passphrase. The path is saved in `%LOCALAPPDATA%\GitNebula\settings.json`; the passphrase is stored separately in Windows Credential Manager. Clone/Fetch/Pull/Push use the selected key and automatically provide the saved phrase only to that key's prompt. The saved phrase remains filled and masked when settings reopen. Leaving the phrase blank preserves the saved value; the delete button removes it. Leaving the key blank uses existing SSH configuration/agent. New host fingerprints still require confirmation; HTTPS uses Git's credential helper.

Detailed settings include a transparency slider, System / Light / Dark appearance, and Japanese / English language, applied immediately. Home displays flowing nebula gas clouds and twinkling stars; animations pause when hidden. Back returns to the previous screen and preserves the commit draft. Commit is directly accessible from working screens and first in the Changes category.

**History → Git Graph** displays colored branch lanes, merges and selectable commits, with details below and additional pages of history. Pull reports changed HEAD, commit/file counts or an already-current result; Fetch and Push retain their Git output.

Stash has save/list/Apply/Pop/Drop and previews. Apply and Pop restore staged state and untracked files, require a clean worktree, and preserve the stash on conflict. Buttons explain and reflect the current worktree and selection. The menu offers dedicated Cherry-pick and Revert screens with a commit selector; the history screen also offers both operations. Revert creates a new undo commit without removing history. Merge and Rebase have branch selectors. Conflict notices link to **競合の解決**, which provides resolution, Continue and Abort; merge completion has its own action. Tags, remotes, staging and commit identity have dedicated screens. Each screen shows only the selected function. A tray click during a Git operation waits for it to finish before returning Home.

Push preserves the Git error output and exit status. CRLF line endings are removed from remote and branch names before executing commands. An initial commit and an attached branch are required for Push; the screen explains either missing condition. Unstage skips untracked and unstaged files in a mixed selection and preserves working files, including before the initial commit.

Windows CI is temporarily disabled in the retained `windows` job; set its `if` condition to `true` to restore it. Backend tests can run on macOS; native WPF, tray and Explorer tests require Windows. See [implementation and validation](../shared/VALIDATION.md).

## Package and Explorer integration

Run packaging in PowerShell 7 on Windows:

```powershell
./Windows/Package.ps1 -Runtime win-x64
# Or -Runtime win-arm64 for a matching Windows machine.
```

Extract the archive under `dist/windows/` into a stable installation folder. To install the current user's Explorer file, folder and folder-background menus:

```powershell
./Windows/Install-ContextMenu.ps1 -Executable 'C:\Apps\GitNebula\GitNebula.exe'
```

Right-click a file, folder, or folder background and choose **GitNebula → 変更をコミット / 差分を確認 / 履歴を表示 / Pull / Push / Fetch / ブランチを切り替え / Clone**. The requested operation opens directly; Commit preselects the changes in the clicked file or folder. Explorer supports a single selected file/folder per dialog; use a folder to include all descendants. Each invocation is forwarded to the running app and uses its existing window. Requests wait for a running Git operation to finish. On Windows 11 this entry may appear under **Show more options**. Administrator privileges are not required. Re-run the installer after upgrading to replace the previous single-command entry.

Clone defaults to the right-clicked directory as its parent and creates a repository-named child folder inside it. The form only asks for the source and parent directory; the repository name is automatic, and the complete destination is shown for confirmation. Existing parent contents are preserved. A later Explorer request updates the parent even if a previous Clone dialog had been edited. Occupied child destinations are rejected without overwriting them.

Command-line examples:

```powershell
GitNebula.exe --action commit --path "C:\path\to\repo"
GitNebula.exe --action diff --path "C:\path\to\repo\file.txt"
GitNebula.exe --action clone --path "C:\Projects"
```

The legacy `--open` argument opens the operation chooser.

Remove the menu before moving or deleting the application:

```powershell
./Windows/Install-ContextMenu.ps1 -Executable 'C:\Apps\GitNebula\GitNebula.exe' -Uninstall
```

## Signed release

Install a code-signing certificate and private key in the current user's certificate store. Install Windows SDK SignTool and put `signtool.exe` on PATH. Do not commit private keys or certificate bundles.

```powershell
./Windows/Package.ps1 -Signed -CertificateThumbprint 'YOUR_CERTIFICATE_THUMBPRINT'
```

The script publishes a self-contained application, signs `GitNebula.exe` and `GitNebula.dll` with SHA-256 and an RFC 3161 timestamp, verifies Authenticode signatures, and creates a ZIP with a checksum. Use `-TimestampUrl` if your certificate provider specifies another timestamp service. Signing requires your own certificate; an unsigned package is a development build.
