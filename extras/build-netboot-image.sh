#!/usr/bin/env bash
# =============================================================
# extras/build-netboot-image.sh — Build pi2s3 HTTP netboot boot files
#
# Produces four files that the Pi 5 bootloader fetches over HTTP:
#   kernel8.img   — Pi OS ARM64 kernel (extracted from Pi OS Lite)
#   initrd.img    — minimal initramfs with partclone + aws-cli + pi2s3
#   config.txt    — Pi boot config
#   cmdline.txt   — kernel command line
#
# Optionally uploads directly to S3 for serving via CloudFront.
#
# Usage:
#   bash extras/build-netboot-image.sh
#   bash extras/build-netboot-image.sh --upload s3://my-bucket/boot/
#   bash extras/build-netboot-image.sh --output-dir ~/netboot-files/
#
# Requirements:
#   Linux (Ubuntu 22.04+), sudo, ~6 GB free disk, ~20 min
#   On x86_64: sudo apt install qemu-user-static binfmt-support
#   For --upload: AWS CLI v2 with write access to target bucket
#
# Infrastructure (one-time, see extras/README.md for full setup):
#   - S3 bucket at boot.pi2s3.com (or any public bucket)
#   - CloudFront distribution in front, CNAME boot.pi2s3.com
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/pi2s3-netboot-$$"
OUTPUT_DIR="${PWD}/pi2s3-netboot-$(date +%Y-%m-%d)"
UPLOAD_TARGET=""
PI_OS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)    shift; OUTPUT_DIR="${1:?--output-dir requires a path}" ;;
        --output-dir=*)  OUTPUT_DIR="${1#--output-dir=}" ;;
        --upload)        shift; UPLOAD_TARGET="${1:?--upload requires s3://...}" ;;
        --upload=*)      UPLOAD_TARGET="${1#--upload=}" ;;
        --pi-os-url)     shift; PI_OS_URL="${1:?}" ;;
        --pi-os-url=*)   PI_OS_URL="${1#--pi-os-url=}" ;;
        --help)
            echo "Usage: $0 [--output-dir <dir>] [--upload s3://bucket/prefix/] [--pi-os-url <url>]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

[[ "$(uname -s)" == "Linux" ]] || { echo "ERROR: This script requires Linux."; exit 1; }
command -v sudo    &>/dev/null || { echo "ERROR: sudo not found."; exit 1; }
command -v losetup &>/dev/null || { echo "ERROR: losetup not found (install util-linux)."; exit 1; }
command -v xz      &>/dev/null || { echo "ERROR: xz not found."; exit 1; }

HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" == "x86_64" ]]; then
    [[ -f /usr/bin/qemu-aarch64-static ]] || {
        echo "ERROR: qemu-aarch64-static not found."
        echo "  sudo apt install qemu-user-static binfmt-support"
        exit 1
    }
fi

if [[ -n "${UPLOAD_TARGET}" ]]; then
    command -v aws &>/dev/null || { echo "ERROR: aws CLI not found (required for --upload)."; exit 1; }
fi

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
BOOT_MNT="${WORK_DIR}/boot"
ROOT_MNT="${WORK_DIR}/root"
INITRAMFS_DIR="${WORK_DIR}/initramfs"
mkdir -p "${BOOT_MNT}" "${ROOT_MNT}" "${INITRAMFS_DIR}"

