#!/usr/bin/env bash
# =============================================================
# extras/failover/route53-swap.sh — AWS Route 53 DNS failover
#
# Swaps a set of records between PROD_RECORD_VALUE and
# STANDBY_RECORD_VALUE using the AWS Route 53 API.
#
# Usage:
#   bash route53-swap.sh --to-standby
#   bash route53-swap.sh --to-primary
#
# Required vars (set in config.env or environment):
#   R53_HOSTED_ZONE_ID    Hosted zone ID (e.g. Z1D633PJN98FT9)
#   R53_FAILOVER_DOMAINS  Comma-separated record names to swap
#                         e.g. "yourdomain.com,www.yourdomain.com"
#   R53_RECORD_TYPE       DNS record type — A, AAAA, or CNAME (default: CNAME)
#   R53_TTL               TTL in seconds (default: 60)
#   PROD_RECORD_VALUE     Value when pointing at production
#                         e.g. an IP, CNAME target, or CF tunnel hostname
#   STANDBY_RECORD_VALUE  Value when pointing at standby
#
# In config.env, set:
#   STANDBY_FAILOVER_CMD="bash ~/pi2s3/extras/failover/route53-swap.sh --to-standby"
#   STANDBY_FAILBACK_CMD="bash ~/pi2s3/extras/failover/route53-swap.sh --to-primary"
#
# Note: The AWS profile used must have route53:ChangeResourceRecordSets and
# route53:ListResourceRecordSets permissions on the hosted zone.
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
[[ -z "${R53_HOSTED_ZONE_ID:-}"    ]] && { echo "ERROR: R53_HOSTED_ZONE_ID not set"    >&2; exit 1; }
[[ -z "${R53_FAILOVER_DOMAINS:-}"  ]] && { echo "ERROR: R53_FAILOVER_DOMAINS not set"  >&2; exit 1; }
[[ -z "${PROD_RECORD_VALUE:-}"     ]] && { echo "ERROR: PROD_RECORD_VALUE not set"     >&2; exit 1; }
[[ -z "${STANDBY_RECORD_VALUE:-}"  ]] && { echo "ERROR: STANDBY_RECORD_VALUE not set"  >&2; exit 1; }
command -v aws &>/dev/null || { echo "ERROR: aws CLI not found" >&2; exit 1; }

R53_RECORD_TYPE="${R53_RECORD_TYPE:-CNAME}"
R53_TTL="${R53_TTL:-60}"
[[ -z "${AWS_PROFILE:-}" ]] && unset AWS_PROFILE || true

if [[ "${DIRECTION}" == "--to-standby" ]]; then
    TARGET_VALUE="${STANDBY_RECORD_VALUE}"
    LABEL="standby"
else
    TARGET_VALUE="${PROD_RECORD_VALUE}"
    LABEL="primary (prod)"
fi

echo "Route53 swap: pointing to ${LABEL} (${TARGET_VALUE})..."

IFS=',' read -ra DOMAINS <<< "${R53_FAILOVER_DOMAINS}"

# Build change batch JSON
CHANGES_JSON=""
for domain in "${DOMAINS[@]}"; do
    domain="${domain// /}"
    [[ -z "${domain}" ]] && continue
    # Ensure trailing dot for Route 53 (it's the standard FQDN format)
    fqdn="${domain%.}."
    CHANGES_JSON+=$(cat <<EOF
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${fqdn}",
        "Type": "${R53_RECORD_TYPE}",
        "TTL": ${R53_TTL},
        "ResourceRecords": [{ "Value": "${TARGET_VALUE}" }]
      }
    },
EOF
)
done
CHANGES_JSON=$(printf '%s' "${CHANGES_JSON}" | sed 's/,[[:space:]]*$//')

CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "pi2s3 hot standby failover → ${LABEL}",
  "Changes": [${CHANGES_JSON}]
}
EOF
)

_R53_ERR_TMP=$(mktemp)
CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${R53_HOSTED_ZONE_ID}" \
    --change-batch "${CHANGE_BATCH}" \
    --query 'ChangeInfo.Id' --output text 2>"${_R53_ERR_TMP}") || {
    echo "  ERROR: Route53 change failed:"
    cat "${_R53_ERR_TMP}"
    rm -f "${_R53_ERR_TMP}"
    exit 1
}
rm -f "${_R53_ERR_TMP}"

echo "  Change submitted: ${CHANGE_ID}"

# Wait for propagation through Route 53 (typically <30s)
echo "  Waiting for Route 53 to propagate changes..."
aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}" 2>/dev/null || true

IFS=',' read -ra DISPLAY_DOMAINS <<< "${R53_FAILOVER_DOMAINS}"
for domain in "${DISPLAY_DOMAINS[@]}"; do
    domain="${domain// /}"
    [[ -z "${domain}" ]] && continue
    echo "  OK  ${domain} → ${TARGET_VALUE}"
done

echo "Route53 swap complete → ${LABEL}"
