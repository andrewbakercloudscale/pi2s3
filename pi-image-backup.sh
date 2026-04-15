#!/usr/bin/env bash
# =============================================================
# pi-image-backup.sh — Full disk image of Raspberry Pi to S3
#
# Streams the entire boot device (NVMe or SD card) through pigz
# directly to S3 — no local staging file required.
#
# What gets backed up:
#   - Boot partition (FAT32: firmware, config.txt, cmdline.txt)
#   - Root partition (ext4: OS, all packages, systemd services)
#   - Docker data root (if on same device — NVMe setup)
#   - Everything else on the device
#
# The result is a bootable block image. Restore it to a new Pi
# with pi-image-restore.sh and it boots exactly as the original.
#
# Usage:
#   bash pi-image-backup.sh               # run backup
#   bash pi-image-backup.sh --setup       # create S3 lifecycle policy (run once)
#   bash pi-image-backup.sh --force       # skip duplicate-check
#   bash pi-image-backup.sh --dry-run     # show what would happen, no upload
#   bash pi-image-backup.sh --list        # list all backups in S3
#   bash pi-image-backup.sh --verify      # verify latest S3 image SHA256
#   bash pi-image-backup.sh --verify=DATE # verify specific date (YYYY-MM-DD)
#
# Cron (installed automatically by install.sh):
#   0 2 * * * bash /home/pi/pi-mi/pi-image-backup.sh >> /var/log/pi-mi-backup.log 2>&1
#
# Prerequisites on Pi:
#   - config.env filled in (see config.env.example)
#   - AWS CLI v2 configured with s3:PutObject, s3:GetObject, s3:ListBucket, s3:DeleteObject
#   - pigz recommended (falls back to gzip): sudo apt install pigz
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found."
    echo "  cp ${SCRIPT_DIR}/config.env.example ${SCRIPT_DIR}/config.env"
    echo "  nano ${SCRIPT_DIR}/config.env"
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# ── Validate required config ─────────────────────────────────────────────────
[[ -z "${S3_BUCKET:-}"  ]] && { echo "ERROR: S3_BUCKET is not set in config.env"; exit 1; }
[[ -z "${S3_REGION:-}"  ]] && { echo "ERROR: S3_REGION is not set in config.env"; exit 1; }
[[ -z "${NTFY_URL:-}"   ]] && { echo "ERROR: NTFY_URL is not set in config.env"; exit 1; }

# ── Defaults for optional config ─────────────────────────────────────────────
MAX_IMAGES="${MAX_IMAGES:-60}"
S3_STORAGE_CLASS="${S3_STORAGE_CLASS:-STANDARD_IA}"
STOP_DOCKER="${STOP_DOCKER:-true}"
DOCKER_STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-30}"
NTFY_LEVEL="${NTFY_LEVEL:-all}"
AWS_PROFILE="${AWS_PROFILE:-}"
# ─────────────────────────────────────────────────────────────────────────────

DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
S3_PREFIX="pi-image-backup"
IMAGE_FILENAME="pi-image-${TIMESTAMP}.img.gz"
MANIFEST_FILENAME="manifest-${TIMESTAMP}.json"
S3_DATE_PREFIX="${S3_PREFIX}/${DATE}"
IMAGE_S3_KEY="${S3_DATE_PREFIX}/${IMAGE_FILENAME}"
MANIFEST_S3_KEY="${S3_DATE_PREFIX}/${MANIFEST_FILENAME}"

DRY_RUN=false
FORCE=false
SETUP=false
LIST=false
VERIFY=false
VERIFY_DATE=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --force)      FORCE=true ;;
        --setup)      SETUP=true ;;
        --list)       LIST=true ;;
        --verify)     VERIFY=true ;;
        --verify=*)   VERIFY=true; VERIFY_DATE="${arg#--verify=}" ;;
    esac
done

_BACKUP_SUCCEEDED=false
_CONTAINERS_STOPPED=false
_STOPPED_IDS=""
_START_TIME=$(date +%s)
DEVICE_SHA256=""

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

aws_cmd() {
    if [[ -n "${AWS_PROFILE}" ]]; then
        aws --profile "${AWS_PROFILE}" --region "${S3_REGION}" "$@"
    else
        aws --region "${S3_REGION}" "$@"
    fi
}

