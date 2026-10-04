# GitNebula for macOS

Native SwiftUI application and Finder Sync extension. Requires macOS 13 or newer and Xcode Command Line Tools (`xcode-select --install`). Git is invoked through `/usr/bin/git`.

From the repository root:

```sh
swift run --package-path Mac
swift test --package-path Mac
bash Mac/package.sh --unsigned
```

The package is written to `dist/mac/GitNebula-unsigned.zip`. Extract and move `GitNebula.app` to `/Applications` or `~/Applications`. Development packages use an ad-hoc signature, not a trusted Developer ID signature.

## Finder integration

The packaged app contains `GitNebulaFinder.appex`. After installing and opening the app, enable **GitNebula Finder** in System Settings → Login Items & Extensions → Finder Extensions (the section name varies by macOS version). Right-click a repository folder, a file, or the folder background, then choose **GitNebula → 変更をコミット / 差分を確認 / 履歴を表示 / Pull / Push / Fetch / ブランチを切り替え / Clone**. Each item opens its own focused dialog. Files and folder descendants are preselected for Commit; several selected files must belong to the same repository. The extension covers folders under `/Users` and `/Volumes`.

Finder opens the requested operation through `gitnebula://commit?path=…` (and the corresponding action name). Paths are URL-encoded; multiple selections use repeated `path` parameters. A new Finder action preserves any existing dialog and its draft. For command-line use:

```sh
open -na GitNebula --args --action commit --path /path/to/repository
open -na GitNebula --args --action diff --path "/path/to/repository/file.txt"
open -na GitNebula --args --action clone --path /path/to/parent
```

After upgrading, replace the application bundle and toggle the Finder extension off and on to reload the menu. The extension covers `/Users` and `/Volumes`.

Disable the extension in System Settings before removing the application. `swift run` runs the development executable and does not install the Finder extension.

## Signed release

Install your Developer ID Application certificate and private key in the macOS keychain. Store App Store Connect/notarization credentials using `xcrun notarytool store-credentials` and use its profile name. Do not add certificates or passwords to this repository.

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-keychain-profile'
bash Mac/package.sh --signed
```

The script signs the extension and application, verifies their signatures, submits the app for notarization, staples and validates the ticket, and creates a ZIP with a SHA-256 checksum. Signing and notarization need your own credentials and network access to Apple's services. Build on each intended CPU architecture; the script packages the host architecture.
