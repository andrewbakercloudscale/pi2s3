#!/usr/bin/env bash
# =============================================================
# install.sh — Set up Pi MI on a Raspberry Pi
#
# Run once on the Pi after cloning this repo:
#   git clone https://github.com/andrewbakercloudscale/pi-mi.git ~/pi-mi
#   cd ~/pi-mi
#   bash install.sh
#
# What this does:
#   1. Creates config.env from config.env.example (if not present)
#   2. Installs dependencies: pigz, pv, AWS CLI v2
#   3. Verifies AWS credentials and S3 bucket access
#   4. Sets up S3 lifecycle policy (run once)
#   5. Installs nightly cron job
#   6. Sets up log rotation
#   7. Runs --dry-run to verify everything works
#
# To uninstall the cron job:
#   bash install.sh --uninstall
#
# To check status:
#   bash install.sh --status
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/pi-image-backup.sh"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
CONFIG_EXAMPLE="${SCRIPT_DIR}/config.env.example"
LOG_FILE="/var/log/pi-mi-backup.log"
CRON_MARKER="pi-image-backup.sh"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*"; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ ERROR: $*" >&2; exit 1; }

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
    log "Uninstalling Pi MI cron job..."
    if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
        ( crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}" ) | crontab -
        ok "Cron job removed."
    else
        log "No cron job found."
    fi
    if [[ -f /etc/logrotate.d/pi-mi-backup ]]; then
        sudo rm -f /etc/logrotate.d/pi-mi-backup
        ok "Log rotation config removed."
    fi
    log "Done. config.env, backup scripts, and S3 data are untouched."
}

# ── Status ────────────────────────────────────────────────────────────────────
status() {
    echo ""
    echo "=== Pi MI status ==="
    echo ""

    echo "Config (${CONFIG_FILE}):"
    if [[ -f "${CONFIG_FILE}" ]]; then
        grep -v '^#' "${CONFIG_FILE}" | grep -v '^$' | sed 's/^/  /'
    else
        echo "  (not created — run install.sh)"
    fi

    echo ""
    echo "Cron job:"
    if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
        crontab -l 2>/dev/null | grep "${CRON_MARKER}" | sed 's/^/  /'
    else
        echo "  (not installed)"
    fi

    echo ""
    echo "Log (${LOG_FILE}):"
    if [[ -f "${LOG_FILE}" ]]; then
        tail -5 "${LOG_FILE}" | sed 's/^/  /'
    else
        echo "  (no log yet)"
    fi

    echo ""
    echo "Dependencies:"
    command -v aws  &>/dev/null \
        && echo "  aws CLI:  $(aws --version 2>&1 | head -1)" \
        || echo "  aws CLI:  NOT INSTALLED"
    command -v pigz &>/dev/null \
        && echo "  pigz:     $(pigz --version 2>&1)" \
        || echo "  pigz:     not installed (gzip fallback)"
    command -v pv   &>/dev/null \
        && echo "  pv:       $(pv --version 2>&1 | head -1)" \
        || echo "  pv:       not installed (no progress bar on restore)"
    echo ""
}

case "${1:-}" in
    --uninstall) uninstall; exit 0 ;;
    --status)    status;    exit 0 ;;
esac

# ── Install ───────────────────────────────────────────────────────────────────
log "============================================================"
log "  Pi MI — installation"
log "  Host: $(hostname) | $(uname -m)"
log "============================================================"
echo ""

# ── Step 1: Create config.env ─────────────────────────────────────────────────
log "Step 1: Configuration..."

if [[ -f "${CONFIG_FILE}" ]]; then
    ok "config.env already exists."
else
    [[ ! -f "${CONFIG_EXAMPLE}" ]] && die "config.env.example not found. Re-clone the repo."
    cp "${CONFIG_EXAMPLE}" "${CONFIG_FILE}"
    log "  Created config.env from config.env.example."
    log ""
    log "  Fill in the required values now:"
    echo ""

    # Prompt for required values interactively
    read -r -p "  S3 bucket name:  " input_bucket
    [[ -z "${input_bucket}" ]] && die "S3_BUCKET cannot be empty."

    read -r -p "  AWS region (e.g. af-south-1, us-east-1):  " input_region
    [[ -z "${input_region}" ]] && die "S3_REGION cannot be empty."

    read -r -p "  ntfy URL (e.g. https://ntfy.sh/my-topic):  " input_ntfy
    [[ -z "${input_ntfy}" ]] && die "NTFY_URL cannot be empty."

    # Write the values into config.env
    sed -i \
        -e "s|S3_BUCKET=\"\"|S3_BUCKET=\"${input_bucket}\"|" \
        -e "s|S3_REGION=\"us-east-1\"|S3_REGION=\"${input_region}\"|" \
        -e "s|NTFY_URL=\"https://ntfy.sh/YOUR_TOPIC\"|NTFY_URL=\"${input_ntfy}\"|" \
        "${CONFIG_FILE}"

    ok "config.env configured."
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

