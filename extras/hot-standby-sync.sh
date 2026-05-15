#!/usr/bin/env bash
# =============================================================
# extras/hot-standby-sync.sh — Daily sync for hot standby Pi
#
# Runs on the STANDBY Pi via cron (every 30 min).
# Detects a sync-ready marker written to S3 by the primary Pi
# after each successful backup, then kicks off a restore cycle:
#
#   1. Reads s3://BUCKET/STANDBY_SYNC_MARKER_KEY (JSON)
#   2. Compares backup_date with last synced date
#   3. Optionally checks that primary is up (safety guard)
#   4. Mounts the SD card boot partition
#   5. Writes a restore trigger file (.pi2s3-sync-request)
#   6. Reboots — the SD firstboot agent auto-restores NVMe then reboots back
#
# The Pi is offline for ~30 min during the restore cycle.
# This is intentional and expected — it happens right after the primary
# has finished backing up and failed back, so primary is serving traffic.
#
# Prerequisites:
#   - Run: bash extras/install-standby-sync.sh (once, on standby Pi)
#   - HOT_STANDBY_SYNC_ENABLED=true in config.env
#   - SD card inserted — the restore agent is installed on it
#
# Log: /var/log/pi2s3-standby-sync.log
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"
CONFIG_FILE="${PARENT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"
# shellcheck disable=SC1091
source "${PARENT_DIR}/lib/log.sh"
# shellcheck disable=SC1091
source "${PARENT_DIR}/lib/aws.sh"

# ── Config defaults ───────────────────────────────────────────────────────────
HOT_STANDBY_SYNC_ENABLED="${HOT_STANDBY_SYNC_ENABLED:-false}"
STANDBY_SYNC_MARKER_KEY="${STANDBY_SYNC_MARKER_KEY:-standby-sync-ready/latest.json}"
STANDBY_SYNC_DEVICE="${STANDBY_SYNC_DEVICE:-/dev/nvme0n1}"
STANDBY_SYNC_SD_BOOT="${STANDBY_SYNC_SD_BOOT:-/dev/mmcblk0p1}"
STANDBY_POST_RESTORE_SCRIPT="${STANDBY_POST_RESTORE_SCRIPT:-}"
STANDBY_SYNC_PRIMARY_URL="${STANDBY_SYNC_PRIMARY_URL:-}"
STANDBY_SYNC_STATE_FILE="${STANDBY_SYNC_STATE_FILE:-${PARENT_DIR}/.standby-last-synced}"
[[ -z "${S3_BUCKET:-}"  ]] && { echo "ERROR: S3_BUCKET not set" >&2; exit 1; }
[[ -z "${AWS_PROFILE:-}" ]] && unset AWS_PROFILE || true

_NTFY_SITE="${CF_SITE_HOSTNAME:-$(hostname -s)}"
HOST_SHORT=$(hostname -s)

# ── Guard ─────────────────────────────────────────────────────────────────────
[[ "${HOT_STANDBY_SYNC_ENABLED}" == "true" ]] || exit 0

# ── Redirect output to log ────────────────────────────────────────────────────
LOG_FILE="/var/log/pi2s3-standby-sync.log"
# Create log file if it doesn't exist (requires root or pre-created by install script)
[[ -f "${LOG_FILE}" ]] || touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/tmp/pi2s3-standby-sync.log"
exec >> "${LOG_FILE}" 2>&1

ntfy_send() {
    [[ -z "${NTFY_URL:-}" ]] && return 0
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    local extra=()
    [[ -n "$tags" ]] && extra+=(-H "Tags: $tags")
    local _attempt _rc=1
    for _attempt in 1 2 3; do
        curl -s --max-time 10 \
            -H "Title: $title" \
            -H "Priority: $priority" \
            "${extra[@]}" \
            -d "$msg" \
            "${NTFY_URL}" > /dev/null 2>&1 && { _rc=0; break; }
        [[ ${_attempt} -lt 3 ]] && sleep $(( _attempt * 5 ))
    done
    return ${_rc}
}

log "========================================================"
log "  pi2s3 standby sync check — $(date)"
log "========================================================"

# ── Read S3 sync marker ───────────────────────────────────────────────────────
MARKER_TMP=$(mktemp)
trap 'rm -f "${MARKER_TMP}"' EXIT

log "Checking S3 for sync marker: s3://${S3_BUCKET}/${STANDBY_SYNC_MARKER_KEY}"
if ! aws_cmd s3 cp "s3://${S3_BUCKET}/${STANDBY_SYNC_MARKER_KEY}" "${MARKER_TMP}" 2>/dev/null; then
    log "  No sync marker found — nothing to sync."
    exit 0
fi

BACKUP_DATE=$(grep -o '"backup_date":"[^"]*"' "${MARKER_TMP}" | cut -d'"' -f4 || true)
BACKUP_HOST=$(grep -o '"backup_host":"[^"]*"' "${MARKER_TMP}" | cut -d'"' -f4 || true)
BACKUP_PREFIX=$(grep -o '"backup_s3_prefix":"[^"]*"' "${MARKER_TMP}" | cut -d'"' -f4 || true)
MARKER_TIME=$(grep -o '"written_at":"[^"]*"' "${MARKER_TMP}" | cut -d'"' -f4 || true)

if [[ -z "${BACKUP_DATE}" ]]; then
    log "  ERROR: could not parse backup_date from marker JSON"
    exit 1
fi

log "  Marker: backup_date=${BACKUP_DATE} host=${BACKUP_HOST} written=${MARKER_TIME}"

