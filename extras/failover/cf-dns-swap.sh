#!/usr/bin/env bash
# =============================================================
# extras/failover/cf-dns-swap.sh — Cloudflare DNS failover
#
# Swaps a set of CNAME records between PROD_TUNNEL_UUID and
# STANDBY_TUNNEL_UUID using the Cloudflare DNS API.
#
# Usage:
#   bash cf-dns-swap.sh --to-standby
#   bash cf-dns-swap.sh --to-primary
#
# Required vars (set in config.env or environment):
#   CF_ZONE_ID            Cloudflare zone ID (from zone dashboard Overview tab)
#   CF_API_TOKEN          API token — needs Zone:DNS:Edit permission
#   CF_FAILOVER_DOMAINS   Comma-separated list of CNAMEs to swap
#                         e.g. "yourdomain.com,www.yourdomain.com"
#   PROD_TUNNEL_UUID      Production Cloudflare Tunnel UUID
#   STANDBY_TUNNEL_UUID   Standby Cloudflare Tunnel UUID
#
# In config.env, set:
#   STANDBY_FAILOVER_CMD="bash ~/pi2s3/extras/failover/cf-dns-swap.sh --to-standby"
#   STANDBY_FAILBACK_CMD="bash ~/pi2s3/extras/failover/cf-dns-swap.sh --to-primary"
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI2S3_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
CONFIG_FILE="${PI2S3_DIR}/config.env"
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}"

# ── Validate ──────────────────────────────────────────────────────────────────
DIRECTION="${1:-}"
if [[ "${DIRECTION}" != "--to-standby" && "${DIRECTION}" != "--to-primary" ]]; then
    echo "Usage: $0 --to-standby | --to-primary" >&2
    exit 1
fi
[[ -z "${CF_ZONE_ID:-}"          ]] && { echo "ERROR: CF_ZONE_ID not set"          >&2; exit 1; }
[[ -z "${CF_API_TOKEN:-}"        ]] && { echo "ERROR: CF_API_TOKEN not set"        >&2; exit 1; }
[[ -z "${CF_FAILOVER_DOMAINS:-}" ]] && { echo "ERROR: CF_FAILOVER_DOMAINS not set" >&2; exit 1; }
[[ -z "${PROD_TUNNEL_UUID:-}"    ]] && { echo "ERROR: PROD_TUNNEL_UUID not set"    >&2; exit 1; }
[[ -z "${STANDBY_TUNNEL_UUID:-}" ]] && { echo "ERROR: STANDBY_TUNNEL_UUID not set" >&2; exit 1; }
command -v curl &>/dev/null || { echo "ERROR: curl not found" >&2; exit 1; }

if [[ "${DIRECTION}" == "--to-standby" ]]; then
    TARGET_UUID="${STANDBY_TUNNEL_UUID}"
    LABEL="standby"
else
    TARGET_UUID="${PROD_TUNNEL_UUID}"
    LABEL="primary (prod)"
fi

CF_API="https://api.cloudflare.com/client/v4"

cf_api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-s -X "${method}" "${CF_API}${path}"
        -H "Authorization: Bearer ${CF_API_TOKEN}"
        -H "Content-Type: application/json")
    [[ -n "${body}" ]] && args+=(-d "${body}")
    curl "${args[@]}"
}

# Wrap CF API calls with up to 3 attempts (exponential backoff).
# Transient 429/503 from CF must not leave DNS stuck on standby.
cf_api_retry() {
    local _attempt _resp _success _err
    for _attempt in 1 2 3; do
        _resp=$(cf_api "$@")
        _success=$(echo "${_resp}" | grep -o '"success":[a-z]*' | cut -d: -f2 || true)
        [[ "${_success}" == "true" ]] && { echo "${_resp}"; return 0; }
        _err=$(echo "${_resp}" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        echo "  CF API attempt ${_attempt}/3 failed: ${_err:-${_resp}}" >&2
        [[ ${_attempt} -lt 3 ]] && sleep $(( _attempt * 10 ))
    done
    echo "${_resp}"
    return 1
}

echo "CF DNS swap: pointing to ${LABEL} (${TARGET_UUID})..."

_SKIP_COUNT=0
IFS=',' read -ra DOMAINS <<< "${CF_FAILOVER_DOMAINS}"
for domain in "${DOMAINS[@]}"; do
    domain="${domain// /}"
    [[ -z "${domain}" ]] && continue

    # Look up the DNS record ID (with retry)
    resp=$(cf_api_retry GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${domain}") || {
        echo "  FAIL  ${domain}: could not look up DNS record after 3 attempts"
        exit 1
    }
    record_id=$(echo "${resp}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    if [[ -z "${record_id}" ]]; then
        echo "  FAIL  ${domain}: no CNAME record found — cannot swap (partial failover is unsafe)"
        (( _SKIP_COUNT++ )) || true
        continue
    fi

    new_content="${TARGET_UUID}.cfargotunnel.com"
    resp=$(cf_api_retry PATCH "/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
        "{\"content\":\"${new_content}\"}") || {
        echo "  FAIL  ${domain}: PATCH failed after 3 attempts"
        exit 1
    }
    echo "  OK  ${domain} → ${new_content}"
done

if [[ ${_SKIP_COUNT} -gt 0 ]]; then
    echo "  ERROR: ${_SKIP_COUNT} domain(s) could not be swapped — aborting to avoid partial failover"
    exit 1
fi

echo "CF DNS swap complete → ${LABEL}"