ntfy_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    local extra=()
    [[ -n "$tags" ]] && extra+=(-H "Tags: $tags")
    curl -s --max-time 10 \
        -H "Title: $title" \
        -H "Priority: $priority" \
        "${extra[@]}" \
        -d "$msg" \
        "${NTFY_URL}" > /dev/null 2>&1 || true
}

on_exit() {
    local rc=$?
    if [[ "${_CONTAINERS_STOPPED}" == "true" && -n "${_STOPPED_IDS}" ]]; then
        log "Restarting Docker containers..."
        # shellcheck disable=SC2086
        docker start ${_STOPPED_IDS} 2>/dev/null || true
        _CONTAINERS_STOPPED=false
        log "  Containers restarted."
    fi
    if [[ "${_BACKUP_SUCCEEDED}" != "true" && $rc -ne 0 ]]; then
        ntfy_send "Pi MI backup FAILED" \
            "Backup on $(hostname) failed (exit ${rc}). Check /var/log/pi-mi-backup.log" \
            "high" "warning,floppy_disk"
    fi
}
trap on_exit EXIT

# ── One-time setup: S3 lifecycle policy ──────────────────────────────────────
if [[ "${SETUP}" == "true" ]]; then
    log "Setting up S3 lifecycle policy..."
    log "  Backups older than 90 days → deleted by S3 as a safety net."
    log "  Script-managed retention: MAX_IMAGES=${MAX_IMAGES}"
    aws_cmd s3api put-bucket-lifecycle-configuration \
        --bucket "${S3_BUCKET}" \
        --lifecycle-configuration "{
            \"Rules\": [{
                \"ID\": \"pi-mi-backup-retention\",
                \"Status\": \"Enabled\",
                \"Filter\": {\"Prefix\": \"${S3_PREFIX}/\"},
                \"Expiration\": {\"Days\": 90}
            }]
        }"
    log "Done."
    exit 0
fi

# ── List backups ─────────────────────────────────────────────────────────────
if [[ "${LIST}" == "true" ]]; then
    log "Available backups in s3://${S3_BUCKET}/${S3_PREFIX}/:"
    echo ""
    DATES=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
        | grep PRE | awk '{print $2}' | tr -d '/' | sort -r || true)
    if [[ -z "${DATES}" ]]; then
        echo "  No backups found in s3://${S3_BUCKET}/${S3_PREFIX}/"
        exit 0
    fi
    _idx=1
    while IFS= read -r _d; do
        [[ -z "${_d}" ]] && continue
        _mfile=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${_d}/" 2>/dev/null \
            | grep manifest | awk '{print $4}' | head -1 || true)
        _info=""
        if [[ -n "${_mfile}" ]]; then
            _m=$(aws_cmd s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${_d}/${_mfile}" - 2>/dev/null || true)
            if [[ -n "${_m}" ]]; then
                _sz=$(echo "${_m}" | grep -o '"compressed_size_human": *"[^"]*"' | cut -d'"' -f4 || true)
                _hn=$(echo "${_m}" | grep -o '"hostname": *"[^"]*"' | cut -d'"' -f4 || true)
                _info=" — ${_sz:-?} compressed (${_hn:-?})"
            fi
        fi
        printf "  [%d] %s%s\n" "${_idx}" "${_d}" "${_info}"
        (( _idx++ )) || true
    done <<< "${DATES}"
    echo ""
    echo "  Total: $(echo "${DATES}" | grep -c . || true) backup(s)"
    exit 0
fi

# ── Verify S3 image integrity ─────────────────────────────────────────────────
if [[ "${VERIFY}" == "true" ]]; then
    log "========================================================"
    log "  Pi MI — S3 image integrity verification"
    log "========================================================"

    if [[ -z "${VERIFY_DATE}" ]]; then
        VERIFY_DATE=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
            | grep PRE | awk '{print $2}' | tr -d '/' | sort -r | head -1 || true)
        [[ -z "${VERIFY_DATE}" ]] && die "No backups found in s3://${S3_BUCKET}/${S3_PREFIX}/"
        log "Using latest backup: ${VERIFY_DATE}"
    else
        log "Verifying backup: ${VERIFY_DATE}"
    fi

    S3_VERIFY_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${VERIFY_DATE}"

    V_MFILE=$(aws_cmd s3 ls "${S3_VERIFY_PATH}/" 2>/dev/null \
        | grep manifest | awk '{print $4}' | head -1 || true)
    [[ -z "${V_MFILE}" ]] && die "No manifest found for ${VERIFY_DATE}"

    V_MANIFEST=$(aws_cmd s3 cp "${S3_VERIFY_PATH}/${V_MFILE}" - 2>/dev/null) \
        || die "Failed to read manifest"
    V_EXPECTED=$(echo "${V_MANIFEST}" \
        | grep -o '"device_sha256": *"[^"]*"' | cut -d'"' -f4 || true)

    if [[ -z "${V_EXPECTED}" ]]; then
        die "No device_sha256 in manifest — this backup predates integrity support. Re-run with --force to create a new backup with a SHA256."
    fi

    V_IFILE=$(aws_cmd s3 ls "${S3_VERIFY_PATH}/" 2>/dev/null \
        | grep '\.img\.gz' | awk '{print $4}' | tail -1 || true)
    [[ -z "${V_IFILE}" ]] && die "No image file found for ${VERIFY_DATE}"

    V_ISIZE=$(aws_cmd s3 ls "${S3_VERIFY_PATH}/${V_IFILE}" 2>/dev/null \
        | awk '{print $3}' || echo "0")
    V_ISIZE_HUMAN=$(numfmt --to=iec "${V_ISIZE}" 2>/dev/null || echo "?")

    log ""
    log "Image:           ${V_IFILE} (${V_ISIZE_HUMAN} compressed)"
    log "Expected SHA256: ${V_EXPECTED}"
    log ""
    log "Streaming S3 → gunzip → sha256sum ..."
    log "  (downloads and decompresses the full image — may take several minutes)"

    V_ACTUAL=$(aws_cmd s3 cp "${S3_VERIFY_PATH}/${V_IFILE}" - \
        | gunzip -c \
        | sha256sum \
        | awk '{print $1}')

    log "Actual SHA256:   ${V_ACTUAL}"
    log ""

    if [[ "${V_EXPECTED}" == "${V_ACTUAL}" ]]; then
        log "VERIFY OK — S3 image integrity confirmed."
        exit 0
    else
        log "VERIFY FAILED — SHA256 mismatch! Image may be corrupted."
        exit 1
    fi
