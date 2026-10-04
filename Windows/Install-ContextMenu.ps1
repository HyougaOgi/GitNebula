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
    'commit' = '変更をコミット…'
    'diff' = '差分を確認…'
    'log' = '履歴を表示…'
    'pull' = '変更を受信（Pull）…'
    'push' = '変更を送信（Push）…'
    'fetch' = 'リモートを更新（Fetch）…'
    'switch' = 'ブランチを切り替え…'
    'clone' = 'リポジトリを複製（Clone）…'
    'workspace' = '詳細操作…'
}
if (-not $Uninstall -and -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The GitNebula executable does not exist.' }
foreach ($entry in $entries.GetEnumerator()) {
    # Replace the previous single-command registration on upgrades as well.
    if (Test-Path -LiteralPath $entry.Key) { Remove-Item -LiteralPath $entry.Key -Recurse -Force }
    if ($Uninstall) { continue }
    New-Item -Path $entry.Key -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'MUIVerb' -Value 'GitNebula' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'Icon' -Value $exe -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'SubCommands' -Value '' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $entry.Key -Name 'MultiSelectModel' -Value 'Single' -PropertyType String -Force | Out-Null
    $index = 0
    foreach ($action in $actions.GetEnumerator()) {
        $verb = $entry.Key + '\shell\' + ('{0:D2}' -f $index) + $action.Key
        New-Item -Path ($verb + '\command') -Force | Out-Null
        Set-Item -LiteralPath $verb -Value $action.Value
        # A single Explorer selection per dialog; folders include their descendants.
        New-ItemProperty -LiteralPath $verb -Name 'MultiSelectModel' -Value 'Single' -PropertyType String -Force | Out-Null
        # Append \. for directories so a drive root's trailing slash cannot escape the quote.
        $target = if ($entry.Key.Contains('\Classes\*\')) { $entry.Value } else { $entry.Value + '\.' }
        Set-Item -LiteralPath ($verb + '\command') -Value ('"' + $exe + '" --action ' + $action.Key + ' --path "' + $target + '"')
        $index++
    }
}
Write-Output 'GitNebula per-user Explorer action menus updated.'
