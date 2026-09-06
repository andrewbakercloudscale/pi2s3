#!/usr/bin/env bash
# =============================================================
# lib/notify-test.sh — the notifier must never mute itself silently.
#
# WHY THIS EXISTS
# ---------------
# Every script carried its own ntfy_send(), and every copy opened with:
#
#     [[ -z "${NTFY_URL:-}" ]] && return 0
#
# On andrew-pi-5 the config moved to Telegram, so NTFY_URL was gone. From
# 2026-07-03 to 2026-08-09 that line discarded every notification these scripts
# raised — 38 nights of "Backup Done", and with them "Backup Failed", "Verify
# Failed", "Backup Overdue", "Backup Missing", "Containers Stuck" and
# "Post-Backup Failed". The backups themselves ran perfectly throughout, which is
# precisely why nobody noticed: the only symptom was silence, and silence is what
# a healthy night sounds like too.
#
# Worse, pi2s3-post-backup-check.sh answered a missing NTFY_URL with `exit 1`, so
# the net that restarts containers the backup left down did not run for those same
# 38 nights.
#
# This asserts the properties that would have caught all of it, with no network:
# curl is stubbed, so "sent" here means "the notifier chose that transport and
# built that request", not "a phone buzzed".
#
# Usage: bash lib/notify-test.sh
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
        [[ -n "$detail" ]] && echo "        ${detail}"
        FAIL=$(( FAIL + 1 ))
    fi
}

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Captured instead of sent. The URL a real send would hit is written to CURL_LOG so
# the transport can be asserted without a network or a token.
CURL_LOG="$(mktemp)"
curl() {
    printf '%s\n' "$*" >> "${CURL_LOG}"
    return "${CURL_RC:-0}"
}
export -f curl 2>/dev/null || true
log() { echo "TESTLOG: $*" >> "${CURL_LOG}"; }

# shellcheck source=lib/notify.sh
source "${LIB_DIR}/notify.sh"

reset_case() { : > "${CURL_LOG}"; CURL_RC=0; unset TG_BOT_TOKEN TG_CHAT_ID NTFY_URL; }

echo "Notifier transport selection"
echo "────────────────────────────"

# ── 1. Nothing configured: loud, not silent ─────────────────────────────────
reset_case
out="$(notify_send 'pi2s3: Backup Failed' 'imaging aborted' 'high' 'warning' 2>&1; echo "rc=$?")"
body="$(cat "${CURL_LOG}")"
chk "unconfigured: no HTTP request is attempted" \
    "$([[ "${body}" != *"http"* ]] && echo yes || echo no)"
chk "unconfigured: the log SAYS alerts are being discarded" \
    "$([[ "${body}" == *"alerts are being DISCARDED"* ]] && echo yes || echo no)" \
    "a silent 'return 0' is the bug this file exists for"
chk "unconfigured: the undelivered title is still recorded" \
    "$([[ "${body}" == *"Backup Failed"* ]] && echo yes || echo no)"
chk "unconfigured: the caller is not failed" \
    "$([[ "${out}" == *"rc=0"* ]] && echo yes || echo no)" \
    "no destination is not the caller's fault, and must not abort a backup"

# The warning is once per run, or a 70-chunk backup buries its own log.
reset_case
notify_send 'one' 'a' >/dev/null 2>&1
notify_send 'two' 'b' >/dev/null 2>&1
count="$(grep -c 'alerts are being DISCARDED' "${CURL_LOG}" || true)"
chk "unconfigured: the warning appears once per run, not per message" \
    "$([[ "${count}" == "1" ]] && echo yes || echo no)" "saw ${count}"

# ── 2. Telegram ─────────────────────────────────────────────────────────────
reset_case
TG_BOT_TOKEN="tok"; TG_CHAT_ID="123"
chk "telegram: notify_configured() is true" "$(notify_configured && echo yes || echo no)"
chk "telegram: transport is reported as telegram" \
    "$([[ "$(notify_transport)" == "telegram" ]] && echo yes || echo no)"
