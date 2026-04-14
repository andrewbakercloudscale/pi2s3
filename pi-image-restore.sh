#!/usr/bin/env bash
# =============================================================
# pi-image-restore.sh — Flash a Pi MI image from S3 to new storage
#
# Run this on a Mac or Linux machine with the target SD card or
# NVMe enclosure connected. Streams the compressed image from S3
# directly to the device — no local download required.
#
# After flashing, boot the new Pi. The restored system will
# expand the root filesystem to fill the new device automatically
# on first boot (Raspberry Pi OS handles this out of the box).
#
# Usage:
#   bash pi-image-restore.sh                       # interactive
#   bash pi-image-restore.sh --list                # list available backups
#   bash pi-image-restore.sh --date 2026-04-12     # restore specific date
#   bash pi-image-restore.sh --device /dev/disk4   # specify target device
#   bash pi-image-restore.sh --yes                 # skip confirmation prompts
#   bash pi-image-restore.sh --verify /dev/disk4   # verify flashed device SHA256
#
# Requirements:
#   - config.env filled in (see config.env.example)
#   - AWS CLI v2 with read access to the S3 bucket
#   - pv optional (progress bar): brew install pv / sudo apt install pv
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

[[ -z "${S3_BUCKET:-}" ]] && { echo "ERROR: S3_BUCKET is not set in config.env"; exit 1; }
[[ -z "${S3_REGION:-}" ]] && { echo "ERROR: S3_REGION is not set in config.env"; exit 1; }

AWS_PROFILE="${AWS_PROFILE:-}"
S3_PREFIX="pi-image-backup"

TARGET_DATE=""
TARGET_DEVICE=""
YES=false
LIST_ONLY=false
VERIFY_DEVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)       LIST_ONLY=true ;;
        --yes|-y)     YES=true ;;
        --date)       shift; TARGET_DATE="${1:-}" ;;
        --date=*)     TARGET_DATE="${1#--date=}" ;;
        --device)     shift; TARGET_DEVICE="${1:-}" ;;
        --device=*)   TARGET_DEVICE="${1#--device=}" ;;
        --verify)     shift; VERIFY_DEVICE="${1:-}" ;;
        --verify=*)   VERIFY_DEVICE="${1#--verify=}" ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--list] [--date YYYY-MM-DD] [--device /dev/...] [--yes] [--verify /dev/...]"
            exit 1
            ;;
    esac
    shift
done

OS_TYPE="$(uname -s)"

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()     { echo "ERROR: $*" >&2; exit 1; }
confirm() {
    [[ "${YES}" == "true" ]] && return 0
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "${answer,,}" == "y" ]]
}

aws_cmd() {
    if [[ -n "${AWS_PROFILE}" ]]; then
        aws --profile "${AWS_PROFILE}" --region "${S3_REGION}" "$@"
    else
        aws --region "${S3_REGION}" "$@"
    fi
}

get_manifest_field() {
    local manifest="$1" field="$2"
    echo "${manifest}" | grep -o "\"${field}\": *\"[^\"]*\"" | cut -d'"' -f4 || true
}

# ── List backups ──────────────────────────────────────────────────────────────
list_backups() {
    log "Available Pi MI backups in s3://${S3_BUCKET}/${S3_PREFIX}/:"
    echo ""

    local dates
    dates=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
        | grep PRE | awk '{print $2}' | tr -d '/' | sort -r)

    [[ -z "${dates}" ]] && die "No backups found in s3://${S3_BUCKET}/${S3_PREFIX}/"

    local idx=1
    while IFS= read -r date; do
        [[ -z "${date}" ]] && continue
        local manifest_file size_info=""
        manifest_file=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${date}/" 2>/dev/null \
            | grep manifest | awk '{print $4}' | head -1 || true)
        if [[ -n "${manifest_file}" ]]; then
            local manifest
            manifest=$(aws_cmd s3 cp \
                "s3://${S3_BUCKET}/${S3_PREFIX}/${date}/${manifest_file}" - 2>/dev/null || true)
            if [[ -n "${manifest}" ]]; then
                local compressed device hostname_val
                compressed=$(get_manifest_field "${manifest}" "compressed_size_human")
                device=$(get_manifest_field "${manifest}" "device")
                hostname_val=$(get_manifest_field "${manifest}" "hostname")
                size_info=" — ${compressed:-?} compressed, ${device:-?} (${hostname_val:-?})"
            fi
        fi
        printf "  [%d] %s%s\n" "${idx}" "${date}" "${size_info}"
        (( idx++ )) || true
    done <<< "${dates}"

    echo ""
    echo "  Total: $(echo "${dates}" | grep -c . || true) backup(s)"
}

