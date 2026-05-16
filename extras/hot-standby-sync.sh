#!/usr/bin/env bash
# =============================================================
# extras/hot-standby-sync.sh — Daily sync for hot standby Pi
#
# Runs on the STANDBY Pi via cron (every 30 min).
# Detects a sync-ready marker written to S3 by the primary Pi
# after each successful backup, then kicks off a restore cycle:
#
#   1. Reads s3://BUCKET/STANDBY_SYNC_MARKER_KEY (JSON)
#   2. Mounts SD to compare backup_date with last-synced state
#   3. Optionally checks that primary is up (safety guard)
#   4. Writes a restore trigger file (.pi2s3-sync-request) to SD
#   5. Reboots — the SD firstboot agent auto-restores NVMe then reboots back
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

# ── Log redirect (early — captures all subsequent errors) ─────────────────────
LOG_FILE="/var/log/pi2s3-standby-sync.log"
[[ -f "${LOG_FILE}" ]] || touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/tmp/pi2s3-standby-sync.log"
exec >> "${LOG_FILE}" 2>&1

# ── Single-instance guard (flock) ─────────────────────────────────────────────
LOCK_FILE="/var/lock/pi2s3-standby-sync.lock"
exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "$(date): already running — skipping"; exit 0; }

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found at ${CONFIG_FILE}"
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
[[ -z "${S3_BUCKET:-}"   ]] && { echo "ERROR: S3_BUCKET not set";  exit 1; }
[[ -z "${S3_REGION:-}"   ]] && { echo "ERROR: S3_REGION not set";  exit 1; }
[[ -z "${AWS_PROFILE:-}" ]] && unset AWS_PROFILE || true

_NTFY_SITE="${CF_SITE_HOSTNAME:-$(hostname -s)}"

# ── Guard ─────────────────────────────────────────────────────────────────────
[[ "${HOT_STANDBY_SYNC_ENABLED}" == "true" ]] || exit 0

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

# ── Shared state (cleanup registered before any mktemp calls) ─────────────────
MARKER_TMP=""
S3_ERR_TMP=""
SD_MNT=""
_SD_MOUNTED=false

cleanup() {
    [[ "${_SD_MOUNTED}" == "true" ]] && sudo umount "${SD_MNT}" 2>/dev/null || true
    [[ -n "${SD_MNT}"       ]] && rm -rf "${SD_MNT}"
    rm -f "${MARKER_TMP:-}" "${S3_ERR_TMP:-}"
}
trap cleanup EXIT

MARKER_TMP=$(mktemp)
S3_ERR_TMP=$(mktemp)

# ── Read S3 sync marker ───────────────────────────────────────────────────────
log "Checking S3 for sync marker: s3://${S3_BUCKET}/${STANDBY_SYNC_MARKER_KEY}"
if ! aws_cmd s3 cp "s3://${S3_BUCKET}/${STANDBY_SYNC_MARKER_KEY}" "${MARKER_TMP}" 2>"${S3_ERR_TMP}"; then
    _err_txt=$(cat "${S3_ERR_TMP}")
    if echo "${_err_txt}" | grep -qiE "NoSuchKey|404|does not exist"; then
        log "  No sync marker found — nothing to sync."
        exit 0
    fi
    log "  ERROR: S3 download failed (check credentials/config — this is not a missing key):"
    log "  ${_err_txt}"
    ntfy_send "S3 > PI: ${_NTFY_SITE}: Sync Error" \
        "$(hostname): S3 marker download failed — check AWS credentials/config.
Error: ${_err_txt}" \
        "high" "warning"
    exit 1
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

# ── Read last-synced state from SD (state survives NVMe restores) ─────────────
# The restore agent writes .pi2s3-last-synced to the SD boot partition (FAT).
# Reading it here avoids a false "new backup" trigger after every reboot.
log "  Mounting SD to read last-synced state..."
SD_MNT=$(mktemp -d)
LAST_SYNCED=""

if sudo mount "${STANDBY_SYNC_SD_BOOT}" "${SD_MNT}" 2>/dev/null; then
    _SD_MOUNTED=true
    LAST_SYNCED=$(cat "${SD_MNT}/.pi2s3-last-synced" 2>/dev/null | tr -d '[:space:]' || true)
else
    log "  WARN: could not mount SD to read sync state — treating as never-synced."
fi

if [[ -n "${LAST_SYNCED}" && "${LAST_SYNCED}" == "${BACKUP_DATE}" ]]; then
    log "  Already synced to ${BACKUP_DATE} — nothing to do."
    [[ "${_SD_MOUNTED}" == "true" ]] && { sudo umount "${SD_MNT}"; _SD_MOUNTED=false; }
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
        [[ "${_SD_MOUNTED}" == "true" ]] && { sudo umount "${SD_MNT}"; _SD_MOUNTED=false; }
        ntfy_send "S3 > PI: ${_NTFY_SITE}: Sync Skipped" \
            "$(hostname): sync skipped — primary health check returned HTTP ${_pcode}.
Primary may be down. Standby will not reboot for sync until primary recovers.
Will retry automatically at next cron run." \
            "default" "warning"
        exit 0
    fi
fi

# ── Mount SD (if not already from state check) and write restore trigger ──────
log ""
log "Writing restore trigger to SD card (${STANDBY_SYNC_SD_BOOT})..."

if [[ "${_SD_MOUNTED}" != "true" ]]; then
    if ! sudo mount "${STANDBY_SYNC_SD_BOOT}" "${SD_MNT}" 2>/dev/null; then
        log "  ERROR: could not mount ${STANDBY_SYNC_SD_BOOT}"
        ntfy_send "S3 > PI: ${_NTFY_SITE}: Sync Failed" \
            "$(hostname): could not mount SD card ${STANDBY_SYNC_SD_BOOT} — cannot write restore trigger." \
            "high" "warning"
        exit 1
    fi
    _SD_MOUNTED=true
fi

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
WRITTEN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

log "  Trigger written: RESTORE_DATE=${BACKUP_DATE} RESTORE_DEVICE=${STANDBY_SYNC_DEVICE}"

sudo umount "${SD_MNT}"
_SD_MOUNTED=false

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
