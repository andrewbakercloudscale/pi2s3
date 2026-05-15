#!/usr/bin/env bash
# =============================================================
# extras/firstboot/standby-restore-agent.sh
#
# Installed on the SD card by install-standby-sync.sh.
# Runs automatically on every SD boot (via /etc/rc.local or
# a systemd service wired by install-standby-sync.sh).
#
# On each SD boot this script checks for a trigger file written
# by hot-standby-sync.sh on the NVMe Pi. If found:
#   1. Reads restore parameters from the trigger
#   2. Runs pi-image-restore.sh → overwrites NVMe from S3
#   3. Runs the post-restore script (tunnel swap, hostname, etc.)
#   4. Removes the trigger so the restore doesn't repeat
#   5. Reboots into the freshly restored NVMe
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

# ── Load trigger parameters ───────────────────────────────────────────────────
# shellcheck disable=SC1090
source "${TRIGGER}"

echo "  Restore date:    ${RESTORE_DATE:-latest}"
echo "  Restore host:    ${RESTORE_HOST:-}"
echo "  Restore device:  ${RESTORE_DEVICE:-/dev/nvme0n1}"
echo "  Post-restore:    ${POST_RESTORE_SCRIPT:-none}"

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
    # Remove trigger so we don't loop on reboot
    rm -f "${TRIGGER}"
    exit 1
fi

# ── Load config (AWS creds, bucket, etc.) ─────────────────────────────────────
CONFIG_FILE="${PI2S3_DIR}/config.env"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "  ERROR: config.env not found at ${CONFIG_FILE}"
    rm -f "${TRIGGER}"
    exit 1
fi
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

ntfy() {
    [[ -z "${NTFY_URL:-}" ]] && return 0
    curl -s --max-time 10 \
        -H "Title: $1" \
        -H "Priority: ${3:-default}" \
        -H "Tags: ${4:-}" \
        -d "$2" \
        "${NTFY_URL}" > /dev/null 2>&1 || true
}

_NTFY_SITE="${NTFY_SITE:-$(hostname -s)}"

ntfy "S3 > PI: ${_NTFY_SITE}: Restore Running" \
    "$(hostname): restore from ${RESTORE_DATE:-latest} started.
Target: ${RESTORE_DEVICE:-/dev/nvme0n1}
Check log: ${LOG}" \
    "low" "arrows_counterclockwise"

# ── Run the restore ───────────────────────────────────────────────────────────
RESTORE_ARGS=(
    --device "${RESTORE_DEVICE:-/dev/nvme0n1}"
    --date   "${RESTORE_DATE:-latest}"
    --resize
    --yes
)
[[ -n "${RESTORE_HOST:-}" ]] && RESTORE_ARGS+=(--host "${RESTORE_HOST}")

# Post-restore script: use value from trigger, then fall back to config.env
_PR_SCRIPT="${POST_RESTORE_SCRIPT:-${STANDBY_POST_RESTORE_SCRIPT:-}}"
if [[ -n "${_PR_SCRIPT}" && -f "${_PR_SCRIPT}" ]]; then
    RESTORE_ARGS+=(--post-restore "${_PR_SCRIPT}")
elif [[ -n "${_PR_SCRIPT}" ]]; then
    echo "  WARN: STANDBY_POST_RESTORE_SCRIPT not found: ${_PR_SCRIPT} — skipping"
fi

echo "  Running: bash ${PI2S3_DIR}/pi-image-restore.sh ${RESTORE_ARGS[*]}"
echo ""

if bash "${PI2S3_DIR}/pi-image-restore.sh" "${RESTORE_ARGS[@]}"; then
    echo ""
    echo "  Restore complete."
    RESTORE_OK=true
else
    echo ""
    echo "  ERROR: pi-image-restore.sh failed (exit $?)"
    RESTORE_OK=false
fi

# ── Clean up trigger (always, even on failure, to avoid boot loops) ───────────
rm -f "${TRIGGER}"

if [[ "${RESTORE_OK}" != "true" ]]; then
    ntfy "S3 > PI: ${_NTFY_SITE}: Restore Failed" \
        "$(hostname): restore from ${RESTORE_DATE:-latest} FAILED.
The NVMe may be in a partial state. Manual intervention required.
Check log: ${LOG}" \
        "urgent" "sos"
    echo "  Rebooting (NVMe may be partial — investigate before relying on standby)."
    sleep 5
    sudo reboot
    exit 1
fi

# ── Write last-synced state ───────────────────────────────────────────────────
# The NVMe root is mounted at RESTORE_ROOT after restore.
# Write the state file there so hot-standby-sync.sh can read it after reboot.
_STATE_DEST=""
if [[ -n "${STANDBY_SYNC_STATE_FILE:-}" && -n "${RESTORE_ROOT:-}" ]]; then
    # Map the state file path into the restored NVMe root
    _STATE_DEST="${RESTORE_ROOT}${STANDBY_SYNC_STATE_FILE}"
    sudo mkdir -p "$(dirname "${_STATE_DEST}")" 2>/dev/null || true
    echo "${RESTORE_DATE:-}" | sudo tee "${_STATE_DEST}" > /dev/null
    echo "  State written: ${_STATE_DEST} = ${RESTORE_DATE:-}"
fi

ntfy "S3 > PI: ${_NTFY_SITE}: Sync Complete" \
    "$(hostname): synced to ${RESTORE_DATE:-latest} backup.
Rebooting to NVMe — standby back up in ~2 min." \
    "low" "white_check_mark,floppy_disk"

echo "  Rebooting to NVMe with fresh data..."
echo "========================================================"
sleep 2
sudo reboot