LOOP=""
cleanup() {
    set +e
    for mnt in proc sys dev/pts dev; do
        mountpoint -q "${ROOT_MNT}/${mnt}" 2>/dev/null && sudo umount -l "${ROOT_MNT}/${mnt}"
    done
    mountpoint -q "${BOOT_MNT}" && sudo umount -l "${BOOT_MNT}"
    mountpoint -q "${ROOT_MNT}" && sudo umount -l "${ROOT_MNT}"
    [[ -n "${LOOP}" ]] && sudo losetup -d "${LOOP}" 2>/dev/null
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log() { echo "  $*"; }

echo ""
echo "  pi2s3 netboot image builder"
echo "  ─────────────────────────────────────────────────"

# ── Step 1: Download and mount Pi OS ─────────────────────────────────────────
log "Step 1: Downloading Pi OS Lite ARM64..."
IMG_XZ="${WORK_DIR}/pi-os.img.xz"
curl -L --progress-bar "${PI_OS_URL}" -o "${IMG_XZ}"
log "Decompressing..."
xz -d "${IMG_XZ}"
IMAGE_FILE="$(ls "${WORK_DIR}"/*.img | head -1)"

log "Step 2: Mounting Pi OS image..."
LOOP=$(sudo losetup --show -fP "${IMAGE_FILE}")
sudo mount "${LOOP}p2" "${ROOT_MNT}"
sudo mount "${LOOP}p1" "${BOOT_MNT}"
sudo mount --bind "${BOOT_MNT}" "${ROOT_MNT}/boot/firmware"

# ── Step 2: Extract kernel from Pi OS ────────────────────────────────────────
log "Step 3: Extracting kernel..."
# Pi 5 uses kernel_2712.img; fall back to kernel8.img for Pi 4/3
KERNEL_SRC=""
for candidate in kernel_2712.img kernel8.img vmlinuz; do
    if [[ -f "${BOOT_MNT}/${candidate}" ]]; then
        KERNEL_SRC="${BOOT_MNT}/${candidate}"
        log "        Found: ${candidate}"
        break
    fi
done
[[ -n "${KERNEL_SRC}" ]] || { echo "ERROR: No kernel found in boot partition."; exit 1; }
cp "${KERNEL_SRC}" "${OUTPUT_DIR}/kernel8.img"

# ── Step 3: Build initramfs ──────────────────────────────────────────────────
log "Step 4: Building initramfs..."
echo ""

# Install build tools into Pi OS root, then pack as initramfs
sudo mount -t proc  proc     "${ROOT_MNT}/proc"
sudo mount -t sysfs sysfs    "${ROOT_MNT}/sys"
sudo mount -o bind  /dev     "${ROOT_MNT}/dev"
sudo mount -o bind  /dev/pts "${ROOT_MNT}/dev/pts"

[[ "${HOST_ARCH}" == "x86_64" ]] && sudo cp /usr/bin/qemu-aarch64-static "${ROOT_MNT}/usr/bin/"

sudo tee "${ROOT_MNT}/usr/sbin/policy-rc.d" > /dev/null <<'EOF'
#!/bin/sh
exit 101
EOF
sudo chmod +x "${ROOT_MNT}/usr/sbin/policy-rc.d"

# Install extra packages needed for restore
sudo chroot "${ROOT_MNT}" /bin/bash <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    partclone pigz pv python3 git unzip curl \
    cloud-guest-utils e2fsprogs parted iproute2 \
    dhcpcd5 2>&1 | tail -5

# AWS CLI v2 (ARM64)
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscli.zip
aws --version

# Clone pi2s3
git clone --depth 1 https://github.com/andrewbakercloudscale/pi2s3.git /opt/pi2s3
CHROOT

echo ""

# Write /init — the first process that runs when the initramfs boots
sudo tee "${ROOT_MNT}/init" > /dev/null <<'INIT'
#!/bin/bash
# pi2s3 netboot init — runs as PID 1

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"
export TERM="linux"

mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs dev /dev
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts

# Ensure partclone is findable
export PATH="/usr/sbin:${PATH}"

clear
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║      pi2s3  Netboot Recovery Environment     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  Waiting for network..."

# Bring up eth0 via DHCP (bootloader may have already done this)
ip link set eth0 up 2>/dev/null || true
dhcpcd eth0 2>/dev/null || dhclient eth0 2>/dev/null || true

# Give network a moment to settle
for i in $(seq 1 10); do
    ip route show default 2>/dev/null | grep -q "default" && break
    sleep 1
done

IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet )[\d.]+' || echo "unknown")
echo "  Network: ${IP}"
echo ""

exec bash /opt/pi2s3/extras/recovery-launcher.sh
INIT
sudo chmod +x "${ROOT_MNT}/init"

# Pack initramfs (exclude kernel, modules for size — kernel is fetched separately)
log "Step 5: Packing initramfs..."
INITRD="${OUTPUT_DIR}/initrd.img"
(cd "${ROOT_MNT}" && sudo find . \
    -not -path "./boot/*" \
    -not -path "./proc/*" \
    -not -path "./sys/*" \
    -not -path "./dev/*" \
    -not -path "./run/*" \
    -not -path "./tmp/*" \
    -not -path "./usr/share/doc/*" \
    -not -path "./usr/share/man/*" \
    -not -path "./usr/share/locale/*" \
    -not -name "*.pyc" \
    | sudo cpio -o -H newc 2>/dev/null \
    | pigz -9 > "${INITRD}")

INITRD_SIZE=$(du -h "${INITRD}" | cut -f1)
log "        initrd.img: ${INITRD_SIZE}"

# Clean up chroot
sudo rm -f "${ROOT_MNT}/usr/sbin/policy-rc.d"
[[ "${HOST_ARCH}" == "x86_64" ]] && sudo rm -f "${ROOT_MNT}/usr/bin/qemu-aarch64-static"

# ── Step 4: Write config.txt and cmdline.txt ─────────────────────────────────
log "Step 6: Writing config.txt and cmdline.txt..."

cat > "${OUTPUT_DIR}/config.txt" <<'EOF'
# pi2s3 netboot config — served from boot.pi2s3.com
# Pi 5 (BCM2712) kernel
arm_64bit=1
kernel=kernel8.img
initramfs initrd.img followkernel
[pi4]
kernel=kernel8.img
[all]
EOF

cat > "${OUTPUT_DIR}/cmdline.txt" <<'EOF'
console=serial0,115200 console=tty1 ip=dhcp rootfstype=ramfs rw quiet
EOF

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
log "Build complete. Output files:"
ls -lh "${OUTPUT_DIR}/" | sed 's/^/    /'
echo ""

if [[ -n "${UPLOAD_TARGET}" ]]; then
    log "Uploading to ${UPLOAD_TARGET}..."
    aws s3 sync "${OUTPUT_DIR}/" "${UPLOAD_TARGET}" \
        --cache-control "max-age=300, must-revalidate" \
        --acl public-read 2>&1 | sed 's/^/    /'
    log "Upload complete."
    echo ""
    BOOT_URL="${UPLOAD_TARGET#s3://}"
    BUCKET="${BOOT_URL%%/*}"
    log "Test with: curl -I https://${BUCKET}/config.txt"
    echo ""
fi

echo "  Flash instructions are not needed for netboot."
echo "  Once files are at boot.pi2s3.com (or your own host),"
echo "  run extras/setup-netboot.sh on each Pi to configure EEPROM."
echo ""
