#!/usr/bin/env bash
# =============================================================
# extras/build-recovery-usb.sh — Build a pi2s3 recovery USB image
#
# Creates a bootable Raspberry Pi OS Lite (ARM64) image with
# pi2s3 and all dependencies pre-installed. Flash to a USB stick
# or SD card with Raspberry Pi Imager and keep it in a drawer for
# zero-prerequisite disaster recovery.
#
# Usage:
#   bash extras/build-recovery-usb.sh
#   bash extras/build-recovery-usb.sh --output ~/pi2s3-recovery.img.xz
#   bash extras/build-recovery-usb.sh --pi-os-url <url>   # pin a specific release
#
# Requirements:
#   - Linux (Ubuntu 22.04+ recommended — also works on a Pi)
#   - sudo access, ~6 GB free disk space
#   - On x86_64: sudo apt install qemu-user-static binfmt-support
#   - On ARM64:  no QEMU needed
#
# Output:
#   pi2s3-recovery-usb-<date>.img.xz (~900 MB)
#   Flash with Raspberry Pi Imager or:
#     xz -d pi2s3-recovery-usb-*.img.xz
#     sudo dd if=pi2s3-recovery-usb-*.img of=/dev/sdX bs=4M status=progress
#
# On first boot the Pi auto-logs in, prompts for S3 bucket + AWS
# credentials, then launches pi-image-restore.sh interactively.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DATE="$(date +%Y-%m-%d)"
WORK_DIR="${TMPDIR:-/tmp}/pi2s3-build-$$"
OUTPUT_FILE="${PWD}/pi2s3-recovery-usb-${BUILD_DATE}.img.xz"
PI_OS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
EXPAND_MB=1800   # extra MB added to image for packages + repo

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)     shift; OUTPUT_FILE="${1:?--output requires a path}" ;;
        --output=*)   OUTPUT_FILE="${1#--output=}" ;;
        --pi-os-url)  shift; PI_OS_URL="${1:?--pi-os-url requires a URL}" ;;
        --pi-os-url=*)PI_OS_URL="${1#--pi-os-url=}" ;;
        --help)
            echo "Usage: $0 [--output <path>] [--pi-os-url <url>]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ── Dependency checks ─────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || { echo "ERROR: This script requires Linux."; exit 1; }
command -v sudo   &>/dev/null || { echo "ERROR: sudo not found."; exit 1; }
command -v losetup &>/dev/null || { echo "ERROR: losetup not found (install util-linux)."; exit 1; }
command -v python3 &>/dev/null || { echo "ERROR: python3 not found."; exit 1; }
command -v xz     &>/dev/null || { echo "ERROR: xz not found (sudo apt install xz-utils)."; exit 1; }

HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" == "x86_64" ]]; then
    if [[ ! -f /usr/bin/qemu-aarch64-static ]]; then
        echo "ERROR: qemu-aarch64-static not found."
        echo "  sudo apt install qemu-user-static binfmt-support"
        exit 1
    fi
fi

# ── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "${WORK_DIR}"
BOOT_MNT="${WORK_DIR}/boot"
ROOT_MNT="${WORK_DIR}/root"
mkdir -p "${BOOT_MNT}" "${ROOT_MNT}"

LOOP=""

