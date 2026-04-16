#!/usr/bin/env bash
# =============================================================
# deploy-pi.sh — Upgrade pi2s3 on the Pi
#
# Pulls latest code from GitHub and redeploys install.sh.
# Uses the CF tunnel (ssh.andrewbaker.ninja) with the service key.
#
# Usage: bash deploy-pi.sh
# =============================================================
set -euo pipefail

PI_HOST="ssh.andrewbaker.ninja"
PI_USER="pi"
PI_DIR="~/pi2s3"
CF_KEY="${HOME}/.cloudflared/pi-service-key"
CF_PROXY="${HOME}/.cloudflared/cf-ssh-proxy.sh"
SSH_OPTS=(-i "${CF_KEY}" -o "ProxyCommand=${CF_PROXY}" -o StrictHostKeyChecking=no -o ServerAliveInterval=15 -o ServerAliveCountMax=10)

echo "── pi2s3 deploy to ${PI_USER}@${PI_HOST}:${PI_DIR} ──"
echo ""

ssh "${SSH_OPTS[@]}" "${PI_USER}@${PI_HOST}" "
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