[[ -z "${S3_BUCKET:-}" ]] && die "S3_BUCKET is empty in config.env. Edit it and re-run."
[[ -z "${S3_REGION:-}" ]] && die "S3_REGION is empty in config.env. Edit it and re-run."
[[ -z "${NTFY_URL:-}"  ]] && die "NTFY_URL is empty in config.env. Edit it and re-run."

CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"
MAX_IMAGES="${MAX_IMAGES:-60}"

# ── Step 2: Dependencies ──────────────────────────────────────────────────────
log ""
log "Step 2: Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive

if command -v pigz &>/dev/null; then
    ok "pigz: $(pigz --version 2>&1)"
else
    log "  Installing pigz..."
    sudo apt-get update -qq && sudo apt-get install -y -qq pigz
    ok "pigz installed."
fi

if command -v pv &>/dev/null; then
    ok "pv: $(pv --version 2>&1 | head -1)"
else
    log "  Installing pv (progress viewer)..."
    sudo apt-get install -y -qq pv 2>/dev/null && ok "pv installed." \
        || warn "pv unavailable — restore will work without it."
fi

if command -v aws &>/dev/null; then
    ok "AWS CLI: $(aws --version 2>&1 | head -1)"
else
    log "  Installing AWS CLI v2..."
    ARCH=$(uname -m)
    if [[ "${ARCH}" == "aarch64" ]]; then
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    else
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    fi
    cd /tmp
    curl -sL "${AWS_URL}" -o awscliv2.zip
    unzip -q awscliv2.zip
    sudo ./aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws
    cd "${SCRIPT_DIR}"
    ok "AWS CLI installed: $(aws --version 2>&1 | head -1)"
fi

# ── Step 3: Verify AWS access ─────────────────────────────────────────────────
log ""
log "Step 3: Verifying AWS access to s3://${S3_BUCKET}/ ..."

AWS_CMD="aws --region ${S3_REGION}"
[[ -n "${AWS_PROFILE:-}" ]] && AWS_CMD="${AWS_CMD} --profile ${AWS_PROFILE}"

if ! ${AWS_CMD} s3 ls "s3://${S3_BUCKET}/" > /dev/null 2>&1; then
    warn "Cannot access s3://${S3_BUCKET}/. Check credentials."
    echo ""
    read -r -p "  Run 'aws configure' now? [y/N] " do_configure
    if [[ "${do_configure,,}" == "y" ]]; then
        aws configure
        ${AWS_CMD} s3 ls "s3://${S3_BUCKET}/" > /dev/null 2>&1 \
            && ok "AWS access confirmed." \
            || die "Still cannot access bucket. Check IAM permissions."
    else
        warn "Skipping. Run 'aws configure' before the first backup."
    fi
else
    ok "AWS access confirmed."
fi

# ── Step 4: S3 lifecycle policy ───────────────────────────────────────────────
log ""
log "Step 4: Configuring S3 lifecycle policy..."
bash "${BACKUP_SCRIPT}" --setup 2>/dev/null \
    && ok "S3 lifecycle policy set." \
    || warn "Could not set lifecycle policy (needs s3:PutLifecycleConfiguration)."
log "  Script-managed retention: ${MAX_IMAGES} images."

# ── Step 5: Cron job ──────────────────────────────────────────────────────────
log ""
log "Step 5: Installing cron job..."

CRON_LINE="${CRON_SCHEDULE} bash ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1"

if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    ( crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}"; echo "${CRON_LINE}" ) | crontab -
    ok "Cron job updated."
else
    ( crontab -l 2>/dev/null; echo "${CRON_LINE}" ) | crontab -
    ok "Cron job installed."
fi
log "  Schedule: ${CRON_SCHEDULE}"

# ── Step 6: Log file + rotation ───────────────────────────────────────────────
log ""
log "Step 6: Setting up logging..."

sudo touch "${LOG_FILE}"
sudo chown "$(id -u):$(id -g)" "${LOG_FILE}"

cat > /tmp/pi-mi-logrotate << EOF
${LOG_FILE} {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
sudo mv /tmp/pi-mi-logrotate /etc/logrotate.d/pi-mi-backup
ok "Log: ${LOG_FILE} (weekly rotation, 4 weeks retained)"

# ── Step 7: Dry run ───────────────────────────────────────────────────────────
log ""
log "Step 7: Dry run..."
bash "${BACKUP_SCRIPT}" --dry-run \
    && ok "Dry run successful — everything looks good." \
    || warn "Dry run had issues. Review the output above before running a real backup."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "============================================================"
log "  Installation complete!"
log ""
log "  Nightly backup: ${CRON_SCHEDULE} → s3://${S3_BUCKET}/"
log "  Retention:      ${MAX_IMAGES} images"
log "  Log:            ${LOG_FILE}"
log ""
log "  Commands:"
log "    Run now:        bash ${BACKUP_SCRIPT} --force"
log "    Dry run:        bash ${BACKUP_SCRIPT} --dry-run"
log "    List backups:   bash ${SCRIPT_DIR}/pi-image-restore.sh --list"
log "    Restore new Pi: bash ${SCRIPT_DIR}/pi-image-restore.sh"
log "    Status:         bash ${SCRIPT_DIR}/install.sh --status"
log "============================================================"
