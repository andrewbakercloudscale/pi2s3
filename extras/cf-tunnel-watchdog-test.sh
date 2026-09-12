#!/usr/bin/env bash
# =============================================================================
# cf-tunnel-watchdog-test.sh — pins the one decision that must never fail open
#
#   bash extras/cf-tunnel-watchdog-test.sh
#   exit 0 = all pass, 1 = a failure
#
# WHY THIS EXISTS
# ---------------
# The watchdog's three checks are: containers running, localhost HTTP, and the
# Cloudflare tunnel's HA connection count. The first two are purely LOCAL and both
# pass happily on a host that cannot reach the internet at all. So the tunnel check
# is the only one that can notice a site nobody outside can get to, and everything
# — the alert, the cloudflared restart, the compose restart, the reboot — hangs off
# it being right.
#
# Until 2026-09-12 it failed OPEN. The detection block ran the tunnel check only if
# the metrics endpoint answered, and logged "skipping tunnel check" otherwise, so a
# cloudflared that was wedged, not listening, or on a changed port left the script
# reporting "OK: ha_connections=..., HTTP=200" indefinitely: no alert, no recovery,
# no reboot. The script it replaced on 2026-09-06 had it right — an empty reading
# counted as down — and the merge lost that. The justification in the comment was
# "e.g. not configured", but CF_METRICS_URL always has a default, so unconfigured
# is not a state that occurs.
#
# The first version of the fix still let ANY non-empty, non-"0" reading through as
# healthy. This test found that on its first run, which is why the comparison is
# numeric rather than a string test.
#
# It sources the real function out of the shipped script rather than restating it,
# so the test cannot drift from the code it is asserting.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/cf-tunnel-watchdog.sh"

[[ -r "${TARGET}" ]] || { echo "cannot read ${TARGET}" >&2; exit 2; }

FN="$(sed -n '/^tunnel_healthy() {/,/^}/p' "${TARGET}")"
[[ -n "${FN}" ]] || { echo "could not extract tunnel_healthy() from ${TARGET}" >&2; exit 2; }
eval "${FN}"

# The detection block must not have a "skip the check" path left in it.
if grep -q 'skipping tunnel check' "${TARGET}"; then
    echo "FAIL: ${TARGET} still contains a 'skipping tunnel check' path" >&2
    exit 1
fi
if grep -q 'METRICS_AVAILABLE' "${TARGET}"; then
    echo "FAIL: ${TARGET} still references METRICS_AVAILABLE, the fail-open flag" >&2
    exit 1
fi

fails=0; checks=0

# $1 description, $2 CF_TUNNEL_CHECK_ENABLED, $3 reading, $4 expected (0 healthy / 1 down)
t() {
    checks=$((checks+1))
    CF_TUNNEL_CHECK_ENABLED="$2"
    if tunnel_healthy "$3"; then got=0; else got=1; fi
    if [[ ${got} -eq $4 ]]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1 (expected $4, got ${got})"
        fails=$((fails+1))
    fi
}

echo ""
echo "=== cf-tunnel-watchdog: tunnel_healthy() ==="
echo ""
t "4 connections -> healthy"                              1 "4"             0
t "0 connections -> DOWN"                                 1 "0"             1
t "metrics UNREACHABLE (empty reading) -> DOWN"            1 ""              1
t "whitespace-only reading -> DOWN"                       1 " "             1
t "float 4.0 -> healthy (prometheus gauges are floats)"   1 "4.0"           0
t "padded \" 4 \" -> healthy"                               1 " 4 "           0
t "non-numeric reading -> DOWN"                           1 "nan"           1
t "a label where the value used to be -> DOWN"            1 "tunnel_id=abc" 1
t "0.0 -> DOWN"                                           1 "0.0"           1
t "deliberately disabled, empty -> healthy"               0 ""              0
t "deliberately disabled, 0 -> healthy"                   0 "0"             0

echo ""
if [[ ${fails} -gt 0 ]]; then
    printf "FAILED: %d of %d checks.\n" "${fails}" "${checks}"
    exit 1
fi
printf "OK: %d checks passed.\n" "${checks}"
exit 0