# ── Compare with last synced date ─────────────────────────────────────────────
LAST_SYNCED=""
if [[ -f "${STANDBY_SYNC_STATE_FILE}" ]]; then
    LAST_SYNCED=$(cat "${STANDBY_SYNC_STATE_FILE}" | tr -d '[:space:]')
fi

if [[ -n "${LAST_SYNCED}" && "${LAST_SYNCED}" == "${BACKUP_DATE}" ]]; then
    log "  Already synced to ${BACKUP_DATE} — nothing to do."
    exit 0
fi

log "  New backup available: ${BACKUP_DATE} (last synced: ${LAST_SYNCED:-never})"

# ── Safety check: only sync when primary is healthy ───────────────────────────
# If primary is unreachable, this standby may be serving traffic.
# Rebooting for a sync while serving traffic would cause an outage.
if [[ -n "${STANDBY_SYNC_PRIMARY_URL}" ]]; then
    log "  Checking primary health: ${STANDBY_SYNC_PRIMARY_URL}"
    _pcode=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        "${STANDBY_SYNC_PRIMARY_URL}" 2>/dev/null || echo "0")
    if [[ "${_pcode}" == "200" || "${_pcode}" == "301" || "${_pcode}" == "302" ]]; then
        log "  Primary OK (HTTP ${_pcode}) — safe to sync."
    else
        log "  WARN: primary returned HTTP ${_pcode} — sync skipped."
        log "  Primary may be down and this standby may be serving traffic."
        log "  Sync will retry at next cron run once primary recovers."
        ntfy_send "S3 > PI: ${_NTFY_SITE}: Sync Skipped" \
            "$(hostname): sync skipped — primary health check returned HTTP ${_pcode}.
Primary may be down. Standby will not reboot for sync until primary recovers.
Will retry automatically at next cron run." \
            "default" "warning"
        exit 0
    fi
fi

# ── Confirm SD card is present ────────────────────────────────────────────────
if [[ ! -b "${STANDBY_SYNC_SD_BOOT}" ]]; then
    log "  ERROR: SD card boot partition ${STANDBY_SYNC_SD_BOOT} not found."
    log "  Is the SD card inserted? Is STANDBY_SYNC_SD_BOOT correct in config.env?"
    ntfy_send "S3 > PI: ${_NTFY_SITE}: Sync Failed" \
        "$(hostname): SD card not found at ${STANDBY_SYNC_SD_BOOT}.
Insert SD card with pi2s3 restore agent installed (run: install-standby-sync.sh)." \
        "high" "warning"
    exit 1
fi

# ── Mount SD and write restore trigger ───────────────────────────────────────
log ""
log "Writing restore trigger to SD card (${STANDBY_SYNC_SD_BOOT})..."

SD_MNT=$(mktemp -d)
_SD_MOUNTED=false

cleanup() {
    if [[ "${_SD_MOUNTED}" == "true" ]]; then
        sudo umount "${SD_MNT}" 2>/dev/null || true
    fi
    rm -rf "${SD_MNT}"
    rm -f "${MARKER_TMP}"
}
trap cleanup EXIT

if sudo mount "${STANDBY_SYNC_SD_BOOT}" "${SD_MNT}" 2>/dev/null; then
    _SD_MOUNTED=true
else
    log "  ERROR: could not mount ${STANDBY_SYNC_SD_BOOT}"
    ntfy_send "S3 > PI: ${_NTFY_SITE}: Sync Failed" \
        "$(hostname): could not mount SD card ${STANDBY_SYNC_SD_BOOT} — cannot write restore trigger." \
        "high" "warning"
    exit 1
fi

# Write trigger parameters for the SD-side restore agent
TRIGGER_FILE="${SD_MNT}/.pi2s3-sync-request"
sudo tee "${TRIGGER_FILE}" > /dev/null <<EOF
# pi2s3 standby sync trigger — written by hot-standby-sync.sh
# DO NOT edit manually. Deleted automatically after restore completes.
RESTORE_DATE="${BACKUP_DATE}"
RESTORE_HOST="${BACKUP_HOST}"
RESTORE_DEVICE="${STANDBY_SYNC_DEVICE}"
POST_RESTORE_SCRIPT="${STANDBY_POST_RESTORE_SCRIPT}"
S3_BUCKET="${S3_BUCKET}"
S3_REGION="${S3_REGION}"
S3_PREFIX="${BACKUP_PREFIX}"
STANDBY_SYNC_STATE_FILE="${STANDBY_SYNC_STATE_FILE}"
NTFY_URL="${NTFY_URL:-}"
NTFY_SITE="${_NTFY_SITE}"
WRITTEN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

log "  Trigger written: RESTORE_DATE=${BACKUP_DATE} RESTORE_DEVICE=${STANDBY_SYNC_DEVICE}"

sudo umount "${SD_MNT}"
_SD_MOUNTED=false
rm -rf "${SD_MNT}"

# ── Notify and reboot ─────────────────────────────────────────────────────────
ntfy_send "S3 > PI: ${_NTFY_SITE}: Sync Starting" \
    "$(hostname) rebooting to sync from ${BACKUP_DATE} backup.
Primary: ${BACKUP_HOST}
Source: s3://${S3_BUCKET}/${BACKUP_PREFIX}/

Standby offline ~30 min. Will notify when back up." \
    "low" "arrows_counterclockwise,floppy_disk"

log ""
log "  Rebooting to SD for restore from backup: ${BACKUP_DATE}"
log "  Standby will be offline ~30 min, then come back up with fresh data."
log "========================================================"

sudo reboot
