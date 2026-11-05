#!/usr/bin/env bash
# =============================================================
# deploy-pi.sh — Upgrade pi2s3 on the Pi
#
# Pulls latest code from GitHub on the Pi and runs install.sh --upgrade.
# Tries direct LAN SSH first; falls back to Cloudflare tunnel.
#
# Usage: bash deploy-pi.sh
# =============================================================
set -euo pipefail

# Customise these for your setup, or override via environment variables.
PI_KEY="${PI_KEY:-${HOME}/.ssh/pi_key}"
PI_LOCAL="${PI_LOCAL:-raspberrypi.local}"
PI_DIR="${PI_DIR:-~/pi2s3}"

_PI_CF_HOST="${PI_CF_HOST:-ssh.andrewbaker.ninja}"
_PI_CF_USER="${PI_CF_USER:-pi}"

# ── Gate: every test passes before anything reaches the Pi ────────────────────
# The watchdog decides when the production host reboots; a broken one ships only
# through here. Every *-test.sh in the repo runs, and one failure blocks the deploy.
_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_gate_fail=0
while IFS= read -r _t; do
    if bash "${_t}" >/dev/null 2>&1; then
        echo "  test ok:   ${_t#"${_REPO}"/}"
    else
        echo "  TEST FAIL: ${_t#"${_REPO}"/}  (run: bash ${_t})"
        _gate_fail=1
    fi
done < <(find "${_REPO}/extras" "${_REPO}/lib" -maxdepth 1 -name '*-test.sh' | sort)
if [[ ${_gate_fail} -ne 0 ]]; then
    echo "ERROR: tests failed. Deploy blocked." >&2
    exit 1
fi

# ── Pick connection (LAN first, CF tunnel fallback) ───────────────────────────
if ssh -i "${PI_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=4 -o BatchMode=yes \
       "pi@${PI_LOCAL}" "exit" 2>/dev/null; then
    echo "Network: home — direct SSH"
    PI_HOST="${PI_LOCAL}"; PI_USER="pi"
    SSH_OPTS=(-i "${PI_KEY}" -o StrictHostKeyChecking=no -o ServerAliveInterval=15 -o ServerAliveCountMax=10)
else
    echo "Network: remote — Cloudflare tunnel"
    PI_HOST="${_PI_CF_HOST}"; PI_USER="${_PI_CF_USER}"
    SSH_OPTS=(-i "${HOME}/.cloudflared/pi-service-key" \
              -o "ProxyCommand=${HOME}/.cloudflared/cf-ssh-proxy.sh" \
              -o StrictHostKeyChecking=no -o ServerAliveInterval=15 -o ServerAliveCountMax=10)
fi

pi_ssh() { ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" "$@"; }

echo ""
echo "── pi2s3 deploy to ${PI_USER}@${PI_HOST}:${PI_DIR} ──"
echo ""

pi_ssh "
    set -e
    cd ${PI_DIR}
    echo '  git pull...'
    git pull
    echo ''
    echo '  install.sh --upgrade...'
    bash install.sh --upgrade
    echo ''
    echo '  install.sh --status...'
    bash install.sh --status
"

echo ""
echo "── Deploy complete ──"
