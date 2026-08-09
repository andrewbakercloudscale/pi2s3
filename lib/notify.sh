#!/usr/bin/env bash
# lib/notify.sh — one push-notification path for every pi2s3 script.
# Source this file; do not execute directly.
#
# Supports two transports, chosen from config.env:
#
#   Telegram   TG_BOT_TOKEN + TG_CHAT_ID   (preferred when both are set)
#   ntfy       NTFY_URL                    (unchanged behaviour, still supported)
#
# WHY THIS FILE EXISTS
# --------------------
# Every script had its own copy of ntfy_send(), each gated on NTFY_URL, and every
# copy began by returning success when that variable was empty:
#
#     ntfy_send() { [[ -z "${NTFY_URL:-}" ]] && return 0; ... }
#
# That is a silent global mute. On andrew-pi-5 the config moved to Telegram, so
# NTFY_URL was gone, and from 2026-07-03 to 2026-08-09 every notification these
# scripts raised was discarded: 38 nights of "Backup Done", and with them the
# "Backup Failed", "Verify Failed", "Backup Overdue", "Backup Missing",
# "Containers Stuck" and "Post-Backup Failed" alerts that share the same function.
# The backups themselves ran perfectly the whole time, which is what made it
# invisible — the only symptom was silence, and silence is what success sounds like.
#
# So: one implementation, both transports, and a configured-but-unreachable
# notifier is LOUD in the log rather than a no-op return.
#
# The transport choice is deliberately not a mode flag. A host with Telegram
# credentials gets Telegram; a host with only NTFY_URL keeps ntfy exactly as
# before; a host with neither is told once, in the log, at the top of the run.

# Has a notifier been configured at all? Callers use this to decide whether to
# WARN, never to decide whether to do their job. See pi2s3-post-backup-check.sh:
# it used to `exit 1` when NTFY_URL was unset, which turned "nobody can be told"
# into "the container safety net does not run", and that net is the whole reason
# the script exists.
notify_configured() {
    [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] && return 0
    [[ -n "${NTFY_URL:-}" ]] && return 0
    return 1
}

# Which transport a message would use. Reported in logs so an operator can see
# what the script believes, rather than inferring it from whether a phone buzzed.
notify_transport() {
    if [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; then
        echo "telegram"
    elif [[ -n "${NTFY_URL:-}" ]]; then
        echo "ntfy"
    else
        echo "none"
    fi
}

# notify_send <title> <message> [priority] [tags]
#
# priority/tags are ntfy concepts and are passed through for that transport;
# Telegram has no equivalent, so the title becomes the message's first line.
# Returns 0 when delivered, 1 when it could not be, 0 when nothing is configured
# (there is no failure to report if there is no destination).
notify_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    local transport
    transport="$(notify_transport)"

    if [[ "${transport}" == "none" ]]; then
        # Said once per run, not per message: a 70-chunk backup would otherwise
        # bury its own log. The variable is intentionally not `local`.
        if [[ -z "${_NOTIFY_UNCONFIGURED_WARNED:-}" ]]; then
            _NOTIFY_UNCONFIGURED_WARNED=1
            log "  WARNING: no notifier configured (set TG_BOT_TOKEN+TG_CHAT_ID, or NTFY_URL) — alerts are being DISCARDED, including failures."
        fi
        log "  (undelivered) ${title}"
        return 0
    fi

    local _attempt _rc=1
    for _attempt in 1 2 3; do
        if [[ "${transport}" == "telegram" ]]; then
            local text
            printf -v text '%s\n\n%s' "${title}" "${msg}"
            curl -s --max-time 15 \
                -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TG_CHAT_ID}" \
                --data-urlencode "text=${text}" > /dev/null 2>&1 && { _rc=0; break; }
        else
            local extra=()
            [[ -n "${tags}" ]] && extra+=(-H "Tags: ${tags}")
            curl -s --max-time 10 \
                -H "Title: ${title}" \
                -H "Priority: ${priority}" \
                "${extra[@]}" \
                -d "${msg}" \
                "${NTFY_URL}" > /dev/null 2>&1 && { _rc=0; break; }
        fi
        [[ ${_attempt} -lt 3 ]] && sleep $(( _attempt * 5 ))
    done

    if [[ ${_rc} -eq 0 ]]; then
        log "  ${transport} sent: ${title}"
    else
        # A configured notifier that cannot deliver is a real fault and must not
        # look like the quiet of a healthy night.
        log "  WARNING: ${transport} FAILED after 3 attempts: ${title}"
    fi
    return ${_rc}
}

# Backwards compatibility for the ~20 existing call sites and for any operator
# script written against the old name. Same arguments, same order.
ntfy_send() { notify_send "$@"; }
