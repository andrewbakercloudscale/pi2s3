#!/usr/bin/env bash
# =============================================================
# post-restore-nvme-boot.sh — wire up NVMe as the boot target
#
# Pass to pi-image-restore.sh via --post-restore:
#   bash pi-image-restore.sh \
#     --device /dev/nvme0n1 --resize --yes --rate-limit 10m \
#     --post-restore extras/post-restore-nvme-boot.sh
#
# Optional: set NEW_HOSTNAME to rename the clone:
#   NEW_HOSTNAME=my-pi-qa bash pi-image-restore.sh ...
#
# What it does:
#   1. Fixes /etc/fstab on the restored root — swaps the original Pi's
#      SD card PARTUUID with this Pi's SD card PARTUUID for /boot/firmware.
#   2. Updates /boot/firmware/cmdline.txt (the running SD card) so the
#      next boot roots into the restored NVMe instead of the SD card.
#   3. Renames hostname if NEW_HOSTNAME is set.
#
# RESTORE_ROOT is exported by the restore script before calling this.
# =============================================================
set -euo pipefail

RESTORE_ROOT="${1:-${RESTORE_ROOT:-}}"

log()  { echo "[post-restore] $*"; }
warn() { echo "[post-restore] WARNING: $*" >&2; }
die()  { echo "[post-restore] ERROR: $*" >&2; exit 1; }

[[ -z "${RESTORE_ROOT}" ]] && die "RESTORE_ROOT is not set"
[[ -d "${RESTORE_ROOT}" ]] || die "RESTORE_ROOT '${RESTORE_ROOT}' is not a directory"

ERRORS=0

# ── 1. Locate the SD card FAT32 boot partition ───────────────────────────────
SD_BOOT_DEV=""
for _dev in /dev/mmcblk0p1 /dev/sda1; do
    if [[ -b "${_dev}" ]]; then
        _fstype=$(lsblk -no FSTYPE "${_dev}" 2>/dev/null || true)
        if [[ "${_fstype}" == "vfat" ]]; then
            SD_BOOT_DEV="${_dev}"
            break
        fi
    fi
done

if [[ -z "${SD_BOOT_DEV}" ]]; then
    warn "SD card FAT32 boot partition not found — cannot wire boot automatically."
    warn "Run manually after restore:"
    warn "  ROOT_UUID=\$(sudo blkid -s PARTUUID -o value /dev/nvme0n1p2)"
    warn "  sudo sed -i \"s|root=[^ ]*|root=PARTUUID=\${ROOT_UUID}|\" /boot/firmware/cmdline.txt"
    warn "  SD_UUID=\$(sudo blkid -s PARTUUID -o value /dev/mmcblk0p1)"
    warn "  sudo sed -i \"s|PARTUUID=<old>|PARTUUID=\${SD_UUID}|\" /mnt/etc/fstab"
    ERRORS=$(( ERRORS + 1 ))
