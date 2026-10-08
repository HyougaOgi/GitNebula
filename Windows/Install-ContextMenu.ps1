param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$exe = [System.IO.Path]::GetFullPath($Executable)
$entries = @{
    'HKCU:\Software\Classes\Directory\shell\GitNebula' = '%1'
    'HKCU:\Software\Classes\Directory\Background\shell\GitNebula' = '%V'
    'HKCU:\Software\Classes\*\shell\GitNebula' = '%1'
}
$actions = [ordered]@{
    'commit' = 'Commit…'
    'diff' = '差分一覧…'
    'stash' = 'Stash…'
    'files' = '作業ファイルの管理…'
    'log' = '履歴…'
    'graph' = 'Git グラフ…'
    'compare' = 'コミットを比較…'
    'file-history' = 'ファイルの履歴…'
    'blame' = 'Blame…'
    'reflog' = 'Reflog…'
    'cherry-pick' = 'Cherry-pick…'
    'revert' = 'Revert…'
    'reset' = 'Reset…'
    'patch' = 'パッチ…'
    'switch' = 'ブランチを切り替え…'
    'merge' = 'Merge…'
    'rebase' = 'Rebase…'
    'branches' = 'ブランチの管理…'
    'conflicts' = '競合の解決…'
    'tags' = 'タグを管理…'
    'fetch' = 'Fetch…'
    'pull' = 'Pull…'
    'push' = 'Push…'
    'remotes' = 'リモートを設定…'
    'clone' = 'この階層に Clone…'
    'init' = 'リポジトリを作成（Init）…'
    'workspace' = 'リポジトリの管理…'
    'identity' = 'コミット作成者の設定…'
    'worktrees' = 'Worktree…'
    'submodules' = 'Submodule…'
}
$groupEnds = @('files', 'patch', 'tags', 'remotes')
if (-not $Uninstall -and -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The GitNebula executable does not exist.' }
foreach ($entry in $entries.GetEnumerator()) {
    # Replace the previous single-command registration on upgrades as well.
    $functions = $entry.Key + 'Functions'
    foreach ($owned in @($entry.Key, $functions)) { if (Test-Path -LiteralPath $owned) { Remove-Item -LiteralPath $owned -Recurse -Force } }
    if ($Uninstall) { continue }
    $target = if ($entry.Key.Contains('\Classes\*\')) { $entry.Value } else { $entry.Value + '\.' }
    New-Item -Path ($entry.Key + '\command') -Force | Out-Null
    Set-Item -LiteralPath $entry.Key -Value 'GitNebula'
    New-ItemProperty -LiteralPath $entry.Key -Name 'Icon' -Value $exe -PropertyType String -Force | Out-Null
    Set-Item -LiteralPath ($entry.Key + '\command') -Value ('"' + $exe + '" --action menu --path "' + $target + '"')
    $entry = @{ Key = $functions; Value = $entry.Value }
    New-Item -Path $entry.Key -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'MUIVerb' -Value 'GitNebula の機能' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'Icon' -Value $exe -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'SubCommands' -Value '' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'MultiSelectModel' -Value 'Single' -PropertyType String -Force | Out-Null
    $index = 0
    foreach ($action in $actions.GetEnumerator()) {
        $verb = $entry.Key + '\shell\' + ('{0:D2}' -f $index) + $action.Key
        New-Item -Path ($verb + '\command') -Force | Out-Null
        Set-Item -LiteralPath $verb -Value $action.Value
        if ($groupEnds -contains $action.Key) { New-ItemProperty -LiteralPath $verb -Name 'CommandFlags' -Value 0x40 -PropertyType DWord -Force | Out-Null }
        # A single Explorer selection per dialog; folders include their descendants.
        New-ItemProperty -LiteralPath $verb -Name 'MultiSelectModel' -Value 'Single' -PropertyType String -Force | Out-Null
        # Append \. for directories so a drive root's trailing slash cannot escape the quote.
        $target = if ($entry.Key.Contains('\Classes\*\')) { $entry.Value } elseif ($action.Key -eq 'clone' -and -not $entry.Key.Contains('\Background\')) { $entry.Value + '\..' } else { $entry.Value + '\.' }
        Set-Item -LiteralPath ($verb + '\command') -Value ('"' + $exe + '" --action ' + $action.Key + ' --path "' + $target + '"')
        $index++
    }
}
Write-Output 'GitNebula per-user Explorer action menus updated.'
