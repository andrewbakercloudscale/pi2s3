#!/usr/bin/env bash
# -e intentionally omitted: watchdog must survive partial check failures and continue recovery phases
set -uo pipefail
# =============================================================
# cf-tunnel-watchdog.sh — Cloudflare tunnel + site health watchdog
#
# Runs every 5 minutes via root cron (installed by install.sh).
#
# Checks, in order:
#   1. the site's containers are all running
#   2. a local HTTP probe returns something other than 5xx/ERR
#   3. the Cloudflare tunnel has at least one HA connection
#
# Any failure triggers escalating recovery:
#
#   Phase 0 (attempt 1, HTTP bad but containers up)
#     → OPcache reset + PHP-FPM graceful reload, then re-check
#
#   Phase 1 (attempts 1–4, 0–20 min)
#     → restart cloudflared + start any stopped containers
#     → restart the web container if HTTP is still bad
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
#   /var/log/pi2s3-watchdog-incidents/incident-*.log — full snapshot at first
#                                       detection, 20 kept, sent as an attachment
#
# HISTORY
# -------
# This is the merge of two scripts that both claimed this job on andrew-pi-5.
# /usr/local/bin/cloudflared-watchdog.sh was the one root cron actually ran, and it
# was the better of the two: it had Phase 0, it scoped its container check to the
# site's own containers, and it captured an incident snapshot at first detection. It
# earned that reputation on six real incidents (Jun 15, Jul 4, Aug 3, Aug 16, Aug 21
# and Sep 1 2026). But it existed only on the Pi — in no repository — and it posted
# to a hardcoded public ntfy topic that this fleet stopped reading when it moved to
# Telegram, so not one of those six alerts reached anybody.
#
# The versioned script here was config-driven and correctly wired to the notifier,
# and was in cron nowhere. Its container check was also actively dangerous on this
# host: see the CF_REQUIRED_CONTAINERS notes below.
#
# Neither was safe to keep. This file is the union, and it is the only one installed.
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

# Locate the pi2s3 checkout: the one that holds config.env, and with it lib/notify.sh.
#
# install.sh --watchdog copies this single file to /usr/local/bin, so for the copy
# that cron actually runs SCRIPT_DIR is /usr/local/bin — which holds neither. Looking
# only beside the script therefore worked in the repo and nowhere else. The candidates
# below are tried in order and the first with a config.env wins, so an install that
# already works keeps the directory it is already using.
PI2S3_DIR=""
for _cand in "${SCRIPT_DIR}" "$(dirname "${SCRIPT_DIR}")" \
             "$(find /home -maxdepth 4 -name 'cf-tunnel-watchdog.sh' -path '*/pi2s3/*' 2>/dev/null \
                | head -1 | xargs -r dirname | xargs -r dirname)"; do
    [[ -n "${_cand}" && -f "${_cand}/config.env" ]] && { PI2S3_DIR="${_cand}"; break; }
done

if [[ -z "${PI2S3_DIR}" ]]; then
    echo "ERROR: config.env not found (looked in ${SCRIPT_DIR}, its parent, and /home/*/pi2s3)"
    exit 1
fi
CONFIG_FILE="${PI2S3_DIR}/config.env"

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# Notifications go through the shared notifier. This script kept a private ntfy_send()
# hard-wired to NTFY_URL, so on a Telegram host every tunnel alert it raised — Down,
# Stuck Down, Restored, Rebooting — was curled at an empty URL and swallowed by
# `|| true`. That is the alert path for the machine being unreachable, muted on the
# exact configuration this fleet runs.
#
# It also gives every title the site name, which matters more here than anywhere:
# "pi2s3: Tunnel Down" does not say whose tunnel.
if [[ -f "${PI2S3_DIR}/lib/notify.sh" ]]; then
    # shellcheck disable=SC1090
    source "${PI2S3_DIR}/lib/notify.sh"
else
    echo "ERROR: ${PI2S3_DIR}/lib/notify.sh not found — refusing to run a watchdog that cannot alert"
    exit 1
fi

# notify.sh logs through log(); this script's log destination is the journal.
log() { logger -t "${LOG_TAG:-pi2s3-watchdog}" "$*"; }

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

# Which containers count as "the site".
#
# THIS IS THE SETTING THAT MATTERS. The versioned watchdog checked *every* container
# on the host for an exited/dead status and treated any hit as the site being down —
# and "the site is down" escalates, within 40 minutes, to rebooting the Pi. On
# andrew-pi-5 that is five site containers (project andrewbakerninja-pi) sharing the
# box with three unrelated ones (cs_wordpress, cs_nginx, cs_analytics). A stopped
# analytics container would have rebooted the production web host.
#
# Resolution order:
#   1. CF_REQUIRED_CONTAINERS — explicit space-separated names, always wins.
#   2. the Compose project — every container labelled with this stack's project.
#      This is the right answer and needs no configuration: it is exactly "the
#      containers this site is made of". It also catches pi_auth, which the hardcoded
#      four-name list in cloudflared-watchdog.sh silently omitted.
#   3. every container on the host, which is the legacy behaviour and is logged as a
#      warning each time, because on a shared host it is a foot-gun.
CF_REQUIRED_CONTAINERS="${CF_REQUIRED_CONTAINERS:-}"
CF_COMPOSE_PROJECT="${CF_COMPOSE_PROJECT:-}"

