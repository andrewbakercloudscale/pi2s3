#!/usr/bin/env bash
# =============================================================
# extras/fleet-deploy.sh — Deploy pi2s3 backups to a fleet of Pis
#
# Reads a CSV manifest of Pis, SSHes into each one (assumed to be in
# recovery mode — netboot or recovery USB), copies config.env and any
# per-Pi post-restore script, then runs pi-image-restore.sh.
#
# Usage:
#   bash extras/fleet-deploy.sh fleet.csv
#   bash extras/fleet-deploy.sh fleet.csv --parallel      # all Pis at once
#   bash extras/fleet-deploy.sh fleet.csv --dry-run       # show plan only
#   bash extras/fleet-deploy.sh fleet.csv --only pi-01    # single Pi by name
#   bash extras/fleet-deploy.sh fleet.csv --config ~/pi2s3/config.env
#
# Manifest format (CSV, lines starting with # are comments):
#   name,host,date,device,post_restore_script
#   pi-01,192.168.1.101,latest,/dev/nvme0n1,./post-restore/classroom.sh
#   pi-02,pi-02.local,latest,/dev/nvme0n1,./post-restore/classroom.sh
#   pi-office,192.168.1.50,2026-04-20,/dev/nvme0n1,./post-restore/office.sh
#
# Fields:
#   name              - friendly name (used in logs)
#   host              - IP address or hostname
#   date              - backup date (YYYY-MM-DD) or "latest"
#   device            - target block device on the remote Pi (e.g. /dev/nvme0n1)
#   post_restore_script - (optional) local path to post-restore script for this Pi
#
# SSH requirements:
#   Key-based auth strongly recommended. The remote Pi should be running
#   the pi2s3 recovery USB image or the netboot environment.
#   Default user: pi — override with --ssh-user
#   Default SSH key: ~/.ssh/id_rsa — override with --ssh-key
#
# Prerequisites on each remote Pi (all present on recovery USB / netboot image):
#   - pi2s3 repo at ~/pi2s3
#   - AWS CLI v2
#   - partclone, pigz, pv
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
LOG_DIR="${PWD}/fleet-deploy-logs-$(date +%Y%m%d_%H%M%S)"

MANIFEST_FILE=""
CONFIG_FILE="${REPO_DIR}/config.env"
SSH_USER="pi"
SSH_KEY=""
PARALLEL=false
DRY_RUN=false
ONLY_NAME=""
RESIZE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parallel)       PARALLEL=true ;;
        --dry-run)        DRY_RUN=true ;;
        --only)           shift; ONLY_NAME="${1:?--only requires a name}" ;;
        --only=*)         ONLY_NAME="${1#--only=}" ;;
        --config)         shift; CONFIG_FILE="${1:?--config requires a path}" ;;
        --config=*)       CONFIG_FILE="${1#--config=}" ;;
        --ssh-user)       shift; SSH_USER="${1:?--ssh-user requires a value}" ;;
        --ssh-user=*)     SSH_USER="${1#--ssh-user=}" ;;
        --ssh-key)        shift; SSH_KEY="${1:?--ssh-key requires a path}" ;;
        --ssh-key=*)      SSH_KEY="${1#--ssh-key=}" ;;
        --no-resize)      RESIZE=false ;;
        --help)
            echo "Usage: $0 <manifest.csv> [options]"
            echo ""
            echo "  --parallel         Deploy to all Pis simultaneously"
            echo "  --dry-run          Show plan without deploying"
            echo "  --only <name>      Deploy to a single Pi by name"
            echo "  --config <path>    Path to config.env (default: ~/pi2s3/config.env)"
            echo "  --ssh-user <user>  SSH user on recovery Pis (default: pi)"
            echo "  --ssh-key <path>   SSH identity file (default: SSH agent)"
            echo "  --no-resize        Skip --resize flag on restore"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -z "${MANIFEST_FILE}" ]]; then MANIFEST_FILE="$1"; else echo "Unexpected argument: $1" >&2; exit 1; fi
            ;;
    esac
    shift
done

