#!/usr/bin/env bash
# =============================================================
# pi-image-restore.sh — Restore a pi2s3 backup from S3 to new storage
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
#   bash pi-image-restore.sh                             # interactive full restore
#   bash pi-image-restore.sh --list                      # list available backups
#   bash pi-image-restore.sh --host raspberrypi          # specify Pi hostname (multi-Pi buckets)
#   bash pi-image-restore.sh --date 2026-04-12           # restore specific date
#   bash pi-image-restore.sh --device /dev/sda           # specify target device
#   bash pi-image-restore.sh --yes                       # skip confirmation prompts
#   bash pi-image-restore.sh --resize                    # expand last partition to fill device after restore
#   bash pi-image-restore.sh --verify /dev/sda           # verify after flash (dd only)
#   bash pi-image-restore.sh --extract /home/pi          # extract a path from backup
#   bash pi-image-restore.sh --extract /etc --date DATE  # extract from specific date
#   bash pi-image-restore.sh --extract /var/lib/docker \
#        --partition nvme0n1p2                           # specify which partition
#
# --extract mounts the backup in a loop device (Linux only) and copies
# the requested path to ./pi2s3-extract-<date>/ — no physical target
# device needed. Useful for recovering individual files or directories.
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

# partclone installs to /usr/sbin on Debian/Ubuntu; ensure it's reachable
export PATH="/usr/sbin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found." >&2
    echo "  cp ${SCRIPT_DIR}/config.env.example ${SCRIPT_DIR}/config.env" >&2
    echo "  nano ${SCRIPT_DIR}/config.env" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/aws.sh"

[[ -z "${S3_BUCKET:-}" ]] && { echo "ERROR: S3_BUCKET is not set in config.env" >&2; exit 1; }
[[ -z "${S3_REGION:-}" ]] && { echo "ERROR: S3_REGION is not set in config.env" >&2; exit 1; }

AWS_PROFILE="${AWS_PROFILE:-}"
BACKUP_ENCRYPTION_PASSPHRASE="${BACKUP_ENCRYPTION_PASSPHRASE:-}"
S3_BASE="pi-image-backup"
S3_PREFIX=""   # set by resolve_s3_prefix()

TARGET_DATE=""
TARGET_DEVICE=""
YES=false
LIST_ONLY=false
RESIZE=false
VERIFY_DEVICE=""
EXTRACT_PATH=""
EXTRACT_PARTITION=""
HOST_FILTER=""
POST_RESTORE_SCRIPT=""
_GPG_PASS_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)           LIST_ONLY=true ;;
        --yes|-y)         YES=true ;;
        --date)           shift; TARGET_DATE="${1:-}" ;;
        --date=*)         TARGET_DATE="${1#--date=}" ;;
        --device)         shift; TARGET_DEVICE="${1:-}" ;;
        --device=*)       TARGET_DEVICE="${1#--device=}" ;;
        --verify)         shift; VERIFY_DEVICE="${1:-}" ;;
        --verify=*)       VERIFY_DEVICE="${1#--verify=}" ;;
        --extract)        shift; EXTRACT_PATH="${1:-}" ;;
        --extract=*)      EXTRACT_PATH="${1#--extract=}" ;;
        --partition)      shift; EXTRACT_PARTITION="${1:-}" ;;
        --partition=*)    EXTRACT_PARTITION="${1#--partition=}" ;;
        --host)           shift; HOST_FILTER="${1:-}" ;;
        --host=*)         HOST_FILTER="${1#--host=}" ;;
        --resize)         RESIZE=true ;;
        --post-restore)   shift; POST_RESTORE_SCRIPT="${1:-}" ;;
        --post-restore=*) POST_RESTORE_SCRIPT="${1#--post-restore=}" ;;
        --help)
            echo "Usage: pi-image-restore.sh [options]

  (no args)                  Interactive restore (prompts for date and device)
  --list                     List all available backups
  --date YYYY-MM-DD          Use a specific backup date (default: latest)
  --device /dev/...          Target block device for full restore
  --yes                      Skip all confirmation prompts
  --resize                   Expand last partition to fill device after restore
  --host <hostname>          Select a specific host's backups (multi-Pi setups)
  --extract <path>           Extract a file or directory — no target device needed
  --partition <name>         Partition to use for --extract (default: largest non-boot)
  --verify /dev/...          Verify a flashed device against the S3 manifest
  --post-restore <script>    Run a script inside the restored filesystem before reboot
                             RESTORE_ROOT is exported pointing to the mounted root.
                             See extras/post-restore-example.sh for a template.
  --help                     Show this help

