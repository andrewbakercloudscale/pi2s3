#!/usr/bin/env bash
# extras/diagnose-restore.sh — diagnose a failed or in-progress pi2s3 restore
#
# Run on the Pi after a restore fails or hangs:
#   sudo bash extras/diagnose-restore.sh
#
# Outputs a self-contained report to stdout and saves it to
# /var/log/pi2s3-diagnose-TIMESTAMP.log for sharing.
set -euo pipefail

REPORT="/var/log/pi2s3-diagnose-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "${REPORT}") 2>&1

hr() { echo "────────────────────────────────────────────────────────────────"; }
section() { echo ""; hr; echo "  $1"; hr; }

echo "pi2s3 restore diagnostic — $(date)"
echo "Host: $(hostname)  |  Uptime: $(uptime -p 2>/dev/null || uptime)"

# ── Power / throttle ─────────────────────────────────────────────────────────
section "POWER & THROTTLE"

if command -v vcgencmd &>/dev/null; then
    raw=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "0x0")
    current=$(( raw & 0xf ))
    history=$(( (raw >> 16) & 0xf ))
    echo "get_throttled = ${raw}"
    echo ""
    echo "  Current state (lower nibble = ${current}):"
    (( current & 0x1 )) && echo "    [!] Under-voltage RIGHT NOW" || echo "    [ ] No current under-voltage"
    (( current & 0x2 )) && echo "    [!] ARM frequency capped RIGHT NOW" || echo "    [ ] ARM not capped"
    (( current & 0x4 )) && echo "    [!] CPU throttled RIGHT NOW" || echo "    [ ] CPU not throttled"
    echo ""
    echo "  History since boot (upper nibble = ${history}):"
    (( history & 0x1 )) && echo "    [!] Under-voltage occurred since boot" || echo "    [ ] No historical under-voltage"
    (( history & 0x4 )) && echo "    [!] Throttling occurred since boot" || echo "    [ ] No historical throttling"
    echo ""
    if [[ ${current} -ne 0 ]]; then
        echo "  >>> ACTIVE PROBLEM: PSU or cable is too weak for Pi 5 under load."
        echo "      Pi 5 needs 27W (5.1V/5A) USB-C. Try official Pi 5 PSU (SC1159)"
        echo "      or a shorter/thicker USB-C cable to reduce voltage drop."
    elif [[ ${history} -ne 0 ]]; then
        echo "  >>> Under-voltage occurred during boot (transient) but is clear now."
        echo "      Monitor whether it recurs under restore load."
    else
        echo "  >>> Power is clean."
    fi
else
    echo "vcgencmd not available — not running on a Raspberry Pi or firmware tools not installed."
fi

echo ""
echo "Undervoltage kernel events (dmesg):"
dmesg | grep -i "undervolt\|voltage normalised\|throttl" | tail -20 || echo "  (none)"

# ── Restore logs ──────────────────────────────────────────────────────────────
section "RESTORE LOGS (/var/log/pi2s3-restore-*.log)"

shopt -s nullglob
restore_logs=(/var/log/pi2s3-restore-[0-9]*.log)
if [[ ${#restore_logs[@]} -eq 0 ]]; then
    echo "No restore logs found in /var/log/."
    echo "  (Logs only exist if script ran as root with /var/log writable)"
else
    for f in "${restore_logs[@]}"; do
        echo ""
        echo ">>> ${f}  ($(wc -l < "${f}") lines, $(stat -c%s "${f}" 2>/dev/null || stat -f%z "${f}") bytes)"
        tail -40 "${f}"
    done
fi

# ── Monitor logs ──────────────────────────────────────────────────────────────
section "MONITOR LOGS (/var/log/pi2s3-restore-monitor-*.log)"

monitor_logs=(/var/log/pi2s3-restore-monitor-*.log)
if [[ ${#monitor_logs[@]} -eq 0 ]]; then
    echo "No monitor logs found."
else
    for f in "${monitor_logs[@]}"; do
        echo ""
        echo ">>> ${f}"
        cat "${f}"
    done
fi

# ── Storage ───────────────────────────────────────────────────────────────────
section "STORAGE (lsblk)"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null || lsblk

echo ""
echo "NVMe partitions:"
lsblk /dev/nvme0n1 2>/dev/null && fdisk -l /dev/nvme0n1 2>/dev/null || echo "  /dev/nvme0n1 not found — NVMe may be absent or not enumerated."

# ── Memory ────────────────────────────────────────────────────────────────────
section "MEMORY"
free -h

# ── CPU ───────────────────────────────────────────────────────────────────────
section "CPU"
echo "Cores: $(nproc)"
grep "^Model name\|^Hardware\|^Model" /proc/cpuinfo 2>/dev/null | head -3 || true
echo ""
echo "Current frequency:"
vcgencmd measure_clock arm 2>/dev/null || cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "  unavailable"

# ── Network ───────────────────────────────────────────────────────────────────
section "NETWORK"
ip -brief addr show 2>/dev/null || ifconfig 2>/dev/null | head -30
echo ""
echo "S3 reachability (af-south-1):"
if command -v aws &>/dev/null; then
    aws s3 ls s3:// --region af-south-1 --profile personal 2>/dev/null | head -3 || \
    aws s3 ls s3:// --region af-south-1 2>/dev/null | head -3 || \
    echo "  (aws CLI not configured or no access — check AWS credentials)"
else
    ping -c 2 -W 3 s3.af-south-1.amazonaws.com 2>/dev/null || echo "  s3.af-south-1.amazonaws.com unreachable"
fi

# ── Active restore processes ──────────────────────────────────────────────────
section "ACTIVE RESTORE PROCESSES"
ps aux | grep -E "pi-image-restore|partclone|aws.*s3|gunzip|pv" | grep -v grep || echo "  No restore processes running."

# ── Recent kernel messages ────────────────────────────────────────────────────
section "RECENT KERNEL MESSAGES (dmesg tail)"
dmesg | tail -30

echo ""
hr
echo "Diagnostic saved to: ${REPORT}"
echo "Share this file when reporting a restore issue."
hr