fi

# ── Detect boot device ───────────────────────────────────────────────────────
detect_boot_device() {
    local root_part boot_dev
    root_part=$(findmnt -n -o SOURCE / 2>/dev/null \
        || lsblk -no NAME,MOUNTPOINT | awk '$2=="/" {print "/dev/"$1}')
    boot_dev=$(lsblk -no PKNAME "${root_part}" 2>/dev/null || true)

    if [[ -z "${boot_dev}" ]]; then
        for dev in nvme0n1 mmcblk0 sda; do
            if [[ -b "/dev/${dev}" ]]; then
                boot_dev="${dev}"
                break
            fi
        done
    fi

    [[ -z "${boot_dev}" ]] && die "Cannot detect boot device. Set BOOT_DEV manually."
    echo "/dev/${boot_dev}"
}

# ── Main ─────────────────────────────────────────────────────────────────────
log "========================================================"
log "  Pi MI — disk image backup"
log "  Host:      $(hostname)"
log "  Date:      ${DATE}"
log "  S3 target: s3://${S3_BUCKET}/${IMAGE_S3_KEY}"
[[ "${DRY_RUN}" == "true" ]] && log "  *** DRY RUN — no data will be uploaded ***"
log "========================================================"

# ── Preflight ────────────────────────────────────────────────────────────────
log ""
log "Preflight checks..."

command -v aws &>/dev/null || die "aws CLI not found. Run: bash install.sh"
aws_cmd s3 ls "s3://${S3_BUCKET}/" > /dev/null 2>&1 \
    || die "Cannot reach s3://${S3_BUCKET}/. Check AWS credentials and bucket name."

BOOT_DEV=$(detect_boot_device)
DEV_SIZE=$(blockdev --getsize64 "${BOOT_DEV}" 2>/dev/null \
           || lsblk -bdno SIZE "${BOOT_DEV}" 2>/dev/null || echo "0")
DEV_SIZE_HUMAN=$(numfmt --to=iec "${DEV_SIZE}" 2>/dev/null || echo "${DEV_SIZE} bytes")

if command -v pigz &>/dev/null; then
    COMPRESSOR="pigz -c"
    COMPRESSOR_NAME="pigz (parallel)"
else
    COMPRESSOR="gzip -c"
    COMPRESSOR_NAME="gzip (install pigz for faster backups: sudo apt install pigz)"
fi

PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")
OS_PRETTY=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "unknown")
KERNEL=$(uname -r)

