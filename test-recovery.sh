#!/usr/bin/env bash
# =============================================================
# test-recovery.sh — Pi MI recovery validation
#
# Two phases. Run them in order when testing a new Pi restore.
#
# ── PHASE 1: Pre-flash (run on your MAC before touching anything) ──
#   Validates the S3 image is present, readable, and complete.
#   Gives you a go/no-go before you commit to flashing.
#
#   bash test-recovery.sh --pre-flash
#   bash test-recovery.sh --pre-flash --date 2026-04-13
#
# ── PHASE 2: Post-boot (run on the NEW PI after first boot) ────────
#   SSH into the restored Pi and run this. Checks every service,
#   volume, tunnel, cron job, and HTTP response.
#
#   bash test-recovery.sh --post-boot
#
# ── Full walkthrough (prints the complete checklist + commands) ─────
#   bash test-recovery.sh --guide
#
# Output: PASS / FAIL / WARN for every check.
# Exit code: 0 = all passed, 1 = one or more failures.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

PHASE=""
TARGET_DATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pre-flash)  PHASE="pre-flash" ;;
        --post-boot)  PHASE="post-boot" ;;
        --guide)      PHASE="guide" ;;
        --date)       shift; TARGET_DATE="${1:-}" ;;
        --date=*)     TARGET_DATE="${1#--date=}" ;;
        *)
            echo "Usage: $0 --pre-flash [--date YYYY-MM-DD] | --post-boot | --guide"
            exit 1
            ;;
    esac
    shift
done

[[ -z "${PHASE}" ]] && {
    echo "Usage: $0 --pre-flash | --post-boot | --guide"
    echo ""
    echo "  --pre-flash   Run on Mac before flashing. Validates S3 image."
    echo "  --post-boot   Run on new Pi after first boot. Validates restore."
    echo "  --guide       Print the full step-by-step recovery walkthrough."
    exit 1
}

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { echo "  [PASS] $*"; (( PASS_COUNT++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL_COUNT++ )) || true; }
warn() { echo "  [WARN] $*"; (( WARN_COUNT++ )) || true; }
section() {
    echo ""
    echo "── $* ──────────────────────────────────────────────────────────────"
}
summary() {
    echo ""
    echo "================================================================"
    echo "  Results: ${PASS_COUNT} passed  ${FAIL_COUNT} failed  ${WARN_COUNT} warnings"
    echo "================================================================"
    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        echo "  RESULT: FAIL — address the failures above before proceeding."
        echo ""
        exit 1
    elif [[ "${WARN_COUNT}" -gt 0 ]]; then
        echo "  RESULT: PASS (with warnings) — review warnings above."
    else
        echo "  RESULT: ALL PASS"
    fi
    echo ""
}

# ── Load config (optional for post-boot) ─────────────────────────────────────
AWS_PROFILE=""
S3_BUCKET=""
S3_REGION=""
S3_PREFIX="pi-image-backup"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi

