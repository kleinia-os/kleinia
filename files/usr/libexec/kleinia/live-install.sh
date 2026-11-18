#!/bin/bash
# Kleinia guided installer — installs the running (live) system to a target disk
# via the native bootc path. Interactive by default; --auto DISK for CI.
set -euo pipefail
REG=ghcr.io/kleinia-os/kleinia:testing
EMBEDDED="containers-storage:$REG"

banner() { printf '\n\033[1;38;2;61;99;255m== %s ==\033[0m\n' "$1"; }

pick_source() {
    if podman image exists "$REG" 2>/dev/null; then
        SRC="--source-imgref $EMBEDDED"
    else
        echo "FATAL: embedded payload store not visible and RAM cannot hold a registry pull."
        echo "       Reboot the live media and retry; if this persists report the bug."
        exit 1
    fi
}

if [ "${1:-}" = "--auto" ]; then
    DISK="${2:?usage: live-install.sh --auto /dev/vdX}"
    pick_source
    bootc install to-disk --filesystem ext4 $SRC "$DISK"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer needs root; run it with sudo."; exit 1
fi

banner "Kleinia 0.1 (Aloe) installer"
echo "This will install Kleinia to a disk of your choice. ALL DATA on that disk will be erased."
echo
lsblk -ndo NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{printf "  /dev/%-8s %8s  %s\n",$1,$2,substr($0,index($0,$4))}'
echo
read -rp "Target disk (e.g. /dev/vda): " DISK
[ -b "$DISK" ] || { echo "Not a block device: $DISK"; exit 1; }
read -rp "ERASE $DISK and install Kleinia? Type YES to continue: " OK
[ "$OK" = "YES" ] || { echo "Aborted."; exit 1; }
pick_source
banner "Installing (embedded payload, no network needed)"
bootc install to-disk --filesystem ext4 $SRC "$DISK"
banner "Done"
echo "Remove the installation medium and reboot:  systemctl reboot"
