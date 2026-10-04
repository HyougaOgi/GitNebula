#!/bin/bash
# Install a packaged application and register its Finder extension for this user.
set -euo pipefail
cd "$(dirname "$0")"
build=true
launch=true
destination="$HOME/Applications"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-build) build=false ;;
    --no-open) launch=false ;;
    --destination) shift; destination="${1:?Specify an installation directory}" ;;
    *) echo 'Usage: bash Mac/install.sh [--no-build] [--no-open] [--destination directory]' >&2; exit 1 ;;
  esac
  shift
done
if "$build"; then bash package.sh --unsigned; fi
archive="$(pwd)/../dist/mac/GitNebula-unsigned.zip"
test -f "$archive" || { echo 'Build the unsigned package first.' >&2; exit 1; }
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto -x -k "$archive" "$stage"
codesign --verify --deep --strict "$stage/GitNebula.app"
mkdir -p "$destination"
app="$destination/GitNebula.app"
if [ -e "$app" ]; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
  test "$identifier" = dev.gitnebula.desktop || { echo "Refusing to replace a different application: $app" >&2; exit 1; }
  backup="$destination/.gitnebula-backups/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$backup"
  mv "$app" "$backup/GitNebula.app"
  echo "Previous version saved to $backup/GitNebula.app"
fi
ditto "$stage/GitNebula.app" "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
pluginkit -a "$app/Contents/PlugIns/GitNebulaFinder.appex"
pluginkit -e use -i dev.gitnebula.desktop.finder
echo "Installed $app"
pluginkit -m -v -i dev.gitnebula.desktop.finder
echo 'If the Finder menu is hidden, open GitNebula → Finder 拡張の設定を開く and enable GitNebula Finder.'
if "$launch"; then open "$app"; fi