notify_send 'pi2s3: Backup Done' 'all good' 'low' 'floppy_disk' >/dev/null 2>&1
body="$(cat "${CURL_LOG}")"
chk "telegram: the request goes to the Telegram API" \
    "$([[ "${body}" == *"api.telegram.org/bottok/sendMessage"* ]] && echo yes || echo no)"
chk "telegram: the chat id is sent" \
    "$([[ "${body}" == *"chat_id=123"* ]] && echo yes || echo no)"
chk "telegram: title and body are both in the text" \
    "$([[ "${body}" == *"Backup Done"* && "${body}" == *"all good"* ]] && echo yes || echo no)"

# ── 3. ntfy still works exactly as before ───────────────────────────────────
reset_case
NTFY_URL="https://ntfy.sh/topic"
chk "ntfy: transport is reported as ntfy" \
    "$([[ "$(notify_transport)" == "ntfy" ]] && echo yes || echo no)"
notify_send 'pi2s3: Backup Done' 'all good' 'low' 'floppy_disk' >/dev/null 2>&1
body="$(cat "${CURL_LOG}")"
chk "ntfy: the request goes to NTFY_URL" \
    "$([[ "${body}" == *"https://ntfy.sh/topic"* ]] && echo yes || echo no)" \
    "existing ntfy installs must be untouched by the Telegram addition"
chk "ntfy: priority and tags are still passed" \
    "$([[ "${body}" == *"Priority: low"* && "${body}" == *"Tags: floppy_disk"* ]] && echo yes || echo no)"

# ── 4. Telegram wins when both are configured ───────────────────────────────
reset_case
TG_BOT_TOKEN="tok"; TG_CHAT_ID="123"; NTFY_URL="https://ntfy.sh/topic"
notify_send 'both' 'x' >/dev/null 2>&1
body="$(cat "${CURL_LOG}")"
chk "both configured: Telegram is chosen and ntfy is not also posted" \
    "$([[ "${body}" == *"api.telegram.org"* && "${body}" != *"ntfy.sh"* ]] && echo yes || echo no)"

# ── 5. A configured notifier that cannot deliver is LOUD ────────────────────
reset_case
TG_BOT_TOKEN="tok"; TG_CHAT_ID="123"; CURL_RC=7
notify_send 'pi2s3: Backup Failed' 'boom' >/dev/null 2>&1; rc=$?
body="$(cat "${CURL_LOG}")"
chk "delivery failure is reported in the log" \
    "$([[ "${body}" == *"FAILED after 3 attempts"* ]] && echo yes || echo no)" \
    "an undeliverable alert must not look like a quiet healthy night"
chk "delivery failure returns non-zero" "$([[ "${rc}" != "0" ]] && echo yes || echo no)"

# ── 6. The old name still works ─────────────────────────────────────────────
reset_case
TG_BOT_TOKEN="tok"; TG_CHAT_ID="123"
ntfy_send 'legacy call site' 'y' >/dev/null 2>&1
chk "ntfy_send() still delivers (≈20 existing call sites use it)" \
    "$([[ "$(cat "${CURL_LOG}")" == *"api.telegram.org"* ]] && echo yes || echo no)"

# ── 7. No script may keep a private copy of the notifier ────────────────────
# extras/ was outside this list for as long as it existed, and all four scripts there
# still carried the NTFY_URL early-return: on this Telegram fleet the tunnel watchdog,
# the standby sync, the FPM monitor and the restore agent were every one of them mute.
# The lesson is the list, not the copies — a check that covers three of seven files
# reports "no private copies" while four sit next door.
ROOT="$(cd "${LIB_DIR}/.." && pwd)"
private=""
for f in "${ROOT}"/pi-image-backup.sh "${ROOT}"/pi2s3-post-backup-check.sh \
         "${ROOT}"/pi2s3-heartbeat.sh "${ROOT}"/extras/cf-tunnel-watchdog.sh \
         "${ROOT}"/extras/hot-standby-sync.sh "${ROOT}"/extras/fpm-saturation-monitor.sh; do
    grep -qE '^\s*(ntfy_send|notify_send)\(\)' "$f" 2>/dev/null && private+=" $(basename "$f")"
