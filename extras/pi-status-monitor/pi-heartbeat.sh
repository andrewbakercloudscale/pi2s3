#!/usr/bin/env bash
# =============================================================
# pi-heartbeat.sh — 60-second rolling status line
#
# Writes one compact line per minute to /dev/tty1 (physical
# screen) covering the vitals useful for debugging a Pi:
#   time, network, voltage, HTTP probe, disk, memory, load, temp
#
# Runs continuously via pi-heartbeat.service.
#
# Install: bash extras/pi-status-monitor/setup.sh
# =============================================================
INTERVAL=60

# Optional: set HEARTBEAT_HTTP_URL in environment to probe an endpoint
# e.g. HEARTBEAT_HTTP_URL="http://localhost:8080/"

while true; do

    # ── Network ───────────────────────────────────────────────
    SSID=$(iwgetid -r 2>/dev/null || true)
    if [[ -n "$SSID" ]]; then
        NET="wifi:${SSID}"
    elif ip link show eth0 2>/dev/null | grep -q 'state UP'; then
        NET="eth0"
    else
        NET="no-net"
    fi

    # ── Voltage / throttle (Pi-specific, safe on all Pi models) ──
    # Only bits 0-3 = current state. Bits 16-19 are sticky "has occurred"
    # history flags — a non-zero overall value is NOT a current problem.
    THROTTLED=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo '')
    THROTTLED_NOW=$(( ${THROTTLED:-0} & 0xF ))
    [[ "$THROTTLED_NOW" -eq 0 ]] && VOLT="ok" || VOLT="WARN(${THROTTLED})"

    # ── Optional HTTP probe ───────────────────────────────────
    if [[ -n "${HEARTBEAT_HTTP_URL:-}" ]]; then
        START=$(date +%s%3N)
        HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
            -H 'Cache-Control: no-cache' "${HEARTBEAT_HTTP_URL}" 2>/dev/null || echo 'ERR')
        MS=$(( $(date +%s%3N) - START ))
        HTTP_INFO="  http=${HTTP}(${MS}ms)"
    else
        HTTP_INFO=""
    fi

    # ── Disk ──────────────────────────────────────────────────
    DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $5}')

    # ── Memory ───────────────────────────────────────────────
    MEM=$(free 2>/dev/null | awk '/^Mem:/{printf "%d%%", $3/$2*100}')

    # ── Load (1-min average) ──────────────────────────────────
    LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo '?')

    # ── CPU temperature ───────────────────────────────────────
    TEMP=$(awk '{printf "%.0f°C", $1/1000}' \
        /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo '?')

    echo "   $(date '+%H:%M')  net=${NET}  volt=${VOLT}${HTTP_INFO}  disk=${DISK}  mem=${MEM}  load=${LOAD}  temp=${TEMP}"

    sleep "$INTERVAL"
done
