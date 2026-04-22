#!/usr/bin/env bash
# =============================================================
# install.sh — Set up pi2s3 on a Raspberry Pi
#
# Run once on the Pi after cloning this repo:
#   git clone https://github.com/andrewbakercloudscale/pi2s3.git ~/pi2s3
#   cd ~/pi2s3
#   bash install.sh
#
# What this does:
#   1. Creates config.env from config.env.example (if not present)
#   2. Installs dependencies: pigz, pv, AWS CLI v2
#   3. Verifies AWS credentials and S3 bucket access
#   4. Sets up S3 lifecycle policy (run once)
#   5. Creates log file with correct ownership (before cron fires)
#   6. Installs nightly backup + heartbeat + post-check cron jobs
#   7. Sets up log rotation
#   8. Optionally installs the Cloudflare tunnel watchdog
#      (if CF_WATCHDOG_ENABLED=true in config.env)
#   9. Runs --dry-run to verify everything works
#
# Options:
#   bash install.sh --uninstall   # remove cron jobs (backup + watchdog + heartbeat)
#   bash install.sh --status      # show current state
#   bash install.sh --watchdog    # install/reinstall watchdog only
#   bash install.sh --upgrade     # git pull + redeploy watchdog binary
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/pi-image-backup.sh"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/extras/cf-tunnel-watchdog.sh"
WATCHDOG_BIN="/usr/local/bin/pi2s3-watchdog.sh"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
CONFIG_EXAMPLE="${SCRIPT_DIR}/config.env.example"
LOG_FILE="/var/log/pi2s3-backup.log"
CRON_MARKER="pi-image-backup.sh"
WATCHDOG_CRON_MARKER="pi2s3-watchdog.sh"
HEARTBEAT_SCRIPT="${SCRIPT_DIR}/pi2s3-heartbeat.sh"
HEARTBEAT_CRON_MARKER="pi2s3-heartbeat.sh"
POST_CHECK_SCRIPT="${SCRIPT_DIR}/pi2s3-post-backup-check.sh"
POST_CHECK_CRON_MARKER="pi2s3-post-backup-check.sh"
STALE_CHECK_CRON_MARKER="pi-image-backup.sh --stale-check"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*"; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ ERROR: $*" >&2; exit 1; }

# Save a snapshot of the current user crontab before modifying it.
# Prints the backup path. Safe to call multiple times — idempotent per session.
_CRONTAB_SNAPSHOT=""
crontab_snapshot() {
    if [[ -z "${_CRONTAB_SNAPSHOT}" ]]; then
        _CRONTAB_SNAPSHOT="/tmp/pi2s3-crontab-backup-$(date +%Y%m%d-%H%M%S)"
        crontab -l > "${_CRONTAB_SNAPSHOT}" 2>/dev/null || true
        log "  Crontab snapshot saved to ${_CRONTAB_SNAPSHOT} (restore: crontab ${_CRONTAB_SNAPSHOT})"
    fi
}
_ROOT_CRONTAB_SNAPSHOT=""
root_crontab_snapshot() {
    if [[ -z "${_ROOT_CRONTAB_SNAPSHOT}" ]]; then
        _ROOT_CRONTAB_SNAPSHOT="/tmp/pi2s3-root-crontab-backup-$(date +%Y%m%d-%H%M%S)"
        sudo crontab -l > "${_ROOT_CRONTAB_SNAPSHOT}" 2>/dev/null || true
        log "  Root crontab snapshot saved to ${_ROOT_CRONTAB_SNAPSHOT}"
    fi
}