# The container whose PHP-FPM Phase 0 reloads, and which Phase 1 restarts when HTTP
# is still bad after everything else has been tried.
CF_WEB_CONTAINER="${CF_WEB_CONTAINER:-pi_wordpress}"

CF_PHASE1_MAX="${CF_PHASE1_MAX:-4}"
CF_PHASE2_MAX="${CF_PHASE2_MAX:-8}"
CF_REBOOT_MIN_INTERVAL="${CF_REBOOT_MIN_INTERVAL:-21600}"
# ─────────────────────────────────────────────────────────────────────────────

# Recovery timing constants (seconds)
_CONTAINER_START_SETTLE=10     # time for containers to start accepting connections
_CLOUDFLARED_SETTLE=30         # time for cloudflared to establish HA connections
_COMPOSE_DOWN_UP_PAUSE=5       # pause between compose down and up
_PHASE2_RECHECK_DELAY=20       # wait after full stack restart before re-checking
_FPM_RELOAD_SETTLE=20          # time for FPM workers to drain and be replaced
_INCIDENT_LOGS_KEPT=20         # incident snapshots retained

STATE_FILE="/var/run/pi2s3-watchdog.state"
LOCK_FILE="/var/run/pi2s3-watchdog.lock"
REBOOT_TS_FILE="/var/log/pi2s3-watchdog-reboot.ts"
PREDIAG_LOG="/var/log/pi2s3-watchdog-prediag.log"
INCIDENT_LOG_DIR="/var/log/pi2s3-watchdog-incidents"
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
# ntfy_send() is lib/notify.sh's alias for notify_send(), so the call sites below
# read unchanged while gaining Telegram support and the site-tagged title.

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

# The Compose project this stack belongs to. Compose defaults the project name to the
# basename of its directory, but the label on a running container is what Docker
# actually filters on, so prefer that and fall back to the basename.
compose_project() {
    [[ -n "${CF_COMPOSE_PROJECT}" ]] && { echo "${CF_COMPOSE_PROJECT}"; return; }
    local dir proj=""
    dir="$(find_compose_dir)"
    [[ -z "${dir}" ]] && { echo ""; return; }
    proj="$(docker ps -a --filter "label=com.docker.compose.project.working_dir=${dir}" \
            --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | head -1 || true)"
    [[ -z "${proj}" ]] && proj="$(basename "${dir}")"
    echo "${proj}"
}

# Containers that are supposed to be running but are not. Scoped per the
# CF_REQUIRED_CONTAINERS notes above — this is what decides whether the watchdog is
# looking at the site or at everything on the box.
stopped_site_containers() {
    local filters=() name proj
    if [[ -n "${CF_REQUIRED_CONTAINERS}" ]]; then
        for name in ${CF_REQUIRED_CONTAINERS}; do
            filters+=(--filter "name=^/${name}$")
        done
    else
        proj="$(compose_project)"
        if [[ -n "${proj}" ]]; then
            filters+=(--filter "label=com.docker.compose.project=${proj}")
        else
            logger -t "${LOG_TAG}" \
                "WARNING: no CF_REQUIRED_CONTAINERS and no Compose project found — checking EVERY container on this host. On a shared host an unrelated stopped container will escalate to a reboot. Set CF_REQUIRED_CONTAINERS in config.env."
        fi
    fi
    docker ps "${filters[@]}" \
        --filter "status=exited" \
        --filter "status=created" \
        --filter "status=dead" \
        --format '{{.Names}}' 2>/dev/null || true
}

# Phase 0 — OPcache reset + PHP-FPM graceful reload.
#
# The fastest fix for a PHP segfault cycle, and the only one that does not drop
# in-flight requests: USR2 to PID 1 (the FPM master inside the container) lets workers
# drain before they are replaced. Worth trying before anything is restarted, but only
# when HTTP is the complaint and every container is still up — reloading FPM in a
# container that is not running achieves nothing.
fpm_soft_reset() {
    logger -t "${LOG_TAG}" "Phase 0: soft FPM reset (OPcache + graceful reload) on ${CF_WEB_CONTAINER}"
    run_step "opcache_reset" docker exec "${CF_WEB_CONTAINER}" php -r 'opcache_reset();'
    run_step "FPM graceful reload" docker exec "${CF_WEB_CONTAINER}" kill -USR2 1
    sleep "${_FPM_RELOAD_SETTLE}"

    local soft_http soft_conns
    soft_http="$(http_probe)"
    soft_conns="$(ha_connections)"
    logger -t "${LOG_TAG}" "Phase 0 result: ha_connections=${soft_conns:-?}, HTTP=${soft_http}"

    if { [[ "${METRICS_AVAILABLE}" == "false" ]] \
         || [[ -n "${soft_conns}" && "${soft_conns}" != "0" ]]; } \
       && [[ "${soft_http}" != "ERR" && "${soft_http:0:1}" != "5" ]]; then
        rm -f "${STATE_FILE}"
        logger -t "${LOG_TAG}" "Phase 0 soft recovery succeeded"
        ntfy_send "pi2s3: Tunnel Restored" \
            "OPcache reset + FPM graceful reload recovered the site (attempt ${ATTEMPT}).
ha_connections=${soft_conns:-n/a} | HTTP=${soft_http}" \
            "default" "white_check_mark"
        return 0
    fi
    return 1
}