done
chk "no shipped script redefines the notifier locally" \
    "$([[ -z "${private}" ]] && echo yes || echo no)" \
    "private copies are how the mute survived in three places at once:${private}"

# ── 8. The container safety net must not depend on a notifier ───────────────
chk "post-backup check does not exit when no notifier is configured" \
    "$(grep -q 'NTFY_URL not set in config.env"; exit 1' "${ROOT}/pi2s3-post-backup-check.sh" && echo no || echo yes)" \
    "it restarts containers the backup left down; refusing to run because nobody can be told is the opposite of a safety net"

# ── 9. Every script must SOURCE the lib before it CALLS it ──────────────────
# Caught in production, not here, the first time: the post-backup check called
# notify_configured() six lines before sourcing notify.sh, so bash printed
# "notify_configured: command not found" and the `||` branch fired unconditionally —
# a correctly configured Telegram host was told it had no notifier. Absence of an
# `exit 1` was not enough to assert; the ORDER is the property.
order_bad=""
for f in "${ROOT}"/pi-image-backup.sh "${ROOT}"/pi2s3-post-backup-check.sh \
         "${ROOT}"/pi2s3-heartbeat.sh "${ROOT}"/install.sh \
         "${ROOT}"/extras/cf-tunnel-watchdog.sh "${ROOT}"/extras/hot-standby-sync.sh \
         "${ROOT}"/extras/fpm-saturation-monitor.sh; do
    [[ -f "$f" ]] || continue
    src_line="$(grep -nE 'source .*lib/notify\.sh' "$f" | head -1 | cut -d: -f1)"
    use_line="$(grep -nE 'notify_send |notify_configured|notify_transport' "$f" \
                | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)"
    # A script that never calls the lib needs no source line.
    [[ -z "${use_line}" ]] && continue
    if [[ -z "${src_line}" ]] || [[ "${src_line}" -ge "${use_line}" ]]; then
        order_bad+=" $(basename "$f")(source=${src_line:-none},use=${use_line})"
    fi
done
chk "every script sources lib/notify.sh before calling it" \
    "$([[ -z "${order_bad}" ]] && echo yes || echo no)" \
    "calling it first yields 'command not found' and a wrong warning:${order_bad}"

# ── 10. Every alert must name the site it came from ─────────────────────────
# The heartbeat that prompted this read "pi2s3: Heartbeat" — the same eight characters
# every host in the fleet sends, on the one message whose entire job is to say WHICH
# machine is still up. Asserted on the wire, not on the helper, because the property
# that matters is what the phone receives.
: > "${CURL_LOG}"
TG_BOT_TOKEN="tok"; TG_CHAT_ID="chat"; NTFY_URL=""
NOTIFY_SITE="example.com"
notify_send 'pi2s3: Heartbeat' 'up 5 days' 'min' >/dev/null 2>&1
sent="$(cat "${CURL_LOG}")"
chk "the site appears in the title of a sent alert" \
    "$([[ "${sent}" == *"example.com"* ]] && echo yes || echo no)" \
    "sent: ${sent}"

chk "the pi2s3 prefix survives the site tag" \
    "$([[ "$(notify_title 'pi2s3: Backup Failed')" == "pi2s3 [example.com]: Backup Failed" ]] && echo yes || echo no)" \
    "got: $(notify_title 'pi2s3: Backup Failed')"

# ── 11. Tagging must be idempotent ──────────────────────────────────────────
# extras/fpm-saturation-monitor.sh named its own site in the title for months. If the
# central tag were unconditional those alerts would read the domain twice, and the
# obvious fix — dropping the tag at those call sites — would silently re-mute anything
# the list of call sites missed. Idempotence means the layers cannot conflict.
chk "a title that already names the site is not tagged twice" \
    "$([[ "$(notify_title 'PI: example.com: FPM Saturated')" == "PI: example.com: FPM Saturated" ]] && echo yes || echo no)" \
    "got: $(notify_title 'PI: example.com: FPM Saturated')"
chk "re-tagging an already-tagged title is a no-op" \
    "$([[ "$(notify_title "$(notify_title 'pi2s3: Tunnel Down')")" == "pi2s3 [example.com]: Tunnel Down" ]] && echo yes || echo no)" \
    "got: $(notify_title "$(notify_title 'pi2s3: Tunnel Down')")"

