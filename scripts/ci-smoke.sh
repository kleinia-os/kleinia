#!/bin/bash
# Boot-smoke: extract kernel/initrd, boot the ISO in QEMU, assert the serial
# login marker. v4 (KLN-64): runs NATIVELY on the build runner (root,
# /dev/kvm straight from the VM); qemu-system-x86-core has no virtio-vga,
# and the boot is headless anyway -> -vga none, serial console is the pass
# channel ("kleinia login:" seen within the timeout).
set -euo pipefail
LOG=/var/tmp/kleinia-ci-smoke.log     # /var/tmp/kleinia-ci -> $KLN_WORK tmpfs
exec > >(tee -a "$LOG") 2>&1
# newest ISO: the release dir accumulates one ISO per run until reboot
ISO=$(ls -t "${ISO_DIR:-/srv/kleinia-ci/out}"/*.iso | head -1)
W=/var/tmp/smoke-$GITHUB_RUN_ID; rm -rf "$W"; mkdir -p "$W"; cd "$W"
xorriso -osirrox on -indev "$ISO" -extract /images/pxeboot/vmlinuz vmlinuz -extract /images/pxeboot/initrd.img initrd.img >/dev/null
truncate -s 10G disk.raw
qemu-system-x86_64 -machine q35 -accel kvm -cpu host -smp 2 -m 3G \
  -kernel vmlinuz -initrd initrd.img \
  -append "root=live:CDLABEL=Kleinia-0.1-Aloe rd.live.image console=tty0 console=ttyS0,115200 enforcing=0" \
  -drive file=$W/disk.raw,if=virtio,format=raw -drive file=$ISO,if=virtio,media=cdrom,format=raw,readonly=on \
  -device virtio-net-pci,netdev=n0 -netdev user,id=n0 -vga none -display none \
  -chardev socket,id=s0,path=$W/serial.sock,server=on,wait=off,logfile=$W/serial.log \
  -serial chardev:s0 -daemonize -pidfile $W/qemu.pid
for i in $(seq 40); do
  sleep 10
  if grep -aq "kleinia login:" $W/serial.log 2>/dev/null; then echo "SMOKE-PASS (login prompt seen)"; \
    kill $(cat $W/qemu.pid); sleep 1; rm -rf "$W"; exit 0; fi
  if ! kill -0 $(cat $W/qemu.pid) 2>/dev/null; then break; fi
done
echo "SMOKE-FAIL"; tail -30 $W/serial.log; exit 1
