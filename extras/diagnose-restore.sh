#!/usr/bin/env bash
# extras/diagnose-restore.sh — comprehensive pi2s3 restore diagnostic
#
# Run on the Pi after a restore fails, hangs, or behaves unexpectedly:
#   sudo bash extras/diagnose-restore.sh
#
# Covers: power/voltage, hardware health, restore size/completeness,
#         WiFi/network config, corporate proxy/firewall, AWS reachability.
#
# Saves full report to /var/log/pi2s3-diagnose-TIMESTAMP.log for sharing.
set -euo pipefail

REPORT="/var/log/pi2s3-diagnose-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "${REPORT}") 2>&1

hr()      { printf '%.0s─' {1..68}; echo; }
section() { echo ""; hr; printf "  %s\n" "$1"; hr; }
ok()      { printf "  [OK]  %s\n" "$*"; }
warn()    { printf "  [!!!] %s\n" "$*"; }
info()    { printf "  [ ]   %s\n" "$*"; }

echo "pi2s3 restore diagnostic"
echo "Generated: $(date)"
echo "Host:      $(hostname)"
echo "Uptime:    $(uptime)"

# ══════════════════════════════════════════════════════════════════════════════
section "1. POWER & VOLTAGE"
# ══════════════════════════════════════════════════════════════════════════════

