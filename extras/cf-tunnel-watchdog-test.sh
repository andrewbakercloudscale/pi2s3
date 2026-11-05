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

# ── Network-fault path (2026-11-05 RCA) ─────────────────────────────────────
# Prod's Wi-Fi stayed associated but carried no traffic for 47 minutes; Phases 1 and 2
# restarted the stack eight times and only the reboot helped. A network fault must skip
# the container restarts, bounce the uplink early and reboot after ~15 minutes.
for f in net_plan is_network_fault internet_reachable; do
    body="$(sed -n "/^${f}() {/,/^}/p" "${TARGET}")"
    [[ -n "${body}" ]] || { echo "could not extract ${f}() from ${TARGET}" >&2; exit 2; }
    eval "${body}"
done

c() { # $1 description, $2 expected, $3 got
    checks=$((checks+1))
    if [[ "$3" == "$2" ]]; then echo "  ok   $1"; else echo "  FAIL $1 (expected $2, got $3)"; fails=$((fails+1)); fi
}

echo ""
echo "=== cf-tunnel-watchdog: network-fault path ==="
echo ""
CF_NET_BOUNCE_AT=2; CF_NET_REBOOT_AT=4
c "attempt 1: restart cloudflared only"   cloudflared "$(net_plan 1)"
c "attempt 2: bounce the uplink"          bounce      "$(net_plan 2)"
c "attempt 3: bounce again"               bounce      "$(net_plan 3)"
c "attempt 4 (about 15 min): reboot"      reboot      "$(net_plan 4)"
c "attempt 9: still reboot"               reboot      "$(net_plan 9)"

nf() { if is_network_fault "$@"; then echo yes; else echo no; fi; }
c "tunnel down, HTTP 200, all up, no internet: network fault"     yes "$(nf 1 200 '' 1)"
c "tunnel down, HTTP 301, no internet: network fault"             yes "$(nf 1 301 '' 1)"
c "internet reachable: not a network fault"                       no  "$(nf 1 200 '' 0)"
c "tunnel healthy: not a network fault"                           no  "$(nf 0 200 '' 1)"
c "HTTP 502 locally: the stack is broken, not the network"        no  "$(nf 1 502 '' 1)"
c "HTTP ERR locally: the stack is broken, not the network"        no  "$(nf 1 ERR '' 1)"
c "a stopped container: the stack is broken, not the network"     no  "$(nf 1 200 'pi_nginx' 1)"

ir() { if internet_reachable; then echo yes; else echo no; fi; }
PORT=$(( 20000 + RANDOM % 20000 ))
python3 -c "import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',${PORT}));s.listen(5);time.sleep(8)" &
LPID=$!; sleep 0.5
CF_NET_PROBES="127.0.0.1:${PORT}";                c "a probe that accepts: reachable"              yes "$(ir)"
CF_NET_PROBES="127.0.0.1:1 127.0.0.1:${PORT}";    c "any one probe accepting is enough"            yes "$(ir)"
CF_NET_PROBES="127.0.0.1:1 127.0.0.1:2";          c "no probe accepts: unreachable"                no  "$(ir)"
CF_NET_PROBES="";                                 c "empty probe list: path off, reads reachable"  yes "$(ir)"
kill ${LPID} 2>/dev/null; wait ${LPID} 2>/dev/null

# Wiring: the network branch runs before Phase 1, exits, and Phase 3 reuses the
# rate-limited reboot.
nl=$(grep -n 'if \[\[ ${NETWORK_FAULT} -eq 1 \]\]; then' "${TARGET}" | head -1 | cut -d: -f1)
p1=$(grep -n '^# ── Phase 1: targeted restart' "${TARGET}" | head -1 | cut -d: -f1)
c "the network branch comes before Phase 1"   yes "$([[ -n "${nl}" && -n "${p1}" && ${nl} -lt ${p1} ]] && echo yes || echo no)"
c "the network branch exits instead of falling into Phase 1" yes "$(sed -n "${nl},${p1}p" "${TARGET}" | grep -q '^    exit 0$' && echo yes || echo no)"
c "the network plan's reboot step calls the rate-limited reboot" yes "$(sed -n "${nl},${p1}p" "${TARGET}" | awk '/^        reboot\)/{f=1;next} f&&/;;/{exit} f' | grep -q 'reboot_pi' && echo yes || echo no)"
c "Phase 3 calls the shared rate-limited reboot" yes "$(sed -n '/^# ── Phase 3/,/^fi$/p' "${TARGET}" | grep -q 'reboot_pi' && echo yes || echo no)"
c "reboot_pi keeps the 6-hour rate limit"     yes "$(sed -n '/^reboot_pi() {/,/^}/p' "${TARGET}" | grep -q 'CF_REBOOT_MIN_INTERVAL' && echo yes || echo no)"
c "the reason names the gateway, for the RCA" yes "$(grep -q 'gateway ${UPLINK_GW} reachable=${UPLINK_GW_OK}' "${TARGET}" && echo yes || echo no)"

echo ""
if [[ ${fails} -gt 0 ]]; then
    printf "FAILED: %d of %d checks.\n" "${fails}" "${checks}"
    exit 1
fi
printf "OK: %d checks passed.\n" "${checks}"
exit 0
