#!/bin/bash
# fpm-saturation-monitor.sh
# Host-cron monitor: detects PHP-FPM worker pool exhaustion and alerts via ntfy.sh.
# Add to crontab: * * * * * /home/pi/pi2s3/fpm-saturation-monitor.sh 2>/dev/null
#
# Config vars (all in config.env — see FPM_* section):
#   FPM_SATURATION_THRESHOLD  consecutive saturated checks before alerting (default: 3)
#   FPM_PROBE_URL             HTTP endpoint to probe — should be fast/cached (default: http://localhost:8082/)
#   FPM_PROBE_TIMEOUT         curl timeout in seconds (default: 5)
#   FPM_WP_CONTAINER          WordPress container name (default: pi_wordpress)
#   FPM_DB_CONTAINER          MariaDB container name (default: pi_mariadb)
#   FPM_ALERT_COOLDOWN        seconds between repeat alerts (default: 1800)
#   NTFY_URL                  ntfy.sh topic URL (shared with pi2s3 config)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

NTFY_URL="${NTFY_URL:-}"
FPM_PROBE_URL="${FPM_PROBE_URL:-http://localhost:8082/}"
FPM_PROBE_TIMEOUT="${FPM_PROBE_TIMEOUT:-5}"
FPM_SATURATION_THRESHOLD="${FPM_SATURATION_THRESHOLD:-3}"
FPM_WP_CONTAINER="${FPM_WP_CONTAINER:-pi_wordpress}"
FPM_DB_CONTAINER="${FPM_DB_CONTAINER:-pi_mariadb}"
FPM_ALERT_COOLDOWN="${FPM_ALERT_COOLDOWN:-1800}"
FPM_DB_ROOT_PASSWORD="${FPM_DB_ROOT_PASSWORD:-}"
FPM_CALLBACK_URL="${FPM_CALLBACK_URL:-}"
FPM_CALLBACK_TOKEN="${FPM_CALLBACK_TOKEN:-}"
FPM_AUTO_RESTART="${FPM_AUTO_RESTART:-false}"
FPM_RESTART_COOLDOWN="${FPM_RESTART_COOLDOWN:-1200}"

STATE_FILE="/tmp/fpm-saturation-count"
ALERTED_FILE="/tmp/fpm-saturation-alerted"
LOCK_ALERTED_FILE="/tmp/fpm-lock-alerted"
RESTART_FILE="/tmp/fpm-auto-restart"

# ── Check 1: HTTP probe ───────────────────────────────────────────────────────
http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time "${FPM_PROBE_TIMEOUT}" \
    "${FPM_PROBE_URL}" 2>/dev/null || echo "0")

http_ok=false
[[ "$http_code" =~ ^[23] ]] && http_ok=true

# ── Check 2: Long-running DB queries (>15 s from wordpress user) ─────────────
db_stuck=0
if [[ -z "${FPM_DB_ROOT_PASSWORD}" ]] && docker ps --format '{{.Names}}' 2>/dev/null \
        | grep -q "^${FPM_DB_CONTAINER}$"; then
    FPM_DB_ROOT_PASSWORD=$(docker exec "${FPM_DB_CONTAINER}" env 2>/dev/null \
        | grep -E "^MYSQL_ROOT_PASSWORD=" | cut -d= -f2- | head -1 || true)
