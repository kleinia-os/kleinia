#!/bin/bash
# Kleinia first-boot fixups. Runs once, before the display manager.
set -u
restorecon -R /etc /var/home /var/lib/AccountsService /var/lib/gdm /var/lib/flatpak 2>/dev/null || true
if [ ! -s /etc/hostname ]; then
    echo kleinia > /etc/hostname
    hostname kleinia 2>/dev/null || true
fi
mkdir -p /var/lib/kleinia
touch /var/lib/kleinia/firstboot-done
exit 0
