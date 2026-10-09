# GitNebula for Windows

Native WPF application. Install .NET 8 SDK and Git for Windows, Git is found on PATH or in standard Git for Windows installation directories; its path can also be set in **アプリの設定**.

## インストール

`GitNebula` フォルダがまだない作業ディレクトリで、以下をまとめて貼り付けてください。

Windows 10/11のx64またはARM64版で、**PowerShell**に以下を貼り付けてください。標準のWindows PowerShell 5.1とPowerShell 7の両方に対応しています。Gitと.NET 8 SDKがなければ[WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/)でインストールします。`winget` がない場合は、Microsoft Storeの **アプリ インストーラー** をインストール／更新してからPowerShellを開き直してください。依存ソフトのインストール中にWindowsの確認画面が出たら許可してください。

```powershell
& {
    $ErrorActionPreference = 'Stop'
    function Update-GitNebulaPath {
        $gitNebulaToolDirectories = @(
            "$env:ProgramW6432\Git\cmd", "$env:ProgramW6432\dotnet",
            "$env:ProgramFiles\Git\cmd", "$env:ProgramFiles\dotnet",
            "$env:LOCALAPPDATA\Programs\Git\cmd"
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
        $env:Path = @([Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User'),
            ($gitNebulaToolDirectories -join ';'), $env:Path) -join ';'
    }
    Update-GitNebulaPath
    if (-not (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw 'Git for Windows installation failed.' }
        Update-GitNebulaPath
    }
    $sdks = @()
    if (Get-Command dotnet.exe -CommandType Application -ErrorAction SilentlyContinue) {
        $sdks = @(dotnet --list-sdks)
        if ($LASTEXITCODE -ne 0) { $sdks = @() }
    }
    if (-not ($sdks -match '^8\.')) {
        winget install --id Microsoft.DotNet.SDK.8 --exact --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw '.NET 8 SDK installation failed.' }
        Update-GitNebulaPath
    }
    git clone https://github.com/HyougaOgi/GitNebula.git
    if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
    Set-Location GitNebula
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\Windows\Install.ps1
    if ($LASTEXITCODE -ne 0) { throw 'GitNebula installation failed. See the error above.' }
}
```

`%LOCALAPPDATA%\Programs\GitNebula` にアプリを配置し、スタートメニューとExplorerの右クリックメニューを登録して、トレイで起動します。x64／ARM64は自動判定し、.NETランタイムもアプリに同梱します。GitNebula本体のインストールに管理者権限は不要です。Windows 11では右クリックの **その他のオプションを確認** にメニューが表示される場合があります。