log "  Boot device:  ${BOOT_DEV} (${DEV_SIZE_HUMAN})"
log "  Compressor:   ${COMPRESSOR_NAME}"
log "  Pi model:     ${PI_MODEL}"
log "  OS:           ${OS_PRETTY}"
log "  Retention:    ${MAX_IMAGES} images"

# ── Check Docker data-root is on the same device as boot ─────────────────────
# If Docker's data-root is on a SEPARATE physical device (e.g. a USB drive),
# that data won't be in the image — this is a critical gap.
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
    if [[ -n "${DOCKER_ROOT}" && -d "${DOCKER_ROOT}" ]]; then
        DOCKER_DEV_NAME=$(df --output=source "${DOCKER_ROOT}" 2>/dev/null \
            | tail -1 | xargs -I{} lsblk -no PKNAME {} 2>/dev/null || true)
        DOCKER_DEV="/dev/${DOCKER_DEV_NAME}"
        BOOT_DEV_NAME=$(basename "${BOOT_DEV}")

        if [[ -n "${DOCKER_DEV_NAME}" && "${DOCKER_DEV_NAME}" != "${BOOT_DEV_NAME}" ]]; then
            log ""
            log "  ┌─────────────────────────────────────────────────────────────┐"
            log "  │ WARNING: Docker data is on a DIFFERENT device than boot!    │"
            log "  │                                                             │"
            log "  │   Boot device:   ${BOOT_DEV} (will be imaged)              │"
            log "  │   Docker data:   ${DOCKER_DEV} (NOT in this image)         │"
            log "  │                                                             │"
            log "  │ Docker volumes, databases, and uploads will NOT be          │"
            log "  │ included in this image. Use BACKUP_EXTRA_DEVICE in          │"
            log "  │ config.env to also image the Docker device:                 │"
            log "  │   BACKUP_EXTRA_DEVICE=\"${DOCKER_DEV}\"                        │"
            log "  └─────────────────────────────────────────────────────────────┘"
            log ""

            # If user has configured the extra device, we'll image it too (below).
            EXTRA_DEVICE="${BACKUP_EXTRA_DEVICE:-}"
            if [[ -z "${EXTRA_DEVICE}" ]]; then
                log "  Continuing with boot device only. Set BACKUP_EXTRA_DEVICE to fix this."
            fi
        else
            log "  Docker data:  on ${BOOT_DEV} (same device — fully covered)"
        fi
    fi
fi

log "  Preflight OK."

# ── Duplicate check ──────────────────────────────────────────────────────────
if [[ "${FORCE}" != "true" && "${DRY_RUN}" != "true" ]]; then
    EXISTING=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_DATE_PREFIX}/" 2>/dev/null \
        | grep -c '\.img\.gz' || true)
    if [[ "${EXISTING}" -gt 0 ]]; then
        log ""
        log "Image for ${DATE} already exists (${EXISTING} file). Skipping."
        log "Use --force to override."
        _BACKUP_SUCCEEDED=true
        exit 0
    fi
fi

# ── Stop Docker briefly for consistent snapshot ───────────────────────────────
if [[ "${STOP_DOCKER}" == "true" ]] \
   && command -v docker &>/dev/null \
   && docker info &>/dev/null 2>&1; then

    _STOPPED_IDS=$(docker ps -q 2>/dev/null || true)
    if [[ -n "${_STOPPED_IDS}" ]]; then
        CONTAINER_COUNT=$(echo "${_STOPPED_IDS}" | wc -w | tr -d ' ')
        log ""
        log "Stopping ${CONTAINER_COUNT} Docker container(s) for consistent snapshot..."
        [[ "${DRY_RUN}" != "true" ]] \
            && docker stop --timeout "${DOCKER_STOP_TIMEOUT}" ${_STOPPED_IDS}
        _CONTAINERS_STOPPED=true
        log "  Stopped. Will restart after imaging."
    fi
fi

# ── Flush filesystem ─────────────────────────────────────────────────────────
log ""
log "Syncing filesystem..."
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true

# ── Stream to S3 ─────────────────────────────────────────────────────────────
log ""
log "Streaming ${BOOT_DEV} → ${COMPRESSOR_NAME} → S3..."
log "  (typically 10–30 min for a 32–128GB device — go make a coffee)"

BACKUP_START=$(date +%s)

