$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '../../Windows/Install-ContextMenu.ps1'
$exe = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Windows/bin/Debug/net8.0-windows/GitNebula.exe'))
$expected = @('commit', 'diff', 'stash', 'files', 'log', 'graph', 'cherry-pick', 'revert', 'switch', 'merge', 'rebase', 'branches', 'conflicts', 'tags', 'fetch', 'pull', 'push', 'remotes', 'clone', 'workspace', 'identity')
$roots = @('HKCU:\Software\Classes\Directory\shell\GitNebula', 'HKCU:\Software\Classes\Directory\Background\shell\GitNebula', 'HKCU:\Software\Classes\*\shell\GitNebula')
foreach ($root in $roots) { if (Test-Path -LiteralPath $root) { throw 'Run this integration test in a clean user profile; an existing GitNebula installation was found.' } }
try {
    # Simulate upgrading the former Open-only menu.
    New-Item -Path ($roots[0] + '\command') -Force | Out-Null
    Set-Item -LiteralPath ($roots[0] + '\command') -Value 'old launcher'
    & $installer -Executable $exe
    & $installer -Executable $exe
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath ($root + '\command')) { throw 'Old single action survived upgrade.' }
        $verbs = @(Get-ChildItem -LiteralPath ($root + '\shell'))
        if ($verbs.Count -ne $expected.Count) { throw 'Missing action menu.' }
        $index = 0
        foreach ($verb in ($verbs | Sort-Object PSChildName)) {
            $command = (Get-Item -LiteralPath ($verb.PSPath + '\command')).GetValue('')
            if ($command -notmatch (' --action ' + [regex]::Escape($expected[$index]) + ' --path ')) { throw "Invalid action order: $command" }
            $separator = (Get-Item -LiteralPath $verb.PSPath).GetValue('CommandFlags', 0)
            $end = @('files', 'revert', 'tags', 'remotes') -contains $expected[$index]
            if (($separator -eq 0x40) -ne $end) { throw 'Missing menu grouping.' }
            $index++
        }
    }
} finally { & $installer -Executable $exe -Uninstall }
foreach ($root in $roots) { if (Test-Path -LiteralPath $root) { throw 'Uninstall did not remove the menu.' } }
Write-Output 'PASS: Explorer action registration, upgrade, repeated install and uninstall'
