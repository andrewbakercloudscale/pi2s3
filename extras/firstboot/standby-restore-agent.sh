#!/usr/bin/env bash
# =============================================================
# extras/firstboot/standby-restore-agent.sh
#
# Installed on the SD card by install-standby-sync.sh.
# Runs automatically on every SD boot (via a systemd oneshot
# service wired by install-standby-sync.sh).
#
# On each SD boot this script checks for a trigger file written
# by hot-standby-sync.sh on the NVMe Pi. If found:
#   1. Safely reads restore parameters from the trigger
#   2. Runs pi-image-restore.sh → overwrites NVMe from S3
#   3. Runs the post-restore script (tunnel swap, hostname, etc.)
#   4. Writes last-synced date to SD boot partition (FAT, persists)
#   5. Removes the trigger so the restore doesn't repeat on next boot
#   6. Reboots into the freshly restored NVMe
#
# If no trigger file is found, this script exits immediately
# and the Pi boots normally (allows normal SD use).
#
# Log: /var/log/pi2s3-standby-restore.log
# =============================================================
set -euo pipefail

TRIGGER="/boot/firmware/.pi2s3-sync-request"
LOG="/var/log/pi2s3-standby-restore.log"

# Exit immediately if no sync was requested
[[ -f "${TRIGGER}" ]] || exit 0

# Redirect to log from this point
exec >> "${LOG}" 2>&1

echo "========================================================"
echo "  pi2s3 standby restore agent — $(date)"
echo "========================================================"

# ── Locate pi2s3 ─────────────────────────────────────────────────────────────
PI2S3_DIR=""
for _candidate in \
    "${HOME}/pi2s3" \
    "/home/pi/pi2s3" \
    "/home/admin/pi2s3" \
    "/root/pi2s3" \
    "/opt/pi2s3"; do
    if [[ -f "${_candidate}/pi-image-restore.sh" ]]; then
        PI2S3_DIR="${_candidate}"
        break
    fi
done

if [[ -z "${PI2S3_DIR}" ]]; then
    echo "  ERROR: pi2s3 tools not found on SD card."
    echo "  Run install-standby-sync.sh on the standby Pi to install them."
    rm -f "${TRIGGER}"
    exit 1
fi

# ── Load config (AWS creds, NTFY_URL, etc.) ───────────────────────────────────
CONFIG_FILE="${PI2S3_DIR}/config.env"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "  ERROR: config.env not found at ${CONFIG_FILE}"
    rm -f "${TRIGGER}"
    exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

_NTFY_SITE="${CF_SITE_HOSTNAME:-$(hostname -s)}"

ntfy() {
    [[ -z "${NTFY_URL:-}" ]] && return 0
    curl -s --max-time 10 \
        -H "Title: $1" \
        -H "Priority: ${3:-default}" \
        -H "Tags: ${4:-}" \
        -d "$2" \
        "${NTFY_URL}" > /dev/null 2>&1 || true
}

# ── Safely parse trigger file (no source — avoids code injection) ─────────────
# The trigger was written by hot-standby-sync.sh on the NVMe, but the NVMe
# reads its S3 marker from a potentially compromised bucket. Never source
# the trigger file directly; parse each field explicitly and validate.
_read_trigger() {
    local field="$1" default="${2:-}"
    local val
    val=$(grep -m1 "^${field}=" "${TRIGGER}" 2>/dev/null \
          | cut -d= -f2- \
          | sed 's/^"//;s/"$//' \
          || true)
    [[ -z "${val}" ]] && { echo "${default}"; return 0; }
    if echo "${val}" | grep -qE '[`$;|&<>()\]'; then
        echo "  WARN: trigger field ${field} contains unsafe characters — using default" >&2
        echo "${default}"
        return 0
    fi
    echo "${val}"
}

RESTORE_DATE=$(_read_trigger RESTORE_DATE "latest")
RESTORE_HOST=$(_read_trigger RESTORE_HOST "")
RESTORE_DEVICE=$(_read_trigger RESTORE_DEVICE "/dev/nvme0n1")
POST_RESTORE_SCRIPT=$(_read_trigger POST_RESTORE_SCRIPT "")

