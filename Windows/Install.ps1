param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [string]$Destination,
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'

function Test-GitNebulaWindows {
    # $IsWindows is unavailable in the built-in Windows PowerShell 5.1.
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Get-GitNebulaRuntime {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture) {
        'AMD64' { return 'win-x64' }
        'ARM64' { return 'win-arm64' }
        default { throw "Unsupported Windows architecture: $architecture. GitNebula requires x64 or ARM64 Windows." }
    }
}

function Find-GitNebulaTool([string]$Name, [switch]$Optional) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $relative = switch ($Name) {
        'git.exe' { 'Git\cmd\git.exe' }
        'dotnet.exe' { 'dotnet\dotnet.exe' }
    }
    foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base -and $relative) {
            $candidate = Join-Path $base $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    if ($Name -eq 'git.exe' -and $env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if ($Optional) { return $null }
    throw "Cannot find $Name. Install Git for Windows or .NET SDK 8 and run the installer again."
}

function Update-GitNebulaPath {
    # Dependency installers update the registry PATH, not this running shell.
    $env:Path = @([Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User'), $env:Path) -join ';'
}

function Install-GitNebulaDependency([string]$Package) {
    $winget = Find-GitNebulaTool 'winget.exe' -Optional
    if (-not $winget) { throw 'WinGet is unavailable. Update Microsoft App Installer, or install Git for Windows and .NET SDK 8 manually.' }
    Write-Host "Installing $Package..."
    & $winget install --id $Package --exact --source winget --accept-package-agreements --accept-source-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Package installation failed (exit $LASTEXITCODE)." }
    Update-GitNebulaPath
}

function Initialize-GitNebulaGit {
    Update-GitNebulaPath
    $git = Find-GitNebulaTool 'git.exe' -Optional
    if (-not $git) {
        Install-GitNebulaDependency 'Git.Git'
        $git = Find-GitNebulaTool 'git.exe'
    }
    & $git --version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Git for Windows could not be started.' }
}

function Initialize-GitNebulaDependencies {
    Initialize-GitNebulaGit
    $dotnet = Find-GitNebulaTool 'dotnet.exe' -Optional
    $sdks = @()
    if ($dotnet) {
        $sdks = @(& $dotnet --list-sdks)
        if ($LASTEXITCODE -ne 0) { $sdks = @() }
    }
    $supportedSdk = '^(?:[89]|[1-9][0-9]+)\.[0-9]+\.[0-9]+ '
    if (-not ($sdks -match $supportedSdk)) {
        Install-GitNebulaDependency 'Microsoft.DotNet.SDK.8'
        $dotnet = Find-GitNebulaTool 'dotnet.exe'
        $sdks = @(& $dotnet --list-sdks)
        if ($LASTEXITCODE -ne 0 -or -not ($sdks -match $supportedSdk)) {
            throw '.NET SDK 8 is still unavailable after installation. Reopen PowerShell and try again.'
        }
    }
    return $dotnet
}

function Publish-GitNebulaApplication([string]$Runtime, [string]$Stage) {
    $dotnet = Initialize-GitNebulaDependencies
    & $dotnet publish (Join-Path $PSScriptRoot 'GitNebula.csproj') -c Release -r $Runtime --self-contained true -o $Stage
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit $LASTEXITCODE). The installed application was not changed." }
}

function Get-GitNebulaSourceDirectory { return $PSScriptRoot }

function Write-GitNebulaInstallManifest([string]$Directory) {
    $names = @((Get-ChildItem -LiteralPath $Directory -Force).Name | Where-Object { $_ -ne 'GitNebula-install-files.json' })
    $names += 'GitNebula-install-files.json'
    @{ files = $names } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'GitNebula-install-files.json') -Encoding UTF8
}

function Add-GitNebulaInstallationFiles([string]$Stage) {
    foreach ($name in @('install.cmd', 'Install.ps1', 'Install-ContextMenu.ps1', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $Stage
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'LICENSE') -Destination $Stage
    Write-GitNebulaInstallManifest -Directory $Stage
}

function Initialize-GitNebulaPayload([string]$Runtime, [string]$Stage) {
    $source = Get-GitNebulaSourceDirectory
    if (Test-Path -LiteralPath (Join-Path $source 'GitNebula.csproj')) {
        Write-Host "Building GitNebula ($Runtime)..."
        Publish-GitNebulaApplication -Runtime $Runtime -Stage $Stage
        Add-GitNebulaInstallationFiles -Stage $Stage
        return
    }
    $manifestPath = Join-Path $source 'GitNebula-install-files.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'This download is incomplete. Extract the complete GitNebula ZIP and run install.cmd from that folder.' }
    $files = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).files)
    foreach ($required in @('GitNebula.exe', 'GitNebula.dll', 'hostfxr.dll', 'coreclr.dll', 'install.cmd', 'Install.ps1', 'Install-ContextMenu.ps1')) {
        if ($files -notcontains $required) { throw "The application package is missing $required." }
    }
    foreach ($name in $files) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name -in @('.', '..') -or
            $name.IndexOfAny([char[]]'\/') -ge 0 -or [IO.Path]::GetFileName($name) -ne $name) {
            throw 'Invalid application package file list.'
        }
        $file = Join-Path $source $name
        if (-not (Test-Path -LiteralPath $file)) { throw "The application package is missing $name." }
    }
    Initialize-GitNebulaGit
    Write-Host 'Installing the packaged application...'
    foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination $Stage -Recurse -Force }
}

