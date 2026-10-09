# Isolated installation tests: no registry changes, shortcuts or app processes.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../Windows/Install.ps1')
$publish = ${function:Publish-GitNebulaApplication}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('GitNebula install [test] ' + [guid]::NewGuid())
$originalPath = $env:Path
$originalArchitecture = $env:PROCESSOR_ARCHITECTURE
$originalNativeArchitecture = $env:PROCESSOR_ARCHITEW6432

function Assert-Install([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-InstallFailure([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch {
        Assert-Install ($_.Exception.Message -like "*$Message*") "Unexpected failure: $_"
        return
    }
    throw "Expected failure containing: $Message"
}
function Test-GitNebulaWindows { return $true }
function Get-GitNebulaShortcutPath { return Join-Path $testRoot 'Start menu/GitNebula.lnk' }
function Test-GitNebulaRunning([string]$Executable) { return $script:running }
function Set-GitNebulaExplorerMenu([string]$Executable, [switch]$Uninstall) {
    if ($Uninstall) { $script:menu = $null; return }
    $script:menu = $Executable
}
function Set-GitNebulaShortcut([string]$Executable, [string]$ShortcutPath) {
    New-Item -ItemType Directory -Path (Split-Path $ShortcutPath -Parent) -Force | Out-Null
    Set-Content -LiteralPath $ShortcutPath -Value $Executable
    if ($script:shortcutFailure) { $script:shortcutFailure = $false; throw 'Shortcut failed' }
}
function Publish-GitNebulaApplication([string]$Runtime, [string]$Stage) {
    $script:publishCount++
    $script:publishedRuntime = $Runtime
    if ($script:buildFailure) { throw 'Build failed' }
    Set-Content -LiteralPath (Join-Path $Stage 'GitNebula.exe') -Value $script:version
    if (-not $script:missingDll) { Set-Content -LiteralPath (Join-Path $Stage 'GitNebula.dll') -Value $script:version }
    New-Item -ItemType Directory -Path (Join-Path $Stage 'resources') | Out-Null
    Set-Content -LiteralPath (Join-Path $Stage 'resources/data.txt') -Value 'resource'
    if ($script:runDuringBuild) { $script:running = $true }
}
function Find-GitNebulaTool([string]$Name) {
    if ($Name -eq 'git.exe') { return 'Invoke-TestGit' }
    return 'Invoke-TestDotnet'
}
function Invoke-TestGit { $global:LASTEXITCODE = $script:gitExit }
function Invoke-TestDotnet {
    if ($args[0] -eq '--list-sdks') {
        $global:LASTEXITCODE = 0
        return $script:sdk
    }
    $global:LASTEXITCODE = 23
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $env:PROCESSOR_ARCHITEW6432 = ''
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    Assert-Install ((Get-GitNebulaRuntime) -eq 'win-x64') 'Wrong x64 runtime'
    $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    Assert-Install ((Get-GitNebulaRuntime) -eq 'win-arm64') 'Must use OS architecture in an emulated shell'
    $env:PROCESSOR_ARCHITEW6432 = ''
    $env:PROCESSOR_ARCHITECTURE = 'x86'
    Assert-InstallFailure { Get-GitNebulaRuntime } 'Unsupported Windows architecture'
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'

    $script:gitExit = 0
    $script:sdk = '8.0.425 [C:\Program Files\dotnet\sdk]'
    Assert-InstallFailure { & $publish -Runtime win-x64 -Stage $testRoot } 'dotnet publish failed (exit 23)'
    $script:sdk = '6.0.428 [C:\Program Files\dotnet\sdk]'
    Assert-InstallFailure { & $publish -Runtime win-x64 -Stage $testRoot } 'Install .NET SDK 8'
    $script:gitExit = 1
    Assert-InstallFailure { & $publish -Runtime win-x64 -Stage $testRoot } 'Git for Windows could not be started'
    $env:Path = $originalPath

    $destination = Join-Path $testRoot 'Programs/GitNebula'
    $script:version = 'version one'
    Install-GitNebula -Destination $destination -NoOpen
    $exe = Join-Path $destination 'GitNebula.exe'
    $shortcut = Get-GitNebulaShortcutPath
    Assert-Install ((Get-Content -LiteralPath $exe -Raw).Trim() -eq 'version one') 'New install did not copy the executable'
    Assert-Install ($script:menu -eq $exe) 'Menu points to a build/temp directory'
    Assert-Install ((Get-Content -LiteralPath $shortcut -Raw).Trim() -eq $exe) 'Wrong shortcut target'
    Assert-Install ($script:publishedRuntime -eq 'win-x64') 'Automatic runtime not used by installer'
    Assert-Install (Test-Path -LiteralPath (Join-Path $destination 'resources/data.txt')) 'Nested resources missing'

    $script:buildFailure = $true
    Assert-InstallFailure { Install-GitNebula -Destination $destination -NoOpen } 'Build failed'
    $script:buildFailure = $false
    Assert-Install ((Get-Content -LiteralPath $exe -Raw).Trim() -eq 'version one') 'Build failure replaced the installed app'
    $script:missingDll = $true
    Assert-InstallFailure { Install-GitNebula -Destination $destination -NoOpen } 'did not produce GitNebula.dll'
    $script:missingDll = $false

    $script:running = $true
    $before = $script:publishCount
    Assert-InstallFailure { Install-GitNebula -Destination $destination -NoOpen } 'Quit GitNebula'
    Assert-Install ($script:publishCount -eq $before) 'Must reject a running app before publishing'
    $script:running = $false
    $script:runDuringBuild = $true
    Assert-InstallFailure { Install-GitNebula -Destination $destination -NoOpen } 'Quit GitNebula'
    $script:running = $false
    $script:runDuringBuild = $false
    Assert-Install ((Get-Content -LiteralPath $exe -Raw).Trim() -eq 'version one') 'App started during build was replaced'

    $script:version = 'version two'
    $script:shortcutFailure = $true
    Assert-InstallFailure { Install-GitNebula -Destination $destination -Runtime win-arm64 -NoOpen } 'Shortcut failed'
    Assert-Install ((Get-Content -LiteralPath $exe -Raw).Trim() -eq 'version one') 'Failed update did not restore the app'
    Assert-Install ($script:menu -eq $exe) 'Failed update did not restore the Explorer registration'
    Assert-Install ((Get-Content -LiteralPath $shortcut -Raw).Trim() -eq $exe) 'Failed update did not restore the shortcut'

    Install-GitNebula -Destination $destination -Runtime win-arm64 -NoOpen
    Assert-Install ((Get-Content -LiteralPath $exe -Raw).Trim() -eq 'version two') 'Successful update did not install the new version'
    $oldExes = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'Programs/.gitnebula-backups') -Filter GitNebula.exe -Recurse)
    Assert-Install ($oldExes.Count -eq 1) 'Update must preserve exactly one previous version'
    Assert-Install ((Get-Content -LiteralPath $oldExes[0].FullName -Raw).Trim() -eq 'version one') 'Backup contains the wrong version'

    $fresh = Join-Path $testRoot 'Fresh/GitNebula'
    $script:shortcutFailure = $true
    Assert-InstallFailure { Install-GitNebula -Destination $fresh -NoOpen } 'Shortcut failed'
    Assert-Install (-not (Test-Path -LiteralPath $fresh)) 'Failed first install left an incomplete application'
    Assert-Install ($null -eq $script:menu) 'Failed first install left a broken menu'
    Assert-Install ((Get-Content -LiteralPath $shortcut -Raw).Trim() -eq $exe) 'Failed first install lost a pre-existing shortcut'

    $occupied = Join-Path $testRoot 'Other app'
    New-Item -ItemType Directory -Path $occupied | Out-Null
    Set-Content -LiteralPath (Join-Path $occupied 'notes.txt') -Value 'keep'
    Assert-InstallFailure { Install-GitNebula -Destination $occupied -NoOpen } 'Refusing to replace'
    Assert-Install ((Get-Content -LiteralPath (Join-Path $occupied 'notes.txt') -Raw).Trim() -eq 'keep') 'Unrelated files changed'
    Assert-Install (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'Programs') -Filter '.gitnebula-install-*' -Force).Count -eq 0) 'Staging directories were not cleaned'
    Write-Output 'PASS: architecture, prerequisites, publish failures, install, update, running-app guard, rollback and preservation'
} finally {
    $env:Path = $originalPath
    $env:PROCESSOR_ARCHITECTURE = $originalArchitecture
    $env:PROCESSOR_ARCHITEW6432 = $originalNativeArchitecture
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
