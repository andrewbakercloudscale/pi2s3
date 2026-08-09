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

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/notify.sh
source "${SCRIPT_DIR}/lib/notify.sh"

# Respect the enabled flag — safe to run even if disabled (cron may fire anyway)
# TG_HEARTBEAT_ENABLED is the current name; NTFY_HEARTBEAT_ENABLED is honoured so an
# existing ntfy install keeps working after this upgrade without editing config.env.
_HB_ENABLED="${TG_HEARTBEAT_ENABLED:-${NTFY_HEARTBEAT_ENABLED:-false}}"
[[ "${_HB_ENABLED}" != "true" ]] && exit 0

# ── Gather system info ────────────────────────────────────────────────────────
HOST="${CF_SITE_HOSTNAME:-$(hostname)}"
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

# Sent through the shared notifier so the heartbeat reaches whichever transport this
# host is configured for. It used to curl NTFY_URL directly, so on a Telegram host it
# posted to an empty URL every morning and failed silently — the one message whose
# entire job is to prove the alerting path still works.
notify_send "pi2s3: Heartbeat" "${MSG}" "min" "white_check_mark"

exit 0