fi
if [[ -n "${FPM_DB_ROOT_PASSWORD}" ]]; then
    db_stuck=$(docker exec "${FPM_DB_CONTAINER}" mariadb \
        -uroot -p"${FPM_DB_ROOT_PASSWORD}" --batch --silent 2>/dev/null \
        -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST
            WHERE TIME > 15 AND USER = 'wordpress';" \
        | tail -1 || echo "0")
fi

# ── Detect orphaned backup lock ───────────────────────────────────────────────
backup_lock=false
if [[ -n "${FPM_DB_ROOT_PASSWORD}" ]]; then
    lock_count=$(docker exec "${FPM_DB_CONTAINER}" mariadb \
        -uroot -p"${FPM_DB_ROOT_PASSWORD}" --batch --silent 2>/dev/null \
        -e "SELECT COUNT(*) FROM information_schema.PROCESSLIST
            WHERE INFO LIKE '%/* pi2s3-lock */%' AND TIME > 5;" \
        | tail -1 || echo "0")
    if [[ "${lock_count:-0}" -gt 0 ]]; then
        backup_lock=true
    fi
fi

# ── Determine saturation ──────────────────────────────────────────────────────
saturated=false
reason=""
if ! $http_ok; then
    saturated=true
    reason="HTTP probe timed out (${FPM_PROBE_TIMEOUT}s) — code ${http_code}"
fi
if [[ "${db_stuck:-0}" -gt 10 ]]; then
    saturated=true
    reason="${reason:+${reason}; }${db_stuck} DB queries stuck >15s"
fi

# ── Orphaned backup lock: kill only if backup is not actively running ─────────
if $backup_lock; then
    lock_ids=$(docker exec "${FPM_DB_CONTAINER}" mariadb \
        -uroot -p"${FPM_DB_ROOT_PASSWORD}" --batch --silent 2>/dev/null \
        -e "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%/* pi2s3-lock */%' AND TIME > 5;" \
        | tr '\n' ' ' || true)

    # If pi-image-backup.sh is actively running, the lock is legitimate — leave it alone.
    if pgrep -f "pi-image-backup.sh" > /dev/null 2>&1; then
        backup_lock=false
    else
        for lid in $lock_ids; do
            docker exec "${FPM_DB_CONTAINER}" mariadb \
                -uroot -p"${FPM_DB_ROOT_PASSWORD}" --batch --silent 2>/dev/null \
                -e "KILL ${lid};" || true
        done
        # Alert with 30-min cooldown
        now=$(date +%s)
        last_lock_alert=$(cat "$LOCK_ALERTED_FILE" 2>/dev/null || echo 0)
        if [[ $((now - last_lock_alert)) -gt 1800 ]]; then
            if [[ -n "$NTFY_URL" ]]; then
                curl -s -X POST "$NTFY_URL" \
                    -H "Title: Orphaned backup lock killed (andrewbaker.ninja)" \
                    -H "Priority: high" \
                    -H "Tags: warning" \
                    -d "Orphaned pi2s3 DB lock detected and killed (conn ${lock_ids}). All writes unblocked. Will not alert again for 30 min." \
                    2>/dev/null || true
            fi
            echo "$now" > "$LOCK_ALERTED_FILE"
        fi
    fi
fi

# ── Update consecutive counter ────────────────────────────────────────────────
if $saturated; then
    count=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$STATE_FILE"
else
    # Recovered — if we were previously alerted, send a recovery notice
    prev=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if [[ "$prev" -ge "$FPM_SATURATION_THRESHOLD" ]]; then
        if [[ -n "$NTFY_URL" ]]; then
            curl -s -X POST "$NTFY_URL" \
                -H "Title: PHP-FPM recovered: andrewbaker.ninja" \
                -H "Priority: low" \
                -H "Tags: white_check_mark" \
                -d "Workers no longer saturated. DB stuck queries: ${db_stuck}." \
                2>/dev/null || true
        fi
        if [[ -n "${FPM_CALLBACK_URL}" && -n "${FPM_CALLBACK_TOKEN}" ]]; then
            curl -s -X POST "${FPM_CALLBACK_URL}" \
                --data-urlencode "action=csdt_fpm_report" \
                --data-urlencode "token=${FPM_CALLBACK_TOKEN}" \
                --data-urlencode "type=recovered" \
                --data-urlencode "msg=Workers no longer saturated. DB stuck queries: ${db_stuck}." \
                2>/dev/null || true
        fi
    fi
    echo "0" > "$STATE_FILE"
    rm -f "$ALERTED_FILE"
    exit 0
fi

# ── Alert if threshold exceeded ───────────────────────────────────────────────
count=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
if [[ "$count" -ge "$FPM_SATURATION_THRESHOLD" ]]; then
    last_alert=$(cat "$ALERTED_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [[ $((now - last_alert)) -gt "$FPM_ALERT_COOLDOWN" ]]; then
        if [[ "${FPM_AUTO_RESTART}" == "true" ]]; then
            alert_action="Auto-restarting ${FPM_WP_CONTAINER} now."
        else
            alert_action="SSH and run: docker restart ${FPM_WP_CONTAINER}"
        fi
        if [[ -n "$NTFY_URL" ]]; then
            curl -s -X POST "$NTFY_URL" \
                -H "Title: PHP-FPM SATURATED: andrewbaker.ninja" \
                -H "Priority: urgent" \
                -H "Tags: fire,rotating_light" \
                -d "All PHP workers exhausted for ${count} consecutive checks (${count} min). Reason: ${reason}. ${alert_action}" \
                2>/dev/null || true
        fi
        if [[ -n "${FPM_CALLBACK_URL}" && -n "${FPM_CALLBACK_TOKEN}" ]]; then
            curl -s -X POST "${FPM_CALLBACK_URL}" \
                --data-urlencode "action=csdt_fpm_report" \
                --data-urlencode "token=${FPM_CALLBACK_TOKEN}" \
                --data-urlencode "type=saturated" \
                --data-urlencode "msg=Workers exhausted for ${count} consecutive checks. ${reason}" \
                2>/dev/null || true
        fi
        echo "$now" > "$ALERTED_FILE"
    fi

    # ── Auto-restart on saturation ────────────────────────────────────────────
    if [[ "${FPM_AUTO_RESTART}" == "true" ]]; then
        last_restart=$(cat "$RESTART_FILE" 2>/dev/null || echo 0)
        now=$(date +%s)
        if [[ $((now - last_restart)) -gt "${FPM_RESTART_COOLDOWN}" ]]; then
            # Kill any orphaned mariadb lock from inside the container before restarting.
            # Killing the host-side docker exec wrapper does not terminate the mariadb
            # process inside the container — it must be killed from within.
            if [[ -n "${FPM_DB_ROOT_PASSWORD}" ]]; then
                docker exec "${FPM_DB_CONTAINER}" pkill -9 -f "pi2s3-lock" 2>/dev/null || true
            fi
            docker restart "${FPM_WP_CONTAINER}" 2>/dev/null || true
            echo "$now" > "$RESTART_FILE"
            if [[ -n "$NTFY_URL" ]]; then
                curl -s -X POST "$NTFY_URL" \
                    -H "Title: PHP-FPM auto-restarted: andrewbaker.ninja" \
                    -H "Priority: high" \
                    -H "Tags: arrows_counterclockwise" \
                    -d "${FPM_WP_CONTAINER} restarted automatically after ${count} consecutive saturated checks. Reason: ${reason}. Next auto-restart available in $((FPM_RESTART_COOLDOWN / 60)) min." \
                    2>/dev/null || true
            fi
            if [[ -n "${FPM_CALLBACK_URL}" && -n "${FPM_CALLBACK_TOKEN}" ]]; then
                curl -s -X POST "${FPM_CALLBACK_URL}" \
                    --data-urlencode "action=csdt_fpm_report" \
                    --data-urlencode "token=${FPM_CALLBACK_TOKEN}" \
                    --data-urlencode "type=restarted" \
                    --data-urlencode "msg=${FPM_WP_CONTAINER} auto-restarted after ${count} consecutive saturated checks. ${reason}" \
                    2>/dev/null || true
            fi
        fi
    fi
fi
