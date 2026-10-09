param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64',
    [switch]$Signed,
    [string]$CertificateThumbprint = $env:WINDOWS_CERT_THUMBPRINT,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Build on Windows with Windows PowerShell 5.1 or PowerShell 7.' }
if ($Signed -and [string]::IsNullOrWhiteSpace($CertificateThumbprint)) { throw 'Provide a code-signing certificate thumbprint from the Windows certificate store.' }
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Install.ps1') -Runtime $Runtime
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('GitNebula-' + [guid]::NewGuid())
$output = Join-Path $root "dist\windows\$Runtime"
try {
    New-Item $stage -ItemType Directory | Out-Null
    dotnet publish "$PSScriptRoot\GitNebula.csproj" -c Release -r $Runtime --self-contained true -o $stage
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
    Add-GitNebulaInstallationFiles -Stage $stage
    if ($Signed) {
        $signtool = (Get-Command signtool.exe -ErrorAction Stop).Source
        & $signtool sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 "$stage\GitNebula.exe" "$stage\GitNebula.dll"
        if ($LASTEXITCODE -ne 0) { throw 'Authenticode signing failed' }
        & $signtool verify /pa /all "$stage\GitNebula.exe" "$stage\GitNebula.dll"
        if ($LASTEXITCODE -ne 0) { throw 'Authenticode verification failed' }
    }
    New-Item $output -ItemType Directory -Force | Out-Null
    $suffix = if ($Signed) { 'signed' } else { 'unsigned' }
    $archive = Join-Path $output "GitNebula-$suffix.zip"
    Compress-Archive -Path "$stage\*" -DestinationPath $archive -Force
    (Get-FileHash $archive -Algorithm SHA256).Hash | Set-Content "$archive.sha256"
    Write-Output "Created $archive"
} finally { if (Test-Path $stage) { Remove-Item $stage -Recurse -Force } }
