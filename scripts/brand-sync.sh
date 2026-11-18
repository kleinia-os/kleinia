#!/bin/bash
# Vendor the Kleinia brand kit into the BlueBuild files tree.
# Single source of truth: the kleinia-brand checkout (default: sibling
# checkout ../kleinia-brand; override with KLEINIA_BRAND_KIT).
# Regenerates: wallpapers, icons, fonts, fastfetch, plymouth theme, grub theme,
# gschema override, fontconfig, /etc/default/grub, plymouthd.conf, os-release (0.1 Aloe).
set -euo pipefail
KIT="${KLEINIA_BRAND_KIT:-$(cd "$(dirname "$0")/.." && pwd)/../kleinia-brand/brand-kit/kleinia-brand-kit}"
FILES="${KLEINIA_FILES_TREE:-$(cd "$(dirname "$0")/.." && pwd)/files}"
MILESTONE=0.1
DISPLAY_CN="Aloe"
CODENAME=aloe
BUILD_NUM="${BUILD_NUM:-0}"
IMGVER="44.$(date +%Y%m%d).$BUILD_NUM"

rm -rf "$FILES/usr"
mkdir -p "$FILES/usr/share/backgrounds/kleinia" \
         "$FILES/usr/share/gnome-background-properties" \
         "$FILES/usr/share/fonts/kleinia" \
         "$FILES/usr/share/fastfetch/logos" \
         "$FILES/usr/share/plymouth/themes/kleinia" \
         "$FILES/usr/share/pixmaps" \
         "$FILES/usr/share/glib-2.0/schemas" "$FILES/usr/lib" \
         "$FILES/usr/share/grub/themes/kleinia" \
         "$FILES/etc/fonts/conf.d" "$FILES/etc/xdg/fastfetch" "$FILES/etc/plymouth" "$FILES/etc/default"