Requires: Linux with partclone, sfdisk, gunzip, AWS CLI v2
Optional: pv (progress bar), gpg (if backup is encrypted)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--list] [--date YYYY-MM-DD] [--device /dev/...] [--yes] [--resize] [--verify /dev/...] [--extract <path>] [--partition <name>] [--host <hostname>] [--post-restore <script>]"
            exit 1
            ;;
    esac
    shift
done

OS_TYPE="$(uname -s)"

confirm() {
    [[ "${YES}" == "true" ]] && return 0
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "${answer,,}" == "y" ]]
}

get_manifest_field() {
    local manifest="$1" field="$2"
    echo "${manifest}" | jq -r ".${field} // empty" 2>/dev/null || true
}

# ── List backups ──────────────────────────────────────────────────────────────
list_backups() {
    log "Available pi2s3 backups in s3://${S3_BUCKET}/${S3_PREFIX}/:"
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

# ── Extract: partial/file-level restore ──────────────────────────────────────
# Streams a single partition from S3, restores it into a loop-device-backed
# temp file, mounts it read-only, then copies the requested path out.
# Linux only — requires losetup + mount (not available on macOS).
do_extract() {
    log "========================================================"
    log "  pi2s3 — partial/file-level restore from S3"
    log "========================================================"
    echo ""

    [[ "${OS_TYPE}" != "Linux" ]] \
        && die "--extract requires Linux (losetup + mount are not available on macOS)"

    command -v losetup &>/dev/null || die "losetup not found (install: sudo apt install util-linux)"
    command -v mount   &>/dev/null || die "mount not found"
    command -v python3 &>/dev/null || die "python3 not found (required for manifest parsing)"

    # ── Pick backup date ──────────────────────────────────────────────────────
    if [[ -z "${TARGET_DATE}" ]]; then
        TARGET_DATE=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
            | grep PRE | awk '{print $2}' | tr -d '/' | sort -r | head -1 || true)
        [[ -z "${TARGET_DATE}" ]] && die "No backups found in s3://${S3_BUCKET}/${S3_PREFIX}/"
        log "Using latest backup: ${TARGET_DATE}"
    fi

    S3_DATE_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${TARGET_DATE}"

    # ── Read manifest ─────────────────────────────────────────────────────────
    local mfile
    mfile=$(aws_cmd s3 ls "${S3_DATE_PATH}/" 2>/dev/null \
        | grep manifest | awk '{print $4}' | head -1 || true)
    [[ -z "${mfile}" ]] && die "No manifest found for ${TARGET_DATE}"

    local manifest
    manifest=$(aws_cmd s3 cp "${S3_DATE_PATH}/${mfile}" - 2>/dev/null) \
        || die "Failed to read manifest"

    local btype
    btype=$(get_manifest_field "${manifest}" "backup_type")
    [[ "${btype}" != "partclone" ]] \
        && die "--extract only works with partclone-format backups (this backup type: ${btype:-dd})"

    # ── Parse partition list from manifest ────────────────────────────────────
    local part_info
    part_info=$(echo "${manifest}" | python3 -c "
import json, sys
m = json.load(sys.stdin)
for p in m.get('partitions', []):
    print('\t'.join([
        p.get('name',''),
        p.get('fstype',''),
        p.get('tool','partclone.dd'),
        p.get('key',''),
        str(p.get('compressed_bytes', 0)),
        str(p.get('size_bytes', 0))
    ]))
") || die "Failed to parse manifest partitions (python3 error)"

    # ── Select partition ──────────────────────────────────────────────────────
    local sel_name="" sel_fstype="" sel_tool="" sel_key="" sel_csize=0 sel_size=0

    if [[ -n "${EXTRACT_PARTITION}" ]]; then
        while IFS=$'\t' read -r p_name p_fstype p_tool p_key p_csize p_size; do
            [[ -z "${p_name}" ]] && continue
            # Accept bare name (nvme0n1p2) or /dev/ prefix
            if [[ "${p_name}" == "${EXTRACT_PARTITION}" \
               || "/dev/${p_name}" == "${EXTRACT_PARTITION}" ]]; then
                sel_name="${p_name}" sel_fstype="${p_fstype}" sel_tool="${p_tool}"
                sel_key="${p_key}"   sel_csize="${p_csize}"   sel_size="${p_size}"
                break
            fi
        done <<< "${part_info}"
        [[ -z "${sel_name}" ]] && die "Partition '${EXTRACT_PARTITION}' not found in manifest. Available: $(echo "${part_info}" | awk -F$'\t' '{print $1}' | tr '\n' ' ')"
    else
        # Auto-select: largest non-vfat partition (typically the root filesystem)
        local largest=0
        while IFS=$'\t' read -r p_name p_fstype p_tool p_key p_csize p_size; do
            [[ -z "${p_name}" ]] && continue
            [[ "${p_fstype}" == "vfat" ]] && continue   # skip boot/EFI partitions
            if (( p_size > largest )); then
                largest="${p_size}"
                sel_name="${p_name}" sel_fstype="${p_fstype}" sel_tool="${p_tool}"
                sel_key="${p_key}"   sel_csize="${p_csize}"   sel_size="${p_size}"
            fi
        done <<< "${part_info}"
        [[ -z "${sel_name}" ]] && die "Could not auto-select a partition. Use --partition <name>."
        log "Auto-selected partition: ${sel_name} (${sel_fstype}, $(numfmt --to=iec "${sel_size}" 2>/dev/null || echo "${sel_size} B") raw)"
    fi

    { command -v "${sel_tool}" &>/dev/null || [[ -x "/usr/sbin/${sel_tool}" ]]; } \
        || die "${sel_tool} not found. Install: sudo apt install partclone"

    local sel_size_h sel_csize_h
    sel_size_h=$(numfmt --to=iec "${sel_size}" 2>/dev/null || echo "${sel_size} B")
    sel_csize_h=$(numfmt --to=iec "${sel_csize}" 2>/dev/null || echo "${sel_csize} B")

    # ── Output directory ──────────────────────────────────────────────────────
    local out_dir
    out_dir="$(pwd)/pi2s3-extract-${TARGET_DATE}"
    mkdir -p "${out_dir}"

    # ── Summary + confirmation ────────────────────────────────────────────────
    echo ""
    log "  Backup date:   ${TARGET_DATE}"
    log "  Partition:     ${sel_name} (${sel_fstype})"
    log "  Partition size:${sel_size_h} raw  /  ${sel_csize_h} compressed"
    log "  Extract path:  ${EXTRACT_PATH}"
    log "  Output:        ${out_dir}/"
    echo ""
    if [[ "${EXTRACT_PATH}" == "/" ]]; then
        log "  WARNING: --extract / will copy the entire root filesystem."
        log "           This may use several GB of disk space."
    fi
    confirm "Download partition and extract '${EXTRACT_PATH}'?" \
        || { echo "Aborted."; exit 0; }

    # ── Cleanup trap ──────────────────────────────────────────────────────────
    local _loop="" _mnt="" _img=""

    _extract_cleanup() {
        [[ -n "${_mnt}"  ]] && sudo umount  "${_mnt}"  2>/dev/null || true
        [[ -n "${_loop}" ]] && sudo losetup -d "${_loop}" 2>/dev/null || true
        [[ -n "${_img}"  && -f "${_img}" ]] && rm -f "${_img}"
        [[ -n "${_mnt}"  && -d "${_mnt}" ]] && rmdir "${_mnt}" 2>/dev/null || true
    }
    trap _extract_cleanup EXIT

    # ── Create sparse temp image ──────────────────────────────────────────────
    _img=$(mktemp --suffix=.img --tmpdir="/tmp" "pi2s3-extract-XXXXXX")
    log ""
    log "Creating sparse image (${sel_size_h}) at ${_img}..."
    truncate -s "${sel_size}" "${_img}"

    # ── Attach loop device ────────────────────────────────────────────────────
    _loop=$(sudo losetup --find --show "${_img}")
    log "Loop device: ${_loop}"

    # ── Detect and set up decryption (extract-local) ──────────────────────────
    local _decrypt_cmd="cat" _extract_gpg_pass_file=""
    local _extract_encrypt_method
    _extract_encrypt_method=$(python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('encryption','none'))" \
        <<< "${manifest}" 2>/dev/null || echo "none")

    if [[ "${_extract_encrypt_method}" == "gpg-aes256" ]]; then
        log "Backup is encrypted (gpg AES-256). Passphrase required."
        command -v gpg &>/dev/null || die "gpg not found. Install: sudo apt install gpg"
        if [[ -z "${BACKUP_ENCRYPTION_PASSPHRASE}" ]]; then
            read -s -r -p "  Enter decryption passphrase: " BACKUP_ENCRYPTION_PASSPHRASE
            echo
        fi
        _extract_gpg_pass_file=$(mktemp)
        chmod 600 "${_extract_gpg_pass_file}"
        printf '%s' "${BACKUP_ENCRYPTION_PASSPHRASE}" > "${_extract_gpg_pass_file}"
        _decrypt_cmd="gpg --batch --yes --passphrase-file ${_extract_gpg_pass_file} --decrypt"
    fi

    # ── Stream restore from S3 ────────────────────────────────────────────────
    echo ""
    log "Streaming partition from S3 → loop device..."
    log "  (${sel_csize_h} to download — may take several minutes)"
    echo ""

    if command -v pv &>/dev/null; then
        aws_cmd s3 cp "s3://${S3_BUCKET}/${sel_key}" - \
            | pv -s "${sel_csize}" \
            | ${_decrypt_cmd} \
            | gunzip \
            | sudo "${sel_tool}" -r -s - -o "${_loop}"
    else
        log "  (Install pv for a progress bar: sudo apt install pv)"
        aws_cmd s3 cp "s3://${S3_BUCKET}/${sel_key}" - \
            | ${_decrypt_cmd} \
            | gunzip \
            | sudo "${sel_tool}" -r -s - -o "${_loop}"
    fi

    [[ -n "${_extract_gpg_pass_file}" ]] && rm -f "${_extract_gpg_pass_file}"

    echo ""
    log "Partition restored to loop device."

    # ── Mount read-only ───────────────────────────────────────────────────────
    _mnt=$(mktemp -d --tmpdir="/tmp" "pi2s3-mnt-XXXXXX")
    log "Mounting ${_loop} at ${_mnt} (read-only)..."
    local _mount_args=("-o" "ro")
    [[ -n "${sel_fstype}" && "${sel_fstype}" != "unknown" ]] \
        && _mount_args+=("-t" "${sel_fstype}")
    sudo mount "${_mount_args[@]}" "${_loop}" "${_mnt}" \
        || die "mount failed — the filesystem type (${sel_fstype:-auto-detect}) may not be supported by this kernel"

    # ── Verify path exists ────────────────────────────────────────────────────
    local src_path="${_mnt}${EXTRACT_PATH}"
    [[ ! -e "${src_path}" ]] \
        && die "Path '${EXTRACT_PATH}' not found in this backup partition"

    # ── Copy files out ────────────────────────────────────────────────────────
    log ""
    log "Copying '${EXTRACT_PATH}' → ${out_dir}/..."
    sudo cp -a "${src_path}" "${out_dir}/"
    sudo chown -R "$(id -u):$(id -g)" "${out_dir}/" 2>/dev/null || true

    # ── Explicit cleanup (reset trap vars so trap no-ops) ─────────────────────
    local _c_mnt="${_mnt}" _c_loop="${_loop}" _c_img="${_img}"
    _mnt=""; _loop=""; _img=""
    trap - EXIT

    log "Unmounting and cleaning up..."
    sudo umount  "${_c_mnt}"  2>/dev/null || true
    sudo losetup -d "${_c_loop}" 2>/dev/null || true
    rm -f "${_c_img}"
    rmdir "${_c_mnt}" 2>/dev/null || true

    # ── Done ─────────────────────────────────────────────────────────────────
    echo ""
    log "========================================================"
    log "  Extract complete!"
    log ""
    log "  Files saved to: ${out_dir}/"
    log "  Backup date:    ${TARGET_DATE}"
    log "  Extracted path: ${EXTRACT_PATH}"
    log "========================================================"
}

# ── Resolve S3 prefix (per-host namespacing) ──────────────────────────────────
resolve_s3_prefix() {
    local hosts
    hosts=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_BASE}/" 2>/dev/null \
        | grep PRE | awk '{print $2}' | tr -d '/' | sort || true)

    [[ -z "${hosts}" ]] && die "No backups found in s3://${S3_BUCKET}/${S3_BASE}/"

    local host_count
    host_count=$(echo "${hosts}" | grep -c . || echo 0)

    if [[ -n "${HOST_FILTER}" ]]; then
        echo "${hosts}" | grep -qxF "${HOST_FILTER}" \
            || die "Host '${HOST_FILTER}' not found. Available: $(echo "${hosts}" | tr '\n' ' ')"
        S3_PREFIX="${S3_BASE}/${HOST_FILTER}"
        log "Host: ${HOST_FILTER}"
        return
    fi

    if [[ "${host_count}" -eq 1 ]]; then
        local only
        only=$(echo "${hosts}" | head -1)
        S3_PREFIX="${S3_BASE}/${only}"
        log "Host: ${only}"
        return
    fi

    # Multiple hosts
    echo "Available Pi hosts:"
    echo ""
    declare -a _host_arr=()
    local _i=1
    while IFS= read -r _h; do
        [[ -z "${_h}" ]] && continue
        _host_arr+=("${_h}")
        printf "  [%d] %s\n" "${_i}" "${_h}"
        (( _i++ )) || true
    done <<< "${hosts}"
    echo ""

    if [[ "${YES}" == "true" ]]; then
        local best="" best_date=""
        for _h in "${_host_arr[@]}"; do
            local _latest
            _latest=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_BASE}/${_h}/" 2>/dev/null \
                | grep PRE | awk '{print $2}' | tr -d '/' | sort -r | head -1 || true)
            [[ "${_latest}" > "${best_date}" ]] && { best_date="${_latest}"; best="${_h}"; }
        done
        [[ -z "${best}" ]] && die "Could not auto-select a host."
        log "Auto-selected host (most recent backup): ${best} (${best_date})"
        S3_PREFIX="${S3_BASE}/${best}"
    else
        read -r -p "Select host (Enter = [1]): " _choice
        _choice="${_choice:-1}"
        local _chosen="${_host_arr[$(( _choice - 1 ))]:-}"
        [[ -z "${_chosen}" ]] && die "Invalid selection."
        S3_PREFIX="${S3_BASE}/${_chosen}"
    fi
}