# Capture the crash state at FIRST detection and send it.
#
# The pre-reboot dump only fires after 40+ minutes, by which time whatever killed the
# site has usually been restarted away. This snapshot is the one taken while the
# evidence still exists, so it is written to disk AND delivered as an attachment.
write_incident_log() {
    mkdir -p "${INCIDENT_LOG_DIR}"
    INCIDENT_LOG="${INCIDENT_LOG_DIR}/incident-$(date +%Y%m%d-%H%M%S).log"
    {
        echo "################################################################"
        echo "WATCHDOG INCIDENT — $(date)"
        echo "Site: $(notify_site)"
        echo "Reasons: ${REASON_STR}"
        echo "${DIAG_MEM} | ${DIAG_SWAP}"
        echo "OOM: ${DIAG_OOM:-none}"
        echo "CF state: ${DIAG_CF}"
        diag_snapshot
    } > "${INCIDENT_LOG}" 2>&1
    # shellcheck disable=SC2012
    ls -t "${INCIDENT_LOG_DIR}"/incident-*.log 2>/dev/null \
        | tail -n +$(( _INCIDENT_LOGS_KEPT + 1 )) | xargs -r rm -f 2>/dev/null || true
    echo "${INCIDENT_LOG}"
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

# 1. Docker containers — any of THE SITE'S containers exited/dead/created?
STOPPED_CONTAINERS=$(stopped_site_containers)
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
        ntfy_send "pi2s3: Tunnel Restored" \
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
        INCIDENT_LOG="$(write_incident_log)"

        # Compact extras for the message body; the full snapshot follows as a file.
        DIAG_DOCKER=$(docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null \
            | head -8 | sed 's/^/  /' || echo "  (docker unavailable)")
        DIAG_CF_LOG=$(journalctl -u cloudflared -n 4 --no-pager -o short 2>/dev/null \
            | tail -4 | sed 's/^/  /' || true)

        ntfy_send "pi2s3: Tunnel Down" \
            "Site down (attempt ${ATTEMPT}). Running targeted restart.

Reasons: ${REASON_STR}
${DIAG_MEM} | ${DIAG_SWAP}
OOM: ${DIAG_OOM:-none}
CF: ${DIAG_CF}

Containers:
${DIAG_DOCKER}

cloudflared (last 4 lines):
${DIAG_CF_LOG}" \
            "high" "rotating_light"

        notify_file "pi2s3: Incident Log" "${INCIDENT_LOG}" "page_facing_up" || true

        # Phase 0 before anything is restarted — see fpm_soft_reset().
        if [[ "${HTTP_CODE}" == "ERR" || "${HTTP_CODE:0:1}" == "5" ]] \
           && [[ -z "${STOPPED_CONTAINERS}" ]]; then
            if fpm_soft_reset; then
                exit 0
            fi
        fi
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

    # If HTTP is still bad and the web container IS running, restart it. This covers
    # a PHP crash that survives the graceful reload Phase 0 already tried.
    CURRENT_HTTP=$(http_probe)
    if [[ "${CURRENT_HTTP}" == "ERR" || "${CURRENT_HTTP:0:1}" == "5" ]] \
       && docker ps --filter "name=^/${CF_WEB_CONTAINER}$" --filter "status=running" \
            --format '{{.Names}}' 2>/dev/null | grep -q .; then
        logger -t "${LOG_TAG}" \
            "Phase 1: HTTP still ${CURRENT_HTTP} — restarting ${CF_WEB_CONTAINER}"
        run_step "docker restart ${CF_WEB_CONTAINER}" docker restart "${CF_WEB_CONTAINER}"
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
        ntfy_send "pi2s3: Tunnel Restored" \
            "Targeted restart succeeded (attempt ${ATTEMPT}).
ha_connections=${NEW_CONNS:-n/a} | HTTP=${NEW_HTTP}" \
            "default" "white_check_mark"
    fi

# ── Phase 2: full stack restart (attempts PHASE1_MAX+1 – PHASE2_MAX) ─────────
elif [[ "${ATTEMPT}" -le "${CF_PHASE2_MAX}" ]]; then

    if [[ "${ATTEMPT}" -eq $(( CF_PHASE1_MAX + 1 )) ]]; then
        ntfy_send "pi2s3: Tunnel Down — Restarting" \
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
        ntfy_send "pi2s3: Tunnel Restored" \
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
        ntfy_send "pi2s3: Tunnel Stuck Down" \
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

    ntfy_send "pi2s3: Rebooting" \
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
