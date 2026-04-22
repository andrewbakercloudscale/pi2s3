#!/usr/bin/env bash
# =============================================================
# deploy-website.sh — Sync website/ to s3://pi2s3.com
#
# Usage:
#   bash deploy-website.sh            # sync + print URL
#   bash deploy-website.sh --dry-run  # show what would be uploaded
#
# Requirements:
#   - AWS CLI v2 with write access to s3://pi2s3.com
#   - Optional: set AWS_PROFILE if not using the default profile
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBSITE_DIR="${SCRIPT_DIR}/website"
S3_BUCKET="pi2s3.com"
AWS_PROFILE="${AWS_PROFILE:-}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--dry-run]"; exit 1 ;;
    esac
    shift
done

aws_cmd() {
    if [[ -n "${AWS_PROFILE}" ]]; then
        aws --profile "${AWS_PROFILE}" "$@"
    else
        aws "$@"
    fi
}

[[ ! -d "${WEBSITE_DIR}" ]] && { echo "ERROR: website/ directory not found at ${WEBSITE_DIR}"; exit 1; }
command -v aws &>/dev/null || { echo "ERROR: aws CLI not found"; exit 1; }

echo ""
echo "  pi2s3.com — website deploy"
echo "  Source:  ${WEBSITE_DIR}/"
echo "  Target:  s3://${S3_BUCKET}/"
[[ "${DRY_RUN}" == "true" ]] && echo "  Mode:    DRY RUN (no changes)"
echo ""

SYNC_ARGS=(
    s3 sync "${WEBSITE_DIR}/" "s3://${S3_BUCKET}/"
    --delete
    --cache-control "max-age=300, must-revalidate"
    --exclude "node_modules/*"
    --exclude "tests/*"
    --exclude "test-results/*"
    --exclude "playwright-report/*"
    --exclude "*.spec.js"
    --exclude "package.json"
    --exclude "package-lock.json"
    --exclude "install"
)
[[ "${DRY_RUN}" == "true" ]] && SYNC_ARGS+=(--dryrun)

aws_cmd "${SYNC_ARGS[@]}"

# Upload install script separately with explicit content-type so curl | bash works
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] s3 cp website/install → s3://${S3_BUCKET}/install (text/plain)"
else
    aws_cmd s3 cp "${WEBSITE_DIR}/install" "s3://${S3_BUCKET}/install" \
        --content-type "text/plain; charset=utf-8" \
        --cache-control "max-age=60, must-revalidate"
fi

if [[ "${DRY_RUN}" != "true" ]]; then
    echo ""
    echo "  Deploy complete."
    echo "  https://pi2s3.com"
    echo "  https://pi2s3.com/install"
fi
