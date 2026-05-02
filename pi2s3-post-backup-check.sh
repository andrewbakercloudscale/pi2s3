#!/usr/bin/env bash
# =============================================================
# pi2s3-post-backup-check.sh — Post-backup container safety net
#
# Runs ~30 minutes after the nightly backup cron to verify Docker
# containers came back up after imaging. If any are still stopped,
# restarts them and sends an ntfy alert.
#
# This guards against the backup script crashing after stopping
# containers but before restarting them (e.g. OOM kill, SIGKILL,
# kernel panic during imaging).
#
# Installed automatically by install.sh when
# POST_BACKUP_CHECK_ENABLED=true in config.env.
#
# Cron example (30 min after a 2:00 AM backup):
#   30 2 * * * bash ~/pi2s3/pi2s3-post-backup-check.sh >> /var/log/pi2s3-backup.log 2>&1
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found at ${CONFIG_FILE}"
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

[[ -z "${NTFY_URL:-}" ]] && { echo "ERROR: NTFY_URL not set in config.env"; exit 1; }

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] POST-CHECK: $*"; }

ntfy_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    local extra=()
    [[ -n "$tags" ]] && extra+=(-H "Tags: $tags")
    curl -s --max-time 10 \
        -H "Title: $title" \
        -H "Priority: $priority" \
        "${extra[@]}" \
        -d "$msg" \
        "${NTFY_URL}" > /dev/null 2>&1 || true
}

# Docker not installed or daemon not running — nothing to check.
if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
    exit 0
fi

STOPPED=$(docker ps \
    --filter "status=exited" \
    --filter "status=created" \
    --filter "status=dead" \
    --format '{{.Names}}' 2>/dev/null || true)

if [[ -z "${STOPPED}" ]]; then
    log "All containers running — OK."
    exit 0
fi

# One or more containers are stopped — attempt restart and alert.
log "Found stopped containers: ${STOPPED}"
log "Attempting restart..."

RESTART_OK=true
for container in ${STOPPED}; do
    if docker start "${container}" 2>&1; then
        log "  Started: ${container}"
    else
        log "  FAILED to start: ${container}"
        RESTART_OK=false
    fi
done

if [[ "${RESTART_OK}" == "true" ]]; then
    ntfy_send "pi2s3.com post-backup alert — containers restarted" \
        "Containers were stopped after backup window on $(hostname) and have been restarted: ${STOPPED}

Backup may have crashed mid-imaging. Check: /var/log/pi2s3-backup.log" \
        "high" "warning,floppy_disk"
    log "Restart complete. Alert sent."
else
    ntfy_send "pi2s3.com ALERT — containers stuck down" \
        "URGENT: Containers stopped after backup on $(hostname) and could NOT be restarted: ${STOPPED}

Manual action required. Run: docker start ${STOPPED}
Log: /var/log/pi2s3-backup.log" \
        "urgent" "sos,floppy_disk"
    log "ERROR: some containers could not be restarted. Alert sent."
    exit 1
fi