更新時はトレイメニューからGitNebulaを終了し、既存のチェックアウトで以下を実行してください。設定と保存した認証情報は維持し、以前のアプリは `%LOCALAPPDATA%\Programs\.gitnebula-backups` に保管します。ビルドに失敗した場合はインストール済みアプリを変更しません。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows\Install.ps1
```

`-NoOpen` でインストール後の起動を省略できます。`-Destination` で配置先、`-Runtime win-x64`／`-Runtime win-arm64` でCPUを明示できます。通常は指定不要です。実行ポリシーの指定はこのプロセスだけに適用し、ユーザー設定は変更しません。

## Development and tests

History and graph reserve space for commit information when the window shrinks. Paths stay on one line, navigation and path controls share rows, and long operation results scroll within a bounded area. Every commit field remains reachable without maximizing.

```powershell
dotnet build Windows/GitNebula.csproj
dotnet run --project Windows/GitNebula.csproj
dotnet run --project tests/windows/GitNebula.BackendTests.csproj
dotnet run --project tests/windows-ui/GitNebula.UiTests.csproj
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/windows/Test-Install.ps1
```

## App screen, residence and Git tools

Normal startup stays in the system tray without a window. Clicking the tray icon opens the **GitNebula** app screen with **詳細設定**. Startup options control opening Home on launch and launching at login. Git work is opened from the Explorer context menu; the tray only contains app/settings/quit. Closing hides the window by default. Git functions in Explorer and the app are grouped in the same order: changes, history, branches, remotes, repository.

**詳細設定 → SSH 認証** accepts a private-key path and masked passphrase. The path is saved in `%LOCALAPPDATA%\GitNebula\settings.json`; the passphrase is stored separately in Windows Credential Manager. Clone/Fetch/Pull/Push use the selected key and automatically provide the saved phrase only to that key's prompt. The saved phrase remains filled and masked when settings reopen. Leaving the phrase blank preserves the saved value; the delete button removes it. Leaving the key blank uses existing SSH configuration/agent. New host fingerprints still require confirmation; HTTPS uses Git's credential helper.

Detailed settings include a transparency slider, System / Light / Dark appearance, and Japanese / English language, applied immediately. Home uses flowing volumetric nebula gas and an animated colored title; background stars twinkle, and animations pause when hidden or motion is disabled. Back returns to the previous screen and preserves the commit draft. Commit is directly accessible from working screens and first in the Changes category.

**History → Git Graph** offers the colored branch-lane view and a 4D nebula view with spatial branch logs, real parent connections, count-dependent node size, volumetric gas, orbit, reversible scroll zoom, focus and history playback. Both modes retain complete commit records and additional pages of history. Pull reports changed HEAD, commit/file counts or an already-current result; Fetch and Push retain their Git output.

Stash has save/list/Apply/Pop/Drop and previews. Apply and Pop restore staged state and untracked files, require a clean worktree, and preserve the stash on conflict. Buttons explain and reflect the current worktree and selection. The menu offers dedicated Cherry-pick and Revert screens with a commit selector; the history screen also offers both operations. Revert creates a new undo commit without removing history. Merge and Rebase have branch selectors. Conflict notices link to **競合の解決**, which provides resolution, Continue and Abort; merge completion has its own action. Tags, remotes, staging and commit identity have dedicated screens. Each screen shows only the selected function. A tray click during a Git operation waits for it to finish before returning Home.

Push preserves the Git error output and exit status. CRLF line endings are removed from remote and branch names before executing commands. An initial commit and an attached branch are required for Push; the screen explains either missing condition. Unstage skips untracked and unstaged files in a mixed selection and preserves working files, including before the initial commit.


Selecting a commit shows its full ID, complete message, author/committer identities and timestamps, full parents, references and tree. Native copy buttons cover the ID, message, each field and all information. The full ID remains above a single scrollable body, so normal windows can reach the final field. History and graph separate information from changed files into tabs. Changed files offer merge-parent selection and aligned comparisons with line numbers, colors, synchronized scrolling and change navigation; working files use the same comparison view.

Branch switching includes untracked remote branches and a **リモートから更新** button, including repositories cloned with a single branch. Selecting a remote branch creates a local tracking branch; existing local names and uncommitted changes are protected. Commit has multiline input and Ctrl+Enter. Pull, Push, Fetch and Clone display Git's reported percentage per stage and a progress bar, then show completion only after Git and refresh finish.

The operation chooser also includes Init, Ignore/Discard, commit comparison, file history, Blame, Reflog, Soft/Mixed/Hard Reset, binary patch export/check/application, Worktree creation/listing and Submodule registration/update. Each tool has its own form and result area. See the [feature matrix](../shared/FEATURES.md).

Windows CI is temporarily disabled in the retained `windows` job; set its `if` condition to `true` to restore it. Backend tests can run on macOS; native WPF, tray and Explorer tests require Windows. See [implementation and validation](../shared/VALIDATION.md).

## Package and Explorer integration

Run packaging in Windows PowerShell 5.1 or PowerShell 7 on Windows. Installing the app uses `Install.ps1` above; packaging only creates an archive:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows\Package.ps1 -Runtime win-x64
# Or -Runtime win-arm64 for a matching Windows machine.
```

For a manually installed ZIP, extract it into `%LOCALAPPDATA%\Programs\GitNebula` before registering the menus below (no SDK is needed to run a self-contained ZIP). The source installer already registers the current user's Explorer file, folder and folder-background menus automatically:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows\Install-ContextMenu.ps1 -Executable "$env:LOCALAPPDATA\Programs\GitNebula\GitNebula.exe"
```

Right-click **GitNebula** to open the repository operation chooser, or choose an operation under **GitNebula の機能**. The requested operation opens directly; Commit preselects the changes in the clicked file or folder. Explorer supports a single selected file/folder per dialog; use a folder to include all descendants. Each invocation is forwarded to the running app. Each repository retains separate work, History and Graph windows; matching requests reuse their window. Resizing History preserves the Graph size and camera, and different repositories preserve work and drafts. Requests wait for a running Git operation to finish in their target window. On Windows 11 this entry may appear under **Show more options**. Administrator privileges are not required. Re-run the installer after upgrading to replace the previous single-command entry.

Clone from a folder row defaults to the containing directory; folder-background Clone uses the current directory and creates a repository-named child folder inside it. The form only asks for the source and parent directory; the repository name is automatic, and the complete destination is shown for confirmation. Existing parent contents are preserved. A later Explorer request updates the parent even if a previous Clone dialog had been edited. Occupied child destinations are rejected without overwriting them.

Command-line examples:

```powershell
GitNebula.exe --action commit --path "C:\path\to\repo"
GitNebula.exe --action diff --path "C:\path\to\repo\file.txt"
GitNebula.exe --action clone --path "C:\Projects"
```

The legacy `--open` argument opens the operation chooser.

Remove the menu before moving or deleting the application:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows\Install-ContextMenu.ps1 -Executable "$env:LOCALAPPDATA\Programs\GitNebula\GitNebula.exe" -Uninstall
```

## Signed release

Install a code-signing certificate and private key in the current user's certificate store. Install Windows SDK SignTool and put `signtool.exe` on PATH. Do not commit private keys or certificate bundles.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows\Package.ps1 -Signed -CertificateThumbprint 'YOUR_CERTIFICATE_THUMBPRINT'
```

The script publishes a self-contained application, signs `GitNebula.exe` and `GitNebula.dll` with SHA-256 and an RFC 3161 timestamp, verifies Authenticode signatures, and creates a ZIP with a checksum. Use `-TimestampUrl` if your certificate provider specifies another timestamp service. Signing requires your own certificate; an unsigned package is a development build.
