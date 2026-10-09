#!/bin/bash
# Prepare desktop dependencies, then install the user-local app and menus.
set -euo pipefail
cd "$(dirname "$0")"
launch=true
installer_arguments=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open) launch=false ;;
    *) installer_arguments+=("$1") ;;
  esac
  shift
done
if [ "$(uname -s)" != Linux ]; then
  echo 'Run Linux/install.sh on Linux.' >&2
  exit 1
fi
for argument in ${installer_arguments[@]+"${installer_arguments[@]}"}; do
  case "$argument" in
    --uninstall|--help|-h) exec /usr/bin/python3 install.py "${installer_arguments[@]}" ;;
  esac
done
if ! /usr/bin/python3 -c 'import gi, cairo; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' >/dev/null 2>&1 ||
   ! command -v git >/dev/null 2>&1 || ! command -v secret-tool >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo 'Install Python 3, GTK 4, PyGObject, Python Cairo, Git and libsecret-tools with your distribution package manager, then retry.' >&2
    exit 1
  fi
  package_manager=(apt-get)
  if [ "$(id -u)" -ne 0 ]; then package_manager=(sudo apt-get); fi
  "${package_manager[@]}" update
  "${package_manager[@]}" install -y git python3 python3-gi python3-cairo python3-gi-cairo gir1.2-gtk-4.0 libsecret-tools python3-nautilus
fi
# On GNOME, the menu needs the Nautilus Python provider even if GTK is ready.
if command -v nautilus >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
  gitnebula_nautilus_status=$(dpkg-query -W -f='${Status}' python3-nautilus 2>/dev/null || true)
  if [ "$gitnebula_nautilus_status" != 'install ok installed' ]; then
    package_manager=(apt-get)
    if [ "$(id -u)" -ne 0 ]; then package_manager=(sudo apt-get); fi
    "${package_manager[@]}" update
    "${package_manager[@]}" install -y python3-nautilus
  fi
fi
if [ "${#installer_arguments[@]}" -gt 0 ]; then
  /usr/bin/python3 install.py "${installer_arguments[@]}"
else
  /usr/bin/python3 install.py
fi
if "$launch" && [ "${#installer_arguments[@]}" -eq 0 ]; then "$HOME/.local/bin/gitnebula" & fi