[[ -z "${MANIFEST_FILE}" ]] && { echo "Usage: $0 <manifest.csv> [options]"; exit 1; }
[[ -f "${MANIFEST_FILE}" ]] || { echo "ERROR: manifest file not found: ${MANIFEST_FILE}" >&2; exit 1; }
[[ -f "${CONFIG_FILE}"   ]] || { echo "ERROR: config.env not found: ${CONFIG_FILE}" >&2; echo "  Use --config to specify its location." >&2; exit 1; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
[[ -n "${SSH_KEY}" ]] && SSH_OPTS+=(-i "${SSH_KEY}")

# ── Parse manifest ─────────────────────────────────────────────────────────────
declare -a PI_NAMES PI_HOSTS PI_DATES PI_DEVICES PI_SCRIPTS
ROW=0

while IFS= read -r line || [[ -n "${line}" ]]; do
    # Skip comments and blank lines
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    IFS=',' read -r _name _host _date _device _script <<< "${line}"
    _name="${_name// /}"; _host="${_host// /}"; _date="${_date// /}"
    _device="${_device// /}"; _script="${_script// /}"

    [[ -z "${_name}" || -z "${_host}" || -z "${_date}" || -z "${_device}" ]] && {
        echo "WARNING: skipping malformed line: ${line}"; continue
    }
    [[ -n "${ONLY_NAME}" && "${_name}" != "${ONLY_NAME}" ]] && continue

    PI_NAMES+=("${_name}")
    PI_HOSTS+=("${_host}")
    PI_DATES+=("${_date}")
    PI_DEVICES+=("${_device}")
    PI_SCRIPTS+=("${_script}")
    (( ROW++ )) || true
done < "${MANIFEST_FILE}"

[[ ${ROW} -eq 0 ]] && { echo "ERROR: no matching entries in manifest." >&2; exit 1; }

# ── Print plan ─────────────────────────────────────────────────────────────────
echo ""
echo "  pi2s3 fleet deploy"
echo "  ────────────────────────────────────────────────────────"
echo "  Manifest:   ${MANIFEST_FILE} (${ROW} Pi$([ "${ROW}" -gt 1 ] && echo 's' || true))"
echo "  Config:     ${CONFIG_FILE}"
echo "  SSH user:   ${SSH_USER}"
echo "  Mode:       $(${PARALLEL} && echo 'parallel' || echo 'sequential')"
[[ "${DRY_RUN}" == "true" ]] && echo "  DRY RUN — no changes will be made"
echo ""
printf "  %-18s %-20s %-12s %-16s %s\n" "NAME" "HOST" "DATE" "DEVICE" "POST-RESTORE"
printf "  %-18s %-20s %-12s %-16s %s\n" "──────────────────" "────────────────────" "────────────" "────────────────" "────────────"
for i in "${!PI_NAMES[@]}"; do
    printf "  %-18s %-20s %-12s %-16s %s\n" \
        "${PI_NAMES[$i]}" "${PI_HOSTS[$i]}" "${PI_DATES[$i]}" "${PI_DEVICES[$i]}" \
        "$(basename "${PI_SCRIPTS[$i]:-none}")"
done
echo ""

[[ "${DRY_RUN}" == "true" ]] && { echo "  Dry run complete."; exit 0; }

read -r -p "  Deploy to ${ROW} Pi$([ "${ROW}" -gt 1 ] && echo 's' || true)? [y/N] " answer
[[ "${answer,,}" == "y" ]] || { echo "  Aborted."; exit 0; }
echo ""
mkdir -p "${LOG_DIR}"

# ── Deploy one Pi ──────────────────────────────────────────────────────────────
deploy_pi() {
    local name="$1" host="$2" date="$3" device="$4" post_script="$5"
    local log_file="${LOG_DIR}/${name}.log"
    local remote="${SSH_USER}@${host}"

    echo "[${name}] Starting deploy → ${host}" | tee -a "${log_file}"

    # 1. Check SSH connectivity
    if ! ssh "${SSH_OPTS[@]}" "${remote}" "echo ok" &>/dev/null; then
        echo "[${name}] ERROR: SSH connection failed to ${host}" | tee -a "${log_file}"
        return 1
    fi

    # 2. Ensure pi2s3 is present (recovery USB / netboot image has it pre-installed)
    ssh "${SSH_OPTS[@]}" "${remote}" "
        if [[ ! -d ~/pi2s3 ]]; then
            git clone --depth 1 https://github.com/andrewbakercloudscale/pi2s3.git ~/pi2s3
        else
            git -C ~/pi2s3 pull --ff-only 2>/dev/null || true
        fi
    " >> "${log_file}" 2>&1

    # 3. Copy config.env
    scp "${SSH_OPTS[@]}" "${CONFIG_FILE}" "${remote}:~/pi2s3/config.env" >> "${log_file}" 2>&1
    echo "[${name}] config.env copied" | tee -a "${log_file}"

    # 4. Copy post-restore script (if specified)
    local remote_post_script=""
    if [[ -n "${post_script}" ]]; then
        if [[ ! -f "${post_script}" ]]; then
            echo "[${name}] WARNING: post-restore script not found: ${post_script}" | tee -a "${log_file}"
        else
            scp "${SSH_OPTS[@]}" "${post_script}" "${remote}:/tmp/post-restore-${name}.sh" >> "${log_file}" 2>&1
            remote_post_script="/tmp/post-restore-${name}.sh"
            echo "[${name}] Post-restore script copied" | tee -a "${log_file}"
        fi
    fi

    # 5. Run restore
    local restore_cmd="bash ~/pi2s3/pi-image-restore.sh --date ${date} --device ${device} --yes"
    ${RESIZE} && restore_cmd+=" --resize"
    [[ -n "${remote_post_script}" ]] && restore_cmd+=" --post-restore ${remote_post_script}"

    echo "[${name}] Running: ${restore_cmd}" | tee -a "${log_file}"
    echo "" >> "${log_file}"

    local rc=0
    ssh "${SSH_OPTS[@]}" "${remote}" "${restore_cmd}" 2>&1 | tee -a "${log_file}" || rc=$?

    echo "" | tee -a "${log_file}"
    if [[ ${rc} -eq 0 ]]; then
        echo "[${name}] SUCCESS — restore complete. Log: ${log_file}" | tee -a "${log_file}"
    else
        echo "[${name}] FAILED (exit ${rc}) — see ${log_file}" | tee -a "${log_file}"
    fi
    return ${rc}
}

# ── Run deploys ────────────────────────────────────────────────────────────────
declare -a PIDS=()
declare -a RESULTS=()

for i in "${!PI_NAMES[@]}"; do
    if ${PARALLEL}; then
        deploy_pi "${PI_NAMES[$i]}" "${PI_HOSTS[$i]}" "${PI_DATES[$i]}" \
            "${PI_DEVICES[$i]}" "${PI_SCRIPTS[$i]:-}" &
        PIDS+=($!)
    else
        rc=0
        deploy_pi "${PI_NAMES[$i]}" "${PI_HOSTS[$i]}" "${PI_DATES[$i]}" \
            "${PI_DEVICES[$i]}" "${PI_SCRIPTS[$i]:-}" || rc=$?
        RESULTS+=("${PI_NAMES[$i]}:${rc}")
        echo ""
    fi
done

# Wait for parallel jobs
if ${PARALLEL}; then
    for i in "${!PIDS[@]}"; do
        rc=0
        wait "${PIDS[$i]}" || rc=$?
        RESULTS+=("${PI_NAMES[$i]}:${rc}")
    done
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "  ────────────────────────────────────────────────────────"
echo "  Fleet deploy summary"
echo "  ────────────────────────────────────────────────────────"
PASS=0; FAIL=0
for result in "${RESULTS[@]}"; do
    name="${result%%:*}"; rc="${result##*:}"
    if [[ "${rc}" -eq 0 ]]; then
        echo "  OK    ${name}"
        (( PASS++ )) || true
    else
        echo "  FAIL  ${name}  (exit ${rc}) — see ${LOG_DIR}/${name}.log"
        (( FAIL++ )) || true
    fi
done
echo "  ────────────────────────────────────────────────────────"
echo "  ${PASS} succeeded  |  ${FAIL} failed"
echo "  Logs: ${LOG_DIR}/"
echo ""

[[ ${FAIL} -gt 0 ]] && exit 1
exit 0
