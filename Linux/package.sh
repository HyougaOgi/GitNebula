#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
release_mode="${1:---unsigned}"
case "$release_mode" in --signed) : "${GPG_KEY_ID:?Set a signing key already installed in your GPG keyring}" ;; --unsigned) ;; *) echo 'Usage: package.sh [--unsigned|--signed]' >&2; exit 1 ;; esac
mkdir -p dist/linux
archive="dist/linux/GitNebula-linux.tar.gz"
rm -f "$archive.asc"
tar -czf "$archive" LICENSE README.md Linux/*.py Linux/en.json Linux/gitnebula.png Linux/README.md
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$archive" > "$archive.sha256"; else shasum -a 256 "$archive" > "$archive.sha256"; fi
if [ "$release_mode" = --signed ]; then
  gpg --batch --yes --local-user "$GPG_KEY_ID" --armor --detach-sign "$archive"
  gpg --verify "$archive.asc" "$archive"
fi
echo "Created $archive ($release_mode)"