aws_cmd() {
    if [[ -n "${AWS_PROFILE}" ]]; then
        aws --profile "${AWS_PROFILE}" --region "${S3_REGION}" "$@"
    else
        aws --region "${S3_REGION}" "$@"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  GUIDE — full recovery walkthrough
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${PHASE}" == "guide" ]]; then
    cat <<'EOF'
================================================================
  Pi MI — Full Recovery Walkthrough
================================================================

BEFORE YOU START
  - New Pi (same model) ready to go
  - NVMe enclosure or SD card reader connected to Mac
  - AWS credentials configured on Mac

────────────────────────────────────────────────────────────────
STEP 1 — Validate the S3 image  (Mac)
────────────────────────────────────────────────────────────────

  bash ~/pi-mi/test-recovery.sh --pre-flash

  Expected: all checks PASS, go/no-go = GO
  If FAIL: do NOT proceed until resolved.

────────────────────────────────────────────────────────────────
STEP 2 — Flash the image  (Mac)
────────────────────────────────────────────────────────────────

  bash ~/pi-mi/pi-image-restore.sh

  What it does:
    1. Shows available backups from S3 (pick latest)
    2. Lists connected storage devices (pick your target)
    3. Final confirmation — type 'y'
    4. Streams S3 → gunzip → dd (~15–20 min for 10–15GB image)
    5. Ejects the device automatically

  On macOS: uses /dev/rdisk for ~10x faster writes.
  Optional: install pv first for a live progress bar:
    brew install pv

────────────────────────────────────────────────────────────────
STEP 3 — First boot  (new Pi)
────────────────────────────────────────────────────────────────

  1. Insert NVMe/SD into new Pi
  2. Power on
  3. Wait ~60–90 seconds for first boot
     (Raspberry Pi OS expands the filesystem automatically)
  4. Find the IP: check your router's DHCP leases
     — or try: ping -c1 raspberrypi.local

  Connecting for the first time (SSH host key will differ):
    ssh-keygen -R raspberrypi.local
    ssh-keygen -R <ip-address>
    ssh pi@raspberrypi.local

────────────────────────────────────────────────────────────────
STEP 4 — Validate the restore  (new Pi)
────────────────────────────────────────────────────────────────

  On the new Pi:
    bash ~/pi-mi/test-recovery.sh --post-boot

  Expected: all checks PASS
  If FAIL: see remediation notes printed by the script.

────────────────────────────────────────────────────────────────
STEP 5 — Smoke test the live site  (browser)
────────────────────────────────────────────────────────────────

  Visit your site URL (from the restored Pi's config).
  Check:
    - Homepage loads
    - Admin login works
    - Latest post/content is present
    - No PHP errors in page source

────────────────────────────────────────────────────────────────
STEP 6 — Cleanup (optional)
────────────────────────────────────────────────────────────────

  If the original Pi is being decommissioned:
    - Deregister from Cloudflare (if tunnel was Pi-specific)
    - Remove old DHCP reservation from router
    - Revoke old SSH host key from any jump servers

  If running both Pis simultaneously (canary test):
    - Change hostname on clone: sudo raspi-config
    - Cloudflare tunnel: one Pi can only use the token at a time

================================================================
EOF
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — Pre-flash (Mac)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${PHASE}" == "pre-flash" ]]; then

    echo ""
    echo "================================================================"
    echo "  Pi MI — Pre-flash validation"
    echo "  Confirming S3 image is ready before you flash anything."
    echo "================================================================"

    # ── Config check ─────────────────────────────────────────────────────────
    section "Configuration"

    if [[ -f "${CONFIG_FILE}" ]]; then
        pass "config.env found"
    else
        fail "config.env not found at ${CONFIG_FILE}"
        echo "         Run: cp ${SCRIPT_DIR}/config.env.example ${SCRIPT_DIR}/config.env"
        echo "              and fill in S3_BUCKET, S3_REGION, NTFY_URL"
        summary; exit 1
    fi

    [[ -n "${S3_BUCKET}" ]] && pass "S3_BUCKET = ${S3_BUCKET}" \
                             || { fail "S3_BUCKET is empty in config.env"; summary; exit 1; }
    [[ -n "${S3_REGION}" ]] && pass "S3_REGION = ${S3_REGION}" \
                             || { fail "S3_REGION is empty in config.env"; summary; exit 1; }

    # ── AWS connectivity ──────────────────────────────────────────────────────
    section "AWS access"

    if command -v aws &>/dev/null; then
        pass "aws CLI: $(aws --version 2>&1 | head -1)"
    else
        fail "aws CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/"
        summary; exit 1
    fi

    if aws_cmd s3 ls "s3://${S3_BUCKET}/" > /dev/null 2>&1; then
        pass "Can access s3://${S3_BUCKET}/"
    else
        fail "Cannot access s3://${S3_BUCKET}/. Check AWS credentials and IAM permissions."
        summary; exit 1
    fi

    # ── Find backup ───────────────────────────────────────────────────────────
    section "S3 backup inventory"

    ALL_DATES=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
        | grep PRE | awk '{print $2}' | tr -d '/' | sort -r || true)

    if [[ -z "${ALL_DATES}" ]]; then
        fail "No backups found in s3://${S3_BUCKET}/${S3_PREFIX}/"
        echo "         Has pi-image-backup.sh run at least once?"
        echo "         Run: bash ${SCRIPT_DIR}/pi-image-backup.sh --force"
        summary; exit 1
    fi

    TOTAL_BACKUPS=$(echo "${ALL_DATES}" | grep -c . || true)
    pass "${TOTAL_BACKUPS} backup(s) found in S3"

    if [[ -z "${TARGET_DATE}" ]]; then
        TARGET_DATE=$(echo "${ALL_DATES}" | head -1)
    fi
    pass "Using backup: ${TARGET_DATE}"

    S3_DATE_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${TARGET_DATE}"

    # ── Check image file ──────────────────────────────────────────────────────
    section "Image file"

    IMAGE_FILE=$(aws_cmd s3 ls "${S3_DATE_PATH}/" 2>/dev/null \
        | grep '\.img\.gz' | awk '{print $4}' | tail -1 || true)

    if [[ -z "${IMAGE_FILE}" ]]; then
        fail "No .img.gz file found in ${S3_DATE_PATH}/"
        summary; exit 1
    fi
    pass "Image file: ${IMAGE_FILE}"

    IMAGE_SIZE=$(aws_cmd s3 ls "${S3_DATE_PATH}/${IMAGE_FILE}" 2>/dev/null \
        | awk '{print $3}' | head -1 || echo "0")
    IMAGE_SIZE_HUMAN=$(numfmt --to=iec "${IMAGE_SIZE}" 2>/dev/null || echo "unknown")

    if [[ "${IMAGE_SIZE}" -gt 0 ]]; then
        pass "Image size: ${IMAGE_SIZE_HUMAN} (non-zero)"
    else
        fail "Image file appears to be 0 bytes — backup may have failed"
    fi

    # Sanity: anything under 100MB is suspicious (even a minimal Pi is bigger compressed)
    if [[ "${IMAGE_SIZE}" -gt 104857600 ]]; then
        pass "Image size sanity check: ${IMAGE_SIZE_HUMAN} > 100MB"
    else
        warn "Image is very small (${IMAGE_SIZE_HUMAN}). Was the backup cut short?"
    fi

    # ── Check manifest ────────────────────────────────────────────────────────
    section "Manifest"

    MANIFEST_FILE=$(aws_cmd s3 ls "${S3_DATE_PATH}/" 2>/dev/null \
        | grep manifest | awk '{print $4}' | head -1 || true)

    if [[ -n "${MANIFEST_FILE}" ]]; then
        pass "Manifest found: ${MANIFEST_FILE}"
        MANIFEST=$(aws_cmd s3 cp "${S3_DATE_PATH}/${MANIFEST_FILE}" - 2>/dev/null || true)
        if [[ -n "${MANIFEST}" ]]; then
            echo ""
            echo "  Backup details:"
            for field in hostname pi_model os device device_size_human compressed_size_human backup_duration_seconds; do
                val=$(echo "${MANIFEST}" | grep -o "\"${field}\": *\"[^\"]*\"" | cut -d'"' -f4 || true)
                [[ -n "${val}" ]] && printf "    %-30s %s\n" "${field}:" "${val}"
            done
            echo ""

            # Validate manifest fields
            MANIFEST_HOST=$(echo "${MANIFEST}" | grep -o '"hostname": *"[^"]*"' | cut -d'"' -f4 || true)
            MANIFEST_DEVICE=$(echo "${MANIFEST}" | grep -o '"device": *"[^"]*"' | cut -d'"' -f4 || true)
            MANIFEST_OS=$(echo "${MANIFEST}" | grep -o '"os": *"[^"]*"' | cut -d'"' -f4 || true)

            [[ -n "${MANIFEST_HOST}"   ]] && pass "Hostname in manifest: ${MANIFEST_HOST}"   || warn "Hostname missing from manifest"
            [[ -n "${MANIFEST_DEVICE}" ]] && pass "Boot device: ${MANIFEST_DEVICE}"          || warn "Device missing from manifest"
            [[ -n "${MANIFEST_OS}"     ]] && pass "OS: ${MANIFEST_OS}"                       || warn "OS missing from manifest"

            # Check for SHA256 integrity field
            MANIFEST_SHA=$(echo "${MANIFEST}" | grep -o '"device_sha256": *"[^"]*"' | cut -d'"' -f4 || true)
            if [[ -n "${MANIFEST_SHA}" ]]; then
                pass "SHA256 integrity available (device_sha256 in manifest)"
                echo "    Hash: ${MANIFEST_SHA:0:16}..."
                echo "    Verify S3 image:    bash ${SCRIPT_DIR}/pi-image-backup.sh --verify --date ${TARGET_DATE}"
                echo "    Verify after flash: bash ${SCRIPT_DIR}/pi-image-restore.sh --verify /dev/diskN --date ${TARGET_DATE}"
            else
                warn "No SHA256 in manifest — backup predates integrity support"
                echo "         Run a new backup to get a verified image: bash ~/pi-mi/pi-image-backup.sh --force"
            fi
        fi
    else
        warn "No manifest found — backup predates manifest support or failed mid-way"
    fi

    # ── Estimate restore time ─────────────────────────────────────────────────
    section "Restore estimate"

    if [[ "${IMAGE_SIZE}" -gt 0 ]]; then
        # Assume ~80MB/s download + ~150MB/s gunzip + ~200MB/s dd write
        # Bottleneck is usually download. Rough: IMAGE_SIZE / 50MB/s (conservative)
        EST_SECS=$(( IMAGE_SIZE / 52428800 ))
        EST_MIN=$(( EST_SECS / 60 ))
        EST_SECS_REM=$(( EST_SECS % 60 ))
        pass "Estimated flash time: ~${EST_MIN}m ${EST_SECS_REM}s"
        pass "Install pv for a progress bar: brew install pv"
    fi

    # ── Go / No-go ────────────────────────────────────────────────────────────
    section "Restore command"
    echo ""
    echo "  When ready to flash, run:"
    echo ""
    if [[ -n "${TARGET_DATE}" ]]; then
        echo "    bash ${SCRIPT_DIR}/pi-image-restore.sh --date ${TARGET_DATE}"
    else
        echo "    bash ${SCRIPT_DIR}/pi-image-restore.sh"
    fi
    echo ""
    echo "  Then SSH into the new Pi and run:"
    echo "    bash ~/pi-mi/test-recovery.sh --post-boot"
    echo ""

    summary
fi

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — Post-boot (new Pi)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${PHASE}" == "post-boot" ]]; then

    # Must be running ON a Pi (Linux/ARM)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "ERROR: --post-boot must be run on the Pi, not on your Mac."
        echo "  SSH into the new Pi first: ssh pi@raspberrypi.local"
        exit 1
    fi

    echo ""
    echo "================================================================"
    echo "  Pi MI — Post-boot recovery validation"
    echo "  Host: $(hostname) | $(uname -m) | $(date)"
    echo "================================================================"

    # ── Config check ─────────────────────────────────────────────────────────
    section "Pi MI configuration"

    if [[ -f "${CONFIG_FILE}" ]]; then
        pass "config.env found at ${CONFIG_FILE}"
        # Source it for later checks
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}" 2>/dev/null || true
        [[ -n "${S3_BUCKET:-}" ]] && pass "S3_BUCKET = ${S3_BUCKET}" \
            || warn "S3_BUCKET is empty — backup cron will fail"
        [[ -n "${S3_REGION:-}" ]] && pass "S3_REGION = ${S3_REGION}" \
            || warn "S3_REGION is empty — backup cron will fail"
        [[ -n "${NTFY_URL:-}"  ]] && pass "NTFY_URL configured" \
            || warn "NTFY_URL is empty — no push notifications"
    else
        fail "config.env not found at ${CONFIG_FILE}"
        echo "         The backup cron will silently fail without this file."
        echo "         Restore it from your original Pi or re-run install.sh:"
        echo "           bash ~/pi-mi/install.sh"
    fi

    # ── OS & hardware ─────────────────────────────────────────────────────────
    section "OS & hardware"

    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")
    OS_PRETTY=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "unknown")
    KERNEL=$(uname -r)
    UPTIME_SECS=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")

    pass "Pi model: ${PI_MODEL}"
    pass "OS: ${OS_PRETTY}"
    pass "Kernel: ${KERNEL}"

    if [[ "${UPTIME_SECS}" -lt 600 ]]; then
        pass "Uptime: ${UPTIME_SECS}s (fresh boot)"
    else
        warn "Uptime: ${UPTIME_SECS}s — not a fresh boot. Re-run after a clean reboot if testing restore."
    fi

    # ── Filesystem expansion ──────────────────────────────────────────────────
    section "Filesystem"

    ROOT_PART=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    ROOT_DEV=$(lsblk -no PKNAME "${ROOT_PART}" 2>/dev/null || echo "unknown")
    DEV_SIZE=$(lsblk -bdno SIZE "/dev/${ROOT_DEV}" 2>/dev/null || echo "0")
    ROOT_SIZE=$(df --output=size / 2>/dev/null | tail -1 | tr -d ' ')
    ROOT_SIZE_BYTES=$(( ROOT_SIZE * 1024 ))

    DEV_SIZE_HUMAN=$(numfmt --to=iec "${DEV_SIZE}" 2>/dev/null || echo "?")
    ROOT_SIZE_HUMAN=$(numfmt --to=iec "${ROOT_SIZE_BYTES}" 2>/dev/null || echo "?")

    pass "Boot device: /dev/${ROOT_DEV} (${DEV_SIZE_HUMAN} total)"
    pass "Root filesystem: ${ROOT_SIZE_HUMAN} usable"

    # Check if root fs is at least 80% of device size (expansion happened)
    if [[ "${DEV_SIZE}" -gt 0 && "${ROOT_SIZE_BYTES}" -gt 0 ]]; then
        EXPAND_RATIO=$(awk "BEGIN {printf \"%.0f\", (${ROOT_SIZE_BYTES} / ${DEV_SIZE}) * 100}")
        if [[ "${EXPAND_RATIO}" -ge 75 ]]; then
            pass "Filesystem expanded: ${ROOT_SIZE_HUMAN} / ${DEV_SIZE_HUMAN} (${EXPAND_RATIO}% of device)"
        else
            warn "Filesystem may not be fully expanded: ${ROOT_SIZE_HUMAN} / ${DEV_SIZE_HUMAN} (${EXPAND_RATIO}%)"
            echo "         Run: sudo raspi-config --expand-rootfs && sudo reboot"
        fi
    fi

    # Check free space (need at least 1GB free)
    ROOT_AVAIL=$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
    ROOT_AVAIL_BYTES=$(( ROOT_AVAIL * 1024 ))
    ROOT_AVAIL_HUMAN=$(numfmt --to=iec "${ROOT_AVAIL_BYTES}" 2>/dev/null || echo "?")
    if [[ "${ROOT_AVAIL_BYTES}" -gt 1073741824 ]]; then
        pass "Free space: ${ROOT_AVAIL_HUMAN}"
    else
        fail "Low free space: ${ROOT_AVAIL_HUMAN} — less than 1GB available"
    fi

    # ── NVMe (if applicable) ──────────────────────────────────────────────────
    section "NVMe"

    if lsblk | grep -q nvme 2>/dev/null; then
        NVME_DEV=$(lsblk -dno NAME | grep nvme | head -1)
        pass "NVMe device present: /dev/${NVME_DEV}"

        if mountpoint -q /mnt/nvme 2>/dev/null; then
            NVME_SIZE=$(df -h /mnt/nvme 2>/dev/null | tail -1 | awk '{print $2}')
            NVME_AVAIL=$(df -h /mnt/nvme 2>/dev/null | tail -1 | awk '{print $4}')
            pass "/mnt/nvme mounted (${NVME_SIZE} total, ${NVME_AVAIL} free)"
        else
            fail "/mnt/nvme is NOT mounted"
            echo "         Check: cat /etc/fstab | grep nvme"
            echo "         Try:   sudo mount -a"
        fi
    else
        warn "No NVMe device detected — running from SD card only"
    fi

    # ── Docker ────────────────────────────────────────────────────────────────
    section "Docker"

    if command -v docker &>/dev/null; then
        pass "Docker installed: $(docker --version)"
    else
        fail "Docker not found — restore may be incomplete"
        summary; exit 1
    fi

    if docker info &>/dev/null 2>&1; then
        pass "Docker daemon running"
    else
        fail "Docker daemon not running"
        echo "         Try: sudo systemctl start docker"
        summary; exit 1
    fi

    DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "unknown")
    pass "Docker data-root: ${DOCKER_ROOT}"

    # Warn if Docker data is still on SD (should be on NVMe if migration was done)
    if echo "${DOCKER_ROOT}" | grep -q nvme 2>/dev/null; then
        pass "Docker data is on NVMe"
    elif echo "${DOCKER_ROOT}" | grep -q mmcblk 2>/dev/null; then
        warn "Docker data is on SD card — expected NVMe. Check /etc/docker/daemon.json"
    fi

    TOTAL_CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
    RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')

    pass "Containers total: ${TOTAL_CONTAINERS}"
    if [[ "${RUNNING_CONTAINERS}" -eq "${TOTAL_CONTAINERS}" && "${TOTAL_CONTAINERS}" -gt 0 ]]; then
        pass "All ${RUNNING_CONTAINERS} container(s) running"
    elif [[ "${RUNNING_CONTAINERS}" -gt 0 ]]; then
        warn "${RUNNING_CONTAINERS}/${TOTAL_CONTAINERS} containers running"
        echo "         Stopped containers:"
        docker ps -a --filter "status=exited" --format "    {{.Names}} ({{.Status}})" 2>/dev/null || true
        echo "         Try: docker start \$(docker ps -aq)"
    else
        fail "No containers running"
        echo "         Try: docker ps -a (check status)"
        echo "         Try: docker compose up -d (if compose file present)"
    fi

    # Check specific expected containers (common Pi stack)
    for container in mariadb wordpress nginx redis; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "${container}"; then
            pass "Container '${container}' running"
        else
            # Not a hard failure — user may not run this stack
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qi "${container}"; then
                fail "Container '${container}' exists but is NOT running"
                echo "         Try: docker start ${container}"
            fi
            # Silently skip if container doesn't exist at all (different stack)
        fi
    done

    # ── Connectivity ──────────────────────────────────────────────────────────
    section "Connectivity"

    # Check if Nginx is responding locally (port 80 or 8082)
    for port in 80 8082; do
        HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 5 \
            "http://localhost:${port}/" 2>/dev/null || echo "000")
        if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "301" || "${HTTP_CODE}" == "302" ]]; then
            pass "HTTP localhost:${port} → ${HTTP_CODE}"
            break
        elif [[ "${HTTP_CODE}" != "000" ]]; then
            warn "HTTP localhost:${port} → ${HTTP_CODE} (non-2xx/3xx)"
        fi
    done

    # Internet connectivity
    if curl -sf --max-time 5 https://1.1.1.1 > /dev/null 2>&1 \
       || curl -sf --max-time 5 https://8.8.8.8 > /dev/null 2>&1; then
        pass "Internet connectivity OK"
    else
        warn "No internet connectivity — Cloudflare tunnel won't work"
    fi

    # ── Cloudflare tunnel ─────────────────────────────────────────────────────
    section "Cloudflare tunnel"

    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        pass "cloudflared service: active"
        CF_UPTIME=$(systemctl show cloudflared --property=ActiveEnterTimestamp 2>/dev/null \
            | cut -d= -f2 || echo "unknown")
        pass "cloudflared up since: ${CF_UPTIME}"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qi cloudflare; then
        pass "cloudflared running in Docker"
    else
        CF_STATUS=$(systemctl is-active cloudflared 2>/dev/null || echo "not found")
        fail "cloudflared: ${CF_STATUS}"
        echo "         Try: sudo systemctl start cloudflared"
        echo "         Check: sudo journalctl -u cloudflared -n 20"
    fi

    # ── Cron jobs ─────────────────────────────────────────────────────────────
    section "Cron jobs"

    CRONTAB=$(crontab -l 2>/dev/null || true)

    if [[ -n "${CRONTAB}" ]]; then
        pass "Crontab exists ($(echo "${CRONTAB}" | grep -c . || true) line(s))"
    else
        warn "No crontab entries found — backup cron may be missing"
        echo "         Re-install: bash ~/pi-mi/install.sh"
    fi

    if echo "${CRONTAB}" | grep -q "pi-image-backup" 2>/dev/null; then
        BACKUP_SCHED=$(echo "${CRONTAB}" | grep "pi-image-backup" | head -1 | awk '{print $1,$2,$3,$4,$5}')
        pass "Pi MI backup cron: ${BACKUP_SCHED}"
    else
        warn "Pi MI backup cron not found in crontab"
        echo "         Re-install: bash ~/pi-mi/install.sh"
    fi

    if echo "${CRONTAB}" | grep -q "backup-to-s3" 2>/dev/null; then
        APP_BACKUP_SCHED=$(echo "${CRONTAB}" | grep "backup-to-s3" | head -1 | awk '{print $1,$2,$3,$4,$5}')
        pass "App-layer backup cron: ${APP_BACKUP_SCHED}"
    fi

    # ── MariaDB (if applicable) ───────────────────────────────────────────────
    section "Database"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi mariadb; then
        # Try to load .env for credentials
        ENV_FILE=""
        for f in ~/andrewbakerninja-pi/.env ~/.env; do
            [[ -f "${f}" ]] && ENV_FILE="${f}" && break
        done

        if [[ -n "${ENV_FILE}" ]]; then
            # shellcheck disable=SC1090
            source "${ENV_FILE}" 2>/dev/null || true
            MYSQL_USER="${MYSQL_USER:-wordpress}"
            MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
            MYSQL_DATABASE="${MYSQL_DATABASE:-wordpress}"
            MARIADB_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null \
                | grep -i mariadb | head -1)

            DB_PING=$(docker exec "${MARIADB_CONTAINER}" \
                sh -c "mysqladmin -u${MYSQL_USER} -p${MYSQL_PASSWORD} ping 2>/dev/null" \
                2>/dev/null || echo "FAIL")

            if echo "${DB_PING}" | grep -q "alive"; then
                pass "MariaDB ping: ${DB_PING}"
            else
                fail "MariaDB not responding: ${DB_PING}"
            fi

            TABLE_COUNT=$(docker exec "${MARIADB_CONTAINER}" \
                sh -c "mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} ${MYSQL_DATABASE} \
                    -e 'SHOW TABLES;' 2>/dev/null | wc -l" 2>/dev/null || echo "0")
            if [[ "${TABLE_COUNT}" -gt 5 ]]; then
                pass "Database has ${TABLE_COUNT} tables"
            else
                fail "Database has only ${TABLE_COUNT} tables — may be empty or not restored"
            fi
        else
            warn "No .env found — skipping DB credentials check"
        fi
    else
        warn "MariaDB container not running — skipping DB check"
    fi

    # ── System resources ──────────────────────────────────────────────────────
    section "System resources"

    # Memory
    MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    MEM_AVAIL=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    MEM_TOTAL_H=$(numfmt --to=iec "$(( MEM_TOTAL * 1024 ))" 2>/dev/null || echo "?")
    MEM_AVAIL_H=$(numfmt --to=iec "$(( MEM_AVAIL * 1024 ))" 2>/dev/null || echo "?")
    MEM_USED_PCT=$(awk "BEGIN {printf \"%.0f\", (1 - ${MEM_AVAIL} / ${MEM_TOTAL}) * 100}")
    pass "RAM: ${MEM_AVAIL_H} free of ${MEM_TOTAL_H} (${MEM_USED_PCT}% used)"

    # Load average
    LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")
    CPU_COUNT=$(nproc 2>/dev/null || echo "1")
    LOAD_PCT=$(awk "BEGIN {printf \"%.0f\", (${LOAD} / ${CPU_COUNT}) * 100}" 2>/dev/null || echo "?")
    if [[ "${LOAD_PCT}" -lt 80 ]]; then
        pass "Load average: ${LOAD} (${LOAD_PCT}% of ${CPU_COUNT} CPUs)"
    else
        warn "High load: ${LOAD} on ${CPU_COUNT} CPUs (${LOAD_PCT}%)"
    fi

    # ── SSH keys ──────────────────────────────────────────────────────────────
    section "SSH"

    pass "SSH access working (you're running this script)"
    warn "SSH host keys are identical to the original Pi"
    echo "         On your Mac, clear stale known_hosts entries:"
    echo "           ssh-keygen -R raspberrypi.local"
    echo "           ssh-keygen -R $(hostname -I | awk '{print $1}' 2>/dev/null || echo '<ip>')"

    # ── Final summary ─────────────────────────────────────────────────────────
    summary
fi
