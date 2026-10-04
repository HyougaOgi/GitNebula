param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$exe = [System.IO.Path]::GetFullPath($Executable)
$entries = @{
    'HKCU:\Software\Classes\Directory\shell\GitNebula' = '%1'
    'HKCU:\Software\Classes\Directory\Background\shell\GitNebula' = '%V'
}
foreach ($entry in $entries.GetEnumerator()) {
    if ($Uninstall) {
        if (Test-Path $entry.Key) { Remove-Item $entry.Key -Recurse -Force }
        continue
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The GitNebula executable does not exist.' }
    New-Item $entry.Key -Force | Out-Null
    Set-Item $entry.Key -Value 'Open in GitNebula'
    New-ItemProperty $entry.Key -Name 'Icon' -Value $exe -PropertyType String -Force | Out-Null
    New-Item ($entry.Key + '\command') -Force | Out-Null
    Set-Item ($entry.Key + '\command') -Value ('"' + $exe + '" --open "' + $entry.Value + '"')
}
Write-Output 'GitNebula per-user Explorer integration updated.'
