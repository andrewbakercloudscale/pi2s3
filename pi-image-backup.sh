#!/usr/bin/env bash
# =============================================================
# pi-image-backup.sh — Partition-level image of Raspberry Pi to S3
#
# Uses partclone to image only USED blocks on each partition —
# much faster than dd on sparse devices (e.g. 954G NVMe with 30G
# used → reads ~30G instead of 954G).
#
# What gets backed up:
#   - All partitions on the boot device (root + data)
#   - GPT/MBR partition table
#   - Boot firmware partition if on a separate device (/boot/firmware)
#
# The result is a complete, bootable image set. Restore to a new
# Pi with pi-image-restore.sh.
#
# Usage:
#   bash pi-image-backup.sh               # run backup
#   bash pi-image-backup.sh --setup       # create S3 lifecycle policy (run once)
#   bash pi-image-backup.sh --force       # skip duplicate-check
#   bash pi-image-backup.sh --dry-run     # show what would happen, no upload
#   bash pi-image-backup.sh --no-stop-docker  # skip Docker stop (daytime test, no downtime)
#   bash pi-image-backup.sh --list        # list all backups in S3
#   bash pi-image-backup.sh --verify      # verify latest backup files exist in S3
#   bash pi-image-backup.sh --verify=DATE # verify specific date (YYYY-MM-DD)
#
# Cron (installed automatically by install.sh):
#   0 2 * * * bash /home/pi/pi2s3/pi-image-backup.sh >> /var/log/pi2s3-backup.log 2>&1
#
# Prerequisites on Pi:
#   - config.env filled in (see config.env.example)
#   - AWS CLI v2 with s3:PutObject, s3:GetObject, s3:ListBucket, s3:DeleteObject
#   - partclone: sudo apt install partclone
#   - pigz recommended (falls back to gzip): sudo apt install pigz
# =============================================================
set -euo pipefail

# partclone installs to /usr/sbin on Debian/Ubuntu; ensure it's reachable
export PATH="/usr/sbin:${PATH}"

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
MANIFEST_FILENAME="manifest-${TIMESTAMP}.json"
S3_DATE_PREFIX="${S3_PREFIX}/${DATE}"
MANIFEST_S3_KEY="${S3_DATE_PREFIX}/${MANIFEST_FILENAME}"

DRY_RUN=false
FORCE=false
SETUP=false
LIST=false
VERIFY=false
VERIFY_DATE=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)         DRY_RUN=true ;;
        --force)           FORCE=true ;;
        --setup)           SETUP=true ;;
        --list)            LIST=true ;;
        --verify)          VERIFY=true ;;
        --verify=*)        VERIFY=true; VERIFY_DATE="${arg#--verify=}" ;;
        --no-stop-docker)  STOP_DOCKER=false ;;
    esac
done

_BACKUP_SUCCEEDED=false
_CONTAINERS_STOPPED=false
_STOPPED_IDS=""
_START_TIME=$(date +%s)

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

# Return the appropriate partclone tool for a filesystem type.
# Falls back to partclone.dd for unrecognised types.
partclone_tool() {
    local fstype="$1"
    case "${fstype}" in
        ext2|ext3|ext4) echo "partclone.ext4" ;;
        vfat|fat16|fat32) echo "partclone.vfat" ;;
        xfs)            echo "partclone.xfs"  ;;
        ntfs)           echo "partclone.ntfs" ;;
        btrfs)          echo "partclone.btrfs" ;;
        *)              echo "partclone.dd"   ;;
    esac
}

