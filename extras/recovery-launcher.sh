#!/usr/bin/env bash
# =============================================================
# extras/recovery-launcher.sh — First-boot restore launcher
#
# Runs automatically on the pi2s3 recovery USB when the Pi boots.
# Prompts for S3 config + AWS credentials if not yet set, then
# launches pi-image-restore.sh interactively.
#
# Called from /home/pi/.bash_profile on the recovery USB image.
# Do not run this manually — use pi-image-restore.sh directly.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI2S3_DIR="$(dirname "${SCRIPT_DIR}")"
CONFIG_FILE="${PI2S3_DIR}/config.env"

clear
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║         pi2s3  Recovery Environment          ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  This Pi is running a pi2s3 recovery image."
echo "  It will guide you through restoring a backup"
echo "  from S3 to a connected NVMe or storage device."
echo ""

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "  First run — enter your S3 details."
    echo "  (These are saved to ${CONFIG_FILE} for this session.)"
    echo ""
    read -r -p "  S3 bucket name (e.g. my-pi-backups): " _bucket
    read -r -p "  AWS region     (e.g. af-south-1):    " _region
    echo ""

    cat > "${CONFIG_FILE}" <<EOF
S3_BUCKET="${_bucket}"
S3_REGION="${_region}"
AWS_PROFILE=""
BACKUP_ENCRYPTION_PASSPHRASE=""
EOF
    echo "  Saved. Now configure your AWS credentials:"
    echo ""
    aws configure
    echo ""
fi

echo "  Starting restore..."
echo ""
exec bash "${PI2S3_DIR}/pi-image-restore.sh" "$@"
