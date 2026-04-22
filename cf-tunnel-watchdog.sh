#!/usr/bin/env bash
set -uo pipefail
# =============================================================
# cf-tunnel-watchdog.sh — Cloudflare tunnel + site health watchdog
#
# Runs every 5 minutes via root cron (installed by install.sh).
# Checks the site is reachable locally and the Cloudflare tunnel
# has active connections. Any failure triggers escalating recovery:
#
#   Phase 1 (attempts 1–4, 0–20 min)
#     → restart cloudflared + start any stopped containers
#
#   Phase 2 (attempts 5–8, 20–40 min)
#     → full docker compose down/up + cloudflared restart
#
#   Phase 3 (attempt 9+, 40+ min)
#     → reboot Pi (rate-limited: max once per 6 hours)
#
# Recovery is confirmed by re-running all checks after each action.
# Push notifications sent via ntfy on first failure, each phase
# escalation, recovery, and stuck-down alerts.
#
# State files (all cleared on reboot except the reboot timestamp):
#   /var/run/pi2s3-watchdog.state     — attempt counter
#   /var/run/pi2s3-watchdog.lock      — prevents concurrent runs
#   /var/log/pi2s3-watchdog-reboot.ts — reboot rate-limit (survives reboots)
#   /var/log/pi2s3-watchdog-prediag.log — pre-reboot diagnostics
#
# Install:
#   bash install.sh --watchdog      (or set CF_WATCHDOG_ENABLED=true in config.env)
#
# Manual test run:
#   sudo bash ~/pi2s3/cf-tunnel-watchdog.sh
#
# Check logs:
#   sudo journalctl -t pi2s3-watchdog --since today
#   sudo journalctl -t pi2s3-watchdog -f
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found at ${CONFIG_FILE}"
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# ── Config (set in config.env) ────────────────────────────────────────────────
# Required:
#   NTFY_URL          — already set for backups, reused here
#   CF_SITE_HOSTNAME  — your site's public hostname (used in notifications)
#
# Optional (sensible defaults below):
CF_SITE_HOSTNAME="${CF_SITE_HOSTNAME:-$(hostname)}"
CF_HTTP_PORT="${CF_HTTP_PORT:-80}"
CF_HTTP_PROBE_PATH="${CF_HTTP_PROBE_PATH:-/}"
CF_METRICS_URL="${CF_METRICS_URL:-http://127.0.0.1:20241/metrics}"
CF_COMPOSE_DIR="${CF_COMPOSE_DIR:-}"
CF_PHASE1_MAX="${CF_PHASE1_MAX:-4}"
CF_PHASE2_MAX="${CF_PHASE2_MAX:-8}"
CF_REBOOT_MIN_INTERVAL="${CF_REBOOT_MIN_INTERVAL:-21600}"
# ─────────────────────────────────────────────────────────────────────────────

# Recovery timing constants (seconds)
_CONTAINER_START_SETTLE=10     # time for containers to start accepting connections
_CLOUDFLARED_SETTLE=30         # time for cloudflared to establish HA connections
_COMPOSE_DOWN_UP_PAUSE=5       # pause between compose down and up
_PHASE2_RECHECK_DELAY=20       # wait after full stack restart before re-checking

STATE_FILE="/var/run/pi2s3-watchdog.state"
LOCK_FILE="/var/run/pi2s3-watchdog.lock"
REBOOT_TS_FILE="/var/log/pi2s3-watchdog-reboot.ts"
PREDIAG_LOG="/var/log/pi2s3-watchdog-prediag.log"
WATCHDOG_BIN="/usr/local/bin/pi2s3-watchdog.sh"
LOG_TAG="pi2s3-watchdog"

