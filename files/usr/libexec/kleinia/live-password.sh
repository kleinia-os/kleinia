#!/bin/bash
set -u
# Early (sysinit stage, pre-GDM): passwords + home directory bootstrap.
# MUST NOT call sudo/gsettings — dbus is not up yet here and those calls
# block ~40s on dbus timeouts (measured on live boot 2026-10-24).
# Dock/extension settings are applied system-wide via /etc/dconf/db/local.d
# instead (compiled at image build time).

# Home bootstrap: sysusers.d creates the liveuser entry but NOT the home
# directory, and a bootc live rootfs has no /home/liveuser at all. Without
# this, the GNOME session core-dumps (ibus, gnome-terminal, the installer...).
if [ ! -d /home/liveuser ]; then
    mkdir -p /home/liveuser
    cp -a /etc/skel/. /home/liveuser/ 2>/dev/null || true
    chown liveuser:liveuser /home 2>/dev/null || true
    chown -R liveuser:liveuser /home/liveuser
    chmod 700 /home/liveuser
fi

# liveuser logs in with just Enter; root gets a known password for debugging
passwd -d liveuser 2>/dev/null || usermod -p "" liveuser 2>/dev/null || true
echo "root:root" | chpasswd 2>/dev/null || true
exit 0
