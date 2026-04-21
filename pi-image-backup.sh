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
#
# TODO — planned features (priority order):
#   DONE(1-missed-backup-alert): --stale-check mode + cron via install.sh.
#     Ntfys if latest backup in S3 is older than STALE_BACKUP_HOURS (default 25h).
#
#   DONE(2-sha256): Per-partition SHA256 computed in-flight via tee >(sha256sum).
#
#   DONE(3-partial-restore): --extract flag on pi-image-restore.sh.
#     Streams partition from S3, loop-mounts it, copies requested path out.
#
#   DONE(4-per-host-namespacing): S3 keys now pi-image-backup/<hostname>/<date>/.
#     pi-image-restore.sh auto-discovers host or prompts when multiple exist.
#
#   DONE(5-bandwidth-throttle): AWS_TRANSFER_RATE_LIMIT in config.env caps upload speed.
#     Uses pv -q -L to throttle the compressed stream before aws s3 cp.
#     Gracefully falls back to cat if unset or pv not installed.
#
#   DONE(6-preflight-health): preflight_health() runs before Docker stop.
#     Checks: stopped/unhealthy containers, free disk space (<PREFLIGHT_MIN_FREE_MB),
#     recent I/O errors in dmesg. PREFLIGHT_ABORT_ON_WARN=true to abort on warnings.
#
#   DROPPED(7-incremental): Incremental backup adds restore complexity with little
#     cost benefit at 3-5 GB/day compressed. Full images restore in one command
#     with no history dependency. Keeping full images only.
#
#   DONE(8-cross-device-restore): --resize flag on pi-image-restore.sh.
#     growpart expands the last partition entry; resize2fs/xfs_growfs expands the
#     filesystem. Works for ext2/3/4 (online). XFS and btrfs: manual step noted.
#
#   DONE(9-per-host-retention): Per-hostname MAX_IMAGES_<hostname> in config.env.
#     Hyphens in hostname replaced with underscores (bash var name constraint).
#     e.g. MAX_IMAGES_my_pi_5=30 overrides the global MAX_IMAGES for that host.
#
#   DONE(10-auto-verify): BACKUP_AUTO_VERIFY=true runs a post-upload S3 check
#     after every backup. Verifies all partition files and manifest are non-zero
#     in S3. Result included in ntfy success notification.
#
#   DONE(11-client-side-encryption): BACKUP_ENCRYPTION_PASSPHRASE in config.env.
#     gpg --symmetric AES-256 encrypts each partition image before S3 upload.
#     Passphrase stored only in config.env, never in S3. Restore detects
#     encryption from manifest "encryption" field and decrypts inline.
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
STALE_BACKUP_HOURS="${STALE_BACKUP_HOURS:-25}"
PREFLIGHT_ENABLED="${PREFLIGHT_ENABLED:-true}"
PREFLIGHT_MIN_FREE_MB="${PREFLIGHT_MIN_FREE_MB:-500}"
PREFLIGHT_ABORT_ON_WARN="${PREFLIGHT_ABORT_ON_WARN:-false}"
AWS_TRANSFER_RATE_LIMIT="${AWS_TRANSFER_RATE_LIMIT:-}"
BACKUP_AUTO_VERIFY="${BACKUP_AUTO_VERIFY:-true}"
BACKUP_ENCRYPTION_PASSPHRASE="${BACKUP_ENCRYPTION_PASSPHRASE:-}"
PRE_BACKUP_CMD="${PRE_BACKUP_CMD:-}"
POST_BACKUP_CMD="${POST_BACKUP_CMD:-}"
DB_CONTAINER="${DB_CONTAINER:-auto}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
PROBE_URL="${PROBE_URL:-}"
PROBE_LATEST_POST="${PROBE_LATEST_POST:-true}"
PROBE_INTERVAL="${PROBE_INTERVAL:-60}"
BACKUP_EXTRA_DEVICE="${BACKUP_EXTRA_DEVICE:-}"
# ─────────────────────────────────────────────────────────────────────────────

DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOST_SHORT=$(hostname -s)
# Per-host retention override: MAX_IMAGES_<hostname> (hyphens → underscores)
_HOST_MAX_VAR="MAX_IMAGES_${HOST_SHORT//-/_}"
if [[ -n "${!_HOST_MAX_VAR:-}" ]]; then
    MAX_IMAGES="${!_HOST_MAX_VAR}"
fi
S3_PREFIX="pi-image-backup/${HOST_SHORT}"
MANIFEST_FILENAME="manifest-${TIMESTAMP}.json"
S3_DATE_PREFIX="${S3_PREFIX}/${DATE}"
MANIFEST_S3_KEY="${S3_DATE_PREFIX}/${MANIFEST_FILENAME}"