# ── Pre-commit hook: block commits on the Pi ─────────────────────────────────
install_no_commit_hook() {
    local hook="${SCRIPT_DIR}/.git/hooks/pre-commit"
    cat > "${hook}" <<'HOOKEOF'
#!/usr/bin/env bash
echo ""
echo "  ✗ ERROR: Do not commit directly on the Pi."
echo "  Edit locally on your Mac, then deploy:"
echo "    git commit && git push && bash deploy-pi.sh"
echo ""
exit 1
HOOKEOF
    chmod +x "${hook}"
}

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
    root_crontab_snapshot
    ( sudo crontab -l 2>/dev/null | grep -v "${WATCHDOG_CRON_MARKER}" || true
      echo "${WATCHDOG_CRON}" ) | sudo crontab -
    ok "Root cron installed: every 5 minutes"

    # Enable persistent journal so watchdog logs survive reboots
    sudo mkdir -p /var/log/journal /etc/systemd/journald.conf.d
    cat | sudo tee /etc/systemd/journald.conf.d/99-pi2s3-persistent.conf > /dev/null <<'JOURNALEOF'
[Journal]
Storage=persistent
SystemMaxUse=300M
MaxRetentionSec=30day
JOURNALEOF
    sudo systemctl restart systemd-journald 2>/dev/null || true
    ok "Persistent journal enabled (300MB cap, 30-day retention)"

    log ""
    log "  Test run:    sudo ${WATCHDOG_BIN}"
    log "  Check logs:  sudo journalctl -t pi2s3-watchdog --since today"
    log "  Site hostname: ${CF_SITE_HOSTNAME:-$(hostname)}"
    log "  HTTP probe:  http://localhost:${CF_HTTP_PORT:-80}${CF_HTTP_PROBE_PATH:-/}"
    log "  CF metrics:  ${CF_METRICS_URL:-http://127.0.0.1:20241/metrics}"
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
upgrade() {
    log "Upgrading pi2s3..."

    # Pull latest code
    if git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        BEFORE=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        git -C "${SCRIPT_DIR}" pull --ff-only
        AFTER=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        if [[ "${BEFORE}" != "${AFTER}" ]]; then
            ok "Code updated: ${BEFORE} → ${AFTER}"
        else
            ok "Already up to date (${AFTER})"
        fi
    else
        warn "Not a git repo — skipping git pull. Update files manually."
    fi

    # Redeploy watchdog binary if installed
    if [[ -f "${WATCHDOG_BIN}" ]]; then
        if [[ -f "${WATCHDOG_SCRIPT}" ]]; then
            sudo cp "${WATCHDOG_SCRIPT}" "${WATCHDOG_BIN}"
            sudo chmod +x "${WATCHDOG_BIN}"
            ok "Watchdog binary updated: ${WATCHDOG_BIN}"
        else
            warn "cf-tunnel-watchdog.sh not found — watchdog binary NOT updated"
        fi
    else
        log "  Watchdog not installed — skipping watchdog update."
    fi

    # Update backup cron schedule if it changed in config
    # shellcheck disable=SC1090
    [[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" || true
    CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"
    CRON_LINE="${CRON_SCHEDULE} bash ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1"
    if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
        crontab_snapshot
        ( crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}"; echo "${CRON_LINE}" ) | crontab -
        ok "Backup cron refreshed: ${CRON_SCHEDULE}"
    fi

    # Update stale-check cron schedule if it changed
    STALE_CHECK_SCHEDULE="${STALE_CHECK_SCHEDULE:-0 6 * * *}"
    if crontab -l 2>/dev/null | grep -qF "${STALE_CHECK_CRON_MARKER}"; then
        STALE_CHECK_CRON_LINE="${STALE_CHECK_SCHEDULE} bash ${BACKUP_SCRIPT} --stale-check >> ${LOG_FILE} 2>&1"
        ( crontab -l 2>/dev/null | grep -vF "${STALE_CHECK_CRON_MARKER}"; echo "${STALE_CHECK_CRON_LINE}" ) | crontab -
        ok "Stale-check cron refreshed: ${STALE_CHECK_SCHEDULE}"
    fi

    # Update post-backup check cron if schedule changed
    POST_BACKUP_CHECK_ENABLED="${POST_BACKUP_CHECK_ENABLED:-true}"
    POST_BACKUP_CHECK_SCHEDULE="${POST_BACKUP_CHECK_SCHEDULE:-30 2 * * *}"
    if [[ "${POST_BACKUP_CHECK_ENABLED}" == "true" ]] \
       && crontab -l 2>/dev/null | grep -qF "${POST_CHECK_CRON_MARKER}"; then
        POST_CHECK_CRON_LINE="${POST_BACKUP_CHECK_SCHEDULE} bash ${POST_CHECK_SCRIPT} >> ${LOG_FILE} 2>&1"
        ( crontab -l 2>/dev/null | grep -vF "${POST_CHECK_CRON_MARKER}"
          echo "${POST_CHECK_CRON_LINE}" ) | crontab -
        ok "Post-backup check cron refreshed: ${POST_BACKUP_CHECK_SCHEDULE}"
    fi

    # Block direct commits on the Pi
    install_no_commit_hook
    ok "Pre-commit hook: direct commits on Pi blocked"

    # Check for new keys in config.env.example that are missing from config.env
    if [[ -f "${CONFIG_FILE}" && -f "${CONFIG_EXAMPLE}" ]]; then
        local _new_keys=()
        while IFS= read -r _line; do
            [[ "${_line}" =~ ^[A-Z_]+=  ]] || continue
            local _key="${_line%%=*}"
            grep -qE "^#?${_key}=" "${CONFIG_FILE}" 2>/dev/null || _new_keys+=("${_key}")
        done < <(grep -E '^[A-Z_]+=' "${CONFIG_EXAMPLE}")
        if [[ ${#_new_keys[@]} -gt 0 ]]; then
            warn "New config keys in config.env.example not yet in your config.env:"
            for _k in "${_new_keys[@]}"; do
                warn "  ${_k}"
            done
            warn "Review ${CONFIG_EXAMPLE} and add any you want to use."
        fi
    fi

    log ""
    log "Upgrade complete. Run 'bash install.sh --status' to verify."
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
    log "Uninstalling pi2s3..."

    if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
        crontab_snapshot
        ( crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}" ) | crontab -
        ok "Backup cron removed."
    else
        log "No backup cron found."
    fi

    if sudo crontab -l 2>/dev/null | grep -qF "${WATCHDOG_CRON_MARKER}"; then
        root_crontab_snapshot
        ( sudo crontab -l 2>/dev/null | grep -v "${WATCHDOG_CRON_MARKER}" ) \
            | sudo crontab -
        ok "Watchdog root cron removed."
    fi

    if crontab -l 2>/dev/null | grep -qF "${POST_CHECK_CRON_MARKER}"; then
        ( crontab -l 2>/dev/null | grep -vF "${POST_CHECK_CRON_MARKER}" ) | crontab -
        ok "Post-backup check cron removed."
    fi

    if crontab -l 2>/dev/null | grep -qF "${STALE_CHECK_CRON_MARKER}"; then
        ( crontab -l 2>/dev/null | grep -vF "${STALE_CHECK_CRON_MARKER}" ) | crontab -
        ok "Stale-check cron removed."
    fi

    if [[ -f "${WATCHDOG_BIN}" ]]; then
        sudo rm -f "${WATCHDOG_BIN}"
        ok "Watchdog binary removed: ${WATCHDOG_BIN}"
    fi

    if crontab -l 2>/dev/null | grep -qF "${HEARTBEAT_CRON_MARKER}"; then
        ( crontab -l 2>/dev/null | grep -vF "${HEARTBEAT_CRON_MARKER}" ) | crontab -
        ok "Heartbeat cron removed."
    fi

    if [[ -f /etc/logrotate.d/pi2s3-backup ]]; then
        sudo rm -f /etc/logrotate.d/pi2s3-backup
        ok "Log rotation config removed."
    fi
    log "Done. config.env, backup scripts, and S3 data are untouched."
}

# ── Status ────────────────────────────────────────────────────────────────────
status() {
    echo ""
    echo "=== pi2s3 status ==="
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
        if [[ -f "${WATCHDOG_BIN}" ]]; then
            # Check if the installed binary matches the source file
            if [[ -f "${WATCHDOG_SCRIPT}" ]] \
               && ! diff -q "${WATCHDOG_SCRIPT}" "${WATCHDOG_BIN}" > /dev/null 2>&1; then
                echo "  Binary: ${WATCHDOG_BIN} (STALE — source has changed)"
                echo "  Update: bash ${SCRIPT_DIR}/install.sh --watchdog"
            else
                echo "  Binary: ${WATCHDOG_BIN} (present, up-to-date)"
            fi
        else
            echo "  Binary: ${WATCHDOG_BIN} (MISSING — reinstall: bash install.sh --watchdog)"
        fi
    else
        echo "  (not installed — set CF_WATCHDOG_ENABLED=true to enable)"
    fi

    echo ""
    echo "Post-backup check cron:"
    if crontab -l 2>/dev/null | grep -qF "${POST_CHECK_CRON_MARKER}"; then
        crontab -l 2>/dev/null | grep "${POST_CHECK_CRON_MARKER}" | sed 's/^/  /'
    else
        echo "  (not installed — set POST_BACKUP_CHECK_ENABLED=true to enable)"
    fi

    echo ""
    echo "Stale-check cron:"
    if crontab -l 2>/dev/null | grep -qF "${STALE_CHECK_CRON_MARKER}"; then
        crontab -l 2>/dev/null | grep -F "${STALE_CHECK_CRON_MARKER}" | sed 's/^/  /'
    else
        echo "  (not installed — set STALE_CHECK_ENABLED=true to enable)"
    fi

    echo ""
    echo "Heartbeat cron:"
    if crontab -l 2>/dev/null | grep -qF "${HEARTBEAT_CRON_MARKER}"; then
        crontab -l 2>/dev/null | grep "${HEARTBEAT_CRON_MARKER}" | sed 's/^/  /'
    else
        echo "  (not installed — set NTFY_HEARTBEAT_ENABLED=true to enable)"
    fi

    echo ""
    echo "Log (${LOG_FILE}):"
    if [[ -f "${LOG_FILE}" ]]; then
        if [[ ! -w "${LOG_FILE}" ]]; then
            echo "  WARNING: log file exists but is not writable — cron jobs will silently fail"
            echo "  Fix: sudo chown $(id -u):$(id -g) ${LOG_FILE}"
        elif [[ ! -s "${LOG_FILE}" ]]; then
            echo "  (file exists but is empty — backup has not run yet)"
        else
            tail -5 "${LOG_FILE}" | sed 's/^/  /'
        fi
    else
        echo "  WARNING: log file missing — cron jobs will silently fail until created"
        echo "  Fix: sudo touch ${LOG_FILE} && sudo chown $(id -u):$(id -g) ${LOG_FILE}"
    fi

    echo ""
    echo "Watchdog log (last 5 lines):"
    sudo journalctl -t pi2s3-watchdog -n 5 --no-pager 2>/dev/null \
        | sed 's/^/  /' || echo "  (no watchdog log yet)"

    echo ""
    echo "Dependencies:"
    command -v aws  &>/dev/null \
        && echo "  aws CLI:  $(aws --version 2>&1 | head -1)" \
        || echo "  aws CLI:  NOT INSTALLED"
    command -v pigz &>/dev/null \
        && echo "  pigz:     $(pigz --version 2>&1)" \
        || echo "  pigz:     not installed (gzip fallback)"
    { command -v partclone.ext4 &>/dev/null || [[ -x /usr/sbin/partclone.ext4 ]]; } \
        && echo "  partclone: $(/usr/sbin/partclone.ext4 --version 2>&1 | head -1 || echo 'installed')" \
        || echo "  partclone: NOT INSTALLED (run install.sh to fix)"
    command -v pv   &>/dev/null \
        && echo "  pv:       $(pv --version 2>&1 | head -1)" \
        || echo "  pv:       not installed (no progress bar on restore)"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {

case "${1:-}" in
    --uninstall)   uninstall;        exit 0 ;;
    --status)      status;           exit 0 ;;
    --watchdog)    install_watchdog; exit 0 ;;
    --upgrade)     upgrade;          exit 0 ;;
    --iam-policy)
        # Print the minimum IAM policy, substituting bucket name if config.env exists
        local _bucket="YOUR-BUCKET-NAME"
        [[ -f "${CONFIG_FILE}" ]] && { source "${CONFIG_FILE}" 2>/dev/null || true; }
        [[ -n "${S3_BUCKET:-}" ]] && _bucket="${S3_BUCKET}"
        sed "s/YOUR-BUCKET-NAME/${_bucket}/g" "${SCRIPT_DIR}/iam-policy.json"
        echo ""
        echo "  Apply with:"
        echo "    aws iam put-user-policy --user-name <USER> --policy-name pi2s3 \\"
        echo "      --policy-document file://${SCRIPT_DIR}/iam-policy.json"
        exit 0 ;;
esac

# ── Install ───────────────────────────────────────────────────────────────────
log "============================================================"
log "  pi2s3 — installation"
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

    read -r -p "  ntfy URL (e.g. https://ntfy.sh/my-topic, or Enter to skip):  " input_ntfy

    # Write the values into config.env
    sed -i \
        -e "s|S3_BUCKET=\"\"|S3_BUCKET=\"${input_bucket}\"|" \
        -e "s|S3_REGION=\"us-east-1\"|S3_REGION=\"${input_region}\"|" \
        "${CONFIG_FILE}"
    if [[ -n "${input_ntfy}" ]]; then
        sed -i "s|NTFY_URL=\"https://ntfy.sh/YOUR_TOPIC\"|NTFY_URL=\"${input_ntfy}\"|" "${CONFIG_FILE}"
    else
        sed -i "s|NTFY_URL=\"https://ntfy.sh/YOUR_TOPIC\"|NTFY_URL=\"\"|" "${CONFIG_FILE}"
        warn "ntfy skipped — no push notifications. Set NTFY_URL in config.env to enable later."
    fi

    ok "config.env configured."
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

[[ -z "${S3_BUCKET:-}" ]] && die "S3_BUCKET is empty in config.env. Edit it and re-run."
[[ -z "${S3_REGION:-}" ]] && die "S3_REGION is empty in config.env. Edit it and re-run."
[[ -z "${NTFY_URL:-}"  ]] && warn "NTFY_URL is not set — backups will run silently with no push notifications."

CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"
MAX_IMAGES="${MAX_IMAGES:-60}"

# ── Step 2: Dependencies ──────────────────────────────────────────────────────
log ""
log "Step 2: Installing dependencies..."

# Detect package manager (Debian/Ubuntu/Raspbian: apt; Arch: pacman; Fedora/RHEL: dnf/yum)
if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    pkg_install() { sudo apt-get install -y -qq "$@"; }
    pkg_update()  { sudo apt-get update -qq; }
elif command -v dnf &>/dev/null; then
    pkg_install() { sudo dnf install -y -q "$@"; }
    pkg_update()  { true; }
elif command -v yum &>/dev/null; then
    pkg_install() { sudo yum install -y -q "$@"; }
    pkg_update()  { true; }
elif command -v pacman &>/dev/null; then
    pkg_install() { sudo pacman -S --noconfirm --quiet "$@"; }
    pkg_update()  { sudo pacman -Sy --quiet; }
else
    pkg_install() { warn "No supported package manager found. Install manually: $*"; return 1; }
    pkg_update()  { true; }
fi

if command -v pigz &>/dev/null; then
    ok "pigz: $(pigz --version 2>&1)"
else
    log "  Installing pigz..."
    pkg_update && pkg_install pigz
    ok "pigz installed."
fi

if command -v pv &>/dev/null; then
    ok "pv: $(pv --version 2>&1 | head -1)"
else
    log "  Installing pv (progress viewer)..."
    pkg_install pv 2>/dev/null && ok "pv installed." \
        || warn "pv unavailable — restore will work without it."
fi

if command -v partclone.ext4 &>/dev/null || [[ -x /usr/sbin/partclone.ext4 ]]; then
    ok "partclone: $(/usr/sbin/partclone.ext4 --version 2>&1 | head -1 || echo 'installed')"
else
    log "  Installing partclone (reads only used blocks — much faster than dd)..."
    pkg_install partclone
    ok "partclone installed."
fi

if command -v aws &>/dev/null; then
    ok "AWS CLI: $(aws --version 2>&1 | head -1)"
else
    log "  Installing AWS CLI v2..."
    ARCH=$(uname -m)
    if [[ "${ARCH}" == "aarch64" ]]; then
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    elif [[ "${ARCH}" == "x86_64" ]]; then
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    else
        warn "AWS CLI v2 has no official build for ${ARCH} (32-bit ARM)."
        warn "Upgrade to 64-bit Raspberry Pi OS for automatic install, or follow:"
        warn "  https://github.com/aws/aws-cli/issues/7207"
        die "Cannot auto-install AWS CLI on ${ARCH}. Install manually then re-run."
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

_aws_ls_err=$(${AWS_CMD} s3 ls "s3://${S3_BUCKET}/" 2>&1)
_aws_ls_rc=$?
if [[ ${_aws_ls_rc} -ne 0 ]]; then
    if echo "${_aws_ls_err}" | grep -qiE "NoSuchBucket|does not exist"; then
        warn "Bucket s3://${S3_BUCKET}/ does not exist."
        echo ""
        read -r -p "  Create it now in ${S3_REGION}? [Y/n] " do_create
        if [[ "${do_create,,}" != "n" ]]; then
            if [[ "${S3_REGION}" == "us-east-1" ]]; then
                ${AWS_CMD} s3 mb "s3://${S3_BUCKET}/" \
                    && ok "Bucket created: s3://${S3_BUCKET}/" \
                    || die "Could not create bucket. Check IAM permissions: bash install.sh --iam-policy"
            else
                ${AWS_CMD} s3 mb "s3://${S3_BUCKET}/" \
                    --create-bucket-configuration LocationConstraint="${S3_REGION}" \
                    && ok "Bucket created: s3://${S3_BUCKET}/" \
                    || die "Could not create bucket. Check IAM permissions: bash install.sh --iam-policy"
            fi
        else
            warn "Skipping. Create the bucket before the first backup."
        fi
    elif echo "${_aws_ls_err}" | grep -qiE "UnableToLocateCredentials|InvalidClientTokenId|ExpiredToken|AccessDenied|AuthorizationError"; then
        warn "AWS credentials issue: ${_aws_ls_err}"
        echo ""
        echo "  Required IAM permissions (run to see the exact policy):"
        echo "    bash install.sh --iam-policy"
        echo ""
        read -r -p "  Run 'aws configure' now? [y/N] " do_configure
        if [[ "${do_configure,,}" == "y" ]]; then
            aws configure
            ${AWS_CMD} s3 ls "s3://${S3_BUCKET}/" > /dev/null 2>&1 \
                && ok "AWS access confirmed." \
                || die "Still cannot access bucket. Run 'bash install.sh --iam-policy' to see required permissions."
        else
            warn "Skipping. Run 'aws configure' before the first backup."
        fi
    else
        warn "Cannot access s3://${S3_BUCKET}/: ${_aws_ls_err}"
        echo "  Required IAM permissions: bash install.sh --iam-policy"
    fi
else
    ok "AWS access confirmed: s3://${S3_BUCKET}/"
fi

# ── Step 4: S3 lifecycle policy ───────────────────────────────────────────────
log ""
log "Step 4: Configuring S3 lifecycle policy..."
bash "${BACKUP_SCRIPT}" --setup 2>/dev/null \
    && ok "S3 lifecycle policy set." \
    || warn "Could not set lifecycle policy (needs s3:PutLifecycleConfiguration)."
log "  Script-managed retention: ${MAX_IMAGES} images."

# ── Step 5: Log file (must exist before cron fires) ──────────────────────────
log ""
log "Step 5: Setting up log file..."

if [[ ! -f "${LOG_FILE}" ]]; then
    sudo touch "${LOG_FILE}"
    sudo chown "$(id -u):$(id -g)" "${LOG_FILE}"
    ok "Log file created: ${LOG_FILE}"
elif [[ ! -w "${LOG_FILE}" ]]; then
    sudo chown "$(id -u):$(id -g)" "${LOG_FILE}"
    ok "Log file ownership fixed: ${LOG_FILE}"
else
    ok "Log file OK: ${LOG_FILE}"
fi

# ── Step 6: Cron job ──────────────────────────────────────────────────────────
log ""
log "Step 6: Installing cron job..."

CRON_LINE="${CRON_SCHEDULE} bash ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1"

if crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
    ( crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}"; echo "${CRON_LINE}" ) | crontab -
    ok "Cron job updated."
else
    ( crontab -l 2>/dev/null; echo "${CRON_LINE}" ) | crontab -
    ok "Cron job installed."
fi
log "  Schedule: ${CRON_SCHEDULE}"

# ── Step 6b: Heartbeat cron (optional) ───────────────────────────────────────
NTFY_HEARTBEAT_ENABLED="${NTFY_HEARTBEAT_ENABLED:-false}"
NTFY_HEARTBEAT_SCHEDULE="${NTFY_HEARTBEAT_SCHEDULE:-0 8 * * *}"

if [[ "${NTFY_HEARTBEAT_ENABLED}" == "true" ]]; then
    if [[ -f "${HEARTBEAT_SCRIPT}" ]]; then
        HEARTBEAT_CRON_LINE="${NTFY_HEARTBEAT_SCHEDULE} bash ${HEARTBEAT_SCRIPT} >> ${LOG_FILE} 2>&1"
        if crontab -l 2>/dev/null | grep -qF "${HEARTBEAT_CRON_MARKER}"; then
            ( crontab -l 2>/dev/null | grep -vF "${HEARTBEAT_CRON_MARKER}"
              echo "${HEARTBEAT_CRON_LINE}" ) | crontab -
            ok "Heartbeat cron updated: ${NTFY_HEARTBEAT_SCHEDULE}"
        else
            ( crontab -l 2>/dev/null; echo "${HEARTBEAT_CRON_LINE}" ) | crontab -
            ok "Heartbeat cron installed: ${NTFY_HEARTBEAT_SCHEDULE}"
        fi
    else
        warn "pi2s3-heartbeat.sh not found — skipping heartbeat cron"
    fi
else
    log "  Heartbeat disabled (NTFY_HEARTBEAT_ENABLED=false in config.env)."
    log "  To enable: set NTFY_HEARTBEAT_ENABLED=true then re-run install.sh"
fi

# ── Step 6c: Post-backup container safety check (optional) ───────────────────
POST_BACKUP_CHECK_ENABLED="${POST_BACKUP_CHECK_ENABLED:-true}"
POST_BACKUP_CHECK_SCHEDULE="${POST_BACKUP_CHECK_SCHEDULE:-30 2 * * *}"

if [[ "${POST_BACKUP_CHECK_ENABLED}" == "true" ]]; then
    if [[ -f "${POST_CHECK_SCRIPT}" ]]; then
        POST_CHECK_CRON_LINE="${POST_BACKUP_CHECK_SCHEDULE} bash ${POST_CHECK_SCRIPT} >> ${LOG_FILE} 2>&1"
        if crontab -l 2>/dev/null | grep -qF "${POST_CHECK_CRON_MARKER}"; then
            ( crontab -l 2>/dev/null | grep -vF "${POST_CHECK_CRON_MARKER}"
              echo "${POST_CHECK_CRON_LINE}" ) | crontab -
            ok "Post-backup check cron updated: ${POST_BACKUP_CHECK_SCHEDULE}"
        else
            ( crontab -l 2>/dev/null; echo "${POST_CHECK_CRON_LINE}" ) | crontab -
            ok "Post-backup check cron installed: ${POST_BACKUP_CHECK_SCHEDULE}"
        fi
        log "  Runs ${POST_BACKUP_CHECK_SCHEDULE} — restarts stopped containers after backup window."
    else
        warn "pi2s3-post-backup-check.sh not found — skipping post-check cron"
    fi
else
    log "  Post-backup check disabled (POST_BACKUP_CHECK_ENABLED=false in config.env)."
    log "  To enable: set POST_BACKUP_CHECK_ENABLED=true then re-run install.sh"
fi

# ── Step 6d: Missed backup stale-check cron (optional) ───────────────────────
STALE_CHECK_ENABLED="${STALE_CHECK_ENABLED:-true}"
STALE_CHECK_SCHEDULE="${STALE_CHECK_SCHEDULE:-0 6 * * *}"

if [[ "${STALE_CHECK_ENABLED}" == "true" ]]; then
    STALE_CHECK_CRON_LINE="${STALE_CHECK_SCHEDULE} bash ${BACKUP_SCRIPT} --stale-check >> ${LOG_FILE} 2>&1"
    if crontab -l 2>/dev/null | grep -qF "${STALE_CHECK_CRON_MARKER}"; then
        ( crontab -l 2>/dev/null | grep -vF "${STALE_CHECK_CRON_MARKER}"
          echo "${STALE_CHECK_CRON_LINE}" ) | crontab -
        ok "Stale-check cron updated: ${STALE_CHECK_SCHEDULE}"
    else
        ( crontab -l 2>/dev/null; echo "${STALE_CHECK_CRON_LINE}" ) | crontab -
        ok "Stale-check cron installed: ${STALE_CHECK_SCHEDULE}"
    fi
    log "  Alerts via ntfy if no backup seen in ${STALE_BACKUP_HOURS:-25}h."
else
    log "  Stale-check disabled (STALE_CHECK_ENABLED=false in config.env)."
fi

# ── Step 7: Log rotation ──────────────────────────────────────────────────────
log ""
log "Step 7: Setting up log rotation..."

cat > /tmp/pi2s3-logrotate << EOF
${LOG_FILE} {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
sudo mv /tmp/pi2s3-logrotate /etc/logrotate.d/pi2s3-backup
ok "Log rotation configured: ${LOG_FILE} (weekly, 4 weeks retained)"

# ── Step 8: Cloudflare tunnel watchdog (optional) ────────────────────────────
log ""
log "Step 8: Cloudflare tunnel watchdog..."

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

# ── Step 8b: Pre-commit hook ─────────────────────────────────────────────────
install_no_commit_hook
ok "Pre-commit hook: direct commits on Pi blocked"

# ── Step 9: Dry run ───────────────────────────────────────────────────────────
log ""
log "Step 9: Dry run..."
if bash "${BACKUP_SCRIPT}" --dry-run; then
    ok "Dry run successful — everything looks good."
    echo ""
    read -r -p "  Run a real backup now? This uploads to S3 immediately. [Y/n] " do_backup
    if [[ "${do_backup,,}" != "n" ]]; then
        log ""
        log "  Running first backup..."
        bash "${BACKUP_SCRIPT}" --force \
            && ok "First backup complete. Check s3://${S3_BUCKET}/ to confirm." \
            || warn "Backup had issues. Review the log: tail -50 ${LOG_FILE}"
    fi
else
    warn "Dry run had issues. Review the output above before running a real backup."
fi

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
    log "  Watchdog logs:  sudo journalctl -t pi2s3-watchdog --since today"
fi
log ""
log "  Commands:"
log "    Run now:           bash ${BACKUP_SCRIPT} --force"
log "    Dry run:           bash ${BACKUP_SCRIPT} --dry-run"
log "    List backups:      bash ${BACKUP_SCRIPT} --list"
log "    Verify S3 image:   bash ${BACKUP_SCRIPT} --verify"
log "    Restore new Pi:    bash ${SCRIPT_DIR}/pi-image-restore.sh"
log "    Verify flashed:    bash ${SCRIPT_DIR}/pi-image-restore.sh --verify /dev/diskN"
log "    Status:            bash ${SCRIPT_DIR}/install.sh --status"
log "    Upgrade:           bash ${SCRIPT_DIR}/install.sh --upgrade"
log "    Install watchdog:  bash ${SCRIPT_DIR}/install.sh --watchdog"
log "    Test watchdog:     sudo ${WATCHDOG_BIN}"
log "============================================================"

} # end main

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
