# GitNebula — Windows

WPF と .NET 8 による Windows ネイティブ実装です。.NET 8 SDK と Git for Windows（PATH に追加）をインストールしてください。

```powershell
dotnet build Windows/GitNebula.csproj
dotnet run --project Windows/GitNebula.csproj
```

実行ファイルの生成:

```powershell
dotnet publish Windows/GitNebula.csproj -c Release -r win-x64 --self-contained true
```

Windows 上で実行してください。インストーラー、署名、Explorer の右クリック拡張は未実装です。
Linux のクラウド環境では WPF を実行できないため、Windows で検証してください。