DRY_RUN=false
FORCE=false
SETUP=false
LIST=false
VERIFY=false
VERIFY_DATE=""
STALE_CHECK=false
COST=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)         DRY_RUN=true ;;
        --force)           FORCE=true ;;
        --setup)           SETUP=true ;;
        --list)            LIST=true ;;
        --verify)          VERIFY=true ;;
        --verify=*)        VERIFY=true; VERIFY_DATE="${arg#--verify=}" ;;
        --no-stop-docker)  STOP_DOCKER=false ;;
        --stale-check)     STALE_CHECK=true ;;
        --cost)            COST=true ;;
        --help)            echo "Usage: pi-image-backup.sh [options]
  (no args)          Run nightly backup
  --force            Skip duplicate-check (run even if today's backup exists)
  --dry-run          Show what would happen without uploading anything
  --setup            Create S3 lifecycle policy (run once after install)
  --list             List all backups in S3 with size and hostname
  --verify           Verify latest backup files exist and are non-zero in S3
  --verify=DATE      Verify a specific backup date (YYYY-MM-DD)
  --stale-check      Alert via ntfy if latest backup is older than STALE_BACKUP_HOURS
  --cost             Show S3 storage used and estimated monthly cost
  --no-stop-docker   Skip Docker stop (for daytime test runs, no downtime)
  --help             Show this help

Config: ${SCRIPT_DIR}/config.env
Log:    /var/log/pi2s3-backup.log"; exit 0 ;;
    esac
done

_BACKUP_SUCCEEDED=false
_CONTAINERS_STOPPED=false
_STOPPED_IDS=""
_PRE_BACKUP_RAN=false
_POST_BACKUP_RAN=false
_USE_DB_LOCK=false
_DB_LOCKED=false
_DB_CONTAINER=""
_DB_ROOT_PASSWORD=""
_DB_LOCK_PID=""
_DB_CONN_ID=""
_PROBE_PID=""
_PROBE_LOG=""
_PROBE_URL_USED=""
_PROBE_RESULTS=""
_START_TIME=$(date +%s)
_GPG_PASS_FILE=""
_BG_PIDS=()
_BG_RESULT_DIR=""

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

# ── MariaDB/MySQL consistent-snapshot lock ───────────────────────────────────
# Issues FLUSH TABLES WITH READ LOCK, keeping all containers/services running.
# Reads and cached pages are served normally during imaging; only writes block.
# The lock is held by a background connection using SELECT SLEEP(86400) as a
# keepalive. db_unlock() kills that connection by its ID, releasing the lock.
#
# Supports three modes (set via DB_CONTAINER in config.env):
#   "auto"          — scan running containers for any mariadb/mysql image
#   "my_container"  — explicit container name
#   ""              — no container; use native mariadb/mysql on localhost
# DB_ROOT_PASSWORD: leave blank to auto-read from the container's environment.
# If no DB is found/configured, falls back silently to STOP_DOCKER.
db_lock() {
    # ── Resolve container ────────────────────────────────────────────────────
    if [[ "${DB_CONTAINER}" == "auto" ]] \
       && command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        _DB_CONTAINER=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
            | grep -iE '\bmariadb\b|\bmysql\b' | awk '{print $1}' | head -1 || true)
        if [[ -z "${_DB_CONTAINER}" ]]; then
            log "  DB lock: no MariaDB/MySQL container found — using STOP_DOCKER fallback"
            return 0
        fi
    elif [[ -n "${DB_CONTAINER}" && "${DB_CONTAINER}" != "auto" ]]; then
        _DB_CONTAINER="${DB_CONTAINER}"
    fi
    # Both blank → no DB lock configured; caller falls back to STOP_DOCKER
    if [[ -z "${_DB_CONTAINER}" && -z "${DB_ROOT_PASSWORD}" ]]; then
        return 0
    fi

    # ── Resolve password ─────────────────────────────────────────────────────
    _DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
    if [[ -z "${_DB_ROOT_PASSWORD}" && -n "${_DB_CONTAINER}" ]]; then
        _DB_ROOT_PASSWORD=$(docker exec "${_DB_CONTAINER}" env 2>/dev/null \
            | grep -E "^MYSQL_ROOT_PASSWORD=|^MARIADB_ROOT_PASSWORD=" \
            | cut -d= -f2- | head -1 || true)
        if [[ -z "${_DB_ROOT_PASSWORD}" ]]; then
            log "  DB lock: could not read root password from container env — using STOP_DOCKER fallback"
            _DB_CONTAINER=""
            return 0
        fi
    fi

    local _target="${_DB_CONTAINER:-localhost}"
    log ""
    log "Locking DB for consistent snapshot (${_target})..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "  [DRY RUN] FLUSH TABLES WITH READ LOCK — skipped"
        _DB_LOCKED=true
        return 0
    fi

    # Run FTWRL in background. The SLEEP(86400) keepalive holds the connection
    # (and the global read lock) open until db_unlock() kills the connection ID.
    # A unique comment allows processlist lookup even if multiple sleep queries exist.
    if [[ -n "${_DB_CONTAINER}" ]]; then
        docker exec -i "${_DB_CONTAINER}" \
            mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent \
            -e "FLUSH TABLES WITH READ LOCK; FLUSH LOGS; SELECT /* pi2s3-lock */ SLEEP(86400);" \
            2>/dev/null &
    else
        { mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent \
              -e "FLUSH TABLES WITH READ LOCK; FLUSH LOGS; SELECT /* pi2s3-lock */ SLEEP(86400);" \
          || mysql -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent \
              -e "FLUSH TABLES WITH READ LOCK; FLUSH LOGS; SELECT /* pi2s3-lock */ SLEEP(86400);" ; } \
          2>/dev/null &
    fi
    _DB_LOCK_PID=$!

    sleep 3  # allow FTWRL to establish before imaging starts

    if ! kill -0 "${_DB_LOCK_PID}" 2>/dev/null; then
        log "  WARNING: DB lock process exited immediately — check DB_ROOT_PASSWORD / container name"
        log "  Falling back to STOP_DOCKER"
        _DB_CONTAINER=""; _DB_LOCK_PID=""; return 0
    fi

    # Find the connection ID so db_unlock() can KILL it cleanly via SQL
    local _q="SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%pi2s3-lock%' LIMIT 1;"
    if [[ -n "${_DB_CONTAINER}" ]]; then
        _DB_CONN_ID=$(docker exec "${_DB_CONTAINER}" \
            mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent -e "${_q}" \
            2>/dev/null | tail -1 || true)
    else
        _DB_CONN_ID=$(mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent -e "${_q}" \
            2>/dev/null | tail -1 || true)
    fi

    _DB_LOCKED=true
    log "  LOCKED — FLUSH TABLES WITH READ LOCK active (conn ${_DB_CONN_ID:-?})"
    log "  Site stays UP. Reads/cached pages served. Writes blocked during imaging."
}

db_kill_orphaned_locks() {
    # Kill any pi2s3-lock sleep connections left by a previous crashed backup.
    # Safe to call unconditionally -- just a no-op if nothing is orphaned.
    local _q="SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%pi2s3-lock%';"
    local _ids=""
    if [[ -n "${_DB_CONTAINER:-}" ]]; then
        _ids=$(docker exec "${_DB_CONTAINER}"             mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent -e "${_q}"             2>/dev/null | tr '\n' ' ' | xargs || true)
    elif [[ -n "${DB_ROOT_PASSWORD:-}" ]]; then
        _ids=$(mariadb -u root -p"${DB_ROOT_PASSWORD}" --batch --silent -e "${_q}"             2>/dev/null | tr '\n' ' ' | xargs || true)
    fi
    if [[ -n "${_ids// /}" ]]; then
        log "  WARNING: orphaned pi2s3 backup lock found (conn ${_ids}) — killing now"
        for _id in ${_ids}; do
            local _kq="KILL ${_id};"
            if [[ -n "${_DB_CONTAINER:-}" ]]; then
                docker exec "${_DB_CONTAINER}"                     mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent -e "${_kq}"                     2>/dev/null || true
            else
                mariadb -u root -p"${DB_ROOT_PASSWORD}" --batch --silent -e "${_kq}"                     2>/dev/null || true
            fi
        done
        log "  Orphaned lock cleared."
    fi
}

db_unlock() {
    [[ "${_DB_LOCKED}" != "true" ]] && return 0
    log ""
    log "Unlocking DB..."

    if [[ "${DRY_RUN}" != "true" && -n "${_DB_CONN_ID:-}" ]]; then
        # KILL the lock-holding connection by its ID — releases FTWRL server-side
        local _q="KILL ${_DB_CONN_ID};"
        if [[ -n "${_DB_CONTAINER}" ]]; then
            docker exec "${_DB_CONTAINER}" \
                mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent -e "${_q}" \
                2>/dev/null || true
        else
            mariadb -u root -p"${_DB_ROOT_PASSWORD}" --batch --silent -e "${_q}" \
                2>/dev/null || true
        fi
    fi
    # Kill the mariadb client inside the container directly — killing the host-side
    # docker exec wrapper (below) does not reliably terminate the process inside
    # the container, leaving an orphaned SLEEP(86400) connection.
    if [[ "${DRY_RUN}" != "true" && -n "${_DB_CONTAINER:-}" ]]; then
        docker exec "${_DB_CONTAINER}" pkill -9 -f "pi2s3-lock" 2>/dev/null || true
    fi
    # Kill the host-side docker exec wrapper and wait for it to exit.
    [[ -n "${_DB_LOCK_PID:-}" ]] && kill "${_DB_LOCK_PID}" 2>/dev/null || true
    wait "${_DB_LOCK_PID:-}" 2>/dev/null || true
    _DB_LOCK_PID=""; _DB_CONN_ID=""; _DB_LOCKED=false
    log "  DB unlocked — writes unblocked."
}

