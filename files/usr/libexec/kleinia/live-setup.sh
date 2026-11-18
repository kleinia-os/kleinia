#!/bin/bash
# Runs once at live-boot: liveuser bootstrap (user, home, empty password),
# root password, GDM autologin, suppress initial-setup, surface the embedded
# payload store for offline bootc install.
# NOTE: no sudo/gsettings calls here — they block on dbus timeouts in early
# boot; desktop defaults are shipped via /etc/dconf/db/local.d instead.
set -u

# Live environment only: the installed system must not get a liveuser,
# autologin or the installer entry. (The old unconditional mode broke the
# installed system: liveuser re-created, GDM autologin hijacked.)
if ! grep -q "rd\.live\.image" /proc/cmdline 2>/dev/null && [ ! -d /run/initramfs/live ]; then
    exit 0
fi

# liveuser is pre-created by systemd-sysusers (no home); make sure the
# user exists even if sysusers was skipped, then bootstrap the home dir.
getent group liveuser >/dev/null || groupadd -r liveuser
id liveuser >/dev/null 2>&1 || useradd -c "Kleinia Live" -g liveuser -G wheel -s /bin/bash liveuser
if [ ! -d /home/liveuser ]; then
    mkdir -p /home/liveuser
    cp -a /etc/skel/. /home/liveuser/ 2>/dev/null || true
fi
chown liveuser:liveuser /home 2>/dev/null || true
cp -a /usr/lib/kleinia/live-skel/. /home/liveuser/ 2>/dev/null || true
chown -R liveuser:liveuser /home/liveuser
chmod 700 /home/liveuser

passwd -d liveuser 2>/dev/null || usermod -p "" liveuser 2>/dev/null || true
echo "root:root" | chpasswd 2>/dev/null || true
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-kleinia-live
chmod 440 /etc/sudoers.d/90-kleinia-live

mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf <<'GDM'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=liveuser
GDM
touch /var/lib/gnome-initial-setup-done

# surface the live-only installer entry: /var/lib/kleinia takes precedence in
# XDG_DATA_DIRS, overriding the NoDisplay system copy in /usr/share/applications
systemctl set-environment "XDG_DATA_DIRS=/var/lib/kleinia:/usr/local/share:/usr/share"

# surface the embedded payload store: the ISO embeds the kleinia image inside the
# squashfs (/var/lib/containers/storage, populated by image-builder's payload step),
# but the live overlay/tmpfs hides it from podman. Remount it as a writable overlay
# so `podman image exists` finds it and bootc can install fully offline.
STORE=/var/lib/containers/storage
LOWER=$(awk '$2=="/" && $3=="overlay"{for(i=4;i<=NF;i++) if($i ~ /^lowerdir=/){split($i,a,"="); split(a[2],b,":"); print b[1]}}' /proc/mounts)
if [ -n "$LOWER" ] && [ -d "$LOWER$STORE/overlay-images" ]; then
    mkdir -p "$STORE" /run/containers-upper /run/containers-work
    for try in 1 2 3; do
        mount -t overlay overlay -o lowerdir="$LOWER$STORE",upperdir=/run/containers-upper,workdir=/run/containers-work "$STORE" 2>/dev/null && break
        sleep 2
    done
    if [ -d "$STORE/overlay-images" ]; then
        echo "[kleinia-live] embedded payload store surfaced (try $try)"
    else
        echo "[kleinia-live] WARNING: embedded store remount failed"
    fi
fi

# serial console autologin for CI/debug rigs
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 ttyS0 $TERM
GETTY
exit 0
