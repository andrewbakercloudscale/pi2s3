#!/usr/bin/env bash
# extras/recover-sd-boot.sh — Fix a Pi with solid red LED (won't boot)
#
# Run on your Mac (or any Linux) with the Pi's SD card inserted:
#   bash extras/recover-sd-boot.sh
#   bash extras/recover-sd-boot.sh /Volumes/bootfs   # if auto-detect fails
#
# Symptoms this fixes:
#   - Pi shows solid red LED, no green ACT blink
#   - Pi never appears on the network after restore + reboot
#   - cmdline.txt has empty root=PARTUUID= (post-restore-nvme-boot.sh failed)
#   - cmdline.txt has wrong PARTUUID (NVMe partition changed)
#
# After running this + rebooting: Pi boots from SD card root.
# SSH in and re-run post-restore-nvme-boot.sh to re-wire NVMe boot.
set -euo pipefail

# ── Locate SD boot partition ──────────────────────────────────────────────────
BOOT_VOLUME="${1:-}"

if [[ -z "${BOOT_VOLUME}" ]]; then
    for candidate in /Volumes/bootfs /Volumes/boot /Volumes/BOOT /Volumes/BOOTFS \
                     /mnt/boot /mnt/bootfs; do
        if [[ -d "${candidate}" ]] && [[ -f "${candidate}/cmdline.txt" ]]; then
            BOOT_VOLUME="${candidate}"
            break
        fi
    done
fi

if [[ -z "${BOOT_VOLUME}" ]] || [[ ! -d "${BOOT_VOLUME}" ]]; then
    echo "ERROR: SD card boot partition not found."
    echo ""
    echo "Insert the Pi's SD card into your Mac, then either:"
    echo "  - Run this script again (auto-detects /Volumes/bootfs)"
    echo "  - Or: bash recover-sd-boot.sh /Volumes/<volume-name>"
    echo ""
    echo "On macOS, find the volume name with:"
    echo "  ls /Volumes/"
    echo "  diskutil list | grep -i FAT"
    exit 1
fi

CMDLINE="${BOOT_VOLUME}/cmdline.txt"
CMDLINE_BAK="${BOOT_VOLUME}/cmdline.txt.bak"

hr() { printf '%.0s─' {1..60}; echo; }
ok()   { printf "  [OK]  %s\n" "$*"; }
warn() { printf "  [!!!] %s\n" "$*"; }
info() { printf "  [ ]   %s\n" "$*"; }

echo ""
hr
echo "  pi2s3 SD card boot recovery"
echo "  Boot volume : ${BOOT_VOLUME}"
echo "  Date        : $(date)"
hr

if [[ ! -f "${CMDLINE}" ]]; then
    echo "ERROR: cmdline.txt not found at ${CMDLINE}"
    echo "This doesn't look like a Pi boot partition."
    exit 1
fi

# ── Show current state ────────────────────────────────────────────────────────
echo ""
echo "  Current cmdline.txt:"
cat "${CMDLINE}" | tr ' ' '\n' | sed 's/^/    /'

root_param=$(grep -oP 'root=\S+' "${CMDLINE}" 2>/dev/null | head -1 || echo "MISSING")
echo ""
echo "  root= parameter: ${root_param}"

# ── Diagnose ──────────────────────────────────────────────────────────────────
echo ""
hr
echo "  Diagnosis"
hr
PROBLEM=0

if [[ "${root_param}" == "MISSING" ]]; then
    warn "No root= in cmdline.txt — file is corrupt or empty"
    PROBLEM=1
elif [[ "${root_param}" =~ ^root=PARTUUID=$ ]] || [[ "${root_param}" == "root=PARTUUID=" ]]; then
    warn "root=PARTUUID= is EMPTY — post-restore-nvme-boot.sh failed to write the NVMe PARTUUID"
    warn "This is why the Pi shows solid red (can't find root partition)"
    PROBLEM=1
