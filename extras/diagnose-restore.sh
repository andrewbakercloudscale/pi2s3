#!/usr/bin/env bash
# extras/diagnose-restore.sh — pi2s3 restore diagnostic
#
# Run on the Pi after a restore fails, hangs, or behaves unexpectedly:
#   sudo bash extras/diagnose-restore.sh
#
# Every FAIL/WARN prints the exact fix command. A summary at the end
# lists every issue found so you don't have to scroll.
#
# Saves full report to /var/log/pi2s3-diagnose-TIMESTAMP.log for sharing.
set -euo pipefail

REPORT="/var/log/pi2s3-diagnose-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee "${REPORT}") 2>&1

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Output helpers ────────────────────────────────────────────────────────────
_ISSUES=()   # collected for summary

hr()      { printf '%.0s─' {1..68}; echo; }
section() { echo ""; hr; printf "${BOLD}  %s${NC}\n" "$1"; hr; }
ok()      { printf "  ${GREEN}[OK]${NC}    %s\n" "$*"; }
info()    { printf "  ${CYAN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "  ${YELLOW}[WARN]${NC}  %s\n" "$*"; _ISSUES+=("WARN  | $*"); }
fail()    { printf "  ${RED}[FAIL]${NC}  %s\n" "$*"; _ISSUES+=("FAIL  | $*"); }
fix()     { printf "         ${CYAN}fix:${NC} %s\n" "$*"; }

_START=$(date +%s)

printf "${BOLD}pi2s3 restore diagnostic${NC}\n"
echo "Generated: $(date)"
echo "Host:      $(hostname)"
echo "Uptime:    $(uptime -p 2>/dev/null || uptime)"

# ── Load config.env early ────────────────────────────────────────────────────
_CFG=""
for _c in /tmp/pi2s3-config.env \
          "$(pwd)/config.env" \
          "${HOME}/pi2s3/config.env" \
          /etc/pi2s3/config.env; do
    [[ -f "${_c}" ]] && _CFG="${_c}" && break
done
[[ -z "${_CFG}" ]] && _CFG=$(find /home /root -maxdepth 4 -name 'config.env' 2>/dev/null | head -1 || true)
if [[ -n "${_CFG}" ]]; then
    set -a; source "${_CFG}"; set +a
    echo "Config:    ${_CFG}"
else
    echo "Config:    not found (run from pi2s3 directory or place config.env in /etc/pi2s3/)"
fi
S3_BUCKET="${S3_BUCKET:-}"
S3_REGION="${S3_REGION:-}"
WIFI_SSID="${WIFI_SSID:-}"

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
        fail "UNDER-VOLTAGE RIGHT NOW — restore WILL crash"
        fix "Use official Pi 5 PSU (5.1V / 5A / 27W, SC1159). Short/thin cable also drops voltage."
    else
        ok "No under-voltage"
    fi
    if (( current & 0x4 )); then
        warn "CPU throttled right now (thermal or voltage)"
    else
        ok "CPU not throttled"
    fi
    if (( current & 0x8 )); then
        warn "Soft temperature limit active — consider heatsink/fan"
    else
        ok "Temperature OK"
    fi

    echo ""
    echo "  Since last boot:"
    if (( history & 0x1 )); then
        warn "Under-voltage event(s) since boot — PSU is marginal"
        fix "Upgrade to official Pi 5 PSU or 27W+ USB-C PD charger"
    else
        ok "No historical under-voltage"
    fi
    if (( history & 0x4 )); then
        warn "CPU was throttled since boot"
    else
        ok "No historical throttling"
    fi

    echo ""
    echo "  Voltages:"
    for rail in core sdram_c sdram_i sdram_p; do
        v=$(vcgencmd measure_volts ${rail} 2>/dev/null || echo "unavailable")
        printf "    %-12s %s\n" "${rail}" "${v}"
    done
    temp=$(vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null \
           | awk '{printf "temp=%.1f'"'"'C", $1/1000}' || echo "unavailable")
    echo ""
    echo "  Temperature: ${temp}"

    uv_count=$(dmesg | grep -c -i "undervolt" 2>/dev/null || echo "0")
    if [[ "${uv_count}" -gt 0 ]]; then
        warn "${uv_count} undervoltage event(s) in kernel log"
        dmesg | grep -i "undervolt\|voltage normalised" | tail -10 | sed 's/^/    /'
    fi
else
    info "vcgencmd not available — power check skipped"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "2. HARDWARE"
# ══════════════════════════════════════════════════════════════════════════════

echo "  CPU:"
echo "    Cores : $(nproc)"
grep -m1 "^Model\|^Hardware" /proc/cpuinfo 2>/dev/null | sed 's/^/    /' || true
if command -v vcgencmd &>/dev/null; then
    echo "    Clock : $(vcgencmd measure_clock arm 2>/dev/null || echo unavailable)"
fi

echo ""
echo "  Memory:"
free -h | sed 's/^/    /'
awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{
    pct=int((t-a)/t*100)
    printf "    Used: %d%% (%d MB / %d MB)\n", pct, (t-a)/1024, t/1024
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
        nvme smart-log /dev/nvme0n1 2>/dev/null \
            | grep -E "temperature|available_spare|percentage_used|media_errors|power_on" \
            | sed 's/^/    /' || true
    fi
else
    fail "/dev/nvme0n1 not found — NVMe absent or PCIe not enumerated"
    fix "Check NVMe is seated. Reboot with rootdelay=5 in cmdline.txt (run post-restore-nvme-boot.sh)."
    echo "    Kernel messages:"
    dmesg | grep -i "nvme\|pcie" | tail -8 | sed 's/^/      /' || echo "      (none)"
fi

echo ""
echo "  EEPROM boot order:"
if command -v rpi-eeprom-config &>/dev/null; then
    rpi-eeprom-config 2>/dev/null | grep -E "BOOT_ORDER|BOOT_UART" | sed 's/^/    /' || echo "    (unavailable)"
    echo "    (NVMe=6, SD=1, USB=4 — nibbles read right-to-left)"
else
    info "rpi-eeprom-config not available"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "3. WIFI & NETWORK"
# ══════════════════════════════════════════════════════════════════════════════

echo "  Interfaces:"
ip -brief addr show 2>/dev/null | sed 's/^/    /' \
    || ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | sed 's/^/    /'

echo ""
echo "  Default gateway:"
gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
if [[ -n "${gw}" ]]; then
    echo "    ${gw}"
else
    fail "No default gateway — not connected to any network"
    fix "Check WiFi credentials in /etc/NetworkManager/system-connections/ or re-run cloud-init"
fi

echo ""
echo "  DNS (resolv.conf):"
mapfile -t _ns < <(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}')
if [[ ${#_ns[@]} -eq 0 ]]; then
    fail "No nameservers in /etc/resolv.conf"
    fix "echo 'nameserver 1.1.1.1' > /etc/resolv.conf  # temporary — NM should set this on connect"
else
    for _n in "${_ns[@]}"; do
        if timeout 3 bash -c "echo >/dev/tcp/${_n}/53" 2>/dev/null; then
            ok "nameserver ${_n} — reachable (TCP/53)"
        else
            fail "nameserver ${_n} — UNREACHABLE — resolv.conf is stale from backup"
            fix "This IP is from a different network (e.g. home router). NM should overwrite it on connect."
            fix "Temporary fix: echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
            fix "Permanent fix: ensure NM manages DNS (dns=default in /etc/NetworkManager/NetworkManager.conf)"
        fi
    done
fi

if command -v nmcli &>/dev/null; then
    echo ""
    echo "  Saved WiFi connections:"
    nmcli -t -f NAME,TYPE,DEVICE,STATE connection show 2>/dev/null | grep -i wifi \
        | sed 's/^/    /' || echo "    (none)"

    echo ""
    echo "  Active WiFi:"
    active_ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep "^yes" | cut -d: -f2 || true)
    if [[ -n "${active_ssid}" ]]; then
        nmcli -t -f active,ssid,signal,bars,security dev wifi 2>/dev/null | grep "^yes" | sed 's/^/    /'
    else
        fail "Not connected to any WiFi network"
        echo "    Visible networks:"
        nmcli -t -f ssid,signal dev wifi list 2>/dev/null | sort -t: -k2 -rn | head -10 \
            | awk -F: '{printf "      %-32s signal=%s\n", $1, $2}'
        if [[ -n "${WIFI_SSID}" ]]; then
            fix "sudo nmcli dev wifi connect \"${WIFI_SSID}\" password \"<password>\""
        else
            fix "Set WIFI_SSID in config.env, then re-run"
        fi
    fi

    echo ""
    echo "  SSID cross-check:"
    if [[ -z "${WIFI_SSID}" ]]; then
        warn "WIFI_SSID not set in config.env — cannot verify correct network"
        fix "Add WIFI_SSID=YourNetworkName to config.env"
    elif [[ -z "${active_ssid}" ]]; then
        : # already handled above
    elif [[ "${active_ssid}" == "${WIFI_SSID}" ]]; then
        ok "Connected to '${active_ssid}' — matches config.env"
    else
        fail "Connected to '${active_ssid}' but config.env WIFI_SSID='${WIFI_SSID}'"
        echo "    Visible networks:"
        nmcli -t -f ssid,signal dev wifi list 2>/dev/null | sort -t: -k2 -rn | head -10 \
            | awk -F: '{printf "      %-32s signal=%s\n", $1, $2}'
        fix "Update WIFI_SSID in config.env to '${active_ssid}', or connect to the right network:"
        fix "sudo nmcli dev wifi connect \"${WIFI_SSID}\" password \"<password>\""
    fi

    echo ""
    echo "  Saved WiFi password health:"
    while IFS= read -r conn_name; do
        [[ -z "${conn_name}" ]] && continue
        ssid=$(nmcli -s -g 802-11-wireless.ssid connection show "${conn_name}" 2>/dev/null || echo "?")
        psk=$(nmcli -s -g 802-11-wireless-security.psk connection show "${conn_name}" 2>/dev/null || echo "")
        len=${#psk}
        if [[ "${psk}" =~ [\'\"\\] ]]; then
            warn "'${conn_name}' (SSID=${ssid}) — password has quote/backslash chars"
            fix "Use paramiko invoke_shell() instead of sshpass for this connection"
        elif [[ "${psk}" =~ [@\&\!\$\#\%\^\*\(\)\+\[\]\{\}\;\:\,\.\<\>\/\?] ]]; then
            warn "'${conn_name}' (SSID=${ssid}) — special chars in password (len=${len}) — sshpass may fail"
        elif [[ ${len} -eq 0 ]]; then
            info "'${conn_name}' (SSID=${ssid}) — open network"
        else
            ok "'${conn_name}' (SSID=${ssid}) — password OK (len=${len})"
        fi
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -i wifi | cut -d: -f1)
else
    info "nmcli not available"
    iwconfig 2>/dev/null | grep -E "ESSID|Signal" | sed 's/^/    /' || true
fi

# ══════════════════════════════════════════════════════════════════════════════
section "4. INTERNET & AWS REACHABILITY"
# ══════════════════════════════════════════════════════════════════════════════

check_host() {
    local label="$1" host="$2" port="${3:-443}"
    if timeout 5 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
        ok "${label} (${host}:${port})"
    else
        fail "${label} (${host}:${port}) — UNREACHABLE"
    fi
}

ping_check() {
    local label="$1" host="$2"
    [[ -z "${host}" ]] && { warn "${label} — no host (gateway missing?)"; return; }
    local result loss
    result=$(ping -c 6 -W 2 -q "${host}" 2>/dev/null | grep -E "packets|rtt" || echo "failed")
    loss=$(echo "${result}" | grep -oP '\d+(?=% packet loss)' || echo "100")
    if   [[ "${loss}" -eq 0 ]];   then ok   "${label} (${host}) — 0% packet loss"
    elif [[ "${loss}" -lt 10 ]];  then warn "${label} (${host}) — ${loss}% loss (marginal)"
    elif [[ "${loss}" -lt 100 ]]; then fail "${label} (${host}) — ${loss}% PACKET LOSS — will break restore"
    else                               fail "${label} (${host}) — unreachable"
    fi
    echo "${result}" | grep -E "rtt|round-trip" | sed 's/^/    /' || true
}

gw2=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
ping_check "Gateway"    "${gw2}"
ping_check "Internet"   "8.8.8.8"
ping_check "Cloudflare" "1.1.1.1"

echo ""
echo "  DNS resolution:"
if host google.com &>/dev/null 2>&1 || nslookup google.com &>/dev/null 2>&1; then
    ok "DNS resolves google.com"
else
    fail "DNS resolution failed"
    fix "Check /etc/resolv.conf — should have nameserver 8.8.8.8 or similar"
fi

_s3_endpoint="s3.${S3_REGION:-us-east-1}.amazonaws.com"
if [[ -n "${S3_REGION}" ]]; then
    if host "${_s3_endpoint}" &>/dev/null 2>&1 || nslookup "${_s3_endpoint}" &>/dev/null 2>&1; then
        ok "DNS resolves ${_s3_endpoint}"
    else
        fail "DNS cannot resolve ${_s3_endpoint}"
        fix "Corporate DNS may be blocking AWS. Try: echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
    fi
fi

echo ""
echo "  HTTPS reachability:"
if [[ -n "${S3_REGION}" ]]; then
    check_host "AWS S3 (${S3_REGION})" "${_s3_endpoint}" 443
fi
check_host "AWS STS (auth)"  "sts.amazonaws.com"  443
check_host "Cloudflare CDN"  "cloudflare.com"     443
check_host "GitHub"          "github.com"         443
check_host "ntfy.sh"         "ntfy.sh"            443

echo ""
echo "  AWS CLI:"
if command -v aws &>/dev/null; then
    ok "aws CLI: $(aws --version 2>&1 | head -1)"
    aws configure list-profiles 2>/dev/null | sed 's/^/    profiles: /' || true
    if [[ -n "${S3_BUCKET}" ]]; then
        echo ""
        echo "  S3 bucket test (s3://${S3_BUCKET}/ region=${S3_REGION}):"
        _ok=0
        for profile in personal default ""; do
            args=(s3 ls "s3://${S3_BUCKET}/" --region "${S3_REGION:-us-east-1}")
            [[ -n "${profile}" ]] && args+=(--profile "${profile}")
            label="${profile:-<no profile>}"
            if aws "${args[@]}" &>/dev/null 2>&1; then
                ok "s3://${S3_BUCKET}/ accessible (profile=${label})"; _ok=1; break
            else
                _err=$(aws "${args[@]}" 2>&1 | tail -1)
                warn "profile=${label}: ${_err}"
            fi
        done
        if [[ ${_ok} -eq 0 ]]; then
            fail "Cannot access s3://${S3_BUCKET}/ with any credential profile"
            fix "Run: aws configure --profile personal   (enter Access Key + Secret)"
            fix "Or:  aws s3 ls s3://${S3_BUCKET}/ --region ${S3_REGION} --profile personal"
        fi
    else
        warn "S3_BUCKET not set in config.env — skipping bucket test"
        fix "Add S3_BUCKET=your-bucket-name to config.env"
    fi
    echo ""
    echo "  AWS identity:"
    aws sts get-caller-identity --region "${S3_REGION:-us-east-1}" --profile personal 2>/dev/null \
        | sed 's/^/    /' \
        || aws sts get-caller-identity --region "${S3_REGION:-us-east-1}" 2>/dev/null \
        | sed 's/^/    /' \
        || echo "    (sts failed — credentials missing or expired)"
else
    fail "aws CLI not installed — S3 restore impossible"
    fix "sudo apt-get install -y awscli"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "5. CORPORATE PROXY / FIREWALL"
# ══════════════════════════════════════════════════════════════════════════════

found_proxy=0
echo "  Proxy environment variables:"
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
    val="${!v:-}"
    if [[ -n "${val}" ]]; then
        warn "${v}=${val}"
        found_proxy=1
    fi
done
[[ ${found_proxy} -eq 0 ]] && ok "No proxy env vars set"

echo ""
for f in /etc/environment /etc/profile.d/proxy.sh /etc/profile.d/proxy.conf; do
    [[ -f "${f}" ]] && grep -i proxy "${f}" 2>/dev/null | sed "s|^|  ${f}: |" || true
done

echo ""
echo "  Outbound firewall (iptables OUTPUT):"
if command -v iptables &>/dev/null; then
    iptables -L OUTPUT -n --line-numbers 2>/dev/null | head -20 | sed 's/^/    /' \
        || echo "    (iptables unavailable)"
elif command -v nft &>/dev/null; then
    nft list ruleset 2>/dev/null | grep -A3 "output" | head -20 | sed 's/^/    /' \
        || echo "    (nft unavailable)"
else
    info "No firewall tool found"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "6. RESTORE LOGS & COMPLETENESS"
# ══════════════════════════════════════════════════════════════════════════════

shopt -s nullglob
restore_logs=(/var/log/pi2s3-restore-[0-9]*.log)
if [[ ${#restore_logs[@]} -eq 0 ]]; then
    warn "No restore logs found in /var/log/"
    info "(Must run restore as root to persist logs there)"
else
    for f in "${restore_logs[@]}"; do
        lines=$(wc -l < "${f}")
        mtime=$(stat -c%y "${f}" 2>/dev/null | cut -d. -f1 || stat -f"%Sm" "${f}" 2>/dev/null || echo "?")
        echo ""
        echo "  ${f}  (${lines} lines, ${mtime})"
        if grep -q "Restore complete" "${f}" 2>/dev/null; then
            ok "Restore completed successfully"
        elif grep -qi "error\|failed\|abort" "${f}" 2>/dev/null; then
            fail "Restore log contains errors"
            grep -i "error\|failed\|abort" "${f}" | tail -5 | sed 's/^/    /'
        else
            warn "No 'Restore complete' line — restore may have crashed or is still running"
        fi
        echo "  Last 15 lines:"
        tail -15 "${f}" | sed 's/^/    /'
    done
fi

echo ""
monitor_logs=(/var/log/pi2s3-restore-monitor-*.log)
if [[ ${#monitor_logs[@]} -gt 0 ]]; then
    echo "  Monitor logs:"
    for f in "${monitor_logs[@]}"; do
        lines=$(wc -l < "${f}")
        echo ""
        echo "  ${f}  (${lines} lines)"
        head -2 "${f}" | sed 's/^/    /'
        [[ ${lines} -gt 3 ]] && echo "    ..."
        tail -3 "${f}" | sed 's/^/    /'
        uv_rows=$(awk -F, 'NR>1 && NF>=6 {
            hex=$6; gsub(/0x|0X/,"",hex)
            val=strtonum("0x" hex)
            if ((val % 16) != 0) count++
        } END{print count+0}' "${f}" 2>/dev/null || echo "0")
        if [[ ${uv_rows} -gt 0 ]]; then
            fail "${uv_rows}/$((lines-1)) samples had active under-voltage during restore"
            fix "Replace PSU — use official Pi 5 27W USB-C power supply"
        else
            ok "No under-voltage during restore"
        fi
        if [[ ${lines} -gt 2 ]]; then
            awk -F, 'NR==2{s=$2;st=$1} NR>1{lr=$2;lt=$1}
                END{if(lt>st){mb=(lr-s)/1024/1024;secs=lt-st
                    printf "    Speed: %.0f MB in %ds = %.1f MB/s avg\n",mb,secs,mb/secs}}' \
                "${f}" 2>/dev/null || true
        fi
    done
fi

echo ""
echo "  NVMe partition state:"
if [[ -b /dev/nvme0n1 ]]; then
    fdisk -l /dev/nvme0n1 2>/dev/null | grep -E "^Disk|^/dev" | sed 's/^/    /' \
        || sfdisk -l /dev/nvme0n1 2>/dev/null | grep -E "^Disk|^/dev" | sed 's/^/    /'
    echo ""
    for part in /dev/nvme0n1p1 /dev/nvme0n1p2 /dev/nvme0n1p3; do
        [[ -b "${part}" ]] || continue
        fstype=$(blkid -o value -s TYPE "${part}" 2>/dev/null || echo "unknown")
        size=$(lsblk -o SIZE -dn "${part}" 2>/dev/null || echo "?")
        printf "    %-18s type=%-8s size=%s\n" "${part}" "${fstype}" "${size}"
        if [[ "${fstype}" == "ext4" ]]; then
            e2fsck -n "${part}" 2>&1 | tail -2 | sed 's/^/      /' || true
        elif [[ "${fstype}" == "vfat" ]]; then
            fsck.vfat -n "${part}" 2>&1 | tail -2 | sed 's/^/      /' || true
        fi
    done
else
    warn "NVMe not present — cannot check partitions"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "7. ACTIVE RESTORE PROCESSES"
# ══════════════════════════════════════════════════════════════════════════════

procs=$(ps aux | grep -E "pi-image-restore|partclone|aws.*s3|gunzip|pv" | grep -v grep || true)
if [[ -n "${procs}" ]]; then
    ok "Restore pipeline is running:"
    echo "${procs}" | sed 's/^/    /'
else
    info "No restore processes running"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "8. BOOT CONFIG"
# ══════════════════════════════════════════════════════════════════════════════

echo "  Active kernel cmdline (/proc/cmdline):"
cat /proc/cmdline | tr ' ' '\n' | sed 's/^/    /'

echo ""
echo "  Boot partition cmdline.txt:"
for p in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    if [[ -f "${p}" ]]; then
        echo "  ${p}:"
        cat "${p}" | tr ' ' '\n' | sed 's/^/    /'
        break
    fi
done

echo ""
echo "  PARTUUID cross-check:"
sd_cmdline=""
for p in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "${p}" ]] && sd_cmdline="${p}" && break
done
if [[ -n "${sd_cmdline}" ]]; then
    cmdline_partuuid=$(grep -oP 'root=PARTUUID=\K[a-f0-9-]+' "${sd_cmdline}" 2>/dev/null || true)
    if [[ -z "${cmdline_partuuid}" ]]; then
        fail "root=PARTUUID= is empty or missing in ${sd_cmdline} — Pi will NOT boot"
        NVME_PU=$(blkid -s PARTUUID -o value /dev/nvme0n1p2 2>/dev/null || true)
        if [[ -n "${NVME_PU}" ]]; then
            fix "sudo sed -i 's|root=PARTUUID=[^ ]*|root=PARTUUID=${NVME_PU}|' ${sd_cmdline}"
        fi
        [[ -f "${sd_cmdline}.bak" ]] && fix "sudo cp ${sd_cmdline}.bak ${sd_cmdline}"
    else
        matched=0
        for part in /dev/nvme0n1p2 /dev/nvme0n1p1 /dev/mmcblk0p2 /dev/mmcblk0p1; do
            [[ -b "${part}" ]] || continue
            actual=$(blkid -s PARTUUID -o value "${part}" 2>/dev/null || true)
            if [[ "${actual}" == "${cmdline_partuuid}" ]]; then
                ok "root=PARTUUID=${cmdline_partuuid} → ${part}"
                matched=1; break
            fi
        done
        if [[ ${matched} -eq 0 ]]; then
            fail "root=PARTUUID=${cmdline_partuuid} does not match any partition — Pi will NOT boot"
            NVME_PU=$(blkid -s PARTUUID -o value /dev/nvme0n1p2 2>/dev/null || true)
            if [[ -n "${NVME_PU}" ]]; then
                echo "    NVMe p2 PARTUUID: ${NVME_PU}"
                fix "sudo sed -i 's|root=PARTUUID=[^ ]*|root=PARTUUID=${NVME_PU}|' ${sd_cmdline}"
            fi
            [[ -f "${sd_cmdline}.bak" ]] && fix "sudo cp ${sd_cmdline}.bak ${sd_cmdline}"
        fi
    fi
    if grep -q "rootdelay" "${sd_cmdline}"; then
        ok "rootdelay present in cmdline.txt"
    else
        warn "rootdelay missing from cmdline.txt — NVMe may not enumerate in time"
        fix "sudo bash extras/post-restore-nvme-boot.sh"
    fi
    cloud_init_id=$(grep -oP 'ds=nocloud;i=\K\S+' "${sd_cmdline}" 2>/dev/null || true)
    if [[ -n "${cloud_init_id}" ]]; then
        info "cloud-init instance-id in cmdline: ${cloud_init_id}"
    fi
else
    info "No cmdline.txt found"
fi

echo ""
echo "  cloud-init instance-id cross-check (meta-data vs NVMe cache):"
meta_data_id=""
for p in /boot/firmware/meta-data /boot/meta-data; do
    [[ -f "${p}" ]] && meta_data_id=$(grep -oP 'instance-id:\s*\K\S+' "${p}" 2>/dev/null || true) && break
done
cached_id=$(cat /var/lib/cloud/data/instance-id 2>/dev/null || true)
if [[ -z "${meta_data_id}" ]]; then
    warn "No meta-data file found — cloud-init may not run on next boot"
    fix "Create /boot/firmware/meta-data with: instance-id: $(date +%s)"
else
    printf "    %-30s %s\n" "meta-data instance-id:" "${meta_data_id}"
    printf "    %-30s %s\n" "NVMe cached instance-id:" "${cached_id:-<none>}"
    if [[ -n "${cached_id}" ]] && [[ "${meta_data_id}" == "${cached_id}" ]]; then
        fail "meta-data instance-id '${meta_data_id}' matches NVMe cache — cloud-init will SKIP all runcmd on next boot"
        fix "Update instance-id in /boot/firmware/meta-data to a new value, e.g.:"
        fix "echo 'instance-id: pi2s3-$(date +%s)' > /boot/firmware/meta-data"
    else
        ok "meta-data instance-id '${meta_data_id}' is new — cloud-init will run on next boot"
    fi
fi

echo ""
echo "  NVMe boot cmdline.txt:"
for p in /dev/nvme0n1p1 /dev/nvme0n1; do
    [[ -b "${p}" ]] || continue
    mp=$(mktemp -d)
    if mount -o ro,noatime "${p}" "${mp}" 2>/dev/null; then
        for cf in "${mp}/cmdline.txt" "${mp}/firmware/cmdline.txt"; do
            if [[ -f "${cf}" ]]; then
                echo "  ${p} → ${cf}:"
                cat "${cf}" | tr ' ' '\n' | sed 's/^/    /'
                grep -q "rootdelay" "${cf}" \
                    && ok "rootdelay present" \
                    || { warn "rootdelay missing from NVMe cmdline.txt"
                         fix "sudo bash extras/post-restore-nvme-boot.sh"; }
            fi
        done
        umount "${mp}" 2>/dev/null || true
    fi
    rmdir "${mp}" 2>/dev/null || true
done

# ══════════════════════════════════════════════════════════════════════════════
section "9. BACKUP MANIFEST (S3)"
# ══════════════════════════════════════════════════════════════════════════════

if [[ -z "${_CFG}" ]]; then
    info "config.env not found — skipping manifest check"
elif ! command -v aws &>/dev/null; then
    warn "aws CLI not installed — cannot fetch manifest"
elif [[ -z "${S3_BUCKET}" ]]; then
    warn "S3_BUCKET not set in config.env"
    fix "Add S3_BUCKET=your-bucket-name to config.env"
else
    prefix="${S3_PREFIX:-pi-image-backup/andrew-pi-5}"
    region="${S3_REGION}"
    echo "  s3://${S3_BUCKET}/${prefix}/  (region=${region})"
    echo ""
    latest=$(aws s3 ls "s3://${S3_BUCKET}/${prefix}/" --region "${region}" 2>/dev/null \
             | grep "manifest.json" | sort | tail -1 | awk '{print $NF}' || true)
    if [[ -z "${latest}" ]]; then
        fail "No manifest.json at s3://${S3_BUCKET}/${prefix}/"
        fix "Run a fresh backup: sudo bash pi-image-backup.sh"
    else
        ok "Latest manifest: ${latest}"
        manifest=$(aws s3 cp "s3://${S3_BUCKET}/${prefix}/${latest}" - --region "${region}" 2>/dev/null || true)
        if [[ -z "${manifest}" ]]; then
            fail "Failed to download manifest — credentials or network?"
            fix "aws s3 cp s3://${S3_BUCKET}/${prefix}/${latest} /tmp/m.json --region ${region} --profile personal"
        elif echo "${manifest}" | jq empty 2>/dev/null; then
            ok "Manifest JSON valid"
            backup_type=$(echo "${manifest}" | jq -r '.backup_type // empty' 2>/dev/null || true)
            hostname_val=$(echo "${manifest}" | jq -r '.hostname // empty' 2>/dev/null || true)
            timestamp_val=$(echo "${manifest}" | jq -r '.timestamp // empty' 2>/dev/null || true)
            printf "    %-16s %s\n" "backup_type"  "${backup_type:-<missing>}"
            printf "    %-16s %s\n" "hostname"     "${hostname_val:-<missing>}"
            printf "    %-16s %s\n" "timestamp"    "${timestamp_val:-<missing>}"
            if [[ "${backup_type}" == "partclone" ]]; then
                ok "backup_type=partclone (correct)"
            elif [[ "${backup_type}" == "dd" ]]; then
                warn "backup_type=dd — raw image, not partclone"
                fix "Re-run backup: sudo bash pi-image-backup.sh"
            else
                warn "backup_type missing or unknown: '${backup_type}'"
                fix "Re-run backup: sudo bash pi-image-backup.sh"
            fi
        else
            fail "Manifest JSON MALFORMED — restore will use wrong method (dd instead of partclone)"
            echo ""
            echo "  Raw manifest (first 400 chars):"
            echo "${manifest}" | head -c 400 | sed 's/^/    /'
            echo ""
            fixed=$(echo "${manifest}" | sed 's/:\s*,/: null,/g' || true)
            if echo "${fixed}" | jq empty 2>/dev/null; then
                ok "Auto-repair fixes the JSON (restore script applies this)"
                echo "    backup_type after repair: $(echo "${fixed}" | jq -r '.backup_type // empty')"
                warn "Root fix: re-run backup to get a clean manifest"
                fix "sudo bash pi-image-backup.sh"
            else
                fail "Auto-repair insufficient — manifest too corrupted"
                fix "sudo bash pi-image-backup.sh"
            fi
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "10. KERNEL MESSAGES"
# ══════════════════════════════════════════════════════════════════════════════

echo "  Errors/warnings:"
dmesg | grep -iE "error|fail|warn|undervolt|nvme|reset|timeout|drop" \
    | grep -iv "firmware\|acpi.*warn\|pci.*warn" \
    | tail -30 | sed 's/^/  /' || echo "  (none)"

echo ""
echo "  Last 20 messages:"
dmesg | tail -20 | sed 's/^/  /'

# ══════════════════════════════════════════════════════════════════════════════
section "11. CLOUD-INIT STATUS"
# ══════════════════════════════════════════════════════════════════════════════

if ! command -v cloud-init &>/dev/null; then
    info "cloud-init not installed"
else
    echo "  Version: $(cloud-init --version 2>/dev/null || echo unknown)"
    echo ""
    echo "  Status:"
    ci_status=$(cloud-init status 2>/dev/null || echo "unavailable")
    echo "    ${ci_status}"
    if echo "${ci_status}" | grep -q "error"; then
        fail "cloud-init finished with errors"
        fix "Check: sudo cat /var/log/cloud-init-output.log"
    elif echo "${ci_status}" | grep -q "running"; then
        warn "cloud-init is still running — runcmd has not completed yet"
    elif echo "${ci_status}" | grep -q "done"; then
        ok "cloud-init completed"
    fi

    echo ""
    echo "  Instance IDs:"
    for f in /run/cloud-init/instance-id \
              /var/lib/cloud/data/instance-id \
              /var/lib/cloud/instance/boot-finished; do
        val="(missing)"
        [[ -f "${f}" ]] && val=$(cat "${f}" 2>/dev/null | head -1 || true)
        printf "    %-48s %s\n" "${f}" "${val}"
    done

    echo ""
    echo "  Result:"
    if [[ -f /run/cloud-init/result.json ]]; then
        cat /run/cloud-init/result.json | sed 's/^/    /'
        grep -q '"errors": \[\]' /run/cloud-init/result.json 2>/dev/null \
            && ok "No errors in result.json" \
            || fail "Errors in result.json"
    else
        warn "/run/cloud-init/result.json missing — cloud-init may not have run"
        fix "To force re-run: update ds=nocloud;i=<new-id> in cmdline.txt on the SD card and reboot"
    fi

    echo ""
    echo "  meta-data instance-id:"
    _md_id=""
    for p in /boot/firmware/meta-data /boot/meta-data; do
        [[ -f "${p}" ]] && _md_id=$(grep -oP 'instance-id:\s*\K\S+' "${p}" 2>/dev/null || true) && break
    done
    _cached_id=$(cat /var/lib/cloud/data/instance-id 2>/dev/null || true)
    if [[ -z "${_md_id}" ]]; then
        warn "No meta-data file — cloud-init datasource may not detect new instance"
    elif [[ "${_md_id}" == "${_cached_id}" ]]; then
        fail "meta-data instance-id '${_md_id}' == cached '${_cached_id}' — cloud-init WILL SKIP runcmd on next boot"
        fix "echo 'instance-id: pi2s3-\$(date +%s)' > /boot/firmware/meta-data"
    else
        ok "meta-data instance-id '${_md_id}' is new (cached='${_cached_id:-none}')"
    fi

    echo ""
    echo "  Sentinel file (/boot/firmware/cloud-init-ran):"
    if [[ -f /boot/firmware/cloud-init-ran ]]; then
        ok "Sentinel exists — runcmd ran"
        cat /boot/firmware/cloud-init-ran | sed 's/^/    /'
    else
        warn "No sentinel file — runcmd did not run (or wrote to wrong path)"
        fix "Check /var/log/cloud-init-output.log for errors"
    fi

    echo ""
    echo "  write_files artifacts:"
    for f in /etc/cloudflared/config.yml /etc/cloudflared/*.json; do
        if [[ -e "${f}" ]]; then
            mtime=$(stat -c%y "${f}" 2>/dev/null | cut -d. -f1 || echo "?")
            size=$(stat -c%s "${f}" 2>/dev/null || echo "?")
            ok "${f}  (${size} bytes, ${mtime})"
        else
            warn "${f} — NOT FOUND (write_files failed?)"
            fix "Check /var/log/cloud-init-output.log"
        fi
    done

    echo ""
    echo "  runcmd output (last 30 lines of /var/log/cloud-init-output.log):"
    if [[ -f /var/log/cloud-init-output.log ]]; then
        tail -30 /var/log/cloud-init-output.log | sed 's/^/    /'
    else
        warn "/var/log/cloud-init-output.log not found"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "12. CLOUDFLARE TUNNEL"
# ══════════════════════════════════════════════════════════════════════════════

if ! command -v cloudflared &>/dev/null; then
    fail "cloudflared not installed"
    fix "curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb -o /tmp/cf.deb && sudo dpkg -i /tmp/cf.deb"
else
    ok "cloudflared $(cloudflared --version 2>&1 | head -1)"

    echo ""
    echo "  Service:"
    cf_active=$(systemctl is-active cloudflared 2>/dev/null || echo "unknown")
    cf_enabled=$(systemctl is-enabled cloudflared 2>/dev/null || echo "unknown")
    if [[ "${cf_active}" == "active" ]]; then
        ok "cloudflared.service  active=${cf_active}  enabled=${cf_enabled}"
    else
        fail "cloudflared.service  active=${cf_active}  enabled=${cf_enabled}"
        fix "sudo systemctl enable cloudflared && sudo systemctl start cloudflared"
    fi

    echo ""
    echo "  Config:"
    cf_config=""
    for p in /etc/cloudflared/config.yml ~/.cloudflared/config.yml; do
        [[ -f "${p}" ]] && cf_config="${p}" && break
    done
    if [[ -n "${cf_config}" ]]; then
        ok "Config: ${cf_config}"
        cat "${cf_config}" | sed 's/^/    /'
        cf_tunnel_id=$(grep -E "^tunnel:" "${cf_config}" 2>/dev/null | awk '{print $2}' || true)
        cf_creds=$(grep -E "^credentials-file:" "${cf_config}" 2>/dev/null | awk '{print $2}' || true)
        if [[ -n "${cf_creds}" ]]; then
            [[ -f "${cf_creds}" ]] \
                && ok "Credentials file present: ${cf_creds}" \
                || { fail "Credentials file MISSING: ${cf_creds}"
                     fix "Re-run cloud-init (bump instance-id in cmdline.txt) or write the file manually"; }
        fi
    else
        fail "No cloudflared config.yml found"
        fix "Expected /etc/cloudflared/config.yml — re-run cloud-init or write manually"
    fi

    echo ""
    echo "  Recent journal (last 25 lines):"
    journalctl -u cloudflared -n 25 --no-pager 2>/dev/null | sed 's/^/  /' \
        || echo "    (no journal entries)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "SUMMARY"
# ══════════════════════════════════════════════════════════════════════════════

_ELAPSED=$(( $(date +%s) - _START ))
echo "  Ran in ${_ELAPSED}s.  Report: ${REPORT}"
echo ""
if [[ ${#_ISSUES[@]} -eq 0 ]]; then
    printf "  ${GREEN}${BOLD}All checks passed — no issues found.${NC}\n"
else
    printf "  ${RED}${BOLD}%d issue(s) found:${NC}\n" "${#_ISSUES[@]}"
    echo ""
    for _i in "${_ISSUES[@]}"; do
        _level="${_i%%|*}"
        _msg="${_i#*| }"
        if [[ "${_level}" == *FAIL* ]]; then
            printf "  ${RED}✗ ${_msg}${NC}\n"
        else
            printf "  ${YELLOW}△ ${_msg}${NC}\n"
        fi
    done
    echo ""
    echo "  Re-run specific sections by searching the report for [FAIL] or [WARN]:"
    echo "    grep -E 'FAIL|WARN|fix:' ${REPORT}"
fi
hr