if [[ "${LIST_ONLY}" == "true" ]]; then
    list_backups
    exit 0
fi

# ── Verify flashed device ─────────────────────────────────────────────────────
# Usage: pi-image-restore.sh --verify /dev/disk4 [--date YYYY-MM-DD]
# Re-reads the device and compares its SHA256 to the manifest.
if [[ -n "${VERIFY_DEVICE}" ]]; then
    log "========================================================"
    log "  Pi MI — post-flash device verification"
    log "========================================================"

    [[ ! -b "${VERIFY_DEVICE}" ]] && die "Device not found: ${VERIFY_DEVICE}"

    # Find the backup to compare against
    if [[ -z "${TARGET_DATE}" ]]; then
        TARGET_DATE=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
            | grep PRE | awk '{print $2}' | tr -d '/' | sort -r | head -1 || true)
        [[ -z "${TARGET_DATE}" ]] && die "No backups found. Specify --date to select one."
        log "Using latest backup for comparison: ${TARGET_DATE}"
    else
        log "Using backup: ${TARGET_DATE}"
    fi

    VD_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${TARGET_DATE}"

    VD_MFILE=$(aws_cmd s3 ls "${VD_PATH}/" 2>/dev/null \
        | grep manifest | awk '{print $4}' | head -1 || true)
    [[ -z "${VD_MFILE}" ]] && die "No manifest found for ${TARGET_DATE}"

    VD_MANIFEST=$(aws_cmd s3 cp "${VD_PATH}/${VD_MFILE}" - 2>/dev/null) \
        || die "Failed to read manifest"
    VD_EXPECTED=$(echo "${VD_MANIFEST}" \
        | grep -o '"device_sha256": *"[^"]*"' | cut -d'"' -f4 || true)

    if [[ -z "${VD_EXPECTED}" ]]; then
        die "No device_sha256 in manifest — this backup predates integrity support."
    fi

    VD_DEV_SIZE=$(blockdev --getsize64 "${VERIFY_DEVICE}" 2>/dev/null \
        || lsblk -bdno SIZE "${VERIFY_DEVICE}" 2>/dev/null || echo "0")
    VD_DEV_SIZE_HUMAN=$(numfmt --to=iec "${VD_DEV_SIZE}" 2>/dev/null || echo "?")

    log ""
    log "Device:          ${VERIFY_DEVICE} (${VD_DEV_SIZE_HUMAN})"
    log "Expected SHA256: ${VD_EXPECTED}"
    log ""
    log "Reading device and computing SHA256..."
    log "  (reads the entire device — same duration as the original backup)"

    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        VD_READ_DEV="${VERIFY_DEVICE/\/dev\/disk//dev/rdisk}"
    else
        VD_READ_DEV="${VERIFY_DEVICE}"
    fi

    VD_ACTUAL=$(sudo dd if="${VD_READ_DEV}" bs=4M status=none 2>/dev/null \
        | sha256sum \
        | awk '{print $1}')

    log "Actual SHA256:   ${VD_ACTUAL}"
    log ""

    if [[ "${VD_EXPECTED}" == "${VD_ACTUAL}" ]]; then
        log "VERIFY OK — device matches S3 image exactly."
        exit 0
    else
        log "VERIFY FAILED — SHA256 mismatch! Flash may be incomplete or corrupted."
        log "  Try reflashing: bash pi-image-restore.sh --date ${TARGET_DATE} --device ${VERIFY_DEVICE}"
        exit 1
    fi
fi

# ── Header ────────────────────────────────────────────────────────────────────
log "========================================================"
log "  Pi MI — restore from S3"
log "========================================================"
echo ""

command -v aws &>/dev/null || die "aws CLI not found."

# ── Pick backup ───────────────────────────────────────────────────────────────
log "Finding available backups..."

ALL_DATES=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
    | grep PRE | awk '{print $2}' | tr -d '/' | sort -r)