# ── Stale binary check ────────────────────────────────────────────────────────
# When install.sh --watchdog copies this script to /usr/local/bin, cron runs
# the binary. If the source has been updated (git pull) but the binary hasn't
# been redeployed, log a warning so the operator knows to re-run install.sh.
if [[ "${BASH_SOURCE[0]}" == "${WATCHDOG_BIN}" ]]; then
    SOURCE_SCRIPT="$(find /home -name 'cf-tunnel-watchdog.sh' -path '*/pi2s3/*' 2>/dev/null | head -1 || true)"
    if [[ -n "${SOURCE_SCRIPT}" ]] \
       && ! diff -q "${SOURCE_SCRIPT}" "${WATCHDOG_BIN}" > /dev/null 2>&1; then
        logger -t "${LOG_TAG}" "WARNING: watchdog binary is stale — source has changed. Run: bash ${SOURCE_SCRIPT%/cf-tunnel-watchdog.sh}/install.sh --watchdog"
    fi
fi

# ── Prevent concurrent runs ───────────────────────────────────────────────────
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    logger -t "${LOG_TAG}" "Already running — skipping this tick"
    exit 0
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
ntfy_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    local extra=()
    [[ -n "${tags}" ]] && extra+=(-H "Tags: ${tags}")
    curl -s --max-time 10 \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        "${extra[@]}" \
        -d "${msg}" \
        "${NTFY_URL}" > /dev/null 2>&1 || true
}

# Run a recovery action, logging a warning if it fails (never aborts the watchdog).
run_step() {
    local _desc="$1"; shift
    local _rc=0
    "$@" 2>&1 | logger -t "${LOG_TAG}" || _rc=$?
    if [[ ${_rc} -ne 0 ]]; then
        logger -t "${LOG_TAG}" "WARNING: ${_desc} exited ${_rc}"
    fi
}

ha_connections() {
    curl -s --max-time 5 "${CF_METRICS_URL}" 2>/dev/null \
        | awk '/^cloudflared_tunnel_ha_connections/ && !/^#/ {print $2}' \
        | head -1
}

http_probe() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Cache-Control: no-cache" \
        "http://localhost:${CF_HTTP_PORT}${CF_HTTP_PROBE_PATH}" 2>/dev/null \
        || echo "ERR"
}

# Auto-detect running Docker containers (any status) for Phase 2 restart.
# If CF_COMPOSE_DIR is set, we use docker compose — otherwise docker start.
find_compose_dir() {
    # Explicitly configured
    [[ -n "${CF_COMPOSE_DIR}" && -f "${CF_COMPOSE_DIR}/docker-compose.yml" ]] \
        && echo "${CF_COMPOSE_DIR}" && return

    # Auto-detect common locations
    for candidate in \
        /opt/stack \
        /opt/docker \
        "${HOME}/stack" \
        "${HOME}/docker"; do
        [[ -f "${candidate}/docker-compose.yml" ]] && echo "${candidate}" && return
    done

    echo ""  # not found
}