# ── Site availability probe ───────────────────────────────────────────────────
# Pings the site every PROBE_INTERVAL seconds during partition imaging.
# Cache-busted via query param + no-cache headers so every request hits PHP/DB.
# For WordPress: auto-discovers the latest post URL via REST API (PROBE_LATEST_POST=true).
# Results are logged and included in the ntfy success notification.
probe_start() {
    local url="${PROBE_URL:-}"

    # Auto-discover latest WordPress post URL via REST API (cache-busts CDN + WP cache)
    if [[ "${PROBE_LATEST_POST}" == "true" && -z "${url}" && -n "${CF_SITE_HOSTNAME:-}" ]]; then
        local _api="https://${CF_SITE_HOSTNAME}/wp-json/wp/v2/posts?per_page=1&_fields=link"
        local _latest
        _latest=$(curl -sf --max-time 8 "${_api}" 2>/dev/null \
            | python3 -c "import sys,json; posts=json.load(sys.stdin); print(posts[0]['link'])" \
            2>/dev/null || true)
        if [[ -n "${_latest}" ]]; then
            url="${_latest%/}"  # strip trailing slash for clean ?param appending
            log "  Probe URL (latest post): ${url}"
        fi
    fi

    [[ -z "${url}" && -n "${CF_SITE_HOSTNAME:-}" ]] && url="https://${CF_SITE_HOSTNAME}/"
    [[ -z "${url}" ]] && return 0

    _PROBE_URL_USED="${url}"
    _PROBE_LOG=$(mktemp)
    log ""
    log "Starting site probe: ${url} (every ${PROBE_INTERVAL}s)"
    log "  Cache-busted via ?pi2s3t=<timestamp> + no-cache headers"

    (
        while true; do
            local _t _code _elapsed
            _t=$(date +%s)
            read -r _code _elapsed < <(
                curl -s -o /dev/null -w "%{http_code} %{time_total}" \
                    -H "Cache-Control: no-cache, no-store, must-revalidate" \
                    -H "Pragma: no-cache" \
                    -H "X-pi2s3-probe: 1" \
                    --max-time 15 \
                    "${url}?pi2s3t=${_t}" 2>/dev/null || echo "ERR 0"
            )
            printf '[%s] HTTP %s (%ss)\n' "$(date '+%H:%M:%S')" "${_code}" "${_elapsed}" \
                >> "${_PROBE_LOG}"
            sleep "${PROBE_INTERVAL}"
        done
    ) &
    _PROBE_PID=$!
}

probe_stop() {
    [[ -z "${_PROBE_PID:-}" ]] && return 0
    kill "${_PROBE_PID}" 2>/dev/null || true
    wait "${_PROBE_PID}" 2>/dev/null || true
    _PROBE_PID=""
    [[ ! -f "${_PROBE_LOG:-}" ]] && return 0

    local _total _ok _fail
    _total=$(grep -c . "${_PROBE_LOG}" 2>/dev/null) || true
    _ok=$(grep -c " HTTP 200 " "${_PROBE_LOG}" 2>/dev/null) || true
    _fail=$(( ${_total:-0} - ${_ok:-0} ))

    log ""
    log "Site probe summary — ${_PROBE_URL_USED:-?} (${_total} check(s)):"
    while IFS= read -r _line; do log "  ${_line}"; done < "${_PROBE_LOG}"

    if [[ "${_fail}" -gt 0 ]]; then
        _PROBE_RESULTS="Site probe: ${_ok}/${_total} OK — ${_fail} non-200 during imaging"
        log "  WARNING: ${_fail} check(s) non-200 — site may have been partially unavailable"
    else
        _PROBE_RESULTS="Site probe: ${_total}/${_total} checks passed ✓"
        log "  All checks passed — site stayed up throughout imaging"
    fi
    rm -f "${_PROBE_LOG}"
}

# ── Stale backup check ────────────────────────────────────────────────────────
# Called via: bash pi-image-backup.sh --stale-check
# Ntfys if the latest backup in S3 is older than STALE_BACKUP_HOURS.
stale_check() {
    log "Checking for missed backup (host: ${HOST_SHORT}, threshold: ${STALE_BACKUP_HOURS}h)..."

    local latest
    latest=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
        | grep PRE | awk '{print $2}' | tr -d '/' | sort -r | head -1 || true)

    if [[ -z "${latest}" ]]; then
        log "No backups found in s3://${S3_BUCKET}/${S3_PREFIX}/"
        ntfy_send "pi2s3 backup MISSING" \
            "No backups found for ${HOST_SHORT} in s3://${S3_BUCKET}/${S3_PREFIX}/. Check AWS credentials and bucket." \
            "high" "warning,floppy_disk"
        exit 1
    fi

    local latest_ts now_ts age_h
    latest_ts=$(date -d "${latest}" +%s 2>/dev/null || echo "0")
    now_ts=$(date +%s)
    age_h=$(( (now_ts - latest_ts) / 3600 ))

    if [[ ${age_h} -gt ${STALE_BACKUP_HOURS} ]]; then
        log "OVERDUE: last backup ${latest} was ${age_h}h ago (threshold: ${STALE_BACKUP_HOURS}h)"
        ntfy_send "pi2s3 backup OVERDUE" \
            "No backup for ${HOST_SHORT} in ${age_h}h. Last: ${latest}. Expected every ${STALE_BACKUP_HOURS}h.
Check cron: crontab -l | grep pi2s3
Log: /var/log/pi2s3-backup.log" \
            "high" "warning,floppy_disk"
        exit 1
    fi

    log "OK: last backup ${latest} (${age_h}h ago, threshold ${STALE_BACKUP_HOURS}h)."
    exit 0
}

