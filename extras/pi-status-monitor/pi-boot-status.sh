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
BOOT_TS=$(date +%s)

hdr() { echo ""; echo "  ── $1 ──"; }
ok()  { echo "    ✓  $*"; }
warn(){ echo "    ⚠  $*"; }
bad() { echo "    ✗  $*"; }

echo ""
echo "$SEP"
printf "  %-20s  boot status   %s\n" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "$SEP"

# ── Internet connectivity ─────────────────────────────────────
hdr "Internet"
_t0=$(date +%s%3N)
GOOGLE_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://www.google.com 2>/dev/null || echo '000')
_ms=$(( $(date +%s%3N) - _t0 ))
if [[ "$GOOGLE_CODE" == "200" || "$GOOGLE_CODE" == "301" || "$GOOGLE_CODE" == "302" ]]; then
    ok "google.com → HTTP ${GOOGLE_CODE} (${_ms}ms)"
else
    bad "google.com → HTTP ${GOOGLE_CODE} (${_ms}ms) — no internet"
fi
EXT_IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo 'unreachable')
echo "    External IP: ${EXT_IP}"
GW=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}' || echo '?')
echo "    Gateway:     ${GW}"

# ── Network interfaces ────────────────────────────────────────
hdr "Network"
ip -o addr show 2>/dev/null \
    | awk '$3=="inet" && $2!="lo" {split($4,a,"/"); printf "    %-10s %s\n", $2, a[1]}' || true
SSID=$(iwgetid -r 2>/dev/null || true)
[[ -n "$SSID" ]] && echo "    WiFi:      $SSID" || echo "    WiFi:      (not connected / ethernet)"

# ── SSH ──────────────────────────────────────────────────────
hdr "SSH"
# Detect active service name (ssh vs sshd distro variation)
SSH_SVC_NAME=""
for _s in ssh sshd; do
    if systemctl is-active --quiet "${_s}" 2>/dev/null; then
        SSH_SVC_NAME="${_s}"; break
    fi
done

# Actual listening port from sshd config (may differ from 22)
SSH_CFG_PORT=$(grep -E '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null \
    | awk '{print $2}' | head -1 || echo '22')
SSH_CFG_PORT="${SSH_CFG_PORT:-22}"

# Host key check — the #1 reason sshd fails to start after a restore
SSH_KEY_COUNT=$(ls /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l || echo 0)
if [[ "${SSH_KEY_COUNT}" -gt 0 ]]; then
    ok "Host keys: ${SSH_KEY_COUNT} key(s) present"
    ls /etc/ssh/ssh_host_*_key 2>/dev/null | while read -r k; do
        echo "    $(ssh-keygen -l -f "${k}" 2>/dev/null || echo "    (unreadable: ${k})")"
    done
else
    bad "Host keys: NONE"
    echo "    ↳ This is why sshd cannot start. Regenerating now..."
    if ssh-keygen -A 2>&1 | sed 's/^/    /'; then
        ok "Host keys regenerated — starting sshd..."
        for _svc in ssh sshd; do
            systemctl enable --now "${_svc}" 2>/dev/null && ok "sshd started (${_svc})" && break
        done
    else
        bad "ssh-keygen -A FAILED — check disk space and /etc/ssh permissions"
    fi
fi

if [[ -n "${SSH_SVC_NAME}" ]]; then
    ok "Service:  ${SSH_SVC_NAME} active"
else
    # Get the real reason from the journal — don't make the user guess
    SSH_STATE=$(systemctl show ssh sshd --property=ActiveState,SubState,Result 2>/dev/null \
        | grep -v '^$' | paste -sd '  ' || echo "unknown")
    bad "Service:  sshd NOT running  (${SSH_STATE})"
    echo ""
    echo "  ── sshd journal (last 15 lines) ──"
    journalctl -u ssh -u sshd -n 15 --no-pager --output=short 2>/dev/null \
        | sed 's/^/    /' || echo "    (no journal entries)"
    echo ""
    warn "Auto-fix: sudo ssh-keygen -A && sudo systemctl enable --now ssh"
fi

SSH_LISTEN=$(ss -tlnp 2>/dev/null | awk -v p=":${SSH_CFG_PORT} " '$0~p {print "open"}' | head -1)
if [[ "${SSH_LISTEN}" == "open" ]]; then
    ok "Port ${SSH_CFG_PORT}: open"
else
    bad "Port ${SSH_CFG_PORT}: CLOSED"
    # Show what IS listening so the user knows what port sshd ended up on
    LISTENING=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | grep -v '0.0.0.0:\*\|:::\*' | head -8 || true)
    [[ -n "${LISTENING}" ]] && echo "    Listening ports: $(echo "${LISTENING}" | tr '\n' '  ')"
fi

# Authorized keys for current/admin user
for _u in admin pi "$(logname 2>/dev/null || true)"; do
    _ak="/home/${_u}/.ssh/authorized_keys"
    [[ -f "${_ak}" ]] || continue
    _n=$(wc -l < "${_ak}" 2>/dev/null || echo 0)
    ok "authorized_keys: ${_n} key(s) for ${_u} (${_ak})"
    break
done

# ── Cloudflare tunnel ─────────────────────────────────────────
hdr "Cloudflare Tunnel"
CF_SVC=$(systemctl is-active cloudflared 2>/dev/null || echo "inactive")
if [[ "${CF_SVC}" == "active" ]]; then
    ok "cloudflared service: active"
else
    bad "cloudflared service: ${CF_SVC}"
    CF_FAIL=$(journalctl -u cloudflared -n 5 --no-pager -o cat 2>/dev/null | tail -3 || true)
    [[ -n "$CF_FAIL" ]] && echo "    Last log: ${CF_FAIL}"
