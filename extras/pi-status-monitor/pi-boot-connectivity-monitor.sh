#!/usr/bin/env bash
# =============================================================
# pi-boot-connectivity-monitor.sh
#
# Runs for the first 10 minutes after boot, polling every 30s.
# Each tick logs: internet (google), SSH port, CF tunnel state.
# Output goes to systemd journal (pi-boot-connectivity service)
# so you can watch it live on the screen or via:
#   journalctl -u pi-boot-connectivity -f
#
# Also attempts self-healing:
#   - SSH not running → regenerate host keys + start sshd
#   - cloudflared not running → restart it
#
# Install: bash extras/pi-status-monitor/setup.sh
# =============================================================

MONITOR_SECS=600   # 10 minutes
INTERVAL=30
BOOT_TS=$(date +%s)
DEADLINE=$(( BOOT_TS + MONITOR_SECS ))
TICK=0

log() { echo "[boot-monitor] $*"; }

# ── SSH self-heal ─────────────────────────────────────────────────────────────
ssh_heal() {
    # Step 1: ensure host keys exist
    local key_count
    key_count=$(ls /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l || echo 0)
    if [[ "${key_count}" -eq 0 ]]; then
        log "SSH HEAL: no host keys found — regenerating..."
        if ssh-keygen -A 2>&1 | sed 's/^/  /'; then
            log "SSH HEAL: host keys regenerated."
        else
            log "SSH HEAL: ssh-keygen -A failed."
        fi
    fi

    # Step 2: enable + start sshd
    local started=0
    for _svc in ssh sshd; do
        if systemctl enable --now "${_svc}" 2>/dev/null; then
            log "SSH HEAL: ${_svc} enabled and started."
            started=1; break
        fi
    done
    [[ "${started}" -eq 0 ]] && log "SSH HEAL: could not start ssh/sshd — check 'journalctl -u ssh'."
}

# ── CF tunnel self-heal ───────────────────────────────────────────────────────
cf_heal() {
    log "CF HEAL: cloudflared not active — attempting restart..."
    if systemctl restart cloudflared 2>/dev/null; then
        sleep 3
        if systemctl is-active --quiet cloudflared 2>/dev/null; then
            log "CF HEAL: cloudflared restarted successfully."
        else
            log "CF HEAL: cloudflared still not active after restart."
            journalctl -u cloudflared -n 10 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true
        fi
    else
        log "CF HEAL: systemctl restart cloudflared failed."
    fi
}

log "Starting — polling for ${MONITOR_SECS}s (every ${INTERVAL}s)"
log "Watching: internet (google), SSH port, cloudflared tunnel"

_ssh_healed=0
_cf_healed=0

while [[ $(date +%s) -lt "${DEADLINE}" ]]; do
    TICK=$(( TICK + 1 ))
    NOW=$(date '+%H:%M:%S')
    ELAPSED=$(( $(date +%s) - BOOT_TS ))
    REMAINING=$(( DEADLINE - $(date +%s) ))

    # ── Internet ─────────────────────────────────────────────
    _t0=$(date +%s%3N)
    _gc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com 2>/dev/null || echo '000')
    _gms=$(( $(date +%s%3N) - _t0 ))
    if [[ "$_gc" == "200" || "$_gc" == "301" || "$_gc" == "302" ]]; then
        INET="google=OK(${_gms}ms)"
    else
        INET="google=FAIL(code=${_gc})"
    fi

    # External IP
    EXT_IP=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null || echo 'unreachable')

    # ── SSH ──────────────────────────────────────────────────
    SSH_ACTIVE=0
    for _s in ssh sshd; do systemctl is-active --quiet "${_s}" 2>/dev/null && SSH_ACTIVE=1 && break; done
    _sshport=$(grep -E '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null \
        | awk '{print $2}' | head -1 || echo '22')
    _sshport="${_sshport:-22}"
    _sshopen=$(ss -tlnp 2>/dev/null | awk -v p=":${_sshport} " '$0~p{print "1"}' | head -1 || echo '')

    if [[ "${SSH_ACTIVE}" -eq 1 && "${_sshopen}" == "1" ]]; then
        SSH_STATUS="ssh=UP:${_sshport}"
    else
        SSH_STATUS="ssh=DOWN(svc=$(systemctl is-active ssh 2>/dev/null || echo ?)  port${_sshport}=$([ "${_sshopen}" == "1" ] && echo open || echo closed))"
        # Self-heal on first detection only (avoid restart loop)
        if [[ "${_ssh_healed}" -eq 0 ]]; then
            _ssh_healed=1
            ssh_heal
        fi
    fi

    # ── Cloudflare tunnel ─────────────────────────────────────
    CF_ACTIVE=$(systemctl is-active cloudflared 2>/dev/null || echo "inactive")
    if [[ "${CF_ACTIVE}" == "active" ]]; then
        CF_STATUS="cf=UP"
    else
        CF_STATUS="cf=${CF_ACTIVE}"
        if [[ "${_cf_healed}" -eq 0 ]]; then
            _cf_healed=1
            cf_heal
            CF_ACTIVE=$(systemctl is-active cloudflared 2>/dev/null || echo "inactive")
            CF_STATUS="cf=${CF_ACTIVE}(after-heal)"
        fi
    fi

    log "tick=${TICK} t+${ELAPSED}s | ${INET} ext=${EXT_IP} | ${SSH_STATUS} | ${CF_STATUS} | remaining=${REMAINING}s"

    sleep "${INTERVAL}"
done

log "Done — 10-minute window elapsed. SSH and CF tunnel status at exit:"
log "  SSH: $(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo inactive)"
log "  CF:  $(systemctl is-active cloudflared 2>/dev/null || echo inactive)"
log "  Port ${_sshport:-22}: $(ss -tlnp 2>/dev/null | awk -v p=':${_sshport:-22} ' '$0~p{print "open"}' | head -1 || echo closed)"
