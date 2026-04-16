#!/usr/bin/env bash
# =============================================================
# pi2s3-heartbeat.sh — Daily "I'm alive" ping to ntfy
#
# Runs once a day via cron (installed by install.sh if
# NTFY_HEARTBEAT_ENABLED=true in config.env).
#
# Sends a low-priority push notification with uptime, memory,
# disk usage, and Docker container count. If this notification
# stops arriving, the Pi is down or unreachable.
#
# Install:
#   Set NTFY_HEARTBEAT_ENABLED=true in config.env
#   bash install.sh  (or bash install.sh --watchdog to reinstall)
#
# Manual run:
#   bash ~/pi2s3/pi2s3-heartbeat.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

[[ ! -f "${CONFIG_FILE}" ]] && exit 0   # silently exit if not configured

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# Respect the enabled flag — safe to run even if disabled (cron may fire anyway)
[[ "${NTFY_HEARTBEAT_ENABLED:-false}" != "true" ]] && exit 0
[[ -z "${NTFY_URL:-}" ]] && exit 0

# ── Gather system info ────────────────────────────────────────────────────────
HOST=$(hostname)
NOW=$(date '+%Y-%m-%d %H:%M')
UPTIME=$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "unknown")

MEM_USED=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
MEM_INFO="${MEM_USED}MiB / ${MEM_TOTAL}MiB used"

ROOT_USAGE=$(df -h / 2>/dev/null | tail -1 | awk '{print $3 " / " $2 " (" $5 ")"}')
NVME_INFO=""
mountpoint -q /mnt/nvme 2>/dev/null \
    && NVME_INFO=$'\n'"NVMe:    $(df -h /mnt/nvme 2>/dev/null | tail -1 | awk '{print $3 " / " $2 " (" $5 ")"}')"

CONTAINER_COUNT=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
CONTAINER_INFO="${CONTAINER_COUNT} container(s) running"
STOPPED_COUNT=$(docker ps -q --filter status=exited 2>/dev/null | wc -l | tr -d ' ')
[[ "${STOPPED_COUNT}" -gt 0 ]] && CONTAINER_INFO+=" (${STOPPED_COUNT} stopped)"

LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")

# ── Send notification ─────────────────────────────────────────────────────────
MSG="${NOW}
Uptime: ${UPTIME}
RAM:     ${MEM_INFO}
Disk:    ${ROOT_USAGE}${NVME_INFO}
Docker:  ${CONTAINER_INFO}
Load:    ${LOAD}"

curl -s --max-time 10 \
    -H "Title: ${HOST} — alive" \
    -H "Priority: min" \
    -H "Tags: white_check_mark" \
    -d "${MSG}" \
    "${NTFY_URL}" > /dev/null 2>&1

exit 0
