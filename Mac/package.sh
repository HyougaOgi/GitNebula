#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test "$(uname -s)" = Darwin || { echo 'Build on macOS.' >&2; exit 1; }
release_mode="${1:---unsigned}"
if [[ "$release_mode" != --unsigned && "$release_mode" != --signed ]]; then echo 'Usage: package.sh [--unsigned|--signed]' >&2; exit 1; fi
if [[ "$release_mode" == --signed ]]; then
  : "${MACOS_SIGNING_IDENTITY:?Set a Developer ID Application identity in the keychain}"
  : "${NOTARY_PROFILE:?Set a notarytool keychain profile name}"
fi
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
output="$(pwd)/../dist/mac"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/GitNebula.app"
extension="$bundle/Contents/PlugIns/GitNebulaFinder.appex"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$extension/Contents/MacOS" "$output"
xcrun swift make-icon.swift "$stage/GitNebula.iconset"
iconutil -c icns "$stage/GitNebula.iconset" -o "$bundle/Contents/Resources/GitNebula.icns"
cp "$binary_dir/GitNebula" "$bundle/Contents/MacOS/"
cp Info.plist "$bundle/Contents/"
cp FinderExtension/Info.plist "$extension/Contents/"
xcrun swiftc -parse-as-library -emit-executable -module-name GitNebulaFinder \
  -target "$(uname -m)-apple-macosx13.0" -framework Cocoa -framework FinderSync \
  -Xlinker -e -Xlinker _NSExtensionMain \
  FinderExtension/FinderSync.swift Sources/GitNebula/LaunchRequest.swift -o "$extension/Contents/MacOS/GitNebulaFinder"
if [[ "$release_mode" == --signed ]]; then
  codesign --force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" --entitlements FinderExtension/entitlements.plist "$extension"
  codesign --force --options runtime --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$bundle"
  codesign --verify --deep --strict "$bundle"
  ditto -c -k --keepParent "$bundle" "$stage/notarize.zip"
  xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
else
  codesign --force --sign - --entitlements FinderExtension/entitlements.plist "$extension"
  codesign --force --sign - "$bundle"
fi
ditto -c -k --keepParent "$bundle" "$output/GitNebula-${release_mode#--}.zip"
shasum -a 256 "$output/GitNebula-${release_mode#--}.zip" > "$output/GitNebula-${release_mode#--}.zip.sha256"
echo "Created $output/GitNebula-${release_mode#--}.zip"