elif echo "${root_param}" | grep -qP 'root=PARTUUID=[a-f0-9-]+'; then
    partuuid=$(echo "${root_param}" | grep -oP 'PARTUUID=\K[a-f0-9-]+')
    ok "root= has a PARTUUID value: ${partuuid}"
    info "Cannot verify this PARTUUID without the NVMe connected to this Mac"
    info "If Pi still won't boot: the PARTUUID may point to the wrong device"
    echo ""
    info "To verify: connect NVMe via USB adapter and run:"
    info "  macOS:  diskutil list  →  find partition  →  diskutil info diskXsY | grep UUID"
    info "  Linux:  sudo blkid /dev/sda2  # or the NVMe partition"
else
    info "root= is not PARTUUID-based: ${root_param}"
fi

# ── Restore from backup ───────────────────────────────────────────────────────
echo ""
hr
echo "  Recovery options"
hr
echo ""

if [[ -f "${CMDLINE_BAK}" ]]; then
    ok "Backup found: cmdline.txt.bak"
    echo ""
    echo "  Backup content:"
    cat "${CMDLINE_BAK}" | tr ' ' '\n' | sed 's/^/    /'
    echo ""
    bak_root=$(grep -oP 'root=\S+' "${CMDLINE_BAK}" | head -1 || echo "MISSING")
    echo "  Backup root=: ${bak_root}"
    echo ""

    if [[ "${bak_root}" =~ PARTUUID=[a-f0-9-]+ ]]; then
        echo "  This backup boots the Pi from its ORIGINAL root partition (before restore)."
        echo "  Safe to restore — gives you a working Pi to SSH into."
        echo "  Then re-run post-restore-nvme-boot.sh to re-wire NVMe boot."
    fi

    echo ""
    printf "  Restore backup now? (y/N): "
    read -r answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        cp "${CMDLINE_BAK}" "${CMDLINE}"
        echo ""
        ok "cmdline.txt restored from backup."
        echo ""
        echo "  Next steps:"
        echo "  1. Eject SD card, insert into Pi, power on"
        echo "  2. Pi should now boot (green LED will blink)"
        echo "  3. SSH in:"
        echo "       ssh admin@<pi-hostname>.local"
        echo "  4. Re-wire NVMe boot:"
        echo "       sudo bash ~/pi2s3/extras/post-restore-nvme-boot.sh"
    else
        echo "  Backup NOT restored."
    fi

else
    warn "No backup found (cmdline.txt.bak not present)"
    echo ""
    echo "  The backup is created by post-restore-nvme-boot.sh before it edits cmdline.txt."
    echo "  Without it, you need the NVMe PARTUUID to write a correct cmdline.txt manually."
    echo ""
    echo "  Option A — Connect NVMe to this Mac via USB adapter:"
    echo "    macOS: diskutil list                          # find the NVMe disk (eg disk3)"
    echo "           diskutil info disk3s2 | grep -i UUID  # get Partition UUID"
    echo "    Then update cmdline.txt (replace <UUID> with the value above):"
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "    sed -i '' 's|root=PARTUUID=[^ ]*|root=PARTUUID=<UUID>|' ${CMDLINE}"
    else
        echo "    sed -i 's|root=PARTUUID=[^ ]*|root=PARTUUID=<UUID>|' ${CMDLINE}"
    fi
    echo ""
    echo "  Option B — Write a fresh Raspberry Pi OS to the SD card:"
    echo "    Use Raspberry Pi Imager (raspberrypi.com/software)"
    echo "    Boot Pi from fresh SD → SSH in → re-run the restore"
    echo ""
    echo "  Option C — If you know the SD card root PARTUUID (old Pi OS install):"
    echo "    Edit cmdline.txt to point root= back at the SD card p2 partition"
    echo "    Pi boots from SD; SSH in; blkid /dev/nvme0n1p2 to get NVMe PARTUUID"
    echo "    Then re-run: sudo bash ~/pi2s3/extras/post-restore-nvme-boot.sh"
fi

echo ""
hr
echo "  Done."
hr
echo ""
