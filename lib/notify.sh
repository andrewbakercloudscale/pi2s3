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

# The site this host speaks for, resolved most-specific-first.
#
# WHY EVERY TITLE CARRIES IT
# --------------------------
# Titles were hard-coded as "pi2s3: Heartbeat", "pi2s3: Backup Failed" and so on —
# identical on every host that runs this. On a phone holding alerts from more than
# one Pi (or one Pi serving more than one domain) the message says a backup failed
# but not WHOSE, and the reader has to SSH somewhere to find out which. A daily
# heartbeat is the worst case: it is read half-awake, and its whole purpose is to
# identify the machine still standing.
#
# NOTIFY_SITE is the explicit override; CF_SITE_HOSTNAME is what install.sh already
# asks for and what the probe URL is built from. The FQDN is preferred over the bare
# hostname only when it actually has a dot in it — many Pis report the short name for
# both, and "andrew-pi-5" tagged as a domain would be a lie in the one field a reader
# trusts.
notify_site() {
    local site="${NOTIFY_SITE:-${CF_SITE_HOSTNAME:-}}"
    if [[ -z "${site}" ]]; then
        site="$(hostname -f 2>/dev/null || true)"
        [[ "${site}" == *.* ]] || site=""
    fi
    [[ -z "${site}" ]] && site="$(hostname 2>/dev/null || true)"
    [[ -z "${site}" ]] && site="unknown-host"
    printf '%s' "${site}"
}

# notify_title <title> — the title with the site in it, exactly once.
#
# Call sites pass "pi2s3: Backup Failed" and the phone shows
# "pi2s3 [example.com]: Backup Failed". Idempotent by design: a caller that already
# names its own site in the title (extras/fpm-saturation-monitor.sh has done so for
# months) is left alone rather than tagged twice, and re-tagging an already-tagged
# title is a no-op — so this can be applied at any layer without coordination.
notify_title() {
    local title="$1" site
    site="$(notify_site)"
    if [[ -z "${site}" || "${title}" == *"${site}"* ]]; then
        printf '%s' "${title}"
    elif [[ "${title}" == pi2s3:* ]]; then
        printf 'pi2s3 [%s]:%s' "${site}" "${title#pi2s3:}"
    else
        printf '[%s] %s' "${site}" "${title}"
    fi
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
# The title is rewritten by notify_title() first, so every message names the site it
# came from whether the caller remembered to or not.
#
# priority/tags are ntfy concepts and are passed through for that transport;
# Telegram has no equivalent, so the title becomes the message's first line.
# Returns 0 when delivered, 1 when it could not be, 0 when nothing is configured
# (there is no failure to report if there is no destination).
notify_send() {
    local title msg="$2" priority="${3:-default}" tags="${4:-}"
    local transport
    # Applied here, not at the ~25 call sites, so a title added later cannot forget it.
    title="$(notify_title "$1")"
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