resolve_s3_prefix

if [[ "${LIST_ONLY}" == "true" ]]; then
    list_backups
    exit 0
fi

if [[ -n "${EXTRACT_PATH}" ]]; then
    do_extract
    exit 0
fi

# ── Verify flashed device (dd format only) ────────────────────────────────────
# Reads back the device and compares SHA256 to the manifest.
# For partclone format, verification happens inline during restore.
if [[ -n "${VERIFY_DEVICE}" ]]; then
    log "========================================================"
    log "  pi2s3 — post-flash device verification"
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
        log "  bash ~/pi2s3/pi-image-backup.sh --verify"
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

# ── Main ──────────────────────────────────────────────────────────────────────
main() {

# ── Header ────────────────────────────────────────────────────────────────────
log "========================================================"
log "  pi2s3 — restore from S3"
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
    diskutil unmountDisk "${TARGET_DEVICE}" 2>/dev/null \
        || die "diskutil unmountDisk ${TARGET_DEVICE} failed — device may be busy. Cannot restore to a mounted device."
else
    lsblk -no NAME "${TARGET_DEVICE}" 2>/dev/null | tail -n +2 | while read -r part; do
        umount "/dev/${part}" 2>/dev/null || true
    done
    # Verify no remaining mounts on the target before writing
    if mount | grep -q "^${TARGET_DEVICE}"; then
        die "${TARGET_DEVICE} is still mounted — cannot write to a mounted device"
    fi
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
        echo "       bash ~/pi2s3/pi-image-restore.sh"
        echo ""
        exit 1
    fi

    command -v sfdisk         &>/dev/null || die "sfdisk not found. Install: sudo apt install util-linux"
    { command -v partclone.ext4 &>/dev/null || [[ -x /usr/sbin/partclone.ext4 ]]; } \
        || die "partclone not found. Install: sudo apt install partclone"
    command -v python3     &>/dev/null || die "python3 not found (required for manifest parsing)"

    # 1. Restore partition table
    PTABLE_KEY=$(get_manifest_field "${MANIFEST}" "partition_table_key")
    [[ -z "${PTABLE_KEY}" ]] && die "No partition_table_key in manifest."

    log ""
    log "Restoring partition table to ${TARGET_DEVICE}..."
    local _ptable_out _ptable_rc=0
    _ptable_out=$(aws_cmd s3 cp "s3://${S3_BUCKET}/${PTABLE_KEY}" - 2>/dev/null \
        | sudo sfdisk --force --no-reread "${TARGET_DEVICE}" 2>&1) || _ptable_rc=$?
    echo "${_ptable_out}" | grep -v '^$' | sed 's/^/  /' || true
    if [[ ${_ptable_rc} -ne 0 ]]; then
        die "sfdisk failed (exit ${_ptable_rc}) — partition table NOT restored to ${TARGET_DEVICE}"
    fi

    # Wait for kernel to update partition table
    sudo partprobe "${TARGET_DEVICE}" 2>/dev/null \
        || sudo blockdev --rereadpt "${TARGET_DEVICE}" 2>/dev/null || true
    sleep 2
    log "  Partition table restored."

    # ── Detect and set up decryption ─────────────────────────────────────────────
    DECRYPT_CMD="cat"
    _ENCRYPT_METHOD=$(python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('encryption','none'))" \
        <<< "${MANIFEST}" 2>/dev/null || echo "none")

    if [[ "${_ENCRYPT_METHOD}" == "gpg-aes256" ]]; then
        log "Backup is encrypted (gpg AES-256). Passphrase required."
        command -v gpg &>/dev/null || die "gpg not found. Install: sudo apt install gpg"
        if [[ -z "${BACKUP_ENCRYPTION_PASSPHRASE}" ]]; then
            read -s -r -p "  Enter decryption passphrase: " BACKUP_ENCRYPTION_PASSPHRASE
            echo
        fi
        _GPG_PASS_FILE=$(mktemp)
        chmod 600 "${_GPG_PASS_FILE}"
        printf '%s' "${BACKUP_ENCRYPTION_PASSPHRASE}" > "${_GPG_PASS_FILE}"
        DECRYPT_CMD="gpg --batch --yes --passphrase-file ${_GPG_PASS_FILE} --decrypt"
        trap 'rm -f "${_GPG_PASS_FILE}"' EXIT
    fi

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

        # Map source partition name to target partition device by number.
        # p-separated naming: nvme0n1p2, mmcblk0p1, loop0p3, md0p1
        # Direct-suffix naming: sda1, sdb10, vda2, xvda1
        if [[ "${PART_NAME}" =~ p([0-9]+)$ ]]; then
            PART_NUM="${BASH_REMATCH[1]}"
        elif [[ "${PART_NAME}" =~ [a-z]([0-9]+)$ ]]; then
            PART_NUM="${BASH_REMATCH[1]}"
        else
            PART_NUM=""
        fi
        [[ -z "${PART_NUM}" ]] && { log "  Skipping ${PART_NAME} — cannot determine partition number"; continue; }

        # Devices that use p-prefix for partitions (nvme, mmcblk, loop, md, ...)
        if [[ "${TARGET_DEVICE}" =~ (nvme|mmcblk|loop|md) ]]; then
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
                | ${DECRYPT_CMD} \
                | gunzip \
                | sudo "${PART_TOOL}" -r -s - -o "${TARGET_PART}"
        else
            aws_cmd s3 cp "s3://${S3_BUCKET}/${PART_KEY}" - \
                | ${DECRYPT_CMD} \
                | gunzip \
                | sudo "${PART_TOOL}" -r -s - -o "${TARGET_PART}"
        fi

        log "  ${TARGET_PART} restored."
    done <<< "${PART_DATA}"

    # 3b. Resize last partition to fill device (--resize)
    if [[ "${RESIZE}" == "true" ]]; then
        local _last_name _last_fs
        IFS=$'\t' read -r _last_name _last_fs < <(echo "${MANIFEST}" | python3 -c "
import json, sys
m = json.load(sys.stdin)
parts = m.get('partitions', [])
if parts:
    p = parts[-1]
    print(p.get('name','') + '\t' + p.get('fstype',''))
" 2>/dev/null || true)

        if [[ -z "${_last_name}" ]]; then
            log "  --resize: could not determine last partition from manifest. Skipping."
        else
            local _last_num
            _last_num=$(echo "${_last_name}" | grep -o '[0-9]*$' || true)
            local _last_target
            if [[ "${TARGET_DEVICE}" =~ (nvme|mmcblk) ]]; then
                _last_target="${TARGET_DEVICE}p${_last_num}"
            else
                _last_target="${TARGET_DEVICE}${_last_num}"
            fi

            log ""
            log "Resizing ${_last_target} (${_last_fs}) to fill ${TARGET_DEVICE}..."

            # Step 1: Expand the partition entry to fill the device
            if command -v growpart &>/dev/null; then
                sudo growpart "${TARGET_DEVICE}" "${_last_num}" 2>&1 | sed 's/^/  /' || true
            else
                log "  growpart not found (sudo apt install cloud-utils). Skipping partition table expand."
                log "  Run manually: sudo growpart ${TARGET_DEVICE} ${_last_num}"
            fi

            sudo partprobe "${TARGET_DEVICE}" 2>/dev/null || true
            sleep 1

            # Step 2: Resize the filesystem
            case "${_last_fs}" in
                ext2|ext3|ext4)
                    log "  Checking filesystem before resize..."
                    local _fsck_rc=0
                    sudo e2fsck -f -y "${_last_target}" 2>&1 | sed 's/^/  /' || _fsck_rc=${PIPESTATUS[0]}
                    # e2fsck exit 0=clean, 1=corrected, 2=reboot needed, 4+=uncorrectable
                    if [[ ${_fsck_rc} -ge 4 ]]; then
                        log "  ERROR: e2fsck exited ${_fsck_rc} — filesystem has uncorrectable errors"
                        log "  Skipping resize. Run manually: sudo e2fsck -f ${_last_target}"
                        return 1
                    fi
                    log "  Expanding filesystem..."
                    sudo resize2fs "${_last_target}" 2>&1 | sed 's/^/  /' || true
                    log "  Filesystem expanded."
                    ;;
                xfs)
                    log "  XFS: filesystem will expand automatically on first mount."
                    log "  Or after boot: sudo xfs_growfs /"
                    ;;
                btrfs)
                    log "  btrfs: filesystem will need manual resize after mount:"
                    log "    sudo btrfs filesystem resize max ${_last_target}"
                    ;;
                *)
                    log "  Filesystem type '${_last_fs}' — resize not automated. Do it manually after boot."
                    ;;
            esac
        fi
    fi

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
                        | ${DECRYPT_CMD} \
                        | gunzip \
                        | sudo "${FW_TOOL}" -r -s - -o "${FW_TARGET}"
                else
                    aws_cmd s3 cp "s3://${S3_BUCKET}/${FW_KEY}" - \
                        | ${DECRYPT_CMD} \
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

