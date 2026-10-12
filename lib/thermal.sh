#!/usr/bin/env bash
# lib/thermal.sh — pause the imaging pipeline when the CPU gets hot
# Source this file; do not execute directly.
# Requires: log() (lib/log.sh), BACKUP_MAX_TEMP_C
#
# A thread cap bounds how busy the backup makes the CPU, but not how hot: on a
# Pi 5 with no fan, ONE pigz thread still climbs past 78°C inside two minutes
# and two threads reach 80°C in forty seconds (andrew-pi-5, 2026-10-12). No
# static setting holds a temperature, so this watches the sensor and SIGSTOPs
# the compressor above BACKUP_MAX_TEMP_C, resuming 5°C lower.
#
# Stopping the compressor stalls the whole pipeline: partclone blocks on a full
# pipe and aws waits on an empty one. aws buffers a whole part before it sends
# it, so no HTTP request is left open across a pause.

_THERMAL_SENSOR="${PI2S3_THERMAL_SENSOR:-/sys/class/thermal/thermal_zone0/temp}"
_THERMAL_POLL_SECS="${PI2S3_THERMAL_POLL_SECS:-5}"
# A host that idles above the resume point (hot room, sensor fault) would never
# cool enough, and a backup that never finishes is worse than a warm one. After
# this long paused the governor resumes anyway and runs for _THERMAL_FORCED_RUN_SECS.
_THERMAL_MAX_PAUSE_SECS="${PI2S3_THERMAL_MAX_PAUSE_SECS:-300}"
_THERMAL_FORCED_RUN_SECS="${PI2S3_THERMAL_FORCED_RUN_SECS:-60}"
_THERMAL_HYSTERESIS_C=5

_THERMAL_DIR=""
_THERMAL_PID=""
_THERMAL_RESULTS=""

# Called by the compressor pipeline stage, in its subshell, immediately before it
# execs the compressor: exec keeps the PID, so this names the compressor itself.
thermal_register() {
    [[ -n "${_THERMAL_DIR}" && -d "${_THERMAL_DIR}" ]] || return 0
    : > "${_THERMAL_DIR}/${BASHPID}"
}

# _thermal_signal STOP|CONT — signal every registered compressor still running.
_thermal_signal() {
    local _f _pid _comm
    for _f in "${_THERMAL_DIR}"/[0-9]*; do
        [[ -e "${_f}" ]] || continue
        _pid="${_f##*/}"
        _comm=$(ps -o comm= -p "${_pid}" 2>/dev/null || true)
        _comm="${_comm##*/}"
        case "${_comm}" in
            pigz|gzip) kill -s "$1" "${_pid}" 2>/dev/null || true ;;
            "")        rm -f "${_f}" ;;   # exited
            *)         ;;                 # not exec'd yet, or the PID was reused: never signal a stranger
        esac
    done
}

_thermal_read_c() {
    local _raw
    _raw=$(cat "${_THERMAL_SENSOR}" 2>/dev/null || true)
    [[ "${_raw}" =~ ^[0-9]+$ ]] || _raw=0
    echo $(( _raw / 1000 ))
}

_thermal_loop() {
    local _max="${BACKUP_MAX_TEMP_C}" _resume=$(( BACKUP_MAX_TEMP_C - _THERMAL_HYSTERESIS_C ))
    local _paused=false _since=0 _hold_until=0 _peak=0 _pauses=0 _paused_secs=0 _forced=0 _t _now
    # However this subshell ends, nothing may be left stopped: a compressor that
    # stays SIGSTOPped is a backup that hangs with the database quiesce long gone.
    trap '_thermal_signal CONT' EXIT
    trap 'exit 0' TERM INT
    while true; do
        _t=$(_thermal_read_c)
        _now=$(date +%s)
        if [[ "${_paused}" == "true" ]]; then
            (( _t > _peak )) && _peak="${_t}"
            if (( _t <= _resume )) || (( _now - _since >= _THERMAL_MAX_PAUSE_SECS )); then
                _thermal_signal CONT
                _paused=false
                _paused_secs=$(( _paused_secs + _now - _since ))
                if (( _t <= _resume )); then
                    log "  Thermal: paused $(( _now - _since ))s (peak ${_peak}°C), resumed at ${_t}°C"
                else
                    _forced=$(( _forced + 1 ))
                    _hold_until=$(( _now + _THERMAL_FORCED_RUN_SECS ))
                    log "  WARN: Thermal: still ${_t}°C after ${_THERMAL_MAX_PAUSE_SECS}s paused — resuming anyway for ${_THERMAL_FORCED_RUN_SECS}s. This host does not cool to ${_resume}°C; raise BACKUP_MAX_TEMP_C or improve cooling."
                fi
                printf 'pauses=%s\nseconds=%s\nforced=%s\n' "${_pauses}" "${_paused_secs}" "${_forced}" \
                    > "${_THERMAL_DIR}/summary"
            else
                _thermal_signal STOP   # a compressor that started while paused
            fi
        elif (( _t >= _max && _now >= _hold_until )); then
            _thermal_signal STOP
            _paused=true; _since="${_now}"; _peak="${_t}"; _pauses=$(( _pauses + 1 ))
        else
            _thermal_signal 0      # signals nothing; drops registrations of compressors that have exited
        fi
        sleep "${_THERMAL_POLL_SECS}"
    done
}

thermal_governor_start() {
    _THERMAL_RESULTS=""
    if (( BACKUP_MAX_TEMP_C <= 0 )); then
        log "  Thermal limit: off (BACKUP_MAX_TEMP_C=0)"
        return 0
    fi
    if [[ ! -r "${_THERMAL_SENSOR}" ]]; then
        log "  Thermal limit: NOT enforced — no sensor at ${_THERMAL_SENSOR}"
        return 0
    fi
    _THERMAL_DIR=$(mktemp -d)
    log "  Thermal limit: pause compression at ${BACKUP_MAX_TEMP_C}°C, resume at $(( BACKUP_MAX_TEMP_C - _THERMAL_HYSTERESIS_C ))°C (now $(_thermal_read_c)°C)"
    _thermal_loop &
    _THERMAL_PID=$!
}

# Safe to call twice and from the exit trap.
thermal_governor_stop() {
    [[ -n "${_THERMAL_DIR}" ]] || return 0
    if [[ -n "${_THERMAL_PID}" ]]; then
        kill "${_THERMAL_PID}" 2>/dev/null || true
        wait "${_THERMAL_PID}" 2>/dev/null || true
        _THERMAL_PID=""
    fi
    _thermal_signal CONT   # the loop's own trap does this too; a SIGKILLed loop would not
    if [[ -f "${_THERMAL_DIR}/summary" ]]; then
        local _pauses _secs _forced
        _pauses=$(grep '^pauses=' "${_THERMAL_DIR}/summary" | cut -d= -f2)
        _secs=$(grep '^seconds=' "${_THERMAL_DIR}/summary" | cut -d= -f2)
        _forced=$(grep '^forced=' "${_THERMAL_DIR}/summary" | cut -d= -f2)
        _THERMAL_RESULTS="Thermal: paused ${_pauses}× (${_secs}s) to stay under ${BACKUP_MAX_TEMP_C}°C"
        (( ${_forced:-0} > 0 )) && _THERMAL_RESULTS+=" — ${_forced} forced resume(s), host not cooling"
    else
        _THERMAL_RESULTS="Thermal: never reached ${BACKUP_MAX_TEMP_C}°C"
    fi
    rm -rf "${_THERMAL_DIR}"; _THERMAL_DIR=""
}