# ── 12. The site must resolve from config, not only from an override ────────
unset NOTIFY_SITE
CF_SITE_HOSTNAME="configured.example"
chk "CF_SITE_HOSTNAME supplies the site when NOTIFY_SITE is unset" \
    "$([[ "$(notify_site)" == "configured.example" ]] && echo yes || echo no)" \
    "got: $(notify_site)"

# A site is never empty: an untagged title is exactly the state being fixed, and the
# fallback chain must terminate on a hostname rather than on "".
CF_SITE_HOSTNAME=""
chk "the site falls back to a hostname rather than to nothing" \
    "$([[ -n "$(notify_site)" ]] && echo yes || echo no)"
chk "an untagged title is impossible even with no config" \
    "$([[ "$(notify_title 'pi2s3: Heartbeat')" != "pi2s3: Heartbeat" ]] && echo yes || echo no)" \
    "got: $(notify_title 'pi2s3: Heartbeat')"

# ── 13. No shipped script may bypass the notifier with a raw ntfy curl ──────
# Four did. A `curl -H "Title: ..."` is a notification that skips both the transport
# choice and the site tag, so it is a mute and an anonymous alert in one line.
raw=""
while IFS= read -r f; do
    grep -qE 'curl[^|]*-H "Title:' "$f" 2>/dev/null && raw+=" ${f#${ROOT}/}"
done < <(find "${ROOT}" -name '*.sh' -not -path '*/.git/*' -not -path '*/website/*' \
              -not -name 'notify.sh' -not -name 'notify-test.sh' 2>/dev/null)
chk "no shipped script sends an ntfy notification by raw curl" \
    "$([[ -z "${raw}" ]] && echo yes || echo no)" \
    "these bypass both the transport choice and the site tag:${raw}"

# ── 14. A script must be able to FIND the lib from where it really lives ────
# extras/fpm-saturation-monitor.sh loads config.env and lib/ from "${SCRIPT_DIR}/..",
# but it ships in extras/ and andrew-pi-5's cron runs it from there — so both loads
# resolved to extras/config.env and extras/lib/, neither of which exists. Being `[[ -f ]]`
# guarded, it started anyway with no credentials loaded and alerted nobody, for as long
# as the cron entry existed. Sourcing the notifier from the same wrong path turns that
# quiet miss into an every-minute hard exit, which is how this was caught.
#
# Executed, not grepped: the property is that the path resolves, and only running the
# resolution proves it.
bad_path=""
while IFS= read -r f; do
    grep -qE 'lib/notify\.sh' "$f" 2>/dev/null || continue
    # Exempt: a script that searches a fixed list of ABSOLUTE candidates is not anchored
    # to its own directory on purpose. extras/firstboot/standby-restore-agent.sh runs on
    # the first boot of a restored SD card, where the repo sits at an absolute path with
    # no relation to wherever the agent itself was dropped — tying it to its own
    # directory would be the bug, not the fix.
    grep -q '"/home/pi/pi2s3"' "$f" 2>/dev/null && continue
    d="$(cd "$(dirname "$f")" && pwd)"
    [[ -f "${d}/lib/notify.sh" || -f "$(dirname "${d}")/lib/notify.sh" ]] \
        || bad_path+=" ${f#${ROOT}/}"
done < <(find "${ROOT}" -name '*.sh' -not -path '*/.git/*' -not -path '*/website/*' \
              -not -path "${ROOT}/lib/*" 2>/dev/null)
chk "every script that sources the lib can reach it from its own directory" \
    "$([[ -z "${bad_path}" ]] && echo yes || echo no)" \
    "these resolve lib/notify.sh to a path that does not exist:${bad_path}"

rm -f "${CURL_LOG}"
echo "────────────────────────────"
if [[ ${FAIL} -eq 0 ]]; then
    echo "  notifier: OK (${PASS} checks)"
    exit 0
fi
echo "  notifier: ${FAIL} of $(( PASS + FAIL )) checks FAILED" >&2
exit 1
