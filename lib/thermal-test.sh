#!/usr/bin/env bash
# =============================================================
# lib/thermal-test.sh — the thermal governor must never leave a backup hung.
#
# WHY THIS EXISTS
# ---------------
# The governor holds a temperature by SIGSTOPping the compressor. Every way it
# can go wrong is quiet: a compressor left stopped is a backup that never
# finishes and never fails, and a governor that signals the wrong PID freezes
# somebody else's process. So this drives the real loop against a fake sensor
# file and real gzip processes, and asserts on the process state the kernel
# reports, not on what the governor logged.
#
# No network, no root, no thermal hardware. Runs on Linux and macOS.
#
# Usage: bash lib/thermal-test.sh
# Exit:  0 = all pass, 1 = a failure.
# =============================================================
set -uo pipefail

PASS=0
FAIL=0
chk() {
    local label="$1" ok="$2" detail="${3:-}"
    if [[ "$ok" == "yes" ]]; then
        echo "  PASS  ${label}"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL  ${label}"
        [[ -n "${detail}" ]] && echo "        ${detail}"
        FAIL=$(( FAIL + 1 ))
    fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
SENSOR="${WORK}/temp"
LOG="${WORK}/log"
_PIDS=()
cleanup() {
    local p
    for p in "${_PIDS[@]:-}"; do
        [[ -n "${p}" ]] || continue
        kill -CONT "${p}" 2>/dev/null; kill -KILL "${p}" 2>/dev/null
    done
    rm -rf "${WORK}"
}
trap cleanup EXIT

export PI2S3_THERMAL_SENSOR="${SENSOR}"
export PI2S3_THERMAL_POLL_SECS=0.2
export PI2S3_THERMAL_MAX_PAUSE_SECS=300
export PI2S3_THERMAL_FORCED_RUN_SECS=60
log() { echo "$*" >> "${LOG}"; }
# shellcheck disable=SC1091
source "${ROOT}/lib/thermal.sh"

# shellcheck disable=SC2034  # read by lib/thermal.sh
BACKUP_MAX_TEMP_C=75
set_temp() { echo $(( $1 * 1000 )) > "${SENSOR}"; }
# The kernel's view: T = stopped. Not what the governor believes it did.
state() { ps -o state= -p "$1" 2>/dev/null | tr -d ' ' | cut -c1; }
settle() { sleep 0.8; }
# A registered compressor that never finishes: gzip reading a fifo nobody writes to.
start_gzip() {
    local fifo="${WORK}/fifo.$RANDOM"
    mkfifo "${fifo}"
    ( thermal_register; exec gzip -c < "${fifo}" > /dev/null ) &
    _LAST=$!
    _PIDS+=("${_LAST}")
    exec {_fd}> "${fifo}"   # hold the write end open so gzip blocks rather than exits
}

# ── 1. Below the limit nothing is touched ───────────────────────────────────
set_temp 60
thermal_governor_start
start_gzip; GZ1="${_LAST}"
settle
chk "a cool host: the compressor runs" "$([[ "$(state "${GZ1}")" != "T" ]] && echo yes || echo no)" "state=$(state "${GZ1}")"

# ── 2. At the limit the compressor is stopped ───────────────────────────────
set_temp 75
settle
chk "at the limit: the compressor is stopped" "$([[ "$(state "${GZ1}")" == "T" ]] && echo yes || echo no)" "state=$(state "${GZ1}")"

# ── 3. Hysteresis: a degree under the limit is not cool enough ──────────────
# Without it the governor flaps every poll, and each flap is a stalled upload.
set_temp 72
settle
chk "between resume and limit: still stopped" "$([[ "$(state "${GZ1}")" == "T" ]] && echo yes || echo no)" "state=$(state "${GZ1}")"

# ── 4. A compressor that starts during a pause is stopped too ───────────────
# The boot-firmware and extra-device jobs start their own pipelines mid-backup.
start_gzip; GZ2="${_LAST}"
settle
chk "a compressor started while paused is stopped" "$([[ "$(state "${GZ2}")" == "T" ]] && echo yes || echo no)" "state=$(state "${GZ2}")"

# ── 5. A stranger with a registered PID is never signalled ──────────────────
# PIDs are reused. A stale registration must not freeze whatever inherited it.
sleep 300 & STRANGER=$!; _PIDS+=("${STRANGER}")
: > "${_THERMAL_DIR}/${STRANGER}"
set_temp 80
settle
chk "a registered PID that is not a compressor is left alone" \
    "$([[ "$(state "${STRANGER}")" != "T" ]] && echo yes || echo no)" "state=$(state "${STRANGER}")"

# ── 6. Cooling to the resume point continues everything ─────────────────────
set_temp 70
settle
chk "at the resume point: both compressors continue" \
    "$([[ "$(state "${GZ1}")" != "T" && "$(state "${GZ2}")" != "T" ]] && echo yes || echo no)" \
    "states=$(state "${GZ1}")/$(state "${GZ2}")"

# ── 7. Stopping the governor mid-pause leaves nothing stopped ───────────────
set_temp 80
settle
chk "(precondition) paused again" "$([[ "$(state "${GZ1}")" == "T" ]] && echo yes || echo no)"
_dir="${_THERMAL_DIR}"
thermal_governor_stop
chk "governor stopped mid-pause: compressors continue" \
    "$([[ "$(state "${GZ1}")" != "T" && "$(state "${GZ2}")" != "T" ]] && echo yes || echo no)" \
    "states=$(state "${GZ1}")/$(state "${GZ2}")"
chk "governor stopped: its state directory is gone" "$([[ ! -e "${_dir}" ]] && echo yes || echo no)"
chk "the summary counts the pauses" "$([[ "${_THERMAL_RESULTS}" == "Thermal: paused 1× "* ]] && echo yes || echo no)" "got: ${_THERMAL_RESULTS}"
thermal_governor_stop
chk "stopping twice is harmless" "yes"

# ── 8. A governor that is killed outright still releases its compressors ────
# on_exit calls thermal_governor_stop, but the loop can die without the script.
set_temp 80
thermal_governor_start
: > "${_THERMAL_DIR}/${GZ1}"
settle
chk "(precondition) paused by the new governor" "$([[ "$(state "${GZ1}")" == "T" ]] && echo yes || echo no)"
kill -TERM "${_THERMAL_PID}"; wait "${_THERMAL_PID}" 2>/dev/null
chk "governor killed mid-pause: its own trap continues the compressor" \
    "$([[ "$(state "${GZ1}")" != "T" ]] && echo yes || echo no)" "state=$(state "${GZ1}")"
_THERMAL_PID=""; thermal_governor_stop

# ── 9. A host that never cools does not hang the backup ─────────────────────
# Whole seconds: the loop's clock is `date +%s`, so a 3s cap fires 2-3s in.
_THERMAL_MAX_PAUSE_SECS=3
_THERMAL_FORCED_RUN_SECS=60
set_temp 90
thermal_governor_start
: > "${_THERMAL_DIR}/${GZ1}"
settle
chk "(precondition) paused while hot" "$([[ "$(state "${GZ1}")" == "T" ]] && echo yes || echo no)"
sleep 3
chk "still hot after the maximum pause: resumed anyway" \
    "$([[ "$(state "${GZ1}")" != "T" ]] && echo yes || echo no)" "state=$(state "${GZ1}")"
settle
chk "and not re-paused during the forced run" \
    "$([[ "$(state "${GZ1}")" != "T" ]] && echo yes || echo no)" "state=$(state "${GZ1}")"
thermal_governor_stop
chk "a forced resume is reported, not hidden" \
    "$([[ "${_THERMAL_RESULTS}" == *"forced resume"* ]] && echo yes || echo no)" "got: ${_THERMAL_RESULTS}"
chk "and warned about in the log" "$(grep -q 'WARN: Thermal' "${LOG}" && echo yes || echo no)"
_THERMAL_MAX_PAUSE_SECS=300

# ── 10. An unreadable sensor fails open, and says so ────────────────────────
# A broken sensor must not stop backups; it must not read as an enforced limit either.
echo "garbage" > "${SENSOR}"
thermal_governor_start
: > "${_THERMAL_DIR}/${GZ1}"
settle
chk "a sensor returning garbage never pauses" "$([[ "$(state "${GZ1}")" != "T" ]] && echo yes || echo no)"
thermal_governor_stop

: > "${LOG}"
_THERMAL_SENSOR="${WORK}/no-such-sensor"
thermal_governor_start
chk "no sensor: no governor is started" "$([[ -z "${_THERMAL_PID}" && -z "${_THERMAL_DIR}" ]] && echo yes || echo no)"
chk "no sensor: the log says the limit is NOT enforced" "$(grep -q 'NOT enforced' "${LOG}" && echo yes || echo no)"
thermal_governor_stop
_THERMAL_SENSOR="${SENSOR}"

# ── 11. BACKUP_MAX_TEMP_C=0 turns it off ────────────────────────────────────
BACKUP_MAX_TEMP_C=0
set_temp 95
thermal_governor_start
chk "limit 0: no governor is started" "$([[ -z "${_THERMAL_PID}" ]] && echo yes || echo no)"
# shellcheck disable=SC2034  # read by lib/thermal.sh
BACKUP_MAX_TEMP_C=75

# ── 12. A paused stream arrives intact ──────────────────────────────────────
# The point of the whole exercise is a restorable image.
set_temp 60
thermal_governor_start
head -c 3000000 /dev/urandom > "${WORK}/in"
(
    ( head -c 1000000; sleep 1.5; cat ) < "${WORK}/in" \
        | ( thermal_register; exec gzip -c -1 ) \
        | gunzip > "${WORK}/out"
) &
_pipe=$!
sleep 0.4; set_temp 80; sleep 1.2; set_temp 60
wait "${_pipe}"
thermal_governor_stop
chk "the stream was actually paused in transit" \
    "$([[ "${_THERMAL_RESULTS}" == "Thermal: paused 1× "* ]] && echo yes || echo no)" "got: ${_THERMAL_RESULTS}"
chk "and decompresses to the bytes that went in" "$(cmp -s "${WORK}/in" "${WORK}/out" && echo yes || echo no)"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