if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY RUN] dd if=${BOOT_DEV} bs=4M | tee SHA256_FIFO | ${COMPRESSOR} | aws s3 cp - s3://${S3_BUCKET}/${IMAGE_S3_KEY}"
else
    # Compute SHA256 of raw device data in parallel via a named pipe.
    # Hashing before compression means the same hash verifies both the S3
    # image (decompress → hash) and the flashed device (re-read → hash).
    _SHA256_FIFO=$(mktemp -u /tmp/pi-mi-sha256.XXXXXX)
    _SHA256_TMP=$(mktemp /tmp/pi-mi-sha256sum.XXXXXX)
    mkfifo "${_SHA256_FIFO}"

    sha256sum "${_SHA256_FIFO}" > "${_SHA256_TMP}" &
    _SHA256_PID=$!

    # Stream: device → tee (→ sha256 fifo + stdout) → compress → S3
    # shellcheck disable=SC2086
    sudo dd if="${BOOT_DEV}" bs=4M status=none 2>/dev/null \
        | tee "${_SHA256_FIFO}" \
        | ${COMPRESSOR} \
        | aws_cmd s3 cp - "s3://${S3_BUCKET}/${IMAGE_S3_KEY}" \
            --storage-class "${S3_STORAGE_CLASS}" \
            --no-progress

    wait "${_SHA256_PID}" || true
    DEVICE_SHA256=$(awk '{print $1}' "${_SHA256_TMP}" 2>/dev/null || echo "")
    rm -f "${_SHA256_FIFO}" "${_SHA256_TMP}"
    [[ -n "${DEVICE_SHA256}" ]] && log "  SHA256 (raw device): ${DEVICE_SHA256}"
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$(( BACKUP_END - BACKUP_START ))

# ── Optional: image a second device (e.g. Docker data on separate drive) ─────
EXTRA_DEVICE="${BACKUP_EXTRA_DEVICE:-}"
if [[ -n "${EXTRA_DEVICE}" && -b "${EXTRA_DEVICE}" ]]; then
    EXTRA_BASENAME=$(basename "${EXTRA_DEVICE}")
    EXTRA_FILENAME="pi-image-extra-${EXTRA_BASENAME}-${TIMESTAMP}.img.gz"
    EXTRA_S3_KEY="${S3_DATE_PREFIX}/${EXTRA_FILENAME}"
    EXTRA_SIZE=$(blockdev --getsize64 "${EXTRA_DEVICE}" 2>/dev/null || echo "0")
    EXTRA_SIZE_HUMAN=$(numfmt --to=iec "${EXTRA_SIZE}" 2>/dev/null || echo "?")

    log ""
    log "Imaging extra device ${EXTRA_DEVICE} (${EXTRA_SIZE_HUMAN})..."
    log "  Key: ${EXTRA_S3_KEY}"

    if [[ "${DRY_RUN}" != "true" ]]; then
        # shellcheck disable=SC2086
        sudo dd if="${EXTRA_DEVICE}" bs=4M status=none 2>/dev/null \
            | ${COMPRESSOR} \
            | aws_cmd s3 cp - "s3://${S3_BUCKET}/${EXTRA_S3_KEY}" \
                --storage-class "${S3_STORAGE_CLASS}" \
                --no-progress
        log "  Extra device imaged OK."
    else
        log "  [DRY RUN] Would image ${EXTRA_DEVICE} → s3://${S3_BUCKET}/${EXTRA_S3_KEY}"
    fi
fi

# ── Restart Docker ───────────────────────────────────────────────────────────
if [[ "${_CONTAINERS_STOPPED}" == "true" && -n "${_STOPPED_IDS}" ]]; then
    log ""
    log "Restarting Docker containers..."
    # shellcheck disable=SC2086
    [[ "${DRY_RUN}" != "true" ]] && docker start ${_STOPPED_IDS} 2>/dev/null || true
    _CONTAINERS_STOPPED=false
    log "  Containers restarted."
fi