# ── Pre-backup health check ───────────────────────────────────────────────────
# Runs before stopping Docker. Warns (or aborts) if the stack looks degraded.
# Checks: stopped/unhealthy containers, free disk space, recent I/O errors.
# Set PREFLIGHT_ABORT_ON_WARN=true to abort backup on any warning.
preflight_health() {
    [[ "${PREFLIGHT_ENABLED}" != "true" ]] && return 0

    log ""
    log "Preflight health checks..."
    local _warn=false

    # Check 1: Docker container health (only if Docker is running)
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        local _unhealthy _exited
        _unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null || true)
        _exited=$(docker ps -a --filter status=exited --filter status=dead \
            --format '{{.Names}}' 2>/dev/null | grep -v '^$' || true)
        if [[ -n "${_unhealthy}" ]]; then
            log "  WARN: unhealthy containers: ${_unhealthy}"
            _warn=true
        fi
        if [[ -n "${_exited}" ]]; then
            log "  WARN: stopped/exited containers: ${_exited}"
            _warn=true
        fi
        [[ -z "${_unhealthy}" && -z "${_exited}" ]] && log "  Docker: all containers healthy."
    fi

    # Check 2: Free disk space on root filesystem
    local _free_mb
    _free_mb=$(df -m / 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
    if [[ ${_free_mb} -lt ${PREFLIGHT_MIN_FREE_MB} ]]; then
        log "  WARN: only ${_free_mb} MB free on / (minimum: ${PREFLIGHT_MIN_FREE_MB} MB)"
        _warn=true
    else
        log "  Free space: ${_free_mb} MB on / (OK)."
    fi

    # Check 3: Recent I/O errors in dmesg (last hour)
    local _io_errors
    _io_errors=$(dmesg --since "1 hour ago" 2>/dev/null \
        | grep -iE "I/O error|EXT4-fs error|blk_update_request: I/O|SCSI error" \
        | tail -3 || true)
    if [[ -n "${_io_errors}" ]]; then
        log "  WARN: recent I/O errors in dmesg:"
        while IFS= read -r _line; do log "    ${_line}"; done <<< "${_io_errors}"
        _warn=true
    else
        log "  I/O errors: none detected."
    fi

    if [[ "${_warn}" == "true" ]]; then
        log ""
        if [[ "${PREFLIGHT_ABORT_ON_WARN}" == "true" ]]; then
            ntfy_send "pi2s3 backup SKIPPED" \
                "Preflight health check failed on $(hostname -s). Backup aborted. Check log: /var/log/pi2s3-backup.log" \
                "high" "warning,floppy_disk"
            die "Preflight health warnings found and PREFLIGHT_ABORT_ON_WARN=true. Aborting."
        else
            log "  Health warnings found — proceeding (set PREFLIGHT_ABORT_ON_WARN=true to abort)."
        fi
    else
        log "  All health checks passed."
    fi
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

# image_to_s3 <device> <s3_key> <tool> <result_file>
# Runs: partclone | compress | [encrypt] | [throttle] | aws s3 cp
# On success: writes "sha256=<hash>\ncompressed=<bytes>" to <result_file>.
# Designed to run inline (sequential) or in a background subshell:
#   image_to_s3 ... &  _BG_PIDS+=("$!")
image_to_s3() {
    local _part="$1" _key="$2" _tool="$3" _result_file="$4"
    local _sha_tmp
    _sha_tmp=$(mktemp)
    # -F: allow cloning mounted partitions
    # shellcheck disable=SC2086
    sudo "${_tool}" -c -F -s "${_part}" -o - \
        | ${COMPRESSOR} \
        | tee >(sha256sum | awk '{print $1}' > "${_sha_tmp}") \
        | ${ENCRYPT_CMD} \
        | ${PV_THROTTLE} \
        | aws_cmd s3 cp - "s3://${S3_BUCKET}/${_key}" \
            --storage-class "${S3_STORAGE_CLASS}" \
            --no-progress
    local _sha _compressed _ch
    _sha=$(cat "${_sha_tmp}"); rm -f "${_sha_tmp}"
    _compressed=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${_key}" 2>/dev/null \
        | awk '{print $3}' | head -1 || echo "0")
    if [[ "${_compressed:-0}" -eq 0 ]]; then
        log "ERROR: ${_key} appears empty in S3 after upload"
        return 1
    fi
    _ch=$(numfmt --to=iec "${_compressed}" 2>/dev/null || echo "?")
    log "  Done: ${_ch} compressed → ${_key}"
    log "  SHA256: ${_sha}"
    printf 'sha256=%s\ncompressed=%s\n' "${_sha}" "${_compressed}" > "${_result_file}"
}

on_exit() {
    local rc=$?
    [[ -n "${_GPG_PASS_FILE}" ]] && rm -f "${_GPG_PASS_FILE}"
    # Kill any parallel imaging background jobs still running
    for _bg_pid in "${_BG_PIDS[@]:-}"; do
        kill "${_bg_pid}" 2>/dev/null || true
        wait "${_bg_pid}" 2>/dev/null || true
    done
    [[ -n "${_BG_RESULT_DIR}" ]] && rm -rf "${_BG_RESULT_DIR}"
    # Safety net: ensure DB is unlocked and probe is stopped on crash
    [[ "${_DB_LOCKED}" == "true" ]] && db_unlock
    [[ -n "${_PROBE_PID:-}" ]] && { kill "${_PROBE_PID}" 2>/dev/null || true; wait "${_PROBE_PID}" 2>/dev/null || true; rm -f "${_PROBE_LOG:-}"; _PROBE_PID=""; }
    # Safety net: if PRE_BACKUP_CMD ran but POST_BACKUP_CMD didn't (crash), run it now.
    if [[ "${_PRE_BACKUP_RAN}" == "true" && "${_POST_BACKUP_RAN}" == "false" \
          && -n "${POST_BACKUP_CMD}" ]]; then
        log "Running POST_BACKUP_CMD (crash recovery): ${POST_BACKUP_CMD}"
        if eval "${POST_BACKUP_CMD}" 2>&1; then
            log "  POST_BACKUP_CMD complete."
            _POST_BACKUP_RAN=true
        else
            log "  ERROR: POST_BACKUP_CMD failed during crash recovery!"
            ntfy_send "pi2s3 — POST_BACKUP_CMD failed" \
                "URGENT: backup crashed and POST_BACKUP_CMD failed on $(hostname).
Manual action required. Command was: ${POST_BACKUP_CMD}" \
                "urgent" "sos,floppy_disk"
        fi
    fi
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
        _LOG_TAIL=""
        if [[ -f "/var/log/pi2s3-backup.log" ]]; then
            _LOG_TAIL=$(tail -10 "/var/log/pi2s3-backup.log" 2>/dev/null || true)
        fi
        ntfy_send "pi2s3 backup FAILED" \
            "Backup on $(hostname) failed (exit ${rc}).
Bucket: s3://${S3_BUCKET}/
Log: /var/log/pi2s3-backup.log${_LOG_TAIL:+

Last 10 log lines:
${_LOG_TAIL}}" \
            "high" "warning,floppy_disk"
    fi
}
[[ "${STALE_CHECK}" == "true" ]] && stale_check

# ── Cost estimate ─────────────────────────────────────────────────────────────
cost_estimate() {
    log "========================================================"
    log "  pi2s3 — S3 storage & cost estimate"
    log "  Host:   ${HOST_SHORT}"
    log "  Bucket: s3://${S3_BUCKET}/${S3_PREFIX}/"
    log "========================================================"

    local _dates _total_bytes=0 _count=0
    _dates=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null \
        | grep PRE | awk '{print $2}' | tr -d '/' | sort || true)

    if [[ -z "${_dates}" ]]; then
        log "No backups found."
        exit 0
    fi

    while IFS= read -r _d; do
        [[ -z "${_d}" ]] && continue
        _sz=$(aws_cmd s3 ls --recursive "s3://${S3_BUCKET}/${S3_PREFIX}/${_d}/" 2>/dev/null \
            | awk '{sum+=$3} END{print sum+0}')
        _sz_h=$(numfmt --to=iec "${_sz}" 2>/dev/null || echo "${_sz} B")
        log "  ${_d}  ${_sz_h}"
        _total_bytes=$(( _total_bytes + _sz ))
        (( _count++ )) || true
    done <<< "${_dates}"

    local _total_gb _price_per_gb _monthly
    _total_gb=$(awk "BEGIN {printf \"%.2f\", ${_total_bytes}/1073741824}")

    case "${S3_STORAGE_CLASS}" in
        STANDARD)    _price_per_gb=0.023 ;;
        STANDARD_IA) _price_per_gb=0.0125 ;;
        ONEZONE_IA)  _price_per_gb=0.01 ;;
        GLACIER_IR)  _price_per_gb=0.004 ;;
        *)           _price_per_gb=0.023 ;;
    esac

    _monthly=$(awk "BEGIN {printf \"%.2f\", ${_total_gb} * ${_price_per_gb}}")

    log ""
    log "  Backups:       ${_count}"
    log "  Total stored:  $(numfmt --to=iec ${_total_bytes} 2>/dev/null || echo "${_total_bytes} B")"
    log "  Storage class: ${S3_STORAGE_CLASS} (\$${_price_per_gb}/GB/month, us-east-1 rate)"
    log "  Est. cost:     \$${_monthly}/month"
    log "  (Actual cost varies by region — af-south-1 is ~10% higher)"
    log "========================================================"
    exit 0
}
[[ "${COST}" == "true" ]] && cost_estimate

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
                \"Filter\": {\"Prefix\": \"pi-image-backup/\"},
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

    # Show SHA-256 checksums recorded at upload time
    log ""
    log "Checksums (SHA-256 of compressed upload, computed in-flight):"
    _HAS_CHECKSUMS=false
    while IFS= read -r sha; do
        [[ -z "${sha}" ]] && continue
        log "  ${sha}"
        _HAS_CHECKSUMS=true
    done < <(echo "${V_MANIFEST}" | grep -o '"sha256": *"[^"]*"' | cut -d'"' -f4 | grep -v '^$')
    if [[ "${_HAS_CHECKSUMS}" == "false" ]]; then
        log "  (none — backup predates checksum support; run a new backup)"
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