function Test-GitNebulaRunning([string]$Executable) {
    foreach ($process in @(Get-Process -Name GitNebula -ErrorAction SilentlyContinue)) {
        if ($process.Path -and [string]::Equals($process.Path, $Executable, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-GitNebulaShortcutPath {
    return Join-Path ([Environment]::GetFolderPath('Programs')) 'GitNebula.lnk'
}

function Set-GitNebulaShortcut([string]$Executable, [string]$ShortcutPath) {
    New-Item -ItemType Directory -Path (Split-Path $ShortcutPath -Parent) -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $Executable
    $shortcut.WorkingDirectory = Split-Path $Executable -Parent
    $shortcut.IconLocation = "$Executable,0"
    $shortcut.Description = 'GitNebula'
    $shortcut.Save()
}

function Set-GitNebulaExplorerMenu([string]$Executable, [switch]$Uninstall) {
    & (Join-Path $PSScriptRoot 'Install-ContextMenu.ps1') -Executable $Executable -Uninstall:$Uninstall
}

function Install-GitNebula {
    param(
        [ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
        [string]$Destination,
        [switch]$NoOpen
    )
    if (-not (Test-GitNebulaWindows)) { throw 'Run Windows/Install.ps1 on Windows, using Windows PowerShell 5.1 or PowerShell 7.' }
    if (-not $Runtime) { $Runtime = Get-GitNebulaRuntime }
    if (-not $Destination) { $Destination = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\GitNebula' }
    $Destination = [IO.Path]::GetFullPath($Destination)
    $parent = Split-Path $Destination -Parent
    if (-not $parent -or $Destination -eq [IO.Path]::GetPathRoot($Destination)) { throw 'Choose an application directory, not a drive root.' }
    if (Test-Path -LiteralPath $Destination) {
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw "The destination is not a directory: $Destination" }
        if (@(Get-ChildItem -LiteralPath $Destination -Force).Count -gt 0 -and
            -not ((Test-Path -LiteralPath (Join-Path $Destination 'GitNebula.exe') -PathType Leaf) -and
                  (Test-Path -LiteralPath (Join-Path $Destination 'GitNebula.dll') -PathType Leaf))) {
            throw "Refusing to replace a directory that is not a GitNebula installation: $Destination"
        }
    }
    $executable = Join-Path $Destination 'GitNebula.exe'
    if (Test-GitNebulaRunning $executable) { throw 'Quit GitNebula from its tray menu before updating, then run this installer again.' }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('GitNebula-install-' + [guid]::NewGuid())
    $pending = Join-Path $parent ('.gitnebula-install-' + [guid]::NewGuid())
    $shortcutPath = Get-GitNebulaShortcutPath
    $previousApp = Test-Path -LiteralPath $executable -PathType Leaf
    $backup = $null
    $installed = $false
    $integrationStarted = $false
    try {
        New-Item -ItemType Directory -Path $stage | Out-Null
        Initialize-GitNebulaPayload -Runtime $Runtime -Stage $stage
        foreach ($file in @('GitNebula.exe', 'GitNebula.dll')) {
            if (-not (Test-Path -LiteralPath (Join-Path $stage $file) -PathType Leaf)) { throw "The build did not produce $file. The installed application was not changed." }
        }
        if (Test-Path -LiteralPath $shortcutPath) { Copy-Item -LiteralPath $shortcutPath -Destination (Join-Path $stage 'previous-shortcut.lnk') }
        # Place the new app on the destination drive before replacing the old one.
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        New-Item -ItemType Directory -Path $pending | Out-Null
        Get-ChildItem -LiteralPath $stage -Force | Where-Object { $_.Name -ne 'previous-shortcut.lnk' } |
            Copy-Item -Destination $pending -Recurse -Force
        if (Test-GitNebulaRunning $executable) { throw 'Quit GitNebula from its tray menu before updating, then run this installer again.' }
        if (Test-Path -LiteralPath $Destination) {
            $backup = Join-Path $parent ('.gitnebula-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid() + '\GitNebula')
            New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force | Out-Null
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $pending -Destination $Destination
        $installed = $true
        $integrationStarted = $true
        Set-GitNebulaExplorerMenu -Executable $executable
        Set-GitNebulaShortcut -Executable $executable -ShortcutPath $shortcutPath
    } catch {
        $failure = $_
        if ($installed) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $Destination }
        if ($integrationStarted) {
            try {
                Set-GitNebulaExplorerMenu -Executable $executable -Uninstall:(-not $previousApp)
                $previousShortcut = Join-Path $stage 'previous-shortcut.lnk'
                if (Test-Path -LiteralPath $previousShortcut) { Copy-Item -LiteralPath $previousShortcut -Destination $shortcutPath -Force }
                elseif (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
            } catch { Write-Warning "Could not restore menu/shortcut registration: $_" }
        }
        throw $failure
    } finally {
        foreach ($temporary in @($stage, $pending)) {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
        }
    }
    if ($backup) { Write-Host "Previous version saved to $backup" }
    Write-Host "Installed $executable"
    Write-Host 'Launch GitNebula from the Start menu. On Windows 11, Explorer entries may be under Show more options.'
    if (-not $NoOpen) {
        try { Start-Process -FilePath $executable }
        catch { Write-Warning "Installation completed, but automatic launch failed: $_. Open GitNebula from the Start menu." }
    }
}

# Dot-sourcing exposes the installer functions for isolated tests without installing.
if ($MyInvocation.InvocationName -ne '.') { Install-GitNebula @PSBoundParameters }