# ── Report compressed size ────────────────────────────────────────────────────
COMPRESSED_SIZE=0
COMPRESSED_SIZE_HUMAN="unknown"
COMPRESSION_RATIO=""
if [[ "${DRY_RUN}" != "true" ]]; then
    COMPRESSED_SIZE=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${IMAGE_S3_KEY}" 2>/dev/null \
        | awk '{print $3}' | head -1 || echo "0")
    COMPRESSED_SIZE_HUMAN=$(numfmt --to=iec "${COMPRESSED_SIZE}" 2>/dev/null \
        || echo "${COMPRESSED_SIZE} bytes")
    if [[ "${DEV_SIZE}" -gt 0 && "${COMPRESSED_SIZE}" -gt 0 ]]; then
        COMPRESSION_RATIO=$(awk \
            "BEGIN {printf \"%.1f%%\", (1 - ${COMPRESSED_SIZE}/${DEV_SIZE}) * 100}")
    fi
    log ""
    log "  Original:    ${DEV_SIZE_HUMAN}"
    log "  Compressed:  ${COMPRESSED_SIZE_HUMAN} (${COMPRESSION_RATIO} saved)"
    log "  Duration:    ${BACKUP_DURATION}s"
fi

# ── Upload manifest ───────────────────────────────────────────────────────────
log ""
log "Uploading manifest..."
MANIFEST_JSON=$(cat <<EOF
{
  "date": "${DATE}",
  "timestamp": "${TIMESTAMP}",
  "hostname": "$(hostname)",
  "pi_model": "${PI_MODEL}",
  "os": "${OS_PRETTY}",
  "kernel": "${KERNEL}",
  "device": "${BOOT_DEV}",
  "device_size_bytes": ${DEV_SIZE},
  "device_size_human": "${DEV_SIZE_HUMAN}",
  "compressed_size_bytes": ${COMPRESSED_SIZE},
  "compressed_size_human": "${COMPRESSED_SIZE_HUMAN}",
  "compression_ratio": "${COMPRESSION_RATIO}",
  "backup_duration_seconds": ${BACKUP_DURATION},
  "s3_bucket": "${S3_BUCKET}",
  "image_key": "${IMAGE_S3_KEY}",
  "manifest_key": "${MANIFEST_S3_KEY}",
  "compressor": "${COMPRESSOR_NAME}",
  "storage_class": "${S3_STORAGE_CLASS}",
  "device_sha256": "${DEVICE_SHA256}"
}
EOF
)

if [[ "${DRY_RUN}" != "true" ]]; then
    echo "${MANIFEST_JSON}" \
        | aws_cmd s3 cp - "s3://${S3_BUCKET}/${MANIFEST_S3_KEY}" \
            --content-type "application/json" \
            --storage-class "STANDARD"
    log "  s3://${S3_BUCKET}/${MANIFEST_S3_KEY}"
else
    log "  [DRY RUN] ${MANIFEST_JSON}"
fi

# ── Prune old images ──────────────────────────────────────────────────────────
log ""
log "Pruning old images (keeping ${MAX_IMAGES} most recent)..."

BACKUP_DATES=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
    | grep PRE | awk '{print $2}' | tr -d '/' | sort)
TOTAL_IMAGES=$(echo "${BACKUP_DATES}" | grep -c . || true)
log "  Total on S3: ${TOTAL_IMAGES}"

if [[ "${TOTAL_IMAGES}" -gt "${MAX_IMAGES}" ]]; then
    DELETE_COUNT=$(( TOTAL_IMAGES - MAX_IMAGES ))
    TO_DELETE=$(echo "${BACKUP_DATES}" | head -"${DELETE_COUNT}")
    while IFS= read -r old_date; do
        [[ -z "${old_date}" ]] && continue
        log "  Deleting: ${old_date}"
        if [[ "${DRY_RUN}" != "true" ]]; then
            aws_cmd s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${old_date}/" --recursive
        fi
    done <<< "${TO_DELETE}"
    log "  Pruned ${DELETE_COUNT} old image(s)."
else
    log "  No pruning needed."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
TOTAL_ELAPSED=$(( $(date +%s) - _START_TIME ))
log ""
log "========================================================"
log "  Backup complete!"
log "  Image: s3://${S3_BUCKET}/${IMAGE_S3_KEY}"
log "  Size:  ${COMPRESSED_SIZE_HUMAN} compressed from ${DEV_SIZE_HUMAN}"
log "  Time:  ${TOTAL_ELAPSED}s"
log ""
log "  Restore: bash pi-image-restore.sh"
log "========================================================"

_BACKUP_SUCCEEDED=true

if [[ "${NTFY_LEVEL}" == "all" && "${DRY_RUN}" != "true" ]]; then
    ntfy_send "Pi MI backup complete" \
        "$(hostname) — ${DATE} — ${COMPRESSED_SIZE_HUMAN} from ${DEV_SIZE_HUMAN} in ${TOTAL_ELAPSED}s." \
        "low" "white_check_mark,floppy_disk"
fi
