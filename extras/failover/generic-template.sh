#!/usr/bin/env bash
# =============================================================
# extras/failover/generic-template.sh — Custom failover template
#
# Copy this file, rename it, and fill in the two swap functions.
# The script is called with --to-standby before backup starts
# and --to-primary after backup is verified in S3.
#
# Usage:
#   bash my-failover.sh --to-standby
#   bash my-failover.sh --to-primary
#
# In config.env, set:
#   STANDBY_FAILOVER_CMD="bash ~/pi2s3/extras/failover/my-failover.sh --to-standby"
#   STANDBY_FAILBACK_CMD="bash ~/pi2s3/extras/failover/my-failover.sh --to-primary"
#
# After calling your swap command, pi-image-backup.sh will:
#   - Read STANDBY_VERIFY_DOMAIN to get the DNS TTL (via dig)
#   - Poll STANDBY_VERIFY_URL until HTTP 2xx/3xx before proceeding
# These keep the backup from starting before the swap has taken effect.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI2S3_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
CONFIG_FILE="${PI2S3_DIR}/config.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

DIRECTION="${1:-}"
if [[ "${DIRECTION}" != "--to-standby" && "${DIRECTION}" != "--to-primary" ]]; then
    echo "Usage: $0 --to-standby | --to-primary" >&2
    exit 1
fi

swap_to_standby() {
    # ── Implement your swap-to-standby logic here ─────────────────────────────
    #
    # Examples:
    #
    # HAProxy: write a new backend config and reload
    #   echo "server standby 192.168.1.20:80 check" > /etc/haproxy/backend.cfg
    #   systemctl reload haproxy
    #
    # nginx upstream swap:
    #   sed -i 's/server 192.168.1.10/server 192.168.1.20/' /etc/nginx/upstream.conf
    #   nginx -s reload
    #
    # Generic curl webhook (e.g. load balancer API):
    #   curl -s -X POST "https://lb.example.com/api/swap" \
    #     -H "Authorization: Bearer ${LB_TOKEN}" \
    #     -d '{"target":"standby"}'
    #
    # Pause here until standby is confirmed serving, or set STANDBY_VERIFY_URL
    # in config.env and let pi-image-backup.sh poll it automatically.
    # ─────────────────────────────────────────────────────────────────────────

    echo "TODO: implement swap_to_standby()" >&2
    exit 1
}

swap_to_primary() {
    # ── Implement your swap-to-primary logic here ──────────────────────────────
    echo "TODO: implement swap_to_primary()" >&2
    exit 1
}

case "${DIRECTION}" in
    --to-standby) swap_to_standby ;;
    --to-primary) swap_to_primary ;;
esac