# Bandwidth throttle via pv (optional)
PV_THROTTLE="cat"
if [[ -n "${AWS_TRANSFER_RATE_LIMIT}" ]]; then
    if command -v pv &>/dev/null; then
        PV_THROTTLE="pv -q -L ${AWS_TRANSFER_RATE_LIMIT}"
        log "  Bandwidth limit: ${AWS_TRANSFER_RATE_LIMIT}/s (via pv)"
    else
        log "  WARN: AWS_TRANSFER_RATE_LIMIT set but pv not installed — throttling disabled."
        log "        Install with: sudo apt install pv"
    fi
fi

# Client-side encryption via gpg (optional)
ENCRYPT_CMD="cat"
ENCRYPT_SUFFIX=""
ENCRYPTION_METHOD="none"
if [[ -n "${BACKUP_ENCRYPTION_PASSPHRASE}" ]]; then
    command -v gpg &>/dev/null \
        || die "BACKUP_ENCRYPTION_PASSPHRASE is set but gpg is not installed. Run: sudo apt install gpg"
    _GPG_PASS_FILE=$(mktemp)
    chmod 600 "${_GPG_PASS_FILE}"
    printf '%s' "${BACKUP_ENCRYPTION_PASSPHRASE}" > "${_GPG_PASS_FILE}"
    ENCRYPT_CMD="gpg --batch --yes --passphrase-file ${_GPG_PASS_FILE} --symmetric --cipher-algo AES256 --compress-algo none -o -"
    ENCRYPT_SUFFIX=".gpg"
    ENCRYPTION_METHOD="gpg-aes256"
    log "  Encryption:   gpg AES-256 (client-side)"
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
[[ -n "${BACKUP_ENCRYPTION_PASSPHRASE}" ]] && log "  Encryption:   gpg AES-256"
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

# ── Pre-backup health check ───────────────────────────────────────────────────
preflight_health

# ── Consistent snapshot: DB lock (preferred) or Docker stop (fallback) ────────
# DB lock path: start probe + FLUSH TABLES WITH READ LOCK. All containers stay
# running. Site serves reads/cached pages throughout imaging (~5-15 min).
# Docker stop path: used only when no DB is configured (STOP_DOCKER=true).
if [[ -n "${DB_CONTAINER}" || -n "${DB_ROOT_PASSWORD}" ]]; then
    probe_start
    db_kill_orphaned_locks
    db_lock
    if [[ "${_DB_LOCKED}" == "true" ]]; then
        _USE_DB_LOCK=true
    else
        # db_lock fell back (no container found, bad credentials, etc.)
        probe_stop
    fi
fi

if [[ "${_USE_DB_LOCK}" != "true" && "${STOP_DOCKER}" == "true" ]] \
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

# ── PRE_BACKUP_CMD: stop non-Docker services (MySQL, nginx, etc.) ─────────────
if [[ -n "${PRE_BACKUP_CMD}" ]]; then
    log ""
    log "Running PRE_BACKUP_CMD: ${PRE_BACKUP_CMD}"
    if [[ "${DRY_RUN}" != "true" ]]; then
        if eval "${PRE_BACKUP_CMD}" 2>&1; then
            _PRE_BACKUP_RAN=true
            log "  PRE_BACKUP_CMD complete."
        else
            die "PRE_BACKUP_CMD failed — aborting backup to avoid inconsistent image."
        fi
    else
        log "  [DRY RUN] skipping PRE_BACKUP_CMD"
    fi
fi

# ── Flush filesystem ─────────────────────────────────────────────────────────
log ""
log "Syncing filesystem..."
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true

# ── Release DB lock immediately after flush ───────────────────────────────────────
# InnoDB dirty pages are now fully on disk. FTWRL was only needed for the
# flush itself (~seconds). Releasing here lets writes resume during the
# multi-minute partclone imaging window. InnoDB crash-recovery replays any
# redo log entries that land during imaging -- fuzzy snapshots are safe.
if [[ "${_USE_DB_LOCK}" == "true" ]]; then
    db_unlock
    log "  DB lock released -- site fully operational during imaging."
    _USE_DB_LOCK=false