[[ -z "${ALL_DATES}" ]] && die "No backups found in s3://${S3_BUCKET}/${S3_PREFIX}/"

if [[ -z "${TARGET_DATE}" ]]; then
    if [[ "${YES}" == "true" ]]; then
        TARGET_DATE=$(echo "${ALL_DATES}" | head -1)
        log "Using latest: ${TARGET_DATE}"
    else
        echo "Available backups (newest first):"
        echo ""
        declare -a DATE_ARRAY=()
        local_idx=1
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            DATE_ARRAY+=("$d")
            echo "  [${local_idx}] $d"
            (( local_idx++ )) || true
        done <<< "${ALL_DATES}"
        echo ""
        read -r -p "Select backup (Enter = latest [1]): " date_choice
        date_choice="${date_choice:-1}"
        TARGET_DATE="${DATE_ARRAY[$(( date_choice - 1 ))]:-}"
        [[ -z "${TARGET_DATE}" ]] && die "Invalid selection."
    fi
fi

S3_DATE_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${TARGET_DATE}"
log "Backup selected: ${TARGET_DATE}"

IMAGE_FILE=$(aws_cmd s3 ls "${S3_DATE_PATH}/" 2>/dev/null \
    | grep '\.img\.gz' | awk '{print $4}' | tail -1)
[[ -z "${IMAGE_FILE}" ]] && die "No .img.gz found in ${S3_DATE_PATH}/"

FULL_IMAGE_KEY="${S3_PREFIX}/${TARGET_DATE}/${IMAGE_FILE}"

# ── Show manifest ─────────────────────────────────────────────────────────────
MANIFEST_FILE=$(aws_cmd s3 ls "${S3_DATE_PATH}/" 2>/dev/null \
    | grep manifest | awk '{print $4}' | head -1 || true)
if [[ -n "${MANIFEST_FILE}" ]]; then
    echo ""
    log "Backup details:"
    MANIFEST=$(aws_cmd s3 cp "${S3_DATE_PATH}/${MANIFEST_FILE}" - 2>/dev/null || true)
    if [[ -n "${MANIFEST}" ]]; then
        for field in hostname pi_model os device device_size_human compressed_size_human backup_duration_seconds; do
            val=$(get_manifest_field "${MANIFEST}" "${field}")
            [[ -n "${val}" ]] && printf "  %-28s %s\n" "${field}:" "${val}"
        done
    fi
fi

IMAGE_SIZE=$(aws_cmd s3 ls "${S3_DATE_PATH}/${IMAGE_FILE}" 2>/dev/null \
    | awk '{print $3}' | head -1 || echo "0")
IMAGE_SIZE_HUMAN=$(numfmt --to=iec "${IMAGE_SIZE}" 2>/dev/null || echo "${IMAGE_SIZE} bytes")

# ── Pick target device ────────────────────────────────────────────────────────
echo ""
if [[ -z "${TARGET_DEVICE}" ]]; then
    log "Available storage devices:"
    echo ""
    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        diskutil list 2>/dev/null | grep -E '^/dev/disk' | while read -r dev _; do
            echo "  ${dev}:"
            diskutil info "${dev}" 2>/dev/null \
                | grep -E '(Media Name|Total Size|Protocol|Removable)' \
                | sed 's/^ */    /'
            echo ""
        done
    else
        lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v loop | sed 's/^/  /'
    fi
    echo ""
    echo "  WARNING: All data on the target device will be permanently destroyed."
    echo ""
    read -r -p "  Enter target device (e.g. /dev/disk4 or /dev/sdb): " TARGET_DEVICE
fi

[[ -z "${TARGET_DEVICE}" ]] && die "No target device specified."

# ── Refuse to overwrite the running system ────────────────────────────────────
BOOT_DISK=""
if [[ "${OS_TYPE}" == "Darwin" ]]; then
    BOOT_DISK=$(diskutil info / 2>/dev/null \
        | grep 'Part of Whole' | awk '{print "/dev/"$NF}' || true)
elif [[ -f /proc/mounts ]]; then
    ROOT_PART=$(awk '$2 == "/" {print $1; exit}' /proc/mounts)
    BOOT_DISK=$(lsblk -no PKNAME "${ROOT_PART}" 2>/dev/null \
        | head -1 | sed 's/^/\/dev\//' || true)
