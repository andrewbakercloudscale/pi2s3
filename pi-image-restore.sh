#!/usr/bin/env bash
# =============================================================
# pi-image-restore.sh — Flash a Pi MI image from S3 to new storage
#
# Supports two backup formats:
#
#   partclone (current) — each partition is a separate image
#     - Restores partition table with sfdisk
#     - Restores each partition with partclone (verifies checksums inline)
#     - REQUIRES LINUX (sfdisk + partclone not available on macOS)
#     - On macOS: boot the new Pi with a minimal SD card, then SSH in
#       and run this script there
#
#   dd (legacy) — single .img.gz of full device
#     - Works on Mac and Linux
#     - Streams gunzip | dd to target device
#
# Run on a Linux machine (Pi or other) with the target NVMe or SD
# card connected. Streams directly from S3 — no local download.
#
# Usage:
#   bash pi-image-restore.sh                       # interactive
#   bash pi-image-restore.sh --list                # list available backups
#   bash pi-image-restore.sh --date 2026-04-12     # restore specific date
#   bash pi-image-restore.sh --device /dev/sda     # specify target device
#   bash pi-image-restore.sh --yes                 # skip confirmation prompts
#   bash pi-image-restore.sh --verify /dev/sda     # verify after flash (dd format only)
#
# Requirements (partclone format):
#   - Linux with sfdisk (util-linux) and partclone installed
#   - AWS CLI v2 with read access to the S3 bucket
#   - python3 (for manifest parsing)
#   - pv optional (progress bar): sudo apt install pv
#
# Requirements (dd legacy format):
#   - Mac or Linux with AWS CLI v2
#   - pv optional: brew install pv / sudo apt install pv
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
VERIFY_DATE_FOR_VERIFY=""

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
                local compressed hostname_val
                # Support both new (total_compressed_human) and old (compressed_size_human) formats
                compressed=$(get_manifest_field "${manifest}" "total_compressed_human")
                [[ -z "${compressed}" ]] && compressed=$(get_manifest_field "${manifest}" "compressed_size_human")
                hostname_val=$(get_manifest_field "${manifest}" "hostname")
                size_info=" — ${compressed:-?} compressed (${hostname_val:-?})"
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

# ── Verify flashed device (dd format only) ────────────────────────────────────
# Reads back the device and compares SHA256 to the manifest.
# For partclone format, verification happens inline during restore.
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

    VD_BACKUP_TYPE=$(get_manifest_field "${VD_MANIFEST}" "backup_type")

    if [[ "${VD_BACKUP_TYPE}" == "partclone" ]]; then
        log ""
        log "This is a partclone-format backup."
        log "Partclone verifies block checksums automatically during restore."
        log "Post-flash SHA256 verification is not available for partclone backups."
        log ""
        log "To verify S3 objects are intact, run on the Pi:"
        log "  bash ~/pi-mi/pi-image-backup.sh --verify"
        exit 0
    fi

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

# ── Read manifest and detect backup type ─────────────────────────────────────
MANIFEST_FILE=$(aws_cmd s3 ls "${S3_DATE_PATH}/" 2>/dev/null \
    | grep manifest | awk '{print $4}' | head -1 || true)

MANIFEST=""
BACKUP_TYPE="dd"   # default for old backups without a manifest

if [[ -n "${MANIFEST_FILE}" ]]; then
    MANIFEST=$(aws_cmd s3 cp "${S3_DATE_PATH}/${MANIFEST_FILE}" - 2>/dev/null || true)
    if [[ -n "${MANIFEST}" ]]; then
        BACKUP_TYPE=$(get_manifest_field "${MANIFEST}" "backup_type")
        [[ -z "${BACKUP_TYPE}" ]] && BACKUP_TYPE="dd"
    fi
fi

# ── Show backup summary ───────────────────────────────────────────────────────
if [[ -n "${MANIFEST}" ]]; then
    echo ""
    log "Backup details:"
    if [[ "${BACKUP_TYPE}" == "partclone" ]]; then
        for field in hostname pi_model os device total_used_human total_compressed_human backup_duration_seconds; do
            val=$(get_manifest_field "${MANIFEST}" "${field}")
            [[ -n "${val}" ]] && printf "  %-28s %s\n" "${field}:" "${val}"
        done
        # Count partitions
        PART_COUNT=$(echo "${MANIFEST}" | grep -c '"name":' || true)
        echo "  partitions:                  ${PART_COUNT}"
    else
        for field in hostname pi_model os device device_size_human compressed_size_human backup_duration_seconds; do
            val=$(get_manifest_field "${MANIFEST}" "${field}")
            [[ -n "${val}" ]] && printf "  %-28s %s\n" "${field}:" "${val}"
        done
    fi