# ── Post-restore hook ────────────────────────────────────────────────────────
if [[ -n "${POST_RESTORE_SCRIPT}" ]]; then
    if [[ ! -f "${POST_RESTORE_SCRIPT}" ]]; then
        log "WARNING: --post-restore script not found: ${POST_RESTORE_SCRIPT}"
        log "         Skipping post-restore hook."
    else
        # Find the root partition: last non-FAT partition in the manifest
        local _pr_name _pr_num _pr_target _pr_mount
        IFS=$'\t' read -r _pr_name < <(echo "${MANIFEST}" | python3 -c "
import json, sys
m = json.load(sys.stdin)
parts = [p for p in m.get('partitions', []) if p.get('fstype','') not in ('vfat','fat32','fat16','')]
if parts:
    print(parts[-1].get('name',''))
" 2>/dev/null || true)

        if [[ -z "${_pr_name:-}" ]]; then
            log "WARNING: --post-restore: could not identify root partition from manifest."
            log "         Skipping post-restore hook."
        else
            _pr_num=$(echo "${_pr_name}" | grep -o '[0-9]*$' || true)
            if [[ "${TARGET_DEVICE}" =~ (nvme|mmcblk) ]]; then
                _pr_target="${TARGET_DEVICE}p${_pr_num}"
            else
                _pr_target="${TARGET_DEVICE}${_pr_num}"
            fi

            sudo partprobe "${TARGET_DEVICE}" 2>/dev/null || true
            sleep 1

            _pr_mount=$(mktemp -d)
            log ""
            log "Post-restore: mounting ${_pr_target} at ${_pr_mount}..."
            if sudo mount -o rw "${_pr_target}" "${_pr_mount}" 2>&1 | sed 's/^/  /'; then
                export RESTORE_ROOT="${_pr_mount}"
                log "Post-restore: running ${POST_RESTORE_SCRIPT}..."
                echo ""
                local _pr_rc=0
                bash "${POST_RESTORE_SCRIPT}" "${_pr_mount}" || _pr_rc=$?
                echo ""
                if [[ ${_pr_rc} -eq 0 ]]; then
                    log "Post-restore: script completed successfully."
                else
                    log "WARNING: post-restore script exited with code ${_pr_rc}."
                    log "         Review the output above and re-run manually if needed."
                fi
                sudo umount "${_pr_mount}" 2>/dev/null || true
            else
                log "WARNING: could not mount ${_pr_target} — skipping post-restore hook."
                log "         Run manually: sudo mount ${_pr_target} /mnt && bash ${POST_RESTORE_SCRIPT} /mnt"
            fi
            rmdir "${_pr_mount}" 2>/dev/null || true
        fi
    fi
fi

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

} # end main

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
