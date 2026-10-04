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

The packaged app contains `GitNebulaFinder.appex`. After installing and opening the app, enable **GitNebula Finder** in System Settings → Login Items & Extensions → Finder Extensions (the section name varies by macOS version). Select a repository folder in Finder and choose **Open in GitNebula**. The extension covers folders under `/Users` and `/Volumes`.

Finder opens the app through `gitnebula://open?path=…`. For command-line use:

```sh
open -a GitNebula --args --open /path/to/repository
```

Disable the extension in System Settings before removing the application. `swift run` runs the development executable and does not install the Finder extension.

## Signed release

Install your Developer ID Application certificate and private key in the macOS keychain. Store App Store Connect/notarization credentials using `xcrun notarytool store-credentials` and use its profile name. Do not add certificates or passwords to this repository.

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-keychain-profile'
bash Mac/package.sh --signed
```

The script signs the extension and application, verifies their signatures, submits the app for notarization, staples and validates the ticket, and creates a ZIP with a SHA-256 checksum. Signing and notarization need your own credentials and network access to Apple's services. Build on each intended CPU architecture; the script packages the host architecture.
