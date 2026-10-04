#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
release_mode="${1:---unsigned}"
case "$release_mode" in --signed) : "${GPG_KEY_ID:?Set a signing key already installed in your GPG keyring}" ;; --unsigned) ;; *) echo 'Usage: package.sh [--unsigned|--signed]' >&2; exit 1 ;; esac
mkdir -p dist/linux
archive="dist/linux/GitNebula-linux.tar.gz"
rm -f "$archive.asc"
tar -czf "$archive" LICENSE README.md Linux/main.py Linux/git_backend.py Linux/install.py Linux/README.md
sha256sum "$archive" > "$archive.sha256"
if [ "$release_mode" = --signed ]; then
  gpg --batch --yes --local-user "$GPG_KEY_ID" --armor --detach-sign "$archive"
  gpg --verify "$archive.asc" "$archive"
fi
echo "Created $archive ($release_mode)"