fi

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
    read -r -p "  Enter target device (e.g. /dev/sda or /dev/nvme0n1): " TARGET_DEVICE
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
if [[ "${BACKUP_TYPE}" == "partclone" ]]; then
    TOTAL_COMPRESSED=$(get_manifest_field "${MANIFEST}" "total_compressed_human")
    echo "  Backup:  ${TARGET_DATE} (partclone format)"
    echo "  Size:    ${TOTAL_COMPRESSED:-?} (compressed, all partitions)"
    echo "  Target:  ${TARGET_DEVICE}"
else
    IMAGE_FILE=$(aws_cmd s3 ls "${S3_DATE_PATH}/" 2>/dev/null \
        | grep '\.img\.gz' | awk '{print $4}' | tail -1 || true)
    [[ -z "${IMAGE_FILE}" ]] && die "No .img.gz found in ${S3_DATE_PATH}/"
    IMAGE_SIZE=$(aws_cmd s3 ls "${S3_DATE_PATH}/${IMAGE_FILE}" 2>/dev/null \
        | awk '{print $3}' | head -1 || echo "0")
    IMAGE_SIZE_HUMAN=$(numfmt --to=iec "${IMAGE_SIZE}" 2>/dev/null || echo "${IMAGE_SIZE} bytes")
    echo "  Source:  s3://${S3_BUCKET}/${S3_PREFIX}/${TARGET_DATE}/${IMAGE_FILE}"
    echo "  Size:    ${IMAGE_SIZE_HUMAN} (compressed)"
    echo "  Target:  ${TARGET_DEVICE}"
fi
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
START_TIME=$(date +%s)