on_exit() {
    local rc=$?
    # Safety net: if the script crashes mid-imaging, ensure Docker comes back up.
    if [[ "${_CONTAINERS_STOPPED}" == "true" && -n "${_STOPPED_IDS}" ]]; then
        log "Restarting Docker containers (crash recovery)..."
        # shellcheck disable=SC2086
        if docker start ${_STOPPED_IDS} 2>&1; then
            log "  Containers restarted."
        else
            log "  ERROR: docker start failed — containers may still be stopped!"
            ntfy_send "pi2s3 — containers NOT restarted" \
                "URGENT: backup crashed and container restart FAILED on $(hostname).
Manual action required. Run: docker start ${_STOPPED_IDS}" \
                "urgent" "sos,floppy_disk"
        fi
        _CONTAINERS_STOPPED=false
    fi
    if [[ "${_BACKUP_SUCCEEDED}" != "true" && $rc -ne 0 ]]; then
        ntfy_send "pi2s3 backup FAILED" \
            "Backup on $(hostname) failed (exit ${rc}).
Bucket: s3://${S3_BUCKET}/
Log: /var/log/pi2s3-backup.log" \
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
                \"ID\": \"pi2s3-backup-retention\",
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
                # Support both old (compressed_size_human) and new (total_compressed_human) manifests
                _sz=$(echo "${_m}" | grep -o '"total_compressed_human": *"[^"]*"' | cut -d'"' -f4 || true)
                [[ -z "${_sz}" ]] && _sz=$(echo "${_m}" | grep -o '"compressed_size_human": *"[^"]*"' | cut -d'"' -f4 || true)
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

# ── Verify backup integrity ───────────────────────────────────────────────────
if [[ "${VERIFY}" == "true" ]]; then
    log "========================================================"
    log "  pi2s3 — backup integrity verification"
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

    log ""
    log "Manifest: ${V_MFILE}"

    # Check every key listed in the manifest exists and is non-zero in S3
    VERIFY_PASS=true
    while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        SIZE=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${key}" 2>/dev/null | awk '{print $3}' | head -1 || echo "0")
        SIZE_H=$(numfmt --to=iec "${SIZE}" 2>/dev/null || echo "?")
        BASENAME=$(basename "${key}")
        if [[ "${SIZE:-0}" -gt 0 ]]; then
            log "  OK  ${BASENAME} (${SIZE_H})"
        else
            log "  MISSING or EMPTY: ${BASENAME}"
            VERIFY_PASS=false
        fi
    done < <(echo "${V_MANIFEST}" | grep -o '"key": *"[^"]*"' | cut -d'"' -f4)

    # Also check partition table
    PTABLE_KEY=$(echo "${V_MANIFEST}" | grep -o '"partition_table_key": *"[^"]*"' | cut -d'"' -f4 || true)
    if [[ -n "${PTABLE_KEY}" ]]; then
        SIZE=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${PTABLE_KEY}" 2>/dev/null | awk '{print $3}' | head -1 || echo "0")
        if [[ "${SIZE:-0}" -gt 0 ]]; then
            log "  OK  partition-table (${SIZE} bytes)"
        else
            log "  MISSING: partition-table"
            VERIFY_PASS=false
        fi
    fi

    log ""
    if [[ "${VERIFY_PASS}" == "true" ]]; then
        log "VERIFY OK — all backup files present in S3."
        exit 0
    else
        log "VERIFY FAILED — one or more files missing from S3."
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
log "  pi2s3 — partition image backup"
log "  Host:      $(hostname)"
log "  Date:      ${DATE}"
log "  S3 target: s3://${S3_BUCKET}/${S3_DATE_PREFIX}/"
[[ "${DRY_RUN}" == "true" ]] && log "  *** DRY RUN — no data will be uploaded ***"
log "========================================================"

# ── Preflight ────────────────────────────────────────────────────────────────
log ""
log "Preflight checks..."

command -v aws          &>/dev/null || die "aws CLI not found. Run: bash install.sh"
command -v partclone.ext4 &>/dev/null || die "partclone not found. Run: sudo apt install partclone"
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

# Enumerate partitions on boot device
mapfile -t BOOT_PARTITIONS < <(
    lsblk -lno NAME,TYPE "${BOOT_DEV}" \
    | awk '$2=="part"{print "/dev/"$1}' | sort
)
[[ ${#BOOT_PARTITIONS[@]} -eq 0 ]] && die "No partitions found on ${BOOT_DEV}"

log "  Boot device:  ${BOOT_DEV} (${DEV_SIZE_HUMAN})"
log "  Partitions:   ${BOOT_PARTITIONS[*]}"
log "  Compressor:   ${COMPRESSOR_NAME}"
log "  Pi model:     ${PI_MODEL}"
log "  OS:           ${OS_PRETTY}"
log "  Retention:    ${MAX_IMAGES} images"

# Check for a separate boot firmware partition (e.g. SD card on /boot/firmware)
BOOT_FW_PART=""
BOOT_FW_SOURCE=$(findmnt -n -o SOURCE /boot/firmware 2>/dev/null || true)
if [[ -n "${BOOT_FW_SOURCE}" ]]; then
    FW_PARENT=$(lsblk -no PKNAME "${BOOT_FW_SOURCE}" 2>/dev/null || true)
    if [[ -n "${FW_PARENT}" && "/dev/${FW_PARENT}" != "${BOOT_DEV}" ]]; then
        BOOT_FW_PART="${BOOT_FW_SOURCE}"
        FW_SIZE=$(lsblk -bdno SIZE "${BOOT_FW_PART}" 2>/dev/null || echo "0")
        FW_SIZE_HUMAN=$(numfmt --to=iec "${FW_SIZE}" 2>/dev/null || echo "?")
        log "  Boot firmware: ${BOOT_FW_PART} (${FW_SIZE_HUMAN}) — will also be imaged"
    fi
fi

# ── Check Docker data-root is on the same device as boot ─────────────────────
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
    if [[ -n "${DOCKER_ROOT}" && -d "${DOCKER_ROOT}" ]]; then
        DOCKER_DEV_NAME=$(df --output=source "${DOCKER_ROOT}" 2>/dev/null \
            | tail -1 | xargs -I{} lsblk -no PKNAME {} 2>/dev/null || true)
        BOOT_DEV_NAME=$(basename "${BOOT_DEV}")
        if [[ -n "${DOCKER_DEV_NAME}" && "${DOCKER_DEV_NAME}" != "${BOOT_DEV_NAME}" ]]; then
            log ""
            log "  WARNING: Docker data is on /dev/${DOCKER_DEV_NAME} — NOT on ${BOOT_DEV}"
            log "  Docker volumes will NOT be in this backup."
            log "  Set BACKUP_EXTRA_DEVICE=\"/dev/${DOCKER_DEV_NAME}\" in config.env to include it."
            log ""
        else
            log "  Docker data:  on ${BOOT_DEV} (same device — fully covered)"
        fi
    fi
fi

log "  Preflight OK."

# ── Duplicate check ──────────────────────────────────────────────────────────
if [[ "${FORCE}" != "true" && "${DRY_RUN}" != "true" ]]; then
    EXISTING=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_DATE_PREFIX}/" 2>/dev/null \
        | grep -c 'manifest' || true)
    if [[ "${EXISTING}" -gt 0 ]]; then
        log ""
        log "Backup for ${DATE} already exists. Skipping."
        log "Use --force to override."
        _BACKUP_SUCCEEDED=true
        exit 0
    fi
fi

# ── Stop Docker for consistent snapshot ──────────────────────────────────────
# Containers are stopped for the duration of partition imaging.
# With partclone reading only used blocks (~10–30GB typical), downtime is
# 5–15 minutes — far less than the old dd approach (60–90 min on a full NVMe).
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

# ── Partition table ───────────────────────────────────────────────────────────
PARTITION_TABLE_KEY="${S3_DATE_PREFIX}/partition-table-${TIMESTAMP}.sfdisk"

log ""
log "Saving partition table..."
if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY RUN] sfdisk -d ${BOOT_DEV} → s3://${S3_BUCKET}/${PARTITION_TABLE_KEY}"
else
    sudo sfdisk -d "${BOOT_DEV}" \
        | aws_cmd s3 cp - "s3://${S3_BUCKET}/${PARTITION_TABLE_KEY}" \
            --content-type "text/plain" \
            --storage-class "STANDARD"
    log "  Saved."
fi

# ── Image each partition with partclone ───────────────────────────────────────
BACKUP_START=$(date +%s)
TOTAL_USED_BYTES=0
TOTAL_COMPRESSED_BYTES=0
PARTITIONS_JSON=""

log ""
log "Imaging ${#BOOT_PARTITIONS[@]} partition(s) with partclone..."

for PART in "${BOOT_PARTITIONS[@]}"; do
    PART_NAME=$(basename "${PART}")
    FSTYPE=$(lsblk -no FSTYPE "${PART}" 2>/dev/null | tr -d '[:space:]' || echo "")
    TOOL=$(partclone_tool "${FSTYPE}")
    PART_KEY="${S3_DATE_PREFIX}/${PART_NAME}-${TIMESTAMP}.img.gz"

    PART_SIZE_BYTES=$(lsblk -bdno SIZE "${PART}" 2>/dev/null || echo "0")
    PART_SIZE_HUMAN=$(numfmt --to=iec "${PART_SIZE_BYTES}" 2>/dev/null || echo "?")

    # Get used space (mounted partitions only)
    PART_USED_BYTES=0
    PART_USED_HUMAN="?"
    if df "${PART}" &>/dev/null 2>&1; then
        PART_USED_BYTES=$(df -B1 --output=used "${PART}" 2>/dev/null | tail -1 | tr -d ' ' || echo "0")
        PART_USED_HUMAN=$(numfmt --to=iec "${PART_USED_BYTES}" 2>/dev/null || echo "?")
        TOTAL_USED_BYTES=$(( TOTAL_USED_BYTES + PART_USED_BYTES ))
    fi

    log ""
    log "  ${PART}  (${FSTYPE:-unknown}, ${PART_SIZE_HUMAN} total, ${PART_USED_HUMAN} used)"
    log "  Tool: ${TOOL}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "  [DRY RUN] ${TOOL} -c -s ${PART} | ${COMPRESSOR} | aws s3 cp - s3://${S3_BUCKET}/${PART_KEY}"
        PART_COMPRESSED_BYTES=0
    else
        # -F: allow cloning mounted partitions (all NVMe partitions remain mounted)
        # stderr is intentionally NOT suppressed so partclone errors/warnings land in the
        # backup log and can fail the pipeline via set -euo pipefail.
        # shellcheck disable=SC2086
        sudo "${TOOL}" -c -F -s "${PART}" -o - \
            | ${COMPRESSOR} \
            | aws_cmd s3 cp - "s3://${S3_BUCKET}/${PART_KEY}" \
                --storage-class "${S3_STORAGE_CLASS}" \
                --no-progress

        PART_COMPRESSED_BYTES=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${PART_KEY}" 2>/dev/null \
            | awk '{print $3}' | head -1 || echo "0")
        if [[ "${PART_COMPRESSED_BYTES:-0}" -eq 0 ]]; then
            die "Upload of ${PART_KEY} appears empty (0 bytes in S3). Backup aborted."
        fi
        PART_COMPRESSED_HUMAN=$(numfmt --to=iec "${PART_COMPRESSED_BYTES}" 2>/dev/null || echo "?")
        TOTAL_COMPRESSED_BYTES=$(( TOTAL_COMPRESSED_BYTES + PART_COMPRESSED_BYTES ))
        log "  Done: ${PART_COMPRESSED_HUMAN} compressed → ${PART_KEY}"
    fi

    # Build partitions JSON array (newline-separated entries, joined later)
    PARTITIONS_JSON+="    {\"name\":\"${PART_NAME}\",\"device\":\"${PART}\",\"fstype\":\"${FSTYPE}\",\"tool\":\"${TOOL}\",\"size_bytes\":${PART_SIZE_BYTES},\"size_human\":\"${PART_SIZE_HUMAN}\",\"used_bytes\":${PART_USED_BYTES},\"used_human\":\"${PART_USED_HUMAN}\",\"compressed_bytes\":${PART_COMPRESSED_BYTES:-0},\"key\":\"${PART_KEY}\"},"$'\n'
done

# ── Optional: separate boot firmware (e.g. SD card /boot/firmware) ────────────
BOOT_FW_JSON=""
if [[ -n "${BOOT_FW_PART}" ]]; then
    FW_NAME=$(basename "${BOOT_FW_PART}")
    FW_KEY="${S3_DATE_PREFIX}/${FW_NAME}-boot-fw-${TIMESTAMP}.img.gz"
    FW_FSTYPE=$(lsblk -no FSTYPE "${BOOT_FW_PART}" 2>/dev/null | tr -d '[:space:]' || echo "vfat")

    log ""
    log "  ${BOOT_FW_PART}  (boot firmware, ${FW_SIZE_HUMAN})"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "  [DRY RUN] partclone.vfat -c -s ${BOOT_FW_PART} | ${COMPRESSOR} | aws s3 cp -"
    else
        sudo partclone.vfat -c -F -s "${BOOT_FW_PART}" -o - \
            | ${COMPRESSOR} \
            | aws_cmd s3 cp - "s3://${S3_BUCKET}/${FW_KEY}" \
                --storage-class "${S3_STORAGE_CLASS}" \
                --no-progress

        FW_COMPRESSED=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${FW_KEY}" 2>/dev/null \
            | awk '{print $3}' | head -1 || echo "0")
        if [[ "${FW_COMPRESSED:-0}" -eq 0 ]]; then
            die "Upload of ${FW_KEY} appears empty (0 bytes in S3). Backup aborted."
        fi
        FW_COMPRESSED_HUMAN=$(numfmt --to=iec "${FW_COMPRESSED}" 2>/dev/null || echo "?")
        TOTAL_COMPRESSED_BYTES=$(( TOTAL_COMPRESSED_BYTES + FW_COMPRESSED ))
        log "  Done: ${FW_COMPRESSED_HUMAN} compressed → ${FW_KEY}"
        BOOT_FW_JSON="{\"name\":\"${FW_NAME}\",\"device\":\"${BOOT_FW_PART}\",\"fstype\":\"${FW_FSTYPE}\",\"key\":\"${FW_KEY}\",\"compressed_bytes\":${FW_COMPRESSED}}"
    fi
fi

BACKUP_END=$(date +%s)
BACKUP_DURATION=$(( BACKUP_END - BACKUP_START ))

# ── Restart Docker after imaging ──────────────────────────────────────────────
if [[ "${_CONTAINERS_STOPPED}" == "true" && -n "${_STOPPED_IDS}" ]]; then
    log ""
    log "Restarting Docker containers (imaging complete)..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        # shellcheck disable=SC2086
        if docker start ${_STOPPED_IDS} 2>&1; then
            log "  Containers restarted."
        else
            log "  ERROR: docker start failed — containers may still be stopped!"
            ntfy_send "pi2s3 — containers NOT restarted" \
                "URGENT: post-imaging container restart FAILED on $(hostname).
Manual action required. Run: docker start ${_STOPPED_IDS}" \
                "urgent" "sos,floppy_disk"
        fi
    else
        log "  [DRY RUN] docker start ${_STOPPED_IDS}"
    fi
    _CONTAINERS_STOPPED=false
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_USED_HUMAN=$(numfmt --to=iec "${TOTAL_USED_BYTES}" 2>/dev/null || echo "?")
TOTAL_COMPRESSED_HUMAN=$(numfmt --to=iec "${TOTAL_COMPRESSED_BYTES}" 2>/dev/null || echo "?")
if [[ "${TOTAL_USED_BYTES}" -gt 0 && "${TOTAL_COMPRESSED_BYTES}" -gt 0 ]]; then
    COMPRESSION_RATIO=$(awk \
        "BEGIN {printf \"%.1f%%\", (1 - ${TOTAL_COMPRESSED_BYTES}/${TOTAL_USED_BYTES}) * 100}")
else
    COMPRESSION_RATIO=""
fi

if [[ "${DRY_RUN}" != "true" ]]; then
    log ""
    log "  Used data:   ${TOTAL_USED_HUMAN} (across all partitions)"
    log "  Compressed:  ${TOTAL_COMPRESSED_HUMAN}${COMPRESSION_RATIO:+ (${COMPRESSION_RATIO} saved)}"
    log "  Duration:    ${BACKUP_DURATION}s"
fi

# ── Upload manifest ───────────────────────────────────────────────────────────
log ""
log "Uploading manifest..."

# Trim trailing comma+newline from last partition entry
PARTITIONS_JSON_CLEAN="${PARTITIONS_JSON%,$'\n'}"

MANIFEST_JSON=$(cat <<EOF
{
  "date": "${DATE}",
  "timestamp": "${TIMESTAMP}",
  "hostname": "$(hostname)",
  "backup_type": "partclone",
  "pi_model": "${PI_MODEL}",
  "os": "${OS_PRETTY}",
  "kernel": "${KERNEL}",
  "device": "${BOOT_DEV}",
  "device_size_bytes": ${DEV_SIZE},
  "device_size_human": "${DEV_SIZE_HUMAN}",
  "total_used_bytes": ${TOTAL_USED_BYTES},
  "total_used_human": "${TOTAL_USED_HUMAN}",
  "total_compressed_bytes": ${TOTAL_COMPRESSED_BYTES},
  "total_compressed_human": "${TOTAL_COMPRESSED_HUMAN}",
  "compression_ratio": "${COMPRESSION_RATIO}",
  "backup_duration_seconds": ${BACKUP_DURATION},
  "partition_table_key": "${PARTITION_TABLE_KEY}",
  "partitions": [
${PARTITIONS_JSON_CLEAN}
  ],
  "boot_firmware": ${BOOT_FW_JSON:-null},
  "s3_bucket": "${S3_BUCKET}",
  "manifest_key": "${MANIFEST_S3_KEY}",
  "compressor": "${COMPRESSOR_NAME}",
  "storage_class": "${S3_STORAGE_CLASS}"
}
EOF
)

if [[ "${DRY_RUN}" != "true" ]]; then
    echo "${MANIFEST_JSON}" \
        | aws_cmd s3 cp - "s3://${S3_BUCKET}/${MANIFEST_S3_KEY}" \
            --content-type "application/json" \
            --storage-class "STANDARD"
    log "  s3://${S3_BUCKET}/${MANIFEST_S3_KEY}"

    # Verify manifest landed in S3 (sanity check — if this fails the upload silently failed)
    MANIFEST_SIZE=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${MANIFEST_S3_KEY}" 2>/dev/null \
        | awk '{print $3}' | head -1 || echo "0")
    if [[ "${MANIFEST_SIZE:-0}" -eq 0 ]]; then
        die "Manifest upload appears empty or missing in S3. Backup may be incomplete."
    fi
    log "  Manifest verified in S3 (${MANIFEST_SIZE} bytes)."
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
log "  Location: s3://${S3_BUCKET}/${S3_DATE_PREFIX}/"
log "  Size:     ${TOTAL_COMPRESSED_HUMAN} compressed from ${TOTAL_USED_HUMAN} used"
log "  Time:     ${TOTAL_ELAPSED}s"
log ""
log "  Restore: bash pi-image-restore.sh"
log "========================================================"

_BACKUP_SUCCEEDED=true

if [[ "${NTFY_LEVEL}" != "failure" && "${DRY_RUN}" != "true" ]]; then
    _NTFY_MSG="$(hostname) — ${DATE}
Bucket: s3://${S3_BUCKET}/${S3_DATE_PREFIX}/
Size:  ${TOTAL_COMPRESSED_HUMAN} compressed (from ${TOTAL_USED_HUMAN} used)
Time:  ${TOTAL_ELAPSED}s"
    ntfy_send "Pi MI backup complete" "${_NTFY_MSG}" "low" "white_check_mark,floppy_disk"
fi
