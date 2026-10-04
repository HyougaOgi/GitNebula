# GitNebula for Windows

Native WPF application. Install .NET 8 SDK and Git for Windows, with `git.exe` on PATH.

```powershell
dotnet build Windows/GitNebula.csproj
dotnet run --project Windows/GitNebula.csproj
dotnet run --project tests/windows/GitNebula.BackendTests.csproj
```

## Package and Explorer integration

Run packaging in PowerShell 7 on Windows:

```powershell
./Windows/Package.ps1 -Runtime win-x64
# Or -Runtime win-arm64 for a matching Windows machine.
```

Extract the archive under `dist/windows/` into a stable installation folder. To install the current user's Explorer folder and folder-background menus:

```powershell
./Windows/Install-ContextMenu.ps1 -Executable 'C:\Apps\GitNebula\GitNebula.exe'
```

Choose **Open in GitNebula** from Explorer. On Windows 11 this entry may appear under **Show more options**. Administrator privileges are not required. The app can also open a repository with `GitNebula.exe --open "C:\path\to\repo"`.

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