# Validate RESTORE_DATE: must be YYYY-MM-DD or "latest"
if [[ "${RESTORE_DATE}" != "latest" ]]; then
    if ! [[ "${RESTORE_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "  ERROR: invalid RESTORE_DATE in trigger: '${RESTORE_DATE}'"
        rm -f "${TRIGGER}"
        exit 1
    fi
fi

# Validate RESTORE_DEVICE: must be a block device path (/dev/...)
if ! [[ "${RESTORE_DEVICE}" =~ ^/dev/[a-zA-Z0-9]+$ ]]; then
    echo "  ERROR: invalid RESTORE_DEVICE in trigger: '${RESTORE_DEVICE}'"
    rm -f "${TRIGGER}"
    exit 1
fi

echo "  Restore date:    ${RESTORE_DATE}"
echo "  Restore host:    ${RESTORE_HOST}"
echo "  Restore device:  ${RESTORE_DEVICE}"
echo "  Post-restore:    ${POST_RESTORE_SCRIPT:-none}"

ntfy "S3 > PI: ${_NTFY_SITE}: Restore Running" \
    "$(hostname): restore from ${RESTORE_DATE} started.
Target: ${RESTORE_DEVICE}
Check log: ${LOG}" \
    "low" "arrows_counterclockwise"

# ── Run the restore ───────────────────────────────────────────────────────────
RESTORE_ARGS=(
    --device "${RESTORE_DEVICE}"
    --date   "${RESTORE_DATE}"
    --resize
    --yes
)
[[ -n "${RESTORE_HOST}" ]] && RESTORE_ARGS+=(--host "${RESTORE_HOST}")

# Post-restore script: use trigger value, fall back to config.env
_PR_SCRIPT="${POST_RESTORE_SCRIPT:-${STANDBY_POST_RESTORE_SCRIPT:-}}"
if [[ -n "${_PR_SCRIPT}" && -f "${_PR_SCRIPT}" ]]; then
    RESTORE_ARGS+=(--post-restore "${_PR_SCRIPT}")
elif [[ -n "${_PR_SCRIPT}" ]]; then
    echo "  WARN: post-restore script not found: ${_PR_SCRIPT} — skipping"
fi

echo "  Running: bash ${PI2S3_DIR}/pi-image-restore.sh ${RESTORE_ARGS[*]}"
echo ""

_restore_rc=0
bash "${PI2S3_DIR}/pi-image-restore.sh" "${RESTORE_ARGS[@]}" || _restore_rc=$?

if [[ ${_restore_rc} -eq 0 ]]; then
    echo ""
    echo "  Restore complete."
    RESTORE_OK=true
else
    echo ""
    echo "  ERROR: pi-image-restore.sh failed (exit ${_restore_rc})"
    RESTORE_OK=false
fi

# ── Write last-synced state to SD boot partition ──────────────────────────────
# Stored on the FAT SD boot partition so hot-standby-sync.sh can read it
# on the next cron run — NVMe data (and any state file on NVMe) is wiped
# by each restore, but the SD boot partition persists.
if [[ "${RESTORE_OK}" == "true" ]]; then
    if [[ -d "/boot/firmware" ]]; then
        _BOOT_STATE="/boot/firmware/.pi2s3-last-synced"
    else
        _BOOT_STATE="/boot/.pi2s3-last-synced"
    fi
    echo "${RESTORE_DATE}" > "${_BOOT_STATE}" 2>/dev/null \
        && echo "  State written: ${_BOOT_STATE} = ${RESTORE_DATE}" \
        || echo "  WARN: could not write sync state to ${_BOOT_STATE}"
fi

# ── Clean up trigger (always — avoids boot loops even on failure) ─────────────
rm -f "${TRIGGER}"

if [[ "${RESTORE_OK}" != "true" ]]; then
    ntfy "S3 > PI: ${_NTFY_SITE}: Restore Failed" \
        "$(hostname): restore from ${RESTORE_DATE} FAILED (exit ${_restore_rc}).
The NVMe may be in a partial state. Manual intervention required.
Check log: ${LOG}" \
        "urgent" "sos"
    echo "  Rebooting (NVMe may be partial — investigate before relying on standby)."
    sleep 5
    sudo reboot || {
        echo "  FATAL: sudo reboot failed — manual reboot required."
        exit 1
    }
    exit 1
fi

ntfy "S3 > PI: ${_NTFY_SITE}: Sync Complete" \
    "$(hostname): synced to ${RESTORE_DATE} backup.
Rebooting to NVMe — standby back up in ~2 min." \
    "low" "white_check_mark,floppy_disk"

echo "  Rebooting to NVMe with fresh data..."
echo "========================================================"
sleep 2
sudo reboot || {
    echo "  FATAL: sudo reboot failed — manual reboot required."
    ntfy "S3 > PI: ${_NTFY_SITE}: Reboot Failed" \
        "$(hostname): restore complete but reboot failed. Pi is stuck on SD card.
Manual reboot required to boot into restored NVMe." \
        "urgent" "sos"
    exit 1
}