# --- wallpapers + GNOME metadata ---
cp -a "$KIT"/wallpapers/*-3840x*.png "$FILES/usr/share/backgrounds/kleinia/"
cp -a "$KIT"/wallpapers/gnome/kleinia-backgrounds.xml "$FILES/usr/share/gnome-background-properties/"

# --- icon: kleinia (hicolor tree merges into the system one) ---
cp -a "$KIT"/icon/hicolor/. "$FILES/usr/share/icons/hicolor/" 2>/dev/null || {
  mkdir -p "$FILES/usr/share/icons/hicolor"; cp -a "$KIT"/icon/hicolor/. "$FILES/usr/share/icons/hicolor/"; }

# --- fonts (OFL) ---
cp -a "$KIT"/typography/fonts/*/*.ttf "$FILES/usr/share/fonts/kleinia/"
cp -a "$KIT"/typography/fonts/*/OFL.txt "$FILES/usr/share/fonts/kleinia/" 2>/dev/null || true

# --- fastfetch ---
cp -a "$KIT"/system/fastfetch/kleinia.txt "$FILES/usr/share/fastfetch/logos/"
cp -a "$KIT"/system/fastfetch/config.jsonc "$FILES/etc/xdg/fastfetch/"

# --- plymouth theme assets (two-step/spinner derivative; center-high white mark) ---
cp -a "$KIT"/system/plymouth/kleinia-logo.png "$FILES/usr/share/plymouth/themes/kleinia/watermark.png"
cat > "$FILES/usr/share/plymouth/themes/kleinia/kleinia.plymouth" <<EOF
[Plymouth Theme]
Name=Kleinia
Description=Kleinia boot splash — night black, white mark, quiet spinner
ModuleName=two-step

[two-step]
Font=JetBrains Mono 12
TitleFont=Inter Tight 30
ImageDir=/usr/share/plymouth/themes/kleinia
DialogHorizontalAlignment=.5
DialogVerticalAlignment=.382
TitleHorizontalAlignment=.5
TitleVerticalAlignment=.382
HorizontalAlignment=.5
VerticalAlignment=.7
WatermarkHorizontalAlignment=.5
WatermarkVerticalAlignment=.42
Transition=none
TransitionDuration=0.0
BackgroundStartColor=0x030821
BackgroundEndColor=0x030821
ProgressBarBackgroundColor=0x5B6075
ProgressBarForegroundColor=0x3D63FF
MessageBelowAnimation=true

[boot-up]
UseEndAnimation=false

[shutdown]
UseEndAnimation=false

[reboot]
UseEndAnimation=false

[updates]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Installing Updates...
SubTitle=Do not turn off your computer

[system-upgrade]
SuppressMessages=true
ProgressBarShowPercentComplete=true
UseProgressBar=true
Title=Upgrading System...
SubTitle=Do not turn off your computer
EOF
cat > "$FILES/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=kleinia
ShowDelay=3
EOF

# --- grub theme + defaults ---
cp -a "$KIT"/system/boot-splash-1920x1080.png "$FILES/usr/share/grub/themes/kleinia/background.png"
cat > "$FILES/usr/share/grub/themes/kleinia/theme.txt" <<'EOF'
# Kleinia GRUB theme — night black + white mark, klein-light selection
title-text: ""
title-color: "#F5F3EE"
desktop-image: "background.png"
terminal-left: "8%"
terminal-top: "70%"
terminal-width: "84%"
terminal-height: "25%"

+ boot_menu {
  left = 12%
  top = 58%
  width = 76%
  height = 30%
  item_font = "Inter Tight 18"
  item_color = "#D9E2FF"
  selected_item_color = "#3D63FF"
  selected_item_pixmap_style = "none"
  item_height = 34
  item_spacing = 10
  icon_width = 0
  icon_height = 0
  item_icon_space = 0
}
EOF
cat > "$FILES/etc/default/grub" <<'EOF'
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="Kleinia"
GRUB_THEME=/usr/share/grub/themes/kleinia/theme.txt
GRUB_BACKGROUND=/usr/share/grub/themes/kleinia/background.png
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_SUBMENU=y
EOF

# --- GDM / system logos (fedora-logo reference chain) ---
cp -a "$KIT"/logo/png/kleinia-mark-white-128.png "$FILES/usr/share/pixmaps/system-logo-white.png"
cp -a "$KIT"/logo/png/kleinia-mark-blue-512.png  "$FILES/usr/share/pixmaps/fedora-logo.png"
cp -a "$KIT"/logo/png/kleinia-mark-blue-128.png  "$FILES/usr/share/pixmaps/fedora-logo-icon.png"

# --- GNOME defaults (gschema override; compiled at image build) ---
cat > "$FILES/usr/share/glib-2.0/schemas/99_kleinia.gschema.override" <<'EOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/kleinia/kleinia-ripple-light-3840x2160.png'
picture-uri-dark='file:///usr/share/backgrounds/kleinia/kleinia-ripple-3840x2160.png'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/kleinia/kleinia-ripple-3840x2160.png'

[org.gnome.desktop.interface]
accent-color='blue'
font-name='Inter Tight 11'
document-font-name='Inter Tight 11'
monospace-font-name='JetBrains Mono 10'
color-scheme='prefer-dark'

[org.gnome.desktop.wm.preferences]
titlebar-font='Inter Tight Bold 11'
EOF

# --- fontconfig: brand fonts take precedence ---
cat > "$FILES/etc/fonts/conf.d/65-kleinia.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias binding="same">
    <family>sans-serif</family>
    <prefer><family>Inter Tight</family></prefer>
  </alias>
  <alias binding="same">
    <family>monospace</family>
    <prefer><family>JetBrains Mono</family></prefer>
  </alias>
</fontconfig>
EOF

# --- os-release (ID=fedora stays: osbuild distrodefs + dnf $releasever depend on it;
#     derivative identity travels via IMAGE_ID/IMAGE_VERSION per bootc convention) ---
cat > "$FILES/usr/lib/os-release" <<EOF
NAME="Kleinia"
PRETTY_NAME="Kleinia $MILESTONE ($DISPLAY_CN)"
ID=fedora
ID_LIKE=fedora
IMAGE_ID=kleinia
IMAGE_VERSION=$IMGVER
VERSION_ID=44
VERSION="$MILESTONE ($DISPLAY_CN)"
VERSION_CODENAME=$CODENAME
LOGO=kleinia
ANSI_COLOR="38;2;61;99;255"
HOME_URL="https://github.com/kleinia"
DOCUMENTATION_URL="https://github.com/kleinia"
BUG_REPORT_URL="https://github.com/kleinia/issues"
SUPPORT_URL="https://github.com/kleinia"
EOF

echo "== vendored: $(find $FILES/usr -type f | wc -l) files, $(du -sh $FILES/usr | cut -f1), IMAGE_VERSION=$IMGVER =="

# --- firstboot fixups: SELinux restorecon of late-created state + default hostname
#     (bootc/ostree drops image /etc/hostname at install; labels of files created
#      post-install by tooling need restoring in real boot context)
mkdir -p "$FILES/usr/libexec/kleinia" "$FILES/etc/systemd/system"
cat > "$FILES/usr/libexec/kleinia/firstboot.sh" <<'EOF'
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
EOF
chmod 0755 "$FILES/usr/libexec/kleinia/firstboot.sh"
cat > "$FILES/etc/systemd/system/kleinia-firstboot.service" <<'EOF'
[Unit]
Description=Kleinia first-boot fixups (SELinux labels, default hostname)
ConditionPathExists=!/var/lib/kleinia/firstboot-done
After=local-fs.target systemd-sysusers.service
Before=dbus.socket dbus-broker.service display-manager.service accounts-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/kleinia/firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
echo "== firstboot unit appended =="

# --- GDM seats race fix: ensure logind (which writes /run/systemd/seats) has
#     started before gdm evaluates its ConditionPathExists=/run/systemd/seats
mkdir -p "$FILES/etc/systemd/system/gdm.service.d"
cat > "$FILES/etc/systemd/system/gdm.service.d/20-kleinia-seats-order.conf" <<'EOF'
[Unit]
After=systemd-logind.service
Wants=systemd-logind.service
EOF
echo "== gdm seats-order drop-in appended =="

# --- Live-ISO support: liveuser autologin, guided installer, CI hook, lab registry
mkdir -p "$FILES/usr/libexec/kleinia" \
         "$FILES/usr/share/applications" \
         "$FILES/etc/systemd/system" \
         "$FILES/etc/containers/registries.conf.d" \
         "$FILES/etc/sudoers.d"

cat > "$FILES/usr/libexec/kleinia/live-setup.sh" <<'EOF'
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

EOF
chmod 0755 "$FILES/usr/libexec/kleinia/live-setup.sh"

cat > "$FILES/etc/systemd/system/kleinia-live-setup.service" <<'EOF'
[Unit]
Description=Kleinia live session setup (liveuser autologin)
After=systemd-user-sessions.service
Before=display-manager.service getty@tty1.service\nRequires=systemd-user-sessions.service

[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/libexec/kleinia/live-setup.sh
ExecStartPost=/usr/bin/systemctl try-restart serial-getty@ttyS0.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$FILES/usr/libexec/kleinia/live-install.sh" <<'EOF'
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
EOF
chmod 0755 "$FILES/usr/libexec/kleinia/live-install.sh"

# --- ReadyMade installer desktop entries: a hidden system copy plus the
# --- live-only visible copy under /var/lib/kleinia/applications (surfaced
# --- via XDG_DATA_DIRS by live-setup.sh; the installed system shows nothing) ---
cat > "$FILES/usr/share/applications/readymade.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Kleinia
Comment=Install Kleinia 0.1 (Aloe) to your disk
Exec=readymade
Icon=kleinia-app-icon
Terminal=false
Categories=System;
StartupNotify=true
StartupWMClass=com.fyralabs.Readymade
NoDisplay=true
EOF
mkdir -p "$FILES/var/lib/kleinia/applications"
cat > "$FILES/var/lib/kleinia/applications/readymade.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Kleinia
Comment=Install Kleinia 0.1 (Aloe) to your disk
Exec=readymade
Icon=kleinia-app-icon
Terminal=false
Categories=System;
StartupNotify=true
StartupWMClass=com.fyralabs.Readymade
EOF
mkdir -p "$FILES/usr/lib/kleinia/live-skel/Desktop" "$FILES/usr/lib/kleinia/live-skel/.config/autostart"
cat > "$FILES/usr/lib/kleinia/live-skel/Desktop/readymade.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Kleinia
Comment=Install Kleinia 0.1 (Aloe)
Exec=readymade
Icon=kleinia-app-icon
Terminal=false
Categories=System;
StartupNotify=true
EOF
cat > "$FILES/usr/lib/kleinia/live-skel/.config/autostart/readymade.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Kleinia
Exec=readymade
Icon=kleinia-app-icon
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

cat > "$FILES/etc/systemd/system/kleinia-autosetup.service" <<'EOF'
[Unit]
Description=Kleinia CI auto-install (only when kleinia.autosetup karg present)
ConditionKernelCommandLine=kleinia.autosetup
After=kleinia-live-setup.service multi-user.target

[Service]
Type=oneshot
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/libexec/kleinia/live-install.sh --auto /dev/vda
ExecStartPost=/usr/bin/systemctl poweroff

[Install]
WantedBy=multi-user.target
EOF

# NOTE: the internal-registry mirror override (containers/registries.conf.d)
# is lab-machine deployment config, not part of the public tree — apply it
# from the lab's own infra config when needed.

# Ensure graphical.target is default
rm -f "$FILES/etc/systemd/system/default.target"
ln -sf /usr/lib/systemd/system/graphical.target "$FILES/etc/systemd/system/default.target"

echo "== live-iso suite appended =="

# --- generic-iso boot configuration (consumed by image-builder from the payload)
# v1: live session boots with SELinux permissive — container-derived squashfs trees
# carry no SELinux labels; the INSTALLED system stays enforcing (bootc relabels).
mkdir -p "$FILES/usr/lib/image-builder/bootc"
cat > "$FILES/usr/lib/image-builder/bootc/iso.yaml" <<'EOF'
label: "Kleinia-0.1-Aloe"
grub2:
  entries:
    - name: "Start Kleinia 0.1 (Aloe)"
      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=Kleinia-0.1-Aloe rd.live.image console=tty0 enforcing=0"
      initrd: "/images/pxeboot/initrd.img"
    - name: "Test media and start Kleinia"
      linux: "/images/pxeboot/vmlinuz root=live:CDLABEL=Kleinia-0.1-Aloe rd.live.image rd.live.check console=tty0 enforcing=0"
      initrd: "/images/pxeboot/initrd.img"
EOF
echo "== iso.yaml appended =="

# --- Desktop polish: gschema overrides for dock + no fedora watermark ---

# Re-write the gschema override to include dock + background-logo fixes
cat > "$FILES/usr/share/glib-2.0/schemas/99_kleinia.gschema.override" <<'EOF'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/kleinia/kleinia-ripple-light-3840x2160.png'
picture-uri-dark='file:///usr/share/backgrounds/kleinia/kleinia-ripple-3840x2160.png'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/kleinia/kleinia-ripple-3840x2160.png'

[org.gnome.desktop.interface]
accent-color='blue'
font-name='Inter Tight 11'
document-font-name='Inter Tight 11'
monospace-font-name='JetBrains Mono 10'
color-scheme='prefer-dark'

[org.gnome.desktop.wm.preferences]
titlebar-font='Inter Tight Bold 11'

[org.gnome.shell]
disabled-extensions=['background-logo@fedorahosted.org']
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'ding@rastersoft.com']

[org.gnome.shell.extensions.dash-to-dock]
dock-fixed=true
dock-position='BOTTOM'
intellihide=false
dash-max-icon-size=48
extend-height=false
height-fraction=0.9

[org.gnome.shell.extensions.ding]
show-home=false
show-volumes=false
show-network-volumes=false
start-corner='top-left'
EOF

echo "== desktop polish done =="

# --- Polkit rule: allow liveuser to run pkexec without auth (live session only) ---
mkdir -p "$FILES/etc/polkit-1/rules.d"
cat > "$FILES/etc/polkit-1/rules.d/50-kleinia-live.rules" <<'EOF'
polkit.addRule(function(action, subject) {
    if (subject.user == "liveuser") {
        return polkit.Result.YES;
    }
});
EOF
echo "== polkit rule done =="
