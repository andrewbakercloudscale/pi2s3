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
PI_DIR=~/pi2s3

_PI_CF_HOST="${PI_CF_HOST:-ssh.andrewbaker.ninja}"
_PI_CF_USER="${PI_CF_USER:-pi}"

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