if [[ "${BACKUP_TYPE}" == "partclone" ]]; then
    # ── Partclone restore ─────────────────────────────────────────────────────
    log ""
    log "Partclone restore — partition by partition..."

    if [[ "${OS_TYPE}" != "Linux" ]]; then
        echo ""
        echo "  Partclone restore requires Linux (sfdisk + partclone are not available on macOS)."
        echo ""
        echo "  To restore on macOS:"
        echo "    1. Boot the new Pi from a minimal SD card (Raspberry Pi OS Lite)"
        echo "    2. Attach the target NVMe via USB enclosure or directly"
        echo "    3. SSH into the Pi, clone the repo, then run:"
        echo "       bash ~/pi-mi/pi-image-restore.sh"
        echo ""
        exit 1
    fi

    command -v sfdisk      &>/dev/null || die "sfdisk not found. Install: sudo apt install util-linux"
    command -v partclone.ext4 &>/dev/null || die "partclone not found. Install: sudo apt install partclone"
    command -v python3     &>/dev/null || die "python3 not found (required for manifest parsing)"

    # 1. Restore partition table
    PTABLE_KEY=$(get_manifest_field "${MANIFEST}" "partition_table_key")
    [[ -z "${PTABLE_KEY}" ]] && die "No partition_table_key in manifest."

    log ""
    log "Restoring partition table to ${TARGET_DEVICE}..."
    aws_cmd s3 cp "s3://${S3_BUCKET}/${PTABLE_KEY}" - 2>/dev/null \
        | sudo sfdisk --force --no-reread "${TARGET_DEVICE}" 2>&1 \
        | grep -v '^$' | sed 's/^/  /' || true

    # Wait for kernel to update partition table
    sudo partprobe "${TARGET_DEVICE}" 2>/dev/null \
        || sudo blockdev --rereadpt "${TARGET_DEVICE}" 2>/dev/null || true
    sleep 2
    log "  Partition table restored."

    # 2. Parse partitions from manifest
    PART_DATA=$(echo "${MANIFEST}" | python3 -c "
import json, sys
m = json.load(sys.stdin)
for p in m.get('partitions', []):
    print('\t'.join([
        p.get('name',''),
        p.get('tool','partclone.dd'),
        p.get('key',''),
        str(p.get('compressed_bytes', 0))
    ]))
") || die "Failed to parse manifest partitions (python3 error)"

    # 3. Restore each partition
    while IFS=$'\t' read -r PART_NAME PART_TOOL PART_KEY PART_CSIZE; do
        [[ -z "${PART_NAME}" || -z "${PART_KEY}" ]] && continue

        # Map source partition name to target partition device by number
        PART_NUM=$(echo "${PART_NAME}" | grep -o '[0-9]*$' || true)
        [[ -z "${PART_NUM}" ]] && { log "  Skipping ${PART_NAME} — cannot determine partition number"; continue; }

        if [[ "${TARGET_DEVICE}" =~ (nvme|mmcblk) ]]; then
            TARGET_PART="${TARGET_DEVICE}p${PART_NUM}"
        else
            TARGET_PART="${TARGET_DEVICE}${PART_NUM}"
        fi

        PART_SIZE_H=$(numfmt --to=iec "${PART_CSIZE}" 2>/dev/null || echo "${PART_CSIZE} bytes")

        log ""
        log "  Restoring ${TARGET_PART}  (${PART_SIZE_H} compressed)"
        log "  Source: ${PART_KEY}"

        # Wait up to 10s for partition device node to appear
        RETRIES=0
        while [[ ! -b "${TARGET_PART}" && ${RETRIES} -lt 10 ]]; do
            sleep 1
            (( RETRIES++ )) || true
        done
        [[ ! -b "${TARGET_PART}" ]] && die "Partition ${TARGET_PART} did not appear after partition table restore."

        if command -v pv &>/dev/null; then
            aws_cmd s3 cp "s3://${S3_BUCKET}/${PART_KEY}" - \
                | pv -s "${PART_CSIZE}" \
                | gunzip \
                | sudo "${PART_TOOL}" -r -s - -o "${TARGET_PART}"
        else
            aws_cmd s3 cp "s3://${S3_BUCKET}/${PART_KEY}" - \
                | gunzip \
                | sudo "${PART_TOOL}" -r -s - -o "${TARGET_PART}"
        fi

        log "  ${TARGET_PART} restored."
    done <<< "${PART_DATA}"

    # 4. Restore boot firmware (separate SD card partition) if present
    FW_DATA=$(echo "${MANIFEST}" | python3 -c "
import json, sys
m = json.load(sys.stdin)
fw = m.get('boot_firmware')
if fw and fw.get('key'):
    print('\t'.join([
        fw.get('name',''),
        fw.get('tool','partclone.vfat'),
        fw.get('key',''),
        str(fw.get('compressed_bytes', 0))
    ]))
") || true

    if [[ -n "${FW_DATA}" ]]; then
        IFS=$'\t' read -r FW_NAME FW_TOOL FW_KEY FW_CSIZE <<< "${FW_DATA}"
        FW_SIZE_H=$(numfmt --to=iec "${FW_CSIZE}" 2>/dev/null || echo "${FW_CSIZE} bytes")
        log ""
        log "Boot firmware is on a separate SD card partition (${FW_NAME}, ${FW_SIZE_H})."
        if [[ "${YES}" == "true" ]]; then
            log "  --yes flag set; skipping boot firmware restore."
            log "  To restore manually: aws s3 cp s3://${S3_BUCKET}/${FW_KEY} - | gunzip | sudo ${FW_TOOL} -r -s - -o /dev/mmcblk0p1"
        else
            read -r -p "  Enter SD card partition for boot firmware (e.g. /dev/mmcblk0p1, or Enter to skip): " FW_TARGET
            if [[ -n "${FW_TARGET}" && -b "${FW_TARGET}" ]]; then
                log "  Restoring boot firmware to ${FW_TARGET}..."
                if command -v pv &>/dev/null; then
                    aws_cmd s3 cp "s3://${S3_BUCKET}/${FW_KEY}" - \
                        | pv -s "${FW_CSIZE}" \
                        | gunzip \
                        | sudo "${FW_TOOL}" -r -s - -o "${FW_TARGET}"
                else
                    aws_cmd s3 cp "s3://${S3_BUCKET}/${FW_KEY}" - \
                        | gunzip \
                        | sudo "${FW_TOOL}" -r -s - -o "${FW_TARGET}"
                fi
                log "  Boot firmware restored."
            else
                log "  Skipping boot firmware restore."
                log "  NOTE: If the Pi boots from SD card, /boot/firmware may need restoring."
            fi
        fi
    fi

else
    # ── Legacy dd restore ─────────────────────────────────────────────────────
    log ""
    log "Flashing... (${IMAGE_SIZE_HUMAN} compressed — will take several minutes)"
    echo ""

    if [[ "${OS_TYPE}" == "Darwin" ]]; then
        WRITE_DEVICE="${TARGET_DEVICE/\/dev\/disk//dev/rdisk}"
        DD_BS="4m"
    else
        WRITE_DEVICE="${TARGET_DEVICE}"
        DD_BS="4M"
    fi

    if command -v pv &>/dev/null; then
        aws_cmd s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${TARGET_DATE}/${IMAGE_FILE}" - \
            | pv -s "${IMAGE_SIZE}" \
            | gunzip -c \
            | sudo dd of="${WRITE_DEVICE}" bs="${DD_BS}" status=none
    else
        log "  (Install pv for a live progress bar: brew install pv / sudo apt install pv)"
        aws_cmd s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${TARGET_DATE}/${IMAGE_FILE}" - \
            | gunzip -c \
            | sudo dd of="${WRITE_DEVICE}" bs="${DD_BS}" status=progress
    fi
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