fi
if [[ -n "${BOOT_DISK}" && "${TARGET_DEVICE}" == "${BOOT_DISK}"* ]]; then
    die "Cannot write to the system boot disk (${BOOT_DISK}). This would destroy your machine."
fi

# ── Final confirmation ────────────────────────────────────────────────────────
echo ""
echo "  Source:  s3://${S3_BUCKET}/${FULL_IMAGE_KEY}"
echo "  Size:    ${IMAGE_SIZE_HUMAN} (compressed)"
echo "  Target:  ${TARGET_DEVICE}"
echo ""
if [[ "${OS_TYPE}" == "Darwin" ]]; then
    diskutil info "${TARGET_DEVICE}" 2>/dev/null \
        | grep -E '(Media Name|Total Size)' | sed 's/^ */  /'
else
    lsblk "${TARGET_DEVICE}" 2>/dev/null | sed 's/^/  /'
fi
echo ""
echo "  *** ALL DATA ON ${TARGET_DEVICE} WILL BE PERMANENTLY DESTROYED ***"
echo ""
confirm "Proceed with flash?" || { echo "Aborted."; exit 0; }

# ── Unmount ───────────────────────────────────────────────────────────────────
log ""
log "Unmounting ${TARGET_DEVICE}..."
if [[ "${OS_TYPE}" == "Darwin" ]]; then
    diskutil unmountDisk "${TARGET_DEVICE}" 2>/dev/null || true
else
    lsblk -no NAME "${TARGET_DEVICE}" 2>/dev/null | tail -n +2 | while read -r part; do
        umount "/dev/${part}" 2>/dev/null || true
    done
fi

# ── Flash ─────────────────────────────────────────────────────────────────────
log ""
log "Flashing... (${IMAGE_SIZE_HUMAN} compressed — will take several minutes)"
echo ""

START_TIME=$(date +%s)

# macOS: use /dev/rdisk (raw device — ~10x faster writes than /dev/disk)
if [[ "${OS_TYPE}" == "Darwin" ]]; then
    WRITE_DEVICE="${TARGET_DEVICE/\/dev\/disk//dev/rdisk}"
    DD_BS="4m"    # macOS requires lowercase suffix
else
    WRITE_DEVICE="${TARGET_DEVICE}"
    DD_BS="4M"
fi

if command -v pv &>/dev/null; then
    aws_cmd s3 cp "s3://${S3_BUCKET}/${FULL_IMAGE_KEY}" - \
        | pv -s "${IMAGE_SIZE}" \
        | gunzip -c \
        | sudo dd of="${WRITE_DEVICE}" bs="${DD_BS}" status=none
else
    log "  (Install pv for a live progress bar: brew install pv / sudo apt install pv)"
    aws_cmd s3 cp "s3://${S3_BUCKET}/${FULL_IMAGE_KEY}" - \
        | gunzip -c \
        | sudo dd of="${WRITE_DEVICE}" bs="${DD_BS}" status=progress
fi

sync
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
log "Flash complete in ${ELAPSED}s."

if [[ "${OS_TYPE}" == "Darwin" ]]; then
    log "Ejecting ${TARGET_DEVICE}..."
    diskutil eject "${TARGET_DEVICE}" 2>/dev/null || true
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
log "========================================================"
log "  Restore complete!"
log ""
log "  Next steps:"
log "    1. Remove the storage from this machine"
log "    2. Insert into the new Raspberry Pi"
log "    3. Boot — root filesystem expands automatically"
log "       on first boot to fill the new device"
log ""
log "  Connecting to the restored Pi:"
log "    The restored Pi has the SAME SSH host key as the original."
log "    If you've connected to the original before, clear the old key:"
log "      ssh-keygen -R raspberrypi.local"
log "      ssh-keygen -R <ip-address>"
log "    Then: ssh pi@raspberrypi.local  (or check router DHCP for IP)"
log ""
log "  If running original + clone simultaneously:"
log "    Change the hostname to avoid conflicts:"
log "      sudo raspi-config  → System Options → Hostname"
log ""
log "  Verify after boot:"
log "    docker ps                    (containers running?)"
log "    systemctl status cloudflared (tunnel up?)"
log "    df -h                        (filesystem expanded to full device?)"
log "    crontab -l                   (backup cron intact?)"
log "========================================================"