fi

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
# Parallelism strategy:
#   • BACKUP_EXTRA_DEVICE partitions are launched in background at the very start,
#     running concurrently with ALL boot-device partition imaging (separate physical
#     bus — SD card / second NVMe / USB drive).
#   • The boot firmware partition (SD card /boot/firmware) is launched in parallel
#     with the LAST NVMe partition — two separate buses, same upload pipe.
#   • All other boot-device partitions run sequentially (same NVMe, upload-bound).
BACKUP_START=$(date +%s)
TOTAL_USED_BYTES=0
TOTAL_COMPRESSED_BYTES=0
PARTITIONS_JSON=""
EXTRA_PARTS_JSON=""
UPLOADED_KEYS=()
_BG_RESULT_DIR=$(mktemp -d)

# ── Helper: collect partition metadata into local vars ────────────────────────
# Sets: _PNAME _FSTYPE _TOOL _SIZE_B _SIZE_H _USED_B _USED_H _KEY
_part_meta() {
    local _p="$1" _key_prefix="$2"
    _PNAME=$(basename "${_p}")
    _FSTYPE=$(lsblk -no FSTYPE "${_p}" 2>/dev/null | tr -d '[:space:]' || echo "")
    _TOOL=$(partclone_tool "${_FSTYPE}")
    _SIZE_B=$(lsblk -bdno SIZE "${_p}" 2>/dev/null || echo "0")
    _SIZE_H=$(numfmt --to=iec "${_SIZE_B}" 2>/dev/null || echo "?")
    _USED_B=0; _USED_H="?"
    if df "${_p}" &>/dev/null 2>&1; then
        _USED_B=$(df -B1 --output=used "${_p}" 2>/dev/null | tail -1 | tr -d ' ' || echo "0")
        _USED_H=$(numfmt --to=iec "${_USED_B}" 2>/dev/null || echo "?")
    fi
    _KEY="${_key_prefix}/${_PNAME}-${TIMESTAMP}.img.gz${ENCRYPT_SUFFIX}"
}

