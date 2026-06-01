#!/bin/bash
# =============================================================
# firstrun-ssh-fix.sh
#
# Drop onto the Pi boot partition (FAT32) to fix SSH on first boot.
# Pi OS runs it via systemd.run= in cmdline.txt.
#
# Writes to stdout → visible in systemd journal AND on the screen
# (both tty1 and journalctl -u pi-boot-connectivity or systemd-run).
#
# What it does:
#   1. Regenerates missing SSH host keys (the #1 cause of sshd not starting)
#   2. Enables and starts sshd
#   3. Verifies port 22 is listening
#   4. Removes itself from cmdline.txt so it doesn't run again
#   5. Prints a clear PASS / FAIL summary
#
# Deploy via prepare-sd.sh or manually:
#   cp extras/firstboot/firstrun-ssh-fix.sh /Volumes/bootfs/firstrun-ssh-fix.sh
#   # Append to cmdline.txt (one line, no newline before):
#   # systemd.run=/boot/firmware/firstrun-ssh-fix.sh systemd.run_success_action=none systemd.run_failure_action=none
# =============================================================

# Write to both the journal and any attached console
exec 1> >(tee -a /dev/console | systemd-cat -t firstrun-ssh-fix -p info) 2>&1

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       firstrun-ssh-fix  $(date '+%H:%M:%S')            ║"
echo "╚══════════════════════════════════════════════════╝"

ERRORS=0

# ── Step 1: Host keys ─────────────────────────────────────────
echo ""
echo "── Step 1: SSH host keys"
KEY_COUNT=$(ls /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l || echo 0)
if [[ "${KEY_COUNT}" -gt 0 ]]; then
    echo "    OK: ${KEY_COUNT} host key(s) already present"
    ls /etc/ssh/ssh_host_*_key 2>/dev/null | while read -r k; do
        echo "       $(ssh-keygen -l -f "${k}" 2>/dev/null || echo "(unreadable: ${k})")"
    done
else
    echo "    MISSING: no host keys found — regenerating..."
    if ssh-keygen -A 2>&1 | sed 's/^/    /'; then
        NEW_COUNT=$(ls /etc/ssh/ssh_host_*_key 2>/dev/null | wc -l || echo 0)
        echo "    OK: ${NEW_COUNT} key(s) generated"
    else
        echo "    ERROR: ssh-keygen -A failed!"
        echo "    Check: disk space (df -h), /etc/ssh permissions (ls -la /etc/ssh)"
        ERRORS=$(( ERRORS + 1 ))
    fi
fi

# ── Step 2: Enable + start sshd ──────────────────────────────
echo ""
echo "── Step 2: Start sshd"
STARTED_SVC=""
for _svc in ssh sshd; do
    if systemctl enable --now "${_svc}" 2>&1 | sed 's/^/    /'; then
        STARTED_SVC="${_svc}"
        echo "    OK: ${_svc} enabled and started"
        break
    fi
done
if [[ -z "${STARTED_SVC}" ]]; then
    echo "    ERROR: could not start ssh or sshd via systemctl"
    echo "    --- systemctl status ssh ---"
    systemctl status ssh --no-pager -l 2>&1 | tail -20 | sed 's/^/    /' || true
    echo "    --- journal (last 10 lines) ---"
    journalctl -u ssh -u sshd -n 10 --no-pager --output=short 2>/dev/null \
        | sed 's/^/    /' || true
    ERRORS=$(( ERRORS + 1 ))
fi

# ── Step 3: Wait and verify port ─────────────────────────────
echo ""
echo "── Step 3: Verify port"
SSH_CFG_PORT=$(grep -E '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null \
    | awk '{print $2}' | head -1 || echo '22')
SSH_CFG_PORT="${SSH_CFG_PORT:-22}"
echo "    Configured port: ${SSH_CFG_PORT}"

for _i in 1 2 3 4 5; do
    sleep 2
    _open=$(ss -tlnp 2>/dev/null | awk -v p=":${SSH_CFG_PORT} " '$0~p{print "1"}' | head -1 || echo '')
    if [[ "${_open}" == "1" ]]; then
        echo "    OK: port ${SSH_CFG_PORT} is OPEN (attempt ${_i})"
        break
    fi
    echo "    Waiting... attempt ${_i}/5 — port ${SSH_CFG_PORT} not yet open"
    if [[ "${_i}" -eq 5 ]]; then
        echo "    ERROR: port ${SSH_CFG_PORT} never opened"
        echo "    Active services: $(systemctl is-active ssh sshd 2>/dev/null | paste -sd ' ')"
        echo "    All listening ports: $(ss -tlnp 2>/dev/null | awk 'NR>1{print $4}' | tr '\n' '  ')"
        ERRORS=$(( ERRORS + 1 ))
    fi
done

# ── Step 4: Self-remove from cmdline.txt ─────────────────────
echo ""
echo "── Step 4: Self-remove from cmdline.txt"
for _cmdline in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    if [[ -f "${_cmdline}" ]] && grep -q 'firstrun-ssh-fix' "${_cmdline}"; then
        cp "${_cmdline}" "${_cmdline}.bak"
        python3 -c "
import re, sys
txt = open('${_cmdline}').read()
txt = re.sub(r' systemd\.run=\S*firstrun-ssh-fix\S*', '', txt)
txt = re.sub(r' systemd\.run_success_action=none', '', txt)
txt = re.sub(r' systemd\.run_failure_action=none', '', txt)
open('${_cmdline}', 'w').write(txt)
" && echo "    OK: removed from ${_cmdline}" || echo "    WARN: could not clean ${_cmdline}"
    fi
done
rm -f /boot/firmware/firstrun-ssh-fix.sh /boot/firstrun-ssh-fix.sh 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────
echo ""
if [[ "${ERRORS}" -eq 0 ]]; then
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  SSH FIX: COMPLETE  — port ${SSH_CFG_PORT} open              ║"
    echo "║  Connect: ssh admin@ssh-qa.andrewbaker.ninja     ║"
    echo "╚══════════════════════════════════════════════════╝"
else
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  SSH FIX: FAILED (${ERRORS} error(s))               ║"
    echo "║  Check journal: journalctl -u ssh -n 30          ║"
    echo "╚══════════════════════════════════════════════════╝"
fi
echo ""