if command -v vcgencmd &>/dev/null; then
    raw=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "0x0")
    current=$(( raw & 0xf ))
    history=$(( (raw >> 16) & 0xf ))

    echo "  get_throttled = ${raw}"
    echo ""
    echo "  Current state:"
    if (( current & 0x1 )); then
        warn "Under-voltage RIGHT NOW — restore will crash. Use 27W (5.1V/5A) USB-C PSU."
    else
        ok "No current under-voltage"
    fi
    if (( current & 0x2 )); then warn "ARM frequency capped RIGHT NOW"; else ok "ARM not capped"; fi
    if (( current & 0x4 )); then warn "CPU throttled RIGHT NOW"; else ok "CPU not throttled"; fi
    if (( current & 0x8 )); then warn "Soft temperature limit active"; else ok "Temperature OK"; fi

    echo ""
    echo "  Historical (since last boot):"
    if (( history & 0x1 )); then warn "Under-voltage occurred since boot"; else ok "No historical under-voltage"; fi
    if (( history & 0x4 )); then warn "Throttling occurred since boot"; else ok "No historical throttling"; fi

    echo ""
    echo "  Measured voltages:"
    for rail in core sdram_c sdram_i sdram_p; do
        v=$(vcgencmd measure_volts ${rail} 2>/dev/null || echo "unavailable")
        printf "    %-12s %s\n" "${rail}" "${v}"
    done

    echo ""
    echo "  CPU temperature:"
    temp=$(vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "temp=%.1f'"'"'C", $1/1000}' || echo "unavailable")
    echo "    ${temp}"

    echo ""
    echo "  Undervoltage kernel events (dmesg):"
    uv_count=$(dmesg | grep -c -i "undervolt" 2>/dev/null || echo "0")
    if [[ "${uv_count}" -gt 0 ]]; then
        warn "${uv_count} undervoltage events in dmesg:"
        dmesg | grep -i "undervolt\|voltage normalised" | tail -20 | sed 's/^/    /'
    else
        ok "No undervoltage events in dmesg"
    fi

    echo ""
    if [[ ${current} -ne 0 ]]; then
        echo "  >>> DIAGNOSIS: ACTIVE UNDER-VOLTAGE. Restore WILL fail."
        echo "      Pi 5 needs 27W (5.1V/5A) USB-C. Options:"
        echo "      1. Use official Pi 5 PSU (SC1159 / 5.1V/5A)"
        echo "      2. Use USB-C PD charger rated 27W+ that negotiates 5V/5A"
        echo "      3. Try a shorter/thicker USB-C cable — resistance drops voltage"
    elif [[ ${uv_count} -gt 2 ]]; then
        echo "  >>> DIAGNOSIS: INTERMITTENT UNDER-VOLTAGE (${uv_count} events)."
        echo "      PSU is marginal. May crash under sustained NVMe + network load."
        echo "      Upgrade to official Pi 5 PSU or higher-rated USB-C PD charger."
    else
        ok "Power looks healthy"
    fi
else
    info "vcgencmd not available — power diagnostics skipped"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "2. HARDWARE"
# ══════════════════════════════════════════════════════════════════════════════

echo "  CPU:"
echo "    Cores: $(nproc)"
grep -m1 "^Model\|^Hardware" /proc/cpuinfo 2>/dev/null | sed 's/^/    /' || true
if command -v vcgencmd &>/dev/null; then
    freq=$(vcgencmd measure_clock arm 2>/dev/null || echo "unavailable")
    echo "    Clock: ${freq}"
fi

echo ""
echo "  Memory:"
free -h | sed 's/^/    /'
echo ""
awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{
    pct=int((t-a)/t*100)
    printf "    Used: %d%% (%d MB used of %d MB)\n", pct, (t-a)/1024, t/1024
}' /proc/meminfo

echo ""
echo "  Storage:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null | sed 's/^/    /' || lsblk | sed 's/^/    /'

echo ""
echo "  NVMe:"
if [[ -b /dev/nvme0n1 ]]; then
    ok "/dev/nvme0n1 present"
    lsblk /dev/nvme0n1 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/    /' || true
    if command -v nvme &>/dev/null; then
        echo ""
        echo "    NVMe SMART (nvme-cli):"
        nvme smart-log /dev/nvme0n1 2>/dev/null | grep -E "temperature|available_spare|percentage_used|media_errors|power_on" | sed 's/^/      /' || echo "      (smart-log failed)"
    fi
else
    warn "/dev/nvme0n1 not found — NVMe absent or PCIe not enumerated"
    echo "    Kernel NVMe messages:"
    dmesg | grep -i "nvme\|pcie" | tail -10 | sed 's/^/      /' || echo "      (none)"
fi

echo ""
echo "  EEPROM boot order:"
if command -v rpi-eeprom-config &>/dev/null; then
    rpi-eeprom-config 2>/dev/null | grep -E "BOOT_ORDER|BOOT_UART|NET_INSTALL" | sed 's/^/    /' || echo "    (unavailable)"
    boot_order=$(rpi-eeprom-config 2>/dev/null | grep BOOT_ORDER | cut -d= -f2 || echo "")
    [[ -n "${boot_order}" ]] && echo "    (NVMe=6, SD=1, USB=4 — order is right-to-left in hex nibbles)"
else
    info "rpi-eeprom-config not available"
fi

echo ""
echo "  Hardware watchdog:"
for wdog in /dev/watchdog /dev/watchdog0; do
    if [[ -c "${wdog}" ]]; then
        owner=$(lsof "${wdog}" 2>/dev/null | awk 'NR>1{print $1, "PID="$2}' | head -3 || echo "  (lsof unavailable)")
        echo "    ${wdog} exists — held by: ${owner:-systemd (default)}"
    else
        echo "    ${wdog} not present"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
section "3. RESTORE SIZE & COMPLETENESS"
# ══════════════════════════════════════════════════════════════════════════════

echo "  Restore logs:"
shopt -s nullglob
restore_logs=(/var/log/pi2s3-restore-[0-9]*.log)
if [[ ${#restore_logs[@]} -eq 0 ]]; then
    warn "No restore logs found in /var/log/"
    info "(Logs persist here if script ran as root — /tmp logs are cleared on reboot)"
else
    for f in "${restore_logs[@]}"; do
        lines=$(wc -l < "${f}")
        size=$(stat -c%s "${f}" 2>/dev/null || stat -f%z "${f}" 2>/dev/null || echo "?")
        mtime=$(stat -c%y "${f}" 2>/dev/null | cut -d. -f1 || stat -f"%Sm" "${f}" 2>/dev/null || echo "?")
        echo ""
        echo "  >>> ${f}  (${lines} lines, ${size} bytes, modified ${mtime})"
        if grep -q "Restore complete" "${f}" 2>/dev/null; then
            ok "Contains 'Restore complete'"
        elif grep -qi "error\|failed\|abort" "${f}" 2>/dev/null; then
            warn "Contains error/failed/abort"
            grep -i "error\|failed\|abort" "${f}" | sed 's/^/      /'
        else
            warn "No 'Restore complete' — restore may be in progress or crashed"
        fi
        echo "  Last 20 lines:"
        tail -20 "${f}" | sed 's/^/    /'
    done
fi

echo ""
echo "  Monitor logs (CSV — timestamp,net_rx,net_tx,cpu_idle%,mem_free_mb,throttled):"
monitor_logs=(/var/log/pi2s3-restore-monitor-*.log)
if [[ ${#monitor_logs[@]} -eq 0 ]]; then
    warn "No monitor logs found"
else
    for f in "${monitor_logs[@]}"; do
        lines=$(wc -l < "${f}")
        echo ""
        echo "  >>> ${f}  (${lines} lines)"
        # Show first + last rows for summary
        head -2 "${f}" | sed 's/^/    /'
        [[ ${lines} -gt 3 ]] && echo "    ..." || true
        tail -3 "${f}" | sed 's/^/    /'

        # Analyse: how many rows had current undervoltage (throttled & 0xf != 0)
        uv_rows=$(awk -F, 'NR>1 && NF>=6 {
            hex=$6; gsub(/0x|0X/,"",hex)
            val=strtonum("0x" hex)
            if ((val % 16) != 0) count++
        } END{print count+0}' "${f}" 2>/dev/null || echo "0")
        total_rows=$(( lines - 1 ))
        if [[ ${uv_rows} -gt 0 ]]; then
            warn "${uv_rows}/${total_rows} monitor samples had active under-voltage during restore"
        else
            ok "No active under-voltage during monitored restore intervals"
        fi

        # Download speed summary
        if [[ ${lines} -gt 2 ]]; then
            awk -F, 'NR==2{start_rx=$2; start_ts=$1} NR>1{last_rx=$2; last_ts=$1}
            END{
                if (last_ts > start_ts) {
                    mb=(last_rx-start_rx)/1024/1024
                    secs=last_ts-start_ts
                    printf "    Download: %.0f MB in %ds = %.1f MB/s avg\n", mb, secs, mb/secs
                }
            }' "${f}" 2>/dev/null || true
        fi
    done
fi

echo ""
echo "  NVMe partition sizes (current state):"
if [[ -b /dev/nvme0n1 ]]; then
    fdisk -l /dev/nvme0n1 2>/dev/null | sed 's/^/    /' || sfdisk -l /dev/nvme0n1 2>/dev/null | sed 's/^/    /'
    echo ""
    echo "  Partition filesystem check:"
    for part in /dev/nvme0n1p1 /dev/nvme0n1p2 /dev/nvme0n1p3; do
        [[ -b "${part}" ]] || continue
        fstype=$(blkid -o value -s TYPE "${part}" 2>/dev/null || echo "unknown")
        size=$(lsblk -o SIZE -dn "${part}" 2>/dev/null || echo "?")
        echo "    ${part}  type=${fstype}  size=${size}"
        if [[ "${fstype}" == "ext4" ]]; then
            # Quick check — don't repair
            e2fsck -n "${part}" 2>&1 | tail -3 | sed 's/^/      /' || true
        elif [[ "${fstype}" == "vfat" ]]; then
            fsck.vfat -n "${part}" 2>&1 | tail -3 | sed 's/^/      /' || true
        fi
    done
else
    warn "/dev/nvme0n1 not present — cannot check partition state"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "4. WIFI & NETWORK CONFIG"
# ══════════════════════════════════════════════════════════════════════════════

echo "  Interfaces:"
ip -brief addr show 2>/dev/null | sed 's/^/    /' || ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | sed 's/^/    /'

echo ""
echo "  Default gateway:"
ip route show default 2>/dev/null | sed 's/^/    /' || route -n 2>/dev/null | grep "^0.0.0.0" | sed 's/^/    /' || echo "    (none)"

echo ""
echo "  DNS servers (/etc/resolv.conf):"
grep "^nameserver" /etc/resolv.conf 2>/dev/null | sed 's/^/    /' || echo "    (not found)"

echo ""
echo "  WiFi (nmcli):"
if command -v nmcli &>/dev/null; then
    echo "  Saved connections:"
    nmcli -t -f NAME,TYPE,DEVICE,STATE connection show 2>/dev/null | grep -i wifi | sed 's/^/    /' || echo "    (none)"
    echo ""
    echo "  Active WiFi:"
    nmcli -t -f active,ssid,signal,bars,security dev wifi 2>/dev/null | grep "^yes" | sed 's/^/    /' || echo "    Not connected to WiFi"
    echo ""
    echo "  Saved WiFi password health:"
    while IFS= read -r conn_name; do
        [[ -z "${conn_name}" ]] && continue
        ssid=$(nmcli -s -g 802-11-wireless.ssid connection show "${conn_name}" 2>/dev/null || echo "?")
        psk=$(nmcli -s -g 802-11-wireless-security.psk connection show "${conn_name}" 2>/dev/null || echo "")
        country=$(nmcli -s -g 802-11-wireless.band connection show "${conn_name}" 2>/dev/null || echo "")
        len=${#psk}
        # Detect chars that break sshpass/shell quoting
        if [[ "${psk}" =~ [\'\"\\] ]]; then
            warn "'${conn_name}' (SSID=${ssid}) — password has quote/backslash chars — sshpass WILL fail"
            echo "         Use paramiko invoke_shell() for automation with this password"
        elif [[ "${psk}" =~ [@\&\!\$\#\%\^\*\(\)\+\[\]\{\}\;\:\,\.\<\>\/\?] ]]; then
            warn "'${conn_name}' (SSID=${ssid}) — password has special chars (len=${len}) — sshpass may fail"
        elif [[ ${len} -eq 0 ]]; then
            info "'${conn_name}' (SSID=${ssid}) — open network (no PSK)"
        else
            ok "'${conn_name}' (SSID=${ssid}) — password safe for shell automation (len=${len})"
        fi
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -i wifi | cut -d: -f1)
else
    info "nmcli not available — WiFi diagnostics limited"
    iwconfig 2>/dev/null | grep -E "ESSID|Signal" | sed 's/^/    /' || true
fi

# ══════════════════════════════════════════════════════════════════════════════
section "5. CORPORATE NETWORK / PROXY / FIREWALL"
# ══════════════════════════════════════════════════════════════════════════════

echo "  Proxy environment variables:"
found_proxy=0
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY all_proxy ALL_PROXY; do
    val="${!v:-}"
    if [[ -n "${val}" ]]; then
        warn "${v}=${val}"
        found_proxy=1
    fi
done
[[ ${found_proxy} -eq 0 ]] && ok "No proxy env vars set"

echo ""
echo "  System proxy config (/etc/environment, /etc/profile.d/proxy*):"
for f in /etc/environment /etc/profile.d/proxy.sh /etc/profile.d/proxy.conf; do
    [[ -f "${f}" ]] && grep -i proxy "${f}" 2>/dev/null | sed "s|^|    ${f}: |" || true
done

echo ""
echo "  iptables / nftables rules (outbound):"
if command -v iptables &>/dev/null; then
    iptables -L OUTPUT -n --line-numbers 2>/dev/null | head -20 | sed 's/^/    /' || echo "    (iptables unavailable)"
elif command -v nft &>/dev/null; then
    nft list ruleset 2>/dev/null | grep -A3 "output" | head -20 | sed 's/^/    /' || echo "    (nft unavailable)"
else
    info "No firewall tool found"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "6. INTERNET & AWS REACHABILITY"
# ══════════════════════════════════════════════════════════════════════════════

check_host() {
    local label="$1" host="$2" port="${3:-443}"
    if timeout 5 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
        ok "${label} (${host}:${port}) — reachable"
    else
        warn "${label} (${host}:${port}) — UNREACHABLE"
    fi
}

echo "  Basic connectivity & packet loss:"
ping_check() {
    local label="$1" host="$2"
    [[ -z "${host}" ]] && { warn "${label} — no host to ping"; return; }
    local result
    result=$(ping -c 10 -W 2 -q "${host}" 2>/dev/null | grep -E "packets|rtt" || echo "failed")
    local loss
    loss=$(echo "${result}" | grep -oP '\d+(?=% packet loss)' || echo "100")
    if [[ "${loss}" -eq 0 ]]; then
        ok "${label} (${host}) — 0% loss"
    elif [[ "${loss}" -lt 10 ]]; then
        warn "${label} (${host}) — ${loss}% packet loss (marginal — may cause S3 stalls)"
    elif [[ "${loss}" -lt 100 ]]; then
        warn "${label} (${host}) — ${loss}% PACKET LOSS (HIGH — will cause restore failures)"
    else
        warn "${label} (${host}) — UNREACHABLE"
    fi
    echo "${result}" | grep -E "rtt|round-trip" | sed 's/^/    /' || true
}
gateway=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
ping_check "Gateway"    "${gateway}"
ping_check "Internet"   "8.8.8.8"
ping_check "Cloudflare" "1.1.1.1"

echo ""
echo "  DNS resolution:"
if host google.com &>/dev/null 2>&1 || nslookup google.com &>/dev/null 2>&1; then
    ok "DNS resolves google.com"
else
    warn "DNS resolution failed for google.com"
fi
if host s3.af-south-1.amazonaws.com &>/dev/null 2>&1 || nslookup s3.af-south-1.amazonaws.com &>/dev/null 2>&1; then
    ok "DNS resolves s3.af-south-1.amazonaws.com"
else
    warn "DNS resolution failed for s3.af-south-1.amazonaws.com — S3 downloads will fail"
fi

echo ""
echo "  HTTPS reachability:"
check_host "AWS S3 af-south-1" "s3.af-south-1.amazonaws.com" 443
check_host "AWS STS (auth)"    "sts.amazonaws.com"            443
check_host "ntfy.sh (alerts)"  "ntfy.sh"                      443
check_host "GitHub"            "github.com"                   443

echo ""
echo "  AWS CLI:"
if command -v aws &>/dev/null; then
    ok "aws CLI installed: $(aws --version 2>&1 | head -1)"
    echo ""
    echo "  Configured profiles:"
    aws configure list-profiles 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    echo ""
    echo "  S3 bucket access test:"
    for profile in personal default ""; do
        args=(s3 ls s3://your-s3-bucket-name/ --region af-south-1)
        [[ -n "${profile}" ]] && args+=(--profile "${profile}")
        label="${profile:-<no profile>}"
        if aws "${args[@]}" &>/dev/null 2>&1; then
            ok "s3://your-s3-bucket-name/ accessible with profile=${label}"
            break
        else
            err=$(aws "${args[@]}" 2>&1 | tail -1)
            warn "s3://your-s3-bucket-name/ NOT accessible with profile=${label}: ${err}"
        fi
    done
    echo ""
    echo "  AWS identity:"
    aws sts get-caller-identity --region af-south-1 --profile personal 2>/dev/null | sed 's/^/    /' || \
    aws sts get-caller-identity --region af-south-1 2>/dev/null | sed 's/^/    /' || \
    echo "    (sts get-caller-identity failed — credentials missing or expired)"
else
    warn "aws CLI not installed — S3 restore not possible"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "7. ACTIVE RESTORE PROCESSES"
# ══════════════════════════════════════════════════════════════════════════════

procs=$(ps aux | grep -E "pi-image-restore|partclone|aws.*s3|gunzip|pv" | grep -v grep || echo "")
if [[ -n "${procs}" ]]; then
    ok "Restore processes running:"
    echo "${procs}" | sed 's/^/    /'
else
    info "No restore processes currently running"
fi

echo ""
echo "  CPU affinity of restore pipeline (taskset):"
for name in aws gunzip pv partclone; do
    pids=$(pgrep -x "${name}" 2>/dev/null || true)
    for pid in ${pids}; do
        affinity=$(taskset -cp "${pid}" 2>/dev/null || echo "unavailable")
        echo "    ${name} (PID ${pid}): ${affinity}"
    done
done

# ══════════════════════════════════════════════════════════════════════════════
section "8. BOOT CONFIG"
# ══════════════════════════════════════════════════════════════════════════════

echo "  Current cmdline.txt (active boot):"
cat /proc/cmdline | tr ' ' '\n' | sed 's/^/    /'

echo ""
echo "  Boot partition cmdline.txt:"
boot_cmdline=""
for p in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    if [[ -f "${p}" ]]; then
        echo "  ${p}:"
        cat "${p}" | tr ' ' '\n' | sed 's/^/    /'
        boot_cmdline="${p}"
        break
    fi
done

echo ""
echo "  NVMe boot cmdline.txt (if mounted):"
nvme_boot=""
for p in /dev/nvme0n1p1 /dev/nvme0n1; do
    [[ -b "${p}" ]] || continue
    mp=$(mktemp -d)
    if mount -o ro,noatime "${p}" "${mp}" 2>/dev/null; then
        for cf in "${mp}/cmdline.txt" "${mp}/firmware/cmdline.txt"; do
            if [[ -f "${cf}" ]]; then
                echo "  ${p} → ${cf}:"
                cat "${cf}" | tr ' ' '\n' | sed 's/^/    /'
                nvme_boot="${cf}"
                if grep -q "rootdelay" "${cf}"; then
                    ok "rootdelay present in NVMe cmdline.txt — NVMe boot should work"
                else
                    warn "rootdelay NOT in NVMe cmdline.txt — NVMe may fail to boot (run post-restore-nvme-boot.sh)"
                fi
            fi
        done
        umount "${mp}" 2>/dev/null || true
    fi
    rmdir "${mp}" 2>/dev/null || true
done
[[ -z "${nvme_boot}" ]] && info "Could not mount NVMe boot partition to check cmdline.txt"

# ══════════════════════════════════════════════════════════════════════════════
section "9. RECENT KERNEL MESSAGES"
# ══════════════════════════════════════════════════════════════════════════════
dmesg | tail -40 | sed 's/^/  /'

# ══════════════════════════════════════════════════════════════════════════════
echo ""
hr
echo "  Diagnostic complete."
echo "  Report saved to: ${REPORT}"
echo "  Share this file when reporting a restore issue."
hr