cleanup() {
    set +e
    [[ -d "${ROOT_MNT}/proc" ]] && sudo umount -l "${ROOT_MNT}/proc"  2>/dev/null
    [[ -d "${ROOT_MNT}/sys"  ]] && sudo umount -l "${ROOT_MNT}/sys"   2>/dev/null
    [[ -d "${ROOT_MNT}/dev/pts" ]] && sudo umount -l "${ROOT_MNT}/dev/pts" 2>/dev/null
    [[ -d "${ROOT_MNT}/dev"  ]] && sudo umount -l "${ROOT_MNT}/dev"   2>/dev/null
    mountpoint -q "${BOOT_MNT}" && sudo umount -l "${BOOT_MNT}"       2>/dev/null
    mountpoint -q "${ROOT_MNT}" && sudo umount -l "${ROOT_MNT}"       2>/dev/null
    [[ -n "${LOOP}" ]] && sudo losetup -d "${LOOP}" 2>/dev/null
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log() { echo "  $*"; }

# ── Step 1: Download Pi OS ────────────────────────────────────────────────────
echo ""
echo "  pi2s3 Recovery USB builder"
echo "  ─────────────────────────────────────────────────"
log "Step 1: Downloading Raspberry Pi OS Lite (ARM64)..."
log "        ${PI_OS_URL}"
echo ""

IMG_XZ="${WORK_DIR}/pi-os-lite.img.xz"
curl -L --progress-bar "${PI_OS_URL}" -o "${IMG_XZ}"

log "Decompressing..."
xz -d "${IMG_XZ}"
IMAGE_FILE="${IMG_XZ%.xz}"
# Pi OS releases may be wrapped in a zip or named differently — handle .img directly
IMAGE_FILE="$(ls "${WORK_DIR}"/*.img 2>/dev/null | head -1)"
[[ -f "${IMAGE_FILE}" ]] || { echo "ERROR: Could not find .img file in ${WORK_DIR}"; exit 1; }

# ── Step 2: Expand image to fit packages ─────────────────────────────────────
log "Step 2: Expanding image by ${EXPAND_MB} MB..."
dd if=/dev/zero bs=1M count="${EXPAND_MB}" >> "${IMAGE_FILE}" 2>/dev/null

# Extend the second (root) partition to use the new space
PART2_START=$(python3 -c "
import subprocess, json
r = subprocess.run(['sfdisk', '--json', '${IMAGE_FILE}'], capture_output=True, text=True)
parts = json.loads(r.stdout)['partitiontable']['partitions']
print(parts[1]['start'])
")
echo "label: dos
${PART2_START},,L" | sudo sfdisk --no-reread -N 2 "${IMAGE_FILE}" 2>&1 | sed 's/^/    /'

# ── Step 3: Mount ─────────────────────────────────────────────────────────────
log "Step 3: Mounting image..."
LOOP=$(sudo losetup --show -fP "${IMAGE_FILE}")
log "        Loop device: ${LOOP}"

sudo e2fsck -f -y "${LOOP}p2" 2>&1 | sed 's/^/    /' || true
sudo resize2fs "${LOOP}p2" 2>&1 | sed 's/^/    /'

sudo mount "${LOOP}p2" "${ROOT_MNT}"
sudo mount "${LOOP}p1" "${BOOT_MNT}"

# Bind /boot/firmware inside root
sudo mount --bind "${BOOT_MNT}" "${ROOT_MNT}/boot/firmware"

# ── Step 4: QEMU + pseudo-filesystems ─────────────────────────────────────────
log "Step 4: Setting up chroot environment..."
sudo mount -t proc  proc          "${ROOT_MNT}/proc"
sudo mount -t sysfs sysfs         "${ROOT_MNT}/sys"
sudo mount -o bind  /dev          "${ROOT_MNT}/dev"
sudo mount -o bind  /dev/pts      "${ROOT_MNT}/dev/pts"

if [[ "${HOST_ARCH}" == "x86_64" ]]; then
    sudo cp /usr/bin/qemu-aarch64-static "${ROOT_MNT}/usr/bin/"
fi

# Prevent services starting during chroot
sudo tee "${ROOT_MNT}/usr/sbin/policy-rc.d" > /dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
sudo chmod +x "${ROOT_MNT}/usr/sbin/policy-rc.d"

# ── Step 5: Install packages ──────────────────────────────────────────────────
log "Step 5: Installing packages (partclone, pigz, pv, aws-cli)..."
echo ""

sudo chroot "${ROOT_MNT}" /bin/bash <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    git partclone pigz pv unzip curl python3 \
    cloud-guest-utils e2fsprogs parted 2>&1 | tail -5

# AWS CLI v2 (ARM64)
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscli.zip
aws --version
CHROOT

echo ""

# ── Step 6: Clone pi2s3 repo ──────────────────────────────────────────────────
log "Step 6: Cloning pi2s3 repository..."
sudo chroot "${ROOT_MNT}" /bin/bash <<'CHROOT'
sudo -u pi git clone --depth 1 https://github.com/andrewbakercloudscale/pi2s3.git /home/pi/pi2s3
CHROOT

# ── Step 7: First-boot autologin + launcher ───────────────────────────────────
log "Step 7: Configuring auto-login and first-boot launcher..."

# Autologin on tty1
sudo mkdir -p "${ROOT_MNT}/etc/systemd/system/getty@tty1.service.d"
sudo tee "${ROOT_MNT}/etc/systemd/system/getty@tty1.service.d/autologin.conf" > /dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
EOF

# .bash_profile: launch restore on tty1 login
sudo tee "${ROOT_MNT}/home/pi/.bash_profile" > /dev/null <<'EOF'
# pi2s3 recovery USB: auto-launch restore on console login
if [[ "$(tty)" == "/dev/tty1" ]] && [[ -f /home/pi/pi2s3/extras/recovery-launcher.sh ]]; then
    bash /home/pi/pi2s3/extras/recovery-launcher.sh
fi
EOF
sudo chroot "${ROOT_MNT}" chown pi:pi /home/pi/.bash_profile

# ── Step 8: Enable SSH ────────────────────────────────────────────────────────
log "Step 8: Enabling SSH..."
sudo touch "${BOOT_MNT}/ssh"

# userconf.txt — default user pi / password: recovery
# Generated with: echo 'recovery' | openssl passwd -6 -stdin
sudo tee "${BOOT_MNT}/userconf.txt" > /dev/null <<'EOF'
pi:$6$rJRkipb7$HJfCdv5dkNT0w7v.FioOqFIJSlXUeJb/IH5DXFJhJ0aBF9gSC4cJgSBsI3SvZiqcxsN2xkiuH4q.rT3cN2OP/
EOF

# ── Step 9: Mark it visually as a recovery image ──────────────────────────────
sudo tee "${ROOT_MNT}/etc/motd" > /dev/null <<'EOF'

  ╔══════════════════════════════════════════════╗
  ║         pi2s3  Recovery Environment          ║
  ║                                              ║
  ║  Run: bash ~/pi2s3/extras/recovery-launcher.sh
  ╚══════════════════════════════════════════════╝

EOF

# ── Step 10: Cleanup + compress ───────────────────────────────────────────────
log "Step 10: Cleaning up..."

sudo rm -f "${ROOT_MNT}/usr/sbin/policy-rc.d"
[[ "${HOST_ARCH}" == "x86_64" ]] && sudo rm -f "${ROOT_MNT}/usr/bin/qemu-aarch64-static"

sudo umount -l "${ROOT_MNT}/boot/firmware"
sudo umount -l "${ROOT_MNT}/proc"
sudo umount -l "${ROOT_MNT}/sys"
sudo umount -l "${ROOT_MNT}/dev/pts"
sudo umount -l "${ROOT_MNT}/dev"
sudo umount -l "${BOOT_MNT}"
sudo umount -l "${ROOT_MNT}"
sudo losetup -d "${LOOP}"; LOOP=""

log "Step 11: Compressing to ${OUTPUT_FILE}..."
echo ""
xz -T0 -v --keep "${IMAGE_FILE}" && mv "${IMAGE_FILE}.xz" "${OUTPUT_FILE}"

IMAGE_SIZE=$(du -h "${OUTPUT_FILE}" | cut -f1)

echo ""
echo "  ─────────────────────────────────────────────────"
echo "  Build complete!"
echo ""
echo "  Output: ${OUTPUT_FILE} (${IMAGE_SIZE})"
echo ""
echo "  Flash with Raspberry Pi Imager (choose 'Use custom'),"
echo "  or from the command line:"
echo ""
echo "    xz -d ${OUTPUT_FILE}"
echo "    sudo dd if=${OUTPUT_FILE%.xz} of=/dev/sdX bs=4M status=progress"
echo ""
echo "  Default SSH password: recovery"
echo "  On first boot the Pi auto-logs in and launches"
echo "  the pi2s3 restore wizard."
echo "  ─────────────────────────────────────────────────"
