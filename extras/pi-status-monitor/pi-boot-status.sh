#!/usr/bin/env bash
# =============================================================
# pi-boot-status.sh — Full system status dump on boot
#
# Prints a human-readable overview to stdout covering everything
# useful for debugging a Pi that won't connect or behave:
#   network, voltage, disk, memory, temperature, failed services,
#   OS/kernel versions, recent dmesg errors.
#
# Runs once at boot via pi-boot-status.service (after network).
# Can also be run manually at any time:
#   sudo pi-boot-status.sh
#
# Install: bash extras/pi-status-monitor/setup.sh
# =============================================================
set -euo pipefail

SEP="════════════════════════════════════════════════════════"

hdr() { echo ""; echo "  ── $1 ──"; }

echo ""
echo "$SEP"
printf "  %-20s  boot status   %s\n" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "$SEP"

# ── Network ──────────────────────────────────────────────────
hdr "Network"
# All non-loopback interfaces with IPs
ip -o addr show 2>/dev/null \
    | awk '$3=="inet" && $2!="lo" {split($4,a,"/"); printf "    %-10s %s\n", $2, a[1]}' || true

# WiFi SSID
SSID=$(iwgetid -r 2>/dev/null || true)
[[ -n "$SSID" ]] && echo "    WiFi:      $SSID" || echo "    WiFi:      (not connected)"

# External IP — confirms internet is up
EXT_IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo 'unreachable')
echo "    External:  $EXT_IP"

# Default gateway
GW=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}' || echo '?')
echo "    Gateway:   $GW"

# ── Voltage / Power ──────────────────────────────────────────
hdr "Voltage / Power"
THROTTLED=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo 'unavailable')
if [[ "$THROTTLED" == "unavailable" ]]; then
    echo "    vcgencmd not available"
else
    THROTTLED_NOW=$(( ${THROTTLED} & 0xF ))
    THROTTLED_HIST=$(( ${THROTTLED} >> 16 & 0xF ))
    if [[ "$THROTTLED_NOW" -eq 0 ]]; then
        echo "    Voltage:   OK  (raw=${THROTTLED})"
    else
        echo "    Voltage:   WARN — currently throttled/under-voltage  (raw=${THROTTLED})"
        [[ $(( THROTTLED_NOW & 0x1 )) -ne 0 ]] && echo "               ↳ under-voltage NOW"
        [[ $(( THROTTLED_NOW & 0x2 )) -ne 0 ]] && echo "               ↳ arm frequency capped NOW"
        [[ $(( THROTTLED_NOW & 0x4 )) -ne 0 ]] && echo "               ↳ throttled NOW"
        [[ $(( THROTTLED_NOW & 0x8 )) -ne 0 ]] && echo "               ↳ soft temperature limit NOW"
    fi
    if [[ "$THROTTLED_HIST" -ne 0 ]]; then
        echo "    History:   throttle/cap/temp events have occurred this boot (sticky bits)"
    fi
fi

# ── System ───────────────────────────────────────────────────
hdr "System"
echo "    OS:        $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo '?')"
echo "    Kernel:    $(uname -r)"
echo "    Uptime:    $(uptime -p 2>/dev/null || uptime)"
TEMP=$(awk '{printf "%.1f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo '?')
echo "    Temp:      $TEMP"
MEM_USED=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
MEM_PCT=$(free 2>/dev/null | awk '/^Mem:/{printf "%d%%", $3/$2*100}')
echo "    Memory:    ${MEM_USED}MiB / ${MEM_TOTAL}MiB used (${MEM_PCT})"
LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo '?')
echo "    Load:      $LOAD  (1m 5m 15m)"

# ── Disk ─────────────────────────────────────────────────────
hdr "Disk"
df -h 2>/dev/null | awk '!seen[$1]++ && NR>1 && $1!~/tmpfs|udev/ \
    { printf "    %-22s %5s used  %5s free  %s\n", $6, $3, $4, $5 }' || true

# ── Failed Services ──────────────────────────────────────────
hdr "Failed Services"
FAILED=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null \
    | awk '{print "    ✗ " $1}' || true)
[[ -n "$FAILED" ]] && echo "$FAILED" || echo "    None  ✓"

# ── Recent dmesg errors ──────────────────────────────────────
hdr "dmesg (errors/warnings since boot)"
DMESG_ERRS=$(dmesg --level=err,crit,alert,emerg --time-format=reltime 2>/dev/null \
    | tail -8 || true)
[[ -n "$DMESG_ERRS" ]] && echo "$DMESG_ERRS" | sed 's/^/    /' || echo "    None  ✓"

# ── Versions ─────────────────────────────────────────────────
hdr "Versions"
echo "    Python:    $(python3 --version 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    cloudflared: $(cloudflared --version 2>/dev/null | awk '{print $3}' || echo 'not installed')"

echo ""
echo "$SEP"
echo "  Watch live:  journalctl -u pi-heartbeat -f"
echo "$SEP"
echo ""