# ── Phase 0: launch BACKUP_EXTRA_DEVICE in background (parallel with all below)
# Extra device runs on a completely separate bus (second NVMe / USB / SD).
EXTRA_PART_NAMES=()
EXTRA_PART_KEYS=()
EXTRA_PART_FSTYPES=()
EXTRA_PART_TOOLS=()
EXTRA_PART_SIZE_B=()
EXTRA_PART_SIZE_H=()
EXTRA_PART_USED_B=()
EXTRA_PART_USED_H=()
if [[ -n "${BACKUP_EXTRA_DEVICE}" ]]; then
    if [[ ! -b "${BACKUP_EXTRA_DEVICE}" ]]; then
        die "BACKUP_EXTRA_DEVICE=${BACKUP_EXTRA_DEVICE} is not a block device."
    fi
    mapfile -t _EXTRA_PARTS < <(
        lsblk -lno NAME,TYPE "${BACKUP_EXTRA_DEVICE}" \
        | awk '$2=="part"{print "/dev/"$1}' | sort
    )
    if [[ ${#_EXTRA_PARTS[@]} -eq 0 ]]; then
        log "  WARNING: BACKUP_EXTRA_DEVICE=${BACKUP_EXTRA_DEVICE} has no partitions — skipping."
    else
        log ""
        log "Launching extra device ${BACKUP_EXTRA_DEVICE} in background (parallel with boot device)..."
        for _EP in "${_EXTRA_PARTS[@]}"; do
            _part_meta "${_EP}" "${S3_DATE_PREFIX}"
            log "  [bg] ${_EP}  (${_FSTYPE:-unknown}, ${_SIZE_H} total, ${_USED_H} used)"
            log "  [bg] Tool: ${_TOOL} → ${_KEY}"
            EXTRA_PART_NAMES+=("${_PNAME}")
            EXTRA_PART_KEYS+=("${_KEY}")
            EXTRA_PART_FSTYPES+=("${_FSTYPE}")
            EXTRA_PART_TOOLS+=("${_TOOL}")
            EXTRA_PART_SIZE_B+=("${_SIZE_B}")
            EXTRA_PART_SIZE_H+=("${_SIZE_H}")
            EXTRA_PART_USED_B+=("${_USED_B}")
            EXTRA_PART_USED_H+=("${_USED_H}")
            if [[ "${DRY_RUN}" == "true" ]]; then
                log "  [DRY RUN] ${_TOOL} -c -s ${_EP} | ${COMPRESSOR_NAME}${ENCRYPT_SUFFIX:+ | gpg} | aws s3 cp -"
                printf 'sha256=\ncompressed=0\n' > "${_BG_RESULT_DIR}/extra_${_PNAME}"
            else
                image_to_s3 "${_EP}" "${_KEY}" "${_TOOL}" \
                    "${_BG_RESULT_DIR}/extra_${_PNAME}" &
                _BG_PIDS+=("$!")
            fi
        done
    fi
fi

# ── Phase 1: boot-device partitions (sequential except the last) ──────────────
log ""
log "Imaging ${#BOOT_PARTITIONS[@]} partition(s) on ${BOOT_DEV}..."

LAST_IDX=$(( ${#BOOT_PARTITIONS[@]} - 1 ))

for (( _i=0; _i<LAST_IDX; _i++ )); do
    PART="${BOOT_PARTITIONS[$_i]}"
    _part_meta "${PART}" "${S3_DATE_PREFIX}"
    TOTAL_USED_BYTES=$(( TOTAL_USED_BYTES + _USED_B ))

    log ""
    log "  ${PART}  (${_FSTYPE:-unknown}, ${_SIZE_H} total, ${_USED_H} used)"
    log "  Tool: ${_TOOL}"

    _RFILE="${_BG_RESULT_DIR}/boot_${_PNAME}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "  [DRY RUN] ${_TOOL} -c -s ${PART} | ${COMPRESSOR_NAME}${ENCRYPT_SUFFIX:+ | gpg} | aws s3 cp - s3://${S3_BUCKET}/${_KEY}"
        printf 'sha256=\ncompressed=0\n' > "${_RFILE}"
    else
        image_to_s3 "${PART}" "${_KEY}" "${_TOOL}" "${_RFILE}"
    fi

    PART_SHA256=$(grep '^sha256=' "${_RFILE}" | cut -d= -f2-)
    PART_COMPRESSED_BYTES=$(grep '^compressed=' "${_RFILE}" | cut -d= -f2-)
    UPLOADED_KEYS+=("${_KEY}")
    TOTAL_COMPRESSED_BYTES=$(( TOTAL_COMPRESSED_BYTES + PART_COMPRESSED_BYTES ))
    PARTITIONS_JSON+="    {\"name\":\"${_PNAME}\",\"device\":\"${PART}\",\"fstype\":\"${_FSTYPE}\",\"tool\":\"${_TOOL}\",\"size_bytes\":${_SIZE_B},\"size_human\":\"${_SIZE_H}\",\"used_bytes\":${_USED_B},\"used_human\":\"${_USED_H}\",\"compressed_bytes\":${PART_COMPRESSED_BYTES:-0},\"sha256\":\"${PART_SHA256:-}\",\"key\":\"${_KEY}\"},"$'\n'
done

# ── Phase 2: last boot partition + boot firmware in parallel ──────────────────
# The boot firmware lives on a separate physical device (SD card), so both reads
# use independent buses. Launch both, then wait.
LAST_PART="${BOOT_PARTITIONS[$LAST_IDX]}"
_part_meta "${LAST_PART}" "${S3_DATE_PREFIX}"
LAST_PNAME="${_PNAME}"; LAST_FSTYPE="${_FSTYPE}"; LAST_TOOL="${_TOOL}"
LAST_KEY="${_KEY}"; LAST_SIZE_B="${_SIZE_B}"; LAST_SIZE_H="${_SIZE_H}"
LAST_USED_B="${_USED_B}"; LAST_USED_H="${_USED_H}"
TOTAL_USED_BYTES=$(( TOTAL_USED_BYTES + LAST_USED_B ))

FW_NAME=""; FW_KEY=""; FW_FSTYPE=""; FW_SIZE_HUMAN="${FW_SIZE_HUMAN:-?}"
if [[ -n "${BOOT_FW_PART}" ]]; then
    FW_NAME=$(basename "${BOOT_FW_PART}")
    FW_KEY="${S3_DATE_PREFIX}/${FW_NAME}-boot-fw-${TIMESTAMP}.img.gz${ENCRYPT_SUFFIX}"
    FW_FSTYPE=$(lsblk -no FSTYPE "${BOOT_FW_PART}" 2>/dev/null | tr -d '[:space:]' || echo "vfat")
fi

log ""
log "  ${LAST_PART}  (${LAST_FSTYPE:-unknown}, ${LAST_SIZE_H} total, ${LAST_USED_H} used)"
log "  Tool: ${LAST_TOOL}"

_LAST_RFILE="${_BG_RESULT_DIR}/boot_${LAST_PNAME}"
if [[ "${DRY_RUN}" == "true" ]]; then
    log "  [DRY RUN] ${LAST_TOOL} -c -s ${LAST_PART} | ${COMPRESSOR_NAME}${ENCRYPT_SUFFIX:+ | gpg} | aws s3 cp -"
    printf 'sha256=\ncompressed=0\n' > "${_LAST_RFILE}"
else
    if [[ -n "${BOOT_FW_PART}" ]]; then
        log ""
        log "  Launching last boot partition + boot firmware in parallel..."
        log "  (separate physical buses — NVMe + SD card)"
        image_to_s3 "${LAST_PART}" "${LAST_KEY}" "${LAST_TOOL}" "${_LAST_RFILE}" &
        _BG_PIDS+=("$!")
    else
        image_to_s3 "${LAST_PART}" "${LAST_KEY}" "${LAST_TOOL}" "${_LAST_RFILE}"
    fi
fi

# ── Boot firmware (parallel with last boot partition, or sequential if no FW) ─
BOOT_FW_JSON=""
_FW_RFILE="${_BG_RESULT_DIR}/boot_fw"
if [[ -n "${BOOT_FW_PART}" ]]; then
    log ""
    log "  ${BOOT_FW_PART}  (boot firmware, ${FW_SIZE_HUMAN})"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "  [DRY RUN] partclone.vfat -c -s ${BOOT_FW_PART} | ${COMPRESSOR_NAME} | aws s3 cp -"
        printf 'sha256=\ncompressed=0\n' > "${_FW_RFILE}"
    else
        # Already launched last boot partition above; launch fw now (parallel)
        image_to_s3 "${BOOT_FW_PART}" "${FW_KEY}" "partclone.vfat" "${_FW_RFILE}" &
        _BG_PIDS+=("$!")
    fi
fi

# ── Wait for all background jobs (last partition, boot fw, extra device) ───────
if [[ ${#_BG_PIDS[@]} -gt 0 ]]; then
    log ""
    log "Waiting for ${#_BG_PIDS[@]} parallel imaging job(s)..."
    for _pid in "${_BG_PIDS[@]}"; do
        wait "${_pid}" || die "A parallel imaging job failed (pid ${_pid}). See log above."
    done
    _BG_PIDS=()
    log "  All parallel jobs complete."
fi

# ── Collect results for last boot partition ───────────────────────────────────
PART_SHA256=$(grep '^sha256=' "${_LAST_RFILE}" | cut -d= -f2-)
PART_COMPRESSED_BYTES=$(grep '^compressed=' "${_LAST_RFILE}" | cut -d= -f2-)
UPLOADED_KEYS+=("${LAST_KEY}")
TOTAL_COMPRESSED_BYTES=$(( TOTAL_COMPRESSED_BYTES + PART_COMPRESSED_BYTES ))
PARTITIONS_JSON+="    {\"name\":\"${LAST_PNAME}\",\"device\":\"${LAST_PART}\",\"fstype\":\"${LAST_FSTYPE}\",\"tool\":\"${LAST_TOOL}\",\"size_bytes\":${LAST_SIZE_B},\"size_human\":\"${LAST_SIZE_H}\",\"used_bytes\":${LAST_USED_B},\"used_human\":\"${LAST_USED_H}\",\"compressed_bytes\":${PART_COMPRESSED_BYTES:-0},\"sha256\":\"${PART_SHA256:-}\",\"key\":\"${LAST_KEY}\"},"$'\n'

# ── Collect results for boot firmware ────────────────────────────────────────
if [[ -n "${BOOT_FW_PART}" ]]; then
    FW_SHA256=$(grep '^sha256=' "${_FW_RFILE}" | cut -d= -f2-)
    FW_COMPRESSED=$(grep '^compressed=' "${_FW_RFILE}" | cut -d= -f2-)
    FW_COMPRESSED_HUMAN=$(numfmt --to=iec "${FW_COMPRESSED}" 2>/dev/null || echo "?")
    TOTAL_COMPRESSED_BYTES=$(( TOTAL_COMPRESSED_BYTES + FW_COMPRESSED ))
    UPLOADED_KEYS+=("${FW_KEY}")
    BOOT_FW_JSON="{\"name\":\"${FW_NAME}\",\"device\":\"${BOOT_FW_PART}\",\"fstype\":\"${FW_FSTYPE}\",\"key\":\"${FW_KEY}\",\"compressed_bytes\":${FW_COMPRESSED},\"sha256\":\"${FW_SHA256:-}\"}"
fi

# ── Collect results for extra device partitions ───────────────────────────────
if [[ ${#EXTRA_PART_NAMES[@]} -gt 0 ]]; then
    log ""
    log "Collecting extra device results..."
    for (( _ei=0; _ei<${#EXTRA_PART_NAMES[@]}; _ei++ )); do
        _EPNAME="${EXTRA_PART_NAMES[$_ei]}"
        _EKEY="${EXTRA_PART_KEYS[$_ei]}"
        _ERFILE="${_BG_RESULT_DIR}/extra_${_EPNAME}"
        EP_SHA256=$(grep '^sha256=' "${_ERFILE}" | cut -d= -f2-)
        EP_COMPRESSED=$(grep '^compressed=' "${_ERFILE}" | cut -d= -f2-)
        EP_COMPRESSED_H=$(numfmt --to=iec "${EP_COMPRESSED}" 2>/dev/null || echo "?")
        TOTAL_COMPRESSED_BYTES=$(( TOTAL_COMPRESSED_BYTES + EP_COMPRESSED ))
        TOTAL_USED_BYTES=$(( TOTAL_USED_BYTES + EXTRA_PART_USED_B[$_ei] ))
        UPLOADED_KEYS+=("${_EKEY}")
        EXTRA_PARTS_JSON+="    {\"name\":\"${_EPNAME}\",\"device\":\"${BACKUP_EXTRA_DEVICE}\",\"fstype\":\"${EXTRA_PART_FSTYPES[$_ei]}\",\"tool\":\"${EXTRA_PART_TOOLS[$_ei]}\",\"size_bytes\":${EXTRA_PART_SIZE_B[$_ei]},\"size_human\":\"${EXTRA_PART_SIZE_H[$_ei]}\",\"used_bytes\":${EXTRA_PART_USED_B[$_ei]},\"used_human\":\"${EXTRA_PART_USED_H[$_ei]}\",\"compressed_bytes\":${EP_COMPRESSED:-0},\"sha256\":\"${EP_SHA256:-}\",\"key\":\"${_EKEY}\"},"$'\n'
        log "  ${_EPNAME}: ${EP_COMPRESSED_H} compressed  SHA256: ${EP_SHA256}"
    done
fi

rm -rf "${_BG_RESULT_DIR}"; _BG_RESULT_DIR=""

BACKUP_END=$(date +%s)
BACKUP_DURATION=$(( BACKUP_END - BACKUP_START ))

# ── Collect probe results ──────────────────────────────────────────────────
# DB already unlocked after flush -- just stop the probe.
probe_stop

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

# ── POST_BACKUP_CMD: restart non-Docker services ──────────────────────────────
if [[ "${_PRE_BACKUP_RAN}" == "true" && -n "${POST_BACKUP_CMD}" ]]; then
    log ""
    log "Running POST_BACKUP_CMD: ${POST_BACKUP_CMD}"
    if [[ "${DRY_RUN}" != "true" ]]; then
        if eval "${POST_BACKUP_CMD}" 2>&1; then
            _POST_BACKUP_RAN=true
            log "  POST_BACKUP_CMD complete."
        else
            log "  ERROR: POST_BACKUP_CMD failed — services may still be stopped!"
            ntfy_send "pi2s3 — POST_BACKUP_CMD failed" \
                "URGENT: POST_BACKUP_CMD failed on $(hostname).
Manual action required. Command was: ${POST_BACKUP_CMD}" \
                "urgent" "sos,floppy_disk"
        fi
    else
        log "  [DRY RUN] skipping POST_BACKUP_CMD"
        _POST_BACKUP_RAN=true
    fi
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

# Trim trailing comma+newline from last partition entries
PARTITIONS_JSON_CLEAN="${PARTITIONS_JSON%,$'\n'}"
EXTRA_PARTS_JSON_CLEAN="${EXTRA_PARTS_JSON%,$'\n'}"

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
  "extra_device": ${BACKUP_EXTRA_DEVICE:+"\"${BACKUP_EXTRA_DEVICE}\""},
  "extra_device_partitions": [
${EXTRA_PARTS_JSON_CLEAN:-}
  ],
  "s3_bucket": "${S3_BUCKET}",
  "manifest_key": "${MANIFEST_S3_KEY}",
  "compressor": "${COMPRESSOR_NAME}",
  "storage_class": "${S3_STORAGE_CLASS}",
  "encryption": "${ENCRYPTION_METHOD}"
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

# ── Auto-verify ───────────────────────────────────────────────────────────────
_VERIFY_STATUS="skipped"
if [[ "${BACKUP_AUTO_VERIFY}" == "true" && "${DRY_RUN}" != "true" ]]; then
    log ""
    log "Auto-verifying uploaded files in S3..."
    _verify_ok=true
    for _vkey in "${UPLOADED_KEYS[@]}"; do
        _vsz=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${_vkey}" 2>/dev/null \
            | awk '{print $3}' | head -1 || echo "0")
        if [[ "${_vsz:-0}" -gt 0 ]]; then
            log "  OK  $(basename "${_vkey}")"
        else
            log "  FAIL  $(basename "${_vkey}") — missing or empty in S3"
            _verify_ok=false
        fi
    done
    # Check manifest
    _msz=$(aws_cmd s3 ls "s3://${S3_BUCKET}/${MANIFEST_S3_KEY}" 2>/dev/null \
        | awk '{print $3}' | head -1 || echo "0")
    if [[ "${_msz:-0}" -gt 0 ]]; then
        log "  OK  $(basename "${MANIFEST_S3_KEY}")"
    else
        log "  FAIL  manifest — missing or empty"
        _verify_ok=false
    fi
    if [[ "${_verify_ok}" == "true" ]]; then
        log "  All files verified in S3."
        _VERIFY_STATUS="passed"
    else
        log "  VERIFY FAILED — one or more files missing from S3!"
        _VERIFY_STATUS="failed"
        ntfy_send "pi2s3 backup — VERIFY FAILED" \
            "Backup on $(hostname) uploaded but S3 verify FAILED for ${DATE}.
Check: bash pi-image-backup.sh --verify=${DATE}
Log: /var/log/pi2s3-backup.log" \
            "high" "warning,floppy_disk"
    fi
fi

if [[ "${NTFY_LEVEL}" != "failure" && "${DRY_RUN}" != "true" ]]; then
    _VERIFY_LINE=""
    [[ "${_VERIFY_STATUS}" == "passed" ]] && _VERIFY_LINE=$'\nVerify: all files confirmed in S3'
    [[ "${_VERIFY_STATUS}" == "failed" ]] && _VERIFY_LINE=$'\nVerify: FAILED — check log'
    _PROBE_LINE=""
    [[ -n "${_PROBE_RESULTS}" ]] && _PROBE_LINE=$'\n'"${_PROBE_RESULTS}"
    _NTFY_MSG="$(hostname) — ${DATE}
Bucket: s3://${S3_BUCKET}/${S3_DATE_PREFIX}/
Size:  ${TOTAL_COMPRESSED_HUMAN} compressed (from ${TOTAL_USED_HUMAN} used)
Time:  ${TOTAL_ELAPSED}s${_VERIFY_LINE}${_PROBE_LINE}"
    ntfy_send "pi2s3 backup complete" "${_NTFY_MSG}" "low" "white_check_mark,floppy_disk"
fi