diag_snapshot() {
    echo "=== PI-MI WATCHDOG DIAG: $(date) ==="
    echo "--- memory ---"
    free -m
    echo "--- docker ps ---"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Health}}' 2>/dev/null \
        || echo "(docker unavailable)"
    echo "--- cloudflared service ---"
    systemctl show cloudflared \
        --property=ActiveState,SubState,NRestarts,ExecMainStatus,MainPID \
        2>/dev/null || true
    echo "--- cloudflared metrics ---"
    curl -s --max-time 3 "${CF_METRICS_URL}" 2>/dev/null | head -20 || echo "(unavailable)"
    echo "--- recent cloudflared log ---"
    journalctl -u cloudflared -n 30 --no-pager 2>/dev/null || true
    echo "--- recent watchdog log ---"
    journalctl -t "${LOG_TAG}" -n 30 --no-pager 2>/dev/null || true
    echo "--- dmesg tail ---"
    dmesg --time-format=reltime 2>/dev/null | tail -20 || true
    echo "--- disk ---"
    df -h / 2>/dev/null || true
    echo "=== END DIAG ==="
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {

# ── Health checks ─────────────────────────────────────────────────────────────
DOWN_REASONS=()

# 1. Docker containers — any exited/dead/created containers?
STOPPED_CONTAINERS=$(docker ps \
    --filter "status=exited" \
    --filter "status=created" \
    --filter "status=dead" \
    --format '{{.Names}}' 2>/dev/null || true)
if [[ -n "${STOPPED_CONTAINERS}" ]]; then
    DOWN_REASONS+=("stopped containers: ${STOPPED_CONTAINERS}")
fi

# 2. Local HTTP probe — 5xx or connection failure triggers recovery
HTTP_CODE=$(http_probe)
if [[ "${HTTP_CODE}" == "ERR" || "${HTTP_CODE:0:1}" == "5" ]]; then
    DOWN_REASONS+=("HTTP probe on :${CF_HTTP_PORT}: ${HTTP_CODE}")
fi

# 3. Cloudflare tunnel — must have at least one HA connection
#    Skipped gracefully if metrics endpoint is unavailable (e.g. not configured)
CONNS=$(ha_connections)
METRICS_AVAILABLE=false
if curl -s --max-time 3 "${CF_METRICS_URL}" > /dev/null 2>&1; then
    METRICS_AVAILABLE=true
    if [[ -z "${CONNS}" || "${CONNS}" == "0" ]]; then
        DOWN_REASONS+=("CF ha_connections=${CONNS:-unreachable}")
    fi
else
    logger -t "${LOG_TAG}" "INFO: CF metrics not available at ${CF_METRICS_URL} — skipping tunnel check"
fi

# ── Healthy path ─────────────────────────────────────────────────────────────
if [[ ${#DOWN_REASONS[@]} -eq 0 ]]; then
    if [[ -f "${STATE_FILE}" ]]; then
        ATTEMPTS=$(cat "${STATE_FILE}")
        rm -f "${STATE_FILE}"
        logger -t "${LOG_TAG}" \
            "RECOVERED after ${ATTEMPTS} attempt(s) — ha_connections=${CONNS:-n/a}, HTTP=${HTTP_CODE}"
        ntfy_send "${CF_SITE_HOSTNAME} RESTORED" \
            "Site is back after ${ATTEMPTS} attempt(s).
ha_connections=${CONNS:-n/a} | HTTP=${HTTP_CODE}" \
            "default" "white_check_mark"
    else
        logger -t "${LOG_TAG}" \
            "OK: ha_connections=${CONNS:-n/a}, HTTP=${HTTP_CODE}"
    fi
    exit 0
fi

# ── Site is down ─────────────────────────────────────────────────────────────
REASON_STR=$(IFS='; '; echo "${DOWN_REASONS[*]}")

ATTEMPT=1
[[ -f "${STATE_FILE}" ]] && ATTEMPT=$(( $(cat "${STATE_FILE}") + 1 ))
echo "${ATTEMPT}" > "${STATE_FILE}"

DIAG_MEM=$(free -m | awk '/^Mem:/{printf "RAM: %sMiB used / %sMiB avail", $3, $7}')
DIAG_SWAP=$(free -m | awk '/^Swap:/{printf "Swap: %sMiB used / %sMiB total", $3, $2}')
DIAG_OOM=$(dmesg --time-format=reltime 2>/dev/null \
    | grep -i 'killed process\|out of memory' | tail -2 | tr '\n' ' ' || true)
DIAG_CF=$(systemctl show cloudflared \
    --property=ActiveState,SubState,NRestarts 2>/dev/null | tr '\n' ' ' || true)

logger -t "${LOG_TAG}" \
    "DOWN attempt ${ATTEMPT} — ${REASON_STR} | ${DIAG_MEM} | ${DIAG_SWAP} | CF: ${DIAG_CF}"

COMPOSE_DIR=$(find_compose_dir)

# ── Phase 1: targeted restart (attempts 1–PHASE1_MAX) ────────────────────────
if [[ "${ATTEMPT}" -le "${CF_PHASE1_MAX}" ]]; then

    if [[ "${ATTEMPT}" -eq 1 ]]; then
        ntfy_send "${CF_SITE_HOSTNAME} DOWN" \
            "Site down (attempt ${ATTEMPT}). Running targeted restart.

Reasons: ${REASON_STR}
${DIAG_MEM} | ${DIAG_SWAP}
OOM: ${DIAG_OOM:-none}
CF: ${DIAG_CF}" \
            "high" "rotating_light"
    fi

    # Start any stopped containers
    if [[ -n "${STOPPED_CONTAINERS}" ]]; then
        logger -t "${LOG_TAG}" \
            "Phase 1: starting stopped containers: ${STOPPED_CONTAINERS}"
        for container in ${STOPPED_CONTAINERS}; do
            run_step "docker start ${container}" docker start "${container}"
        done
        sleep "${_CONTAINER_START_SETTLE}"
    fi

    # Restart cloudflared if tunnel connections are the issue
    if [[ "${METRICS_AVAILABLE}" == "true" && ( -z "${CONNS}" || "${CONNS}" == "0" ) ]]; then
        logger -t "${LOG_TAG}" "Phase 1: restarting cloudflared"
        run_step "systemctl restart cloudflared" systemctl restart cloudflared
    elif ! systemctl is-active --quiet cloudflared 2>/dev/null; then
        logger -t "${LOG_TAG}" "Phase 1: cloudflared not active — starting"
        run_step "systemctl start cloudflared" systemctl start cloudflared
    fi

    sleep "${_CLOUDFLARED_SETTLE}"
    NEW_CONNS=$(ha_connections)
    NEW_HTTP=$(http_probe)
    logger -t "${LOG_TAG}" \
        "Phase 1 result: ha_connections=${NEW_CONNS:-?}, HTTP=${NEW_HTTP}"

    if { [[ "${METRICS_AVAILABLE}" == "false" ]] \
         || [[ -n "${NEW_CONNS}" && "${NEW_CONNS}" != "0" ]]; } \
       && [[ "${NEW_HTTP}" != "ERR" && "${NEW_HTTP:0:1}" != "5" ]]; then
        rm -f "${STATE_FILE}"
        logger -t "${LOG_TAG}" "Phase 1 recovery succeeded"
        ntfy_send "${CF_SITE_HOSTNAME} RESTORED" \
            "Targeted restart succeeded (attempt ${ATTEMPT}).
ha_connections=${NEW_CONNS:-n/a} | HTTP=${NEW_HTTP}" \
            "default" "white_check_mark"
    fi

# ── Phase 2: full stack restart (attempts PHASE1_MAX+1 – PHASE2_MAX) ─────────
elif [[ "${ATTEMPT}" -le "${CF_PHASE2_MAX}" ]]; then

    if [[ "${ATTEMPT}" -eq $(( CF_PHASE1_MAX + 1 )) ]]; then
        ntfy_send "${CF_SITE_HOSTNAME} still DOWN — full restart" \
            "Targeted restart failed after ${CF_PHASE1_MAX} attempts. Full Docker stack restart.

Reasons: ${REASON_STR}
${DIAG_MEM} | ${DIAG_SWAP}" \
            "high" "warning"
    fi

    logger -t "${LOG_TAG}" \
        "Phase 2: full stack restart (attempt ${ATTEMPT})"

    if [[ -n "${COMPOSE_DIR}" ]]; then
        # Preferred: docker compose down/up for clean restart
        logger -t "${LOG_TAG}" "Phase 2: docker compose down in ${COMPOSE_DIR}"
        run_step "docker compose down" \
            bash -c "cd '${COMPOSE_DIR}' && docker compose down --timeout 20"
        sleep "${_COMPOSE_DOWN_UP_PAUSE}"
        run_step "docker compose up" \
            bash -c "cd '${COMPOSE_DIR}' && docker compose up -d"
    else
        # Fallback: restart all non-running containers directly
        logger -t "${LOG_TAG}" \
            "Phase 2: no compose dir found — restarting all stopped containers"
        mapfile -t _all_containers < <(docker ps -aq 2>/dev/null || true)
        if [[ ${#_all_containers[@]} -gt 0 ]]; then
            run_step "docker start all" docker start "${_all_containers[@]}"
        fi
    fi

    sleep 20
    run_step "systemctl restart cloudflared" systemctl restart cloudflared
    sleep 30

    NEW_CONNS=$(ha_connections)
    NEW_HTTP=$(http_probe)
    logger -t "${LOG_TAG}" \
        "Phase 2 result: ha_connections=${NEW_CONNS:-?}, HTTP=${NEW_HTTP}"

    if { [[ "${METRICS_AVAILABLE}" == "false" ]] \
         || [[ -n "${NEW_CONNS}" && "${NEW_CONNS}" != "0" ]]; } \
       && [[ "${NEW_HTTP}" != "ERR" && "${NEW_HTTP:0:1}" != "5" ]]; then
        rm -f "${STATE_FILE}"
        logger -t "${LOG_TAG}" "Phase 2 recovery succeeded"
        ntfy_send "${CF_SITE_HOSTNAME} RESTORED" \
            "Full stack restart succeeded (attempt ${ATTEMPT}).
ha_connections=${NEW_CONNS:-n/a} | HTTP=${NEW_HTTP}" \
            "default" "white_check_mark"
    fi

# ── Phase 3: Pi reboot (attempt PHASE2_MAX+1 and beyond) ────────────────────
else

    NOW=$(date +%s)
    LAST_REBOOT=0
    [[ -f "${REBOOT_TS_FILE}" ]] \
        && LAST_REBOOT=$(cat "${REBOOT_TS_FILE}" 2>/dev/null || echo 0)
    SINCE_LAST=$(( NOW - LAST_REBOOT ))

    if [[ "${LAST_REBOOT}" -gt 0 \
          && "${SINCE_LAST}" -lt "${CF_REBOOT_MIN_INTERVAL}" ]]; then
        MINS_AGO=$(( SINCE_LAST / 60 ))
        logger -t "${LOG_TAG}" \
            "RATE LIMIT: rebooted ${MINS_AGO} min ago — not rebooting again yet"
        ntfy_send "${CF_SITE_HOSTNAME} STUCK DOWN — manual needed" \
            "Site down 40+ min. Watchdog rebooted ${MINS_AGO}m ago — not rebooting again.

Manual action required.
Reasons: ${REASON_STR}
Pre-reboot diag: ${PREDIAG_LOG}" \
            "urgent" "sos"
        exit 0
    fi

    logger -t "${LOG_TAG}" \
        "Phase 3: rebooting Pi (attempt ${ATTEMPT}, reasons: ${REASON_STR})"

    # Dump full diagnostics to persistent log before the reboot
    {
        echo ""
        echo "################################################################"
        echo "WATCHDOG TRIGGERED REBOOT — $(date)"
        echo "Attempt ${ATTEMPT} | Reasons: ${REASON_STR}"
        diag_snapshot
    } >> "${PREDIAG_LOG}" 2>&1

    echo "${NOW}" > "${REBOOT_TS_FILE}"

    ntfy_send "${CF_SITE_HOSTNAME} — REBOOTING Pi" \
        "Stack restart failed after ${ATTEMPT} attempts. Rebooting now.

Reasons: ${REASON_STR}
${DIAG_MEM} | ${DIAG_SWAP}
OOM: ${DIAG_OOM:-none}
Diag: ${PREDIAG_LOG}" \
        "urgent" "sos"

    # Graceful Docker shutdown (best-effort, 20 s)
    if [[ -n "${COMPOSE_DIR}" ]]; then
        run_step "pre-reboot docker compose down" \
            timeout 20 bash -c "cd '${COMPOSE_DIR}' && docker compose down --timeout 15"
    fi
    sync

    sudo reboot
fi

} # end main

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