fi

# Tunnel ID — from token unit or config.yml
CF_TUNNEL_ID=""
CF_UNIT=$(systemctl cat cloudflared 2>/dev/null || true)
if echo "${CF_UNIT}" | grep -q -- '--token'; then
    # Token-based (remotely managed) — extract tunnel ID from token JWT middle segment
    CF_TOKEN=$(echo "${CF_UNIT}" | grep -oP '(?<=--token )\S+' | head -1 || true)
    if [[ -n "${CF_TOKEN}" ]]; then
        # JWT middle segment is base64-encoded JSON
        CF_TUNNEL_ID=$(echo "${CF_TOKEN}" | cut -d. -f2 | \
            python3 -c "import sys,base64,json; d=sys.stdin.read().strip(); \
            d+='='*(-len(d)%4); print(json.loads(base64.b64decode(d)).get('t','?'))" \
            2>/dev/null || echo '?')
        echo "    Mode:      token-based (remotely managed)"
    fi
elif [[ -f /etc/cloudflared/config.yml ]]; then
    CF_TUNNEL_ID=$(grep -m1 '^tunnel:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $2}' || echo '?')
    echo "    Mode:      credentials-file (config.yml)"
fi
[[ -n "${CF_TUNNEL_ID}" ]] && echo "    Tunnel ID: ${CF_TUNNEL_ID}"

# Hostnames the tunnel is serving (from dashboard-managed routes via cloudflared)
CF_ROUTES=$(cloudflared tunnel route ip show 2>/dev/null | head -5 || true)
if [[ -z "${CF_ROUTES}" ]]; then
    # Fall back to config.yml ingress
    CF_ROUTES=$(grep -A1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null \
        | grep -v '^--$' | grep 'hostname:' | awk '{print $2}' | head -5 || true)
fi
if [[ -n "${CF_ROUTES}" ]]; then
    echo "    Hostnames served:"
    echo "${CF_ROUTES}" | sed 's/^/      /'
fi

# Verify SSH hostname specifically reachable (quick local port probe)
CF_SSH_HOST=$(grep -r 'ssh-qa\|ssh\.' /etc/cloudflared/ 2>/dev/null \
    | grep -oP '[a-z0-9._-]+\.andrewbaker\.ninja' | head -1 || true)
[[ -z "${CF_SSH_HOST}" ]] && CF_SSH_HOST=$(echo "${CF_UNIT}" | \
    grep -oP '[a-z0-9._-]+\.andrewbaker\.ninja' | grep 'ssh' | head -1 || true)
if [[ -n "${CF_SSH_HOST}" ]]; then
    echo "    SSH hostname: ${CF_SSH_HOST}"
fi

# cloudflared version
CF_VER=$(cloudflared --version 2>/dev/null | awk '{print $3}' || echo 'not installed')
echo "    Version:   ${CF_VER}"

# ── Docker containers ─────────────────────────────────────────
hdr "Docker"
if command -v docker &>/dev/null; then
    docker ps --format '    {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "    (docker ps failed)"
    STOPPED=$(docker ps -q --filter status=exited 2>/dev/null | wc -l | tr -d ' ')
    [[ "${STOPPED}" -gt 0 ]] && warn "${STOPPED} container(s) stopped/exited"
else
    echo "    docker not installed"
fi

# ── Voltage / Power ──────────────────────────────────────────
hdr "Voltage / Power"
THROTTLED=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo 'unavailable')
if [[ "$THROTTLED" == "unavailable" ]]; then
    echo "    vcgencmd not available"
else
    THROTTLED_NOW=$(( ${THROTTLED} & 0xF ))
    THROTTLED_HIST=$(( ${THROTTLED} >> 16 & 0xF ))
    if [[ "$THROTTLED_NOW" -eq 0 ]]; then
        ok "Voltage: OK  (raw=${THROTTLED})"
    else
        bad "Voltage: WARN — currently throttled/under-voltage  (raw=${THROTTLED})"
        [[ $(( THROTTLED_NOW & 0x1 )) -ne 0 ]] && warn "under-voltage NOW"
        [[ $(( THROTTLED_NOW & 0x2 )) -ne 0 ]] && warn "arm frequency capped NOW"
        [[ $(( THROTTLED_NOW & 0x4 )) -ne 0 ]] && warn "throttled NOW"
        [[ $(( THROTTLED_NOW & 0x8 )) -ne 0 ]] && warn "soft temperature limit NOW"
    fi
    [[ "$THROTTLED_HIST" -ne 0 ]] && warn "Throttle/cap/temp events occurred this boot (sticky bits)"
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
[[ -n "$FAILED" ]] && echo "$FAILED" || ok "None"

# ── Recent dmesg errors ──────────────────────────────────────
hdr "dmesg (errors/warnings since boot)"
DMESG_ERRS=$(dmesg --level=err,crit,alert,emerg --time-format=reltime 2>/dev/null \
    | tail -8 || true)
[[ -n "$DMESG_ERRS" ]] && echo "$DMESG_ERRS" | sed 's/^/    /' || ok "None"

# ── Versions ─────────────────────────────────────────────────
hdr "Versions"
echo "    Python:      $(python3 --version 2>/dev/null | awk '{print $2}' || echo '?')"
echo "    cloudflared: ${CF_VER}"
echo "    docker:      $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo '?')"

echo ""
echo "$SEP"
echo "  Watch live:       journalctl -u pi-heartbeat -f"
echo "  Boot connectivity: journalctl -u pi-boot-connectivity -f"
echo "  Fix SSH now:       sudo ssh-keygen -A && sudo systemctl enable --now ssh"
echo "$SEP"
echo ""
