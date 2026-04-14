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
#   5. Installs nightly backup cron job
#   6. Sets up log rotation
#   7. Optionally installs the Cloudflare tunnel watchdog
#      (if CF_WATCHDOG_ENABLED=true in config.env)
#   8. Runs --dry-run to verify everything works
#
# Options:
#   bash install.sh --uninstall   # remove cron jobs (backup + watchdog)
#   bash install.sh --status      # show current state
#   bash install.sh --watchdog    # install/reinstall watchdog only
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/pi-image-backup.sh"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/cf-tunnel-watchdog.sh"
WATCHDOG_BIN="/usr/local/bin/pi-mi-watchdog.sh"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
CONFIG_EXAMPLE="${SCRIPT_DIR}/config.env.example"
LOG_FILE="/var/log/pi-mi-backup.log"
CRON_MARKER="pi-image-backup.sh"
WATCHDOG_CRON_MARKER="pi-mi-watchdog.sh"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*"; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ ERROR: $*" >&2; exit 1; }

# ── Install watchdog helper ───────────────────────────────────────────────────
install_watchdog() {
    log ""
    log "Installing Cloudflare tunnel watchdog..."

    # shellcheck disable=SC1090
    [[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" || true

    if [[ -z "${CF_SITE_HOSTNAME:-}" ]]; then
        warn "CF_SITE_HOSTNAME is not set in config.env — notifications will use hostname"
        warn "Set CF_SITE_HOSTNAME=\"your-site.com\" in config.env for better alerts"
    fi

    # Install script to /usr/local/bin so root cron can find it
    sudo cp "${WATCHDOG_SCRIPT}" "${WATCHDOG_BIN}"
    sudo chmod +x "${WATCHDOG_BIN}"
    ok "Watchdog installed to ${WATCHDOG_BIN}"

    # Root cron: run every 5 minutes
    WATCHDOG_CRON="*/5 * * * * ${WATCHDOG_BIN}"
    ( sudo crontab -l 2>/dev/null | grep -v "${WATCHDOG_CRON_MARKER}" || true
      echo "${WATCHDOG_CRON}" ) | sudo crontab -
    ok "Root cron installed: every 5 minutes"

    # Enable persistent journal so watchdog logs survive reboots
    sudo mkdir -p /var/log/journal /etc/systemd/journald.conf.d
    cat | sudo tee /etc/systemd/journald.conf.d/99-pi-mi-persistent.conf > /dev/null <<'JOURNALEOF'
[Journal]
Storage=persistent
SystemMaxUse=300M
MaxRetentionSec=30day
JOURNALEOF
    sudo systemctl restart systemd-journald 2>/dev/null || true
    ok "Persistent journal enabled (300MB cap, 30-day retention)"

    log ""
    log "  Test run:    sudo ${WATCHDOG_BIN}"
    log "  Check logs:  sudo journalctl -t pi-mi-watchdog --since today"
    log "  Site hostname: ${CF_SITE_HOSTNAME:-$(hostname)}"
    log "  HTTP probe:  http://localhost:${CF_HTTP_PORT:-80}${CF_HTTP_PROBE_PATH:-/}"
    log "  CF metrics:  ${CF_METRICS_URL:-http://127.0.0.1:20241/metrics}"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
    log "Uninstalling Pi MI..."

    if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
        ( crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}" ) | crontab -
        ok "Backup cron removed."
    else
        log "No backup cron found."
    fi

    if sudo crontab -l 2>/dev/null | grep -qF "${WATCHDOG_CRON_MARKER}"; then
        ( sudo crontab -l 2>/dev/null | grep -v "${WATCHDOG_CRON_MARKER}" ) \
            | sudo crontab -
        ok "Watchdog root cron removed."
    fi

    if [[ -f "${WATCHDOG_BIN}" ]]; then
        sudo rm -f "${WATCHDOG_BIN}"
        ok "Watchdog binary removed: ${WATCHDOG_BIN}"
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
    echo "Backup cron:"
    if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
        crontab -l 2>/dev/null | grep "${CRON_MARKER}" | sed 's/^/  /'
    else
        echo "  (not installed)"
    fi

    echo ""
    echo "Watchdog cron (root):"
    if sudo crontab -l 2>/dev/null | grep -qF "${WATCHDOG_CRON_MARKER}"; then
        sudo crontab -l 2>/dev/null | grep "${WATCHDOG_CRON_MARKER}" | sed 's/^/  /'
        echo "  Binary: ${WATCHDOG_BIN} ($([ -f "${WATCHDOG_BIN}" ] && echo "present" || echo "MISSING"))"
    else
        echo "  (not installed — set CF_WATCHDOG_ENABLED=true to enable)"
    fi

    echo ""
    echo "Log (${LOG_FILE}):"
    if [[ -f "${LOG_FILE}" ]]; then
        tail -5 "${LOG_FILE}" | sed 's/^/  /'
    else
        echo "  (no log yet)"
    fi

    echo ""
    echo "Watchdog log (last 5 lines):"
    sudo journalctl -t pi-mi-watchdog -n 5 --no-pager 2>/dev/null \
        | sed 's/^/  /' || echo "  (no watchdog log yet)"

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
    --uninstall) uninstall;        exit 0 ;;
    --status)    status;           exit 0 ;;
    --watchdog)  install_watchdog; exit 0 ;;
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

# ── Step 7: Cloudflare tunnel watchdog (optional) ────────────────────────────
log ""
log "Step 7: Cloudflare tunnel watchdog..."

CF_WATCHDOG_ENABLED="${CF_WATCHDOG_ENABLED:-false}"

if [[ "${CF_WATCHDOG_ENABLED}" == "true" ]]; then
    if [[ ! -f "${WATCHDOG_SCRIPT}" ]]; then
        warn "cf-tunnel-watchdog.sh not found — skipping watchdog install"
    else
        install_watchdog
        ok "Watchdog installed (runs every 5 min as root)."
    fi
else
    log "  Watchdog disabled (CF_WATCHDOG_ENABLED=false in config.env)."
    log "  To enable: set CF_WATCHDOG_ENABLED=true then run: bash install.sh --watchdog"
fi

# ── Step 8: Dry run ───────────────────────────────────────────────────────────
log ""
log "Step 8: Dry run..."
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
if [[ "${CF_WATCHDOG_ENABLED}" == "true" ]]; then
    log "  CF watchdog:    every 5 min (root cron) → ${WATCHDOG_BIN}"
    log "  Watchdog logs:  sudo journalctl -t pi-mi-watchdog --since today"
fi
log ""
log "  Commands:"
log "    Run now:           bash ${BACKUP_SCRIPT} --force"
log "    Dry run:           bash ${BACKUP_SCRIPT} --dry-run"
log "    List backups:      bash ${SCRIPT_DIR}/pi-image-restore.sh --list"
log "    Restore new Pi:    bash ${SCRIPT_DIR}/pi-image-restore.sh"
log "    Status:            bash ${SCRIPT_DIR}/install.sh --status"
log "    Install watchdog:  bash ${SCRIPT_DIR}/install.sh --watchdog"
log "    Test watchdog:     sudo ${WATCHDOG_BIN}"
log "============================================================"