else
    SD_PARTUUID=$(sudo blkid -s PARTUUID -o value "${SD_BOOT_DEV}" 2>/dev/null || true)
    if [[ -z "${SD_PARTUUID}" ]]; then
        warn "Could not read PARTUUID from ${SD_BOOT_DEV}"
        ERRORS=$(( ERRORS + 1 ))
    else
        log "SD boot partition: ${SD_BOOT_DEV} (PARTUUID=${SD_PARTUUID})"

        # ── 2. Fix /etc/fstab on restored root ───────────────────────────────
        FSTAB="${RESTORE_ROOT}/etc/fstab"
        if [[ -f "${FSTAB}" ]]; then
            OLD_FW_PARTUUID=$(grep '/boot/firmware' "${FSTAB}" 2>/dev/null \
                | grep -oP 'PARTUUID=\K[a-f0-9-]+' | head -1 || true)
            if [[ -n "${OLD_FW_PARTUUID}" && "${OLD_FW_PARTUUID}" != "${SD_PARTUUID}" ]]; then
                log "fstab: /boot/firmware PARTUUID ${OLD_FW_PARTUUID} → ${SD_PARTUUID}"
                sudo sed -i "s|PARTUUID=${OLD_FW_PARTUUID}|PARTUUID=${SD_PARTUUID}|g" "${FSTAB}"
                log "fstab updated."
            elif [[ -z "${OLD_FW_PARTUUID}" ]]; then
                warn "fstab: no /boot/firmware PARTUUID entry found — check ${FSTAB} manually."
                ERRORS=$(( ERRORS + 1 ))
            else
                log "fstab: /boot/firmware PARTUUID already correct."
            fi
        else
            warn "fstab not found at ${FSTAB}"
            ERRORS=$(( ERRORS + 1 ))
        fi

        # ── 3. Update /boot/firmware/cmdline.txt to root= the NVMe partition ─
        ROOT_PART=$(findmnt -n -o SOURCE "${RESTORE_ROOT}" 2>/dev/null \
            || awk -v mp="${RESTORE_ROOT}" '$2==mp{print $1;exit}' /proc/mounts 2>/dev/null \
            || true)

        if [[ -z "${ROOT_PART}" || ! -b "${ROOT_PART}" ]]; then
            warn "Could not determine which block device is mounted at ${RESTORE_ROOT}"
            warn "Update cmdline.txt manually:"
            warn "  sudo sed -i 's|root=[^ ]*|root=PARTUUID=<nvme-root-partuuid>|' /boot/firmware/cmdline.txt"
            ERRORS=$(( ERRORS + 1 ))
        else
            ROOT_PARTUUID=$(sudo blkid -s PARTUUID -o value "${ROOT_PART}" 2>/dev/null || true)
            if [[ -z "${ROOT_PARTUUID}" ]]; then
                warn "Could not read PARTUUID from ${ROOT_PART}"
                ERRORS=$(( ERRORS + 1 ))
            else
                CMDLINE="/boot/firmware/cmdline.txt"
                if [[ -f "${CMDLINE}" ]]; then
                    OLD_ROOT=$(grep -oP 'root=\S+' "${CMDLINE}" | head -1 || echo "root=<none>")
                    sudo sed -i "s|root=[^ ]*|root=PARTUUID=${ROOT_PARTUUID}|" "${CMDLINE}"
                    log "cmdline.txt: ${OLD_ROOT} → root=PARTUUID=${ROOT_PARTUUID}"
                else
                    warn "${CMDLINE} not found — cannot update boot target."
                    ERRORS=$(( ERRORS + 1 ))
                fi
            fi
        fi
    fi
fi

# ── 4. Rename hostname (optional) ────────────────────────────────────────────
if [[ -n "${NEW_HOSTNAME:-}" ]]; then
    HOSTNAME_FILE="${RESTORE_ROOT}/etc/hostname"
    HOSTS_FILE="${RESTORE_ROOT}/etc/hosts"
    OLD_HOSTNAME=$(cat "${HOSTNAME_FILE}" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -z "${OLD_HOSTNAME}" ]]; then
        warn "Could not read hostname from ${HOSTNAME_FILE}"
        ERRORS=$(( ERRORS + 1 ))
    elif [[ "${OLD_HOSTNAME}" == "${NEW_HOSTNAME}" ]]; then
        log "hostname: already '${NEW_HOSTNAME}' — no change."
    else
        echo "${NEW_HOSTNAME}" | sudo tee "${HOSTNAME_FILE}" > /dev/null
        [[ -f "${HOSTS_FILE}" ]] && \
            sudo sed -i "s/\b${OLD_HOSTNAME}\b/${NEW_HOSTNAME}/g" "${HOSTS_FILE}"
        log "hostname: ${OLD_HOSTNAME} → ${NEW_HOSTNAME}"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ ${ERRORS} -eq 0 ]]; then
    log "Boot wiring complete — no errors."
    log "On next reboot (SD card in place) the Pi will boot from the restored NVMe root."
else
    warn "Boot wiring completed with ${ERRORS} warning(s) — see above."
    warn "Review the warnings and fix manually before rebooting."
fi
