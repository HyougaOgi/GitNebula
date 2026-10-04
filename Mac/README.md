# GitNebula for macOS

Native SwiftUI application and Finder Sync extension. Requires macOS 13 or newer and Xcode Command Line Tools (`xcode-select --install`). Git is invoked through `/usr/bin/git`.

From the repository root:

```sh
swift run --package-path Mac
swift test --package-path Mac
bash Mac/install.sh
```

`install.sh` builds the app and Finder extension, installs `~/Applications/GitNebula.app`, registers it with LaunchServices and PlugInKit, requests that the extension be enabled, and opens the app. Existing versions are retained under `~/Applications/.gitnebula-backups/`. To reinstall an already built package, run `bash Mac/install.sh --no-build`; add `--no-open` to leave the app closed. An alternate installation directory can be passed with `--destination`.

For packaging only, run `bash Mac/package.sh --unsigned`. The package is written to `dist/mac/GitNebula-unsigned.zip`. Development packages use an ad-hoc signature, not a trusted Developer ID signature.

## Opening a repository

Type or paste an absolute path, `~/Projects/my-repo`, or a local `file://` URL into **リポジトリのパス**, then press Enter or **開く**. **参照…** opens the native folder picker. Quoted paths containing spaces are accepted. The path remains editable after a failed attempt. The app activates as a regular macOS application even when started with `swift run`.

To create a repository in an existing folder, choose **リポジトリを作成（Init）**. The new Stash, Tag, remote/identity settings, history editing, Blame, patch, Worktree and Submodule tools are described in the [feature matrix](../shared/FEATURES.md).

## Finder integration

The packaged app contains `GitNebulaFinder.appex`. The launch screen shows its enabled state; **Finder 拡張の設定を開く** opens macOS extension settings. If the menu does not appear after installation, enable **GitNebula Finder** there and click **状態を更新** in the app. macOS may require the user's confirmation to enable an extension. Right-click a repository folder, a file, or the folder background, then choose the icon-marked **GitNebula** submenu. It provides the usual Git actions and the new Stash, Tag, remote and history tools. Each item opens its own focused dialog. Files and folder descendants are preselected for Commit; several selected files must belong to the same repository. The extension covers `/Users`, `/Volumes`, `/private/tmp`, and `/opt`.

Finder opens the requested operation through `gitnebula://commit?path=…` (and the corresponding action name). Paths are URL-encoded; multiple selections use repeated `path` parameters. A new Finder action preserves any existing dialog and its draft. For command-line use:

```sh
open -na GitNebula --args --action commit --path /path/to/repository
open -na GitNebula --args --action diff --path "/path/to/repository/file.txt"
open -na GitNebula --args --action clone --path /path/to/parent
```

After upgrading, quit the previous app, run the installer again, and toggle the Finder extension off and on if Finder still shows the old menu. A GitNebula toolbar button is also available from Finder's toolbar customization.

Disable the extension in System Settings before removing the application. `swift run` runs the development executable and does not install the Finder extension.

## Signed release

Install your Developer ID Application certificate and private key in the macOS keychain. Store App Store Connect/notarization credentials using `xcrun notarytool store-credentials` and use its profile name. Do not add certificates or passwords to this repository.

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-keychain-profile'
bash Mac/package.sh --signed
```

The script signs the extension and application, verifies their signatures, submits the app for notarization, staples and validates the ticket, and creates a ZIP with a SHA-256 checksum. Signing and notarization need your own credentials and network access to Apple's services. Build on each intended CPU architecture; the script packages the host architecture.
