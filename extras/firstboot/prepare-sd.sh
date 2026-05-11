#!/usr/bin/env bash
# =============================================================
# extras/firstboot/prepare-sd.sh
#
# Prepare a Pi OS SD card for Cloudflare tunnel access.
# WiFi only — no ethernet required.
#
# Two modes:
#
#   Inject (default) — you already flashed with Raspberry Pi Imager:
#     bash extras/firstboot/prepare-sd.sh
#
#   Flash — downloads Pi OS and does everything in one command:
#     bash extras/firstboot/prepare-sd.sh --flash
#
# Both modes produce a card that on first Pi boot:
#   1. Connects to your WiFi
#   2. Starts cloudflared with your tunnel credentials
#   3. Exposes SSH at your CF hostname — no inbound firewall holes
#
# SSH in after ~3 min:
#   ssh -o ProxyCommand='cloudflared access ssh --hostname <host>' admin@<host>
#
# Once in, run the restore:
#   curl -sL pi2s3.com/restore | bash
#
# Options:
#   --flash               Download Pi OS + flash SD (skip Pi Imager)
#   --disk    <disk>      SD card disk number, e.g. disk4 (--flash only)
#   --tunnel  <uuid>      Cloudflare tunnel UUID
#   --creds   <path>      Tunnel credentials JSON path
#   --hostname <host>     CF hostname, e.g. qa.andrewbaker.ninja
#   --ssid    <ssid>      WiFi SSID
#   --wifi-pass <pass>    WiFi password
#   --pi-user <name>      Pi username (default: admin)
#   --pi-pass <pass>      Pi password (flash mode only)
#   --volume  <path>      Boot partition path (auto-detected if omitted)
#   --country <code>      WiFi regulatory domain (default: ZA)
#   --cf-api-token <tok>  CF API token (Tunnel:Edit) — syncs remote tunnel config
#                         so cloudflared serves any hostname via WordPress instead
#                         of returning 404.  Required for DNS-swap failover.
# =============================================================
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

ok()      { printf "  ${GREEN}✓${NC}  %s\n" "$*"; }
info()    { printf "  ${CYAN}→${NC}  %s\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; }
die()     { printf "  ${RED}✗${NC}  %s\n" "$*" >&2; exit 1; }
section() { printf "\n${BOLD}%s${NC}\n" "$*"; }
prompt()  { local _v; printf "  ${CYAN}?${NC}  %s: " "$1"; read -r _v; printf -v "$2" '%s' "${_v}"; }
prompt_s(){ local _v; printf "  ${CYAN}?${NC}  %s: " "$1"; read -rs _v; echo; printf -v "$2" '%s' "${_v}"; }

# Decompress a .xz image: uses xz if available, falls back to Python lzma.
decompress_xz() {
    local src="$1" dst="$2"
    if command -v xz &>/dev/null; then
        xz -dk "${src}" --stdout > "${dst}"
    else
        info "xz not found — using Python lzma (slower but works)..."
        python3 - "${src}" "${dst}" << 'PYEOF'
import lzma, sys, shutil
with lzma.open(sys.argv[1]) as f_in, open(sys.argv[2], 'wb') as f_out:
    shutil.copyfileobj(f_in, f_out)
PYEOF
    fi
}

# ── Defaults ──────────────────────────────────────────────────────────────────
FLASH_MODE=false
DISK=""
TUNNEL_UUID=""
CREDS_FILE=""
CF_HOSTNAME=""
WIFI_SSID=""
WIFI_PASS=""
PI_USER="admin"
PI_PASS=""
VOLUME=""
WIFI_COUNTRY="ZA"
CF_API_TOKEN=""
CACHE_DIR="${HOME}/.pi2s3-cache"
PI_OS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --flash)               FLASH_MODE=true ;;
        --disk)      shift;    DISK="$1" ;;
        --tunnel)    shift;    TUNNEL_UUID="$1" ;;
        --creds)     shift;    CREDS_FILE="$1" ;;
        --hostname)  shift;    CF_HOSTNAME="$1" ;;
        --ssid)      shift;    WIFI_SSID="$1" ;;
        --wifi-pass) shift;    WIFI_PASS="$1" ;;
        --pi-user)   shift;    PI_USER="$1" ;;
        --pi-pass)   shift;    PI_PASS="$1" ;;
        --volume)    shift;    VOLUME="$1" ;;
        --country)       shift;    WIFI_COUNTRY="$1" ;;
        --cf-api-token)  shift;    CF_API_TOKEN="$1" ;;
        --help|-h)
            grep '^# ' "$0" | head -50 | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[[ "$(uname)" == "Darwin" ]] || die "Run this on macOS."
command -v python3 &>/dev/null || die "python3 not found (pre-installed on macOS)."
mkdir -p "${CACHE_DIR}"

printf "\n${BOLD}  pi2s3 — prepare SD card${NC}  ${DIM}%s${NC}\n" \
    "$(${FLASH_MODE} && echo 'flash mode' || echo 'inject mode')"
printf "  ${DIM}──────────────────────────────────────────${NC}\n"

# ══════════════════════════════════════════════════════════════════════════════
# FLASH MODE — download Pi OS and write to SD card
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${FLASH_MODE}" == "true" ]]; then

    section "SD card"

    # Auto-detect or prompt for disk
    if [[ -z "${DISK}" ]]; then
        echo ""
        echo "  Removable disks:"
        diskutil list | awk '/^\/dev\/disk/{dev=$1} /Removable/{print "    " dev}' || true
        echo ""
        echo "  All disks (check size to identify your SD card):"
        diskutil list external 2>/dev/null | grep '^/dev/' | while read -r dev _; do
            sz=$(diskutil info "${dev}" 2>/dev/null | awk '/Total Size/{$1=$2=""; print $0}' | xargs)
            printf "    %-14s %s\n" "${dev}" "${sz}"
        done || diskutil list | grep '^/dev/' | sed 's/^/    /'
        echo ""
        prompt "SD card disk (e.g. disk4 — double-check before continuing)" DISK
    fi

    DISK="${DISK#/dev/}"
    DISK_DEV="/dev/${DISK}"
    RAW_DEV="/dev/r${DISK}"

    [[ -b "${DISK_DEV}" ]] || die "Disk not found: ${DISK_DEV}"
    [[ "${DISK}" == "disk0" ]] && die "Refusing to write to disk0 (your internal SSD)."

    DISK_SIZE=$(diskutil info "${DISK_DEV}" 2>/dev/null | awk -F: '/Total Size/{print $2}' | xargs)
    echo ""
    warn "About to ERASE ${DISK_DEV} (${DISK_SIZE})"
    printf "  Type YES to confirm: "; read -r _c
    [[ "${_c}" == "YES" ]] || { echo "  Aborted."; exit 0; }

    # Collect WiFi and Pi password while we download
    section "Configuration"

    [[ -n "${WIFI_SSID}" ]]  || prompt   "WiFi SSID" WIFI_SSID
    [[ -n "${WIFI_PASS}" ]]  || prompt_s "WiFi password" WIFI_PASS
    [[ -n "${WIFI_SSID}" ]]  || die "WiFi SSID required."
    [[ -n "${PI_PASS}" ]]    || prompt_s "Pi password (for user '${PI_USER}')" PI_PASS
    [[ -n "${PI_PASS}" ]]    || die "Pi password required."

    # Download Pi OS
    section "Pi OS download"
    info "Resolving download URL..."
    ACTUAL_URL=$(curl -sIL --max-time 15 "${PI_OS_URL}" 2>/dev/null \
        | awk 'tolower($1)=="location:"{url=$2} END{print url}' | tr -d '\r' || echo "")
    [[ -z "${ACTUAL_URL}" ]] && ACTUAL_URL="${PI_OS_URL}"
    IMG_XZ_NAME=$(basename "${ACTUAL_URL%%\?*}")
    IMG_XZ="${CACHE_DIR}/${IMG_XZ_NAME}"
    IMG="${IMG_XZ%.xz}"

    if [[ -f "${IMG}" ]]; then
        ok "Cached image: $(basename "${IMG}")"
    else
        if [[ ! -f "${IMG_XZ}" ]]; then
            info "Downloading $(basename "${IMG_XZ}") (~500 MB)..."
            curl -L --progress-bar "${PI_OS_URL}" -o "${IMG_XZ}"
            ok "Downloaded"
        fi
        info "Decompressing (~2-3 min)..."
        decompress_xz "${IMG_XZ}" "${IMG}"
        ok "Decompressed: $(basename "${IMG}")"
    fi

    # Flash
    section "Flashing"
    info "Unmounting ${DISK_DEV}..."
    diskutil unmountDisk "${DISK_DEV}" 2>/dev/null || true

    IMG_BYTES=$(stat -f%z "${IMG}" 2>/dev/null || echo 0)
    IMG_HUMAN=$(python3 -c "print(f'{${IMG_BYTES}/1024/1024/1024:.1f} GB')" 2>/dev/null || echo "?")
    info "Writing ${IMG_HUMAN} to ${RAW_DEV} (takes ~3-5 min, sudo required)..."

    if command -v pv &>/dev/null; then
        pv -s "${IMG_BYTES}" "${IMG}" | sudo dd of="${RAW_DEV}" bs=4m conv=sync
    else
        sudo dd if="${IMG}" of="${RAW_DEV}" bs=4m conv=sync status=progress
    fi
    sudo sync
    ok "Flash complete"

    info "Remounting partitions..."
    sleep 2
    diskutil mountDisk "${DISK_DEV}" 2>/dev/null || true
    sleep 2
fi

# ══════════════════════════════════════════════════════════════════════════════
# FIND BOOT PARTITION (both modes)
# ══════════════════════════════════════════════════════════════════════════════
section "Boot partition"

if [[ -z "${VOLUME}" ]]; then
    for _c in /Volumes/bootfs /Volumes/boot /Volumes/BOOT /Volumes/BOOTFS; do
        if [[ -d "${_c}" && -f "${_c}/cmdline.txt" ]]; then
            VOLUME="${_c}"; break
        fi
    done
fi

[[ -z "${VOLUME}" ]] && \
    die "Boot partition not found. Insert the SD card or pass --volume /Volumes/<name>"
[[ -f "${VOLUME}/cmdline.txt" ]] || \
    die "${VOLUME} has no cmdline.txt — not a Pi boot partition."

ok "Boot partition: ${VOLUME}"

# ══════════════════════════════════════════════════════════════════════════════
# COLLECT TUNNEL CONFIG (both modes)
# ══════════════════════════════════════════════════════════════════════════════
section "Cloudflare tunnel"

if [[ -z "${TUNNEL_UUID}" ]]; then
    if command -v cloudflared &>/dev/null; then
        echo "  Your existing tunnels:"
        cloudflared tunnel list 2>/dev/null | sed 's/^/    /' || true
        echo ""
    fi
    prompt "Tunnel UUID" TUNNEL_UUID
fi
[[ -z "${TUNNEL_UUID}" ]] && \
    die "Tunnel UUID required. Create one: cloudflared tunnel create andrewninja-pi-qa"

[[ -z "${CREDS_FILE}" ]] && CREDS_FILE="${HOME}/.cloudflared/${TUNNEL_UUID}.json"
[[ -f "${CREDS_FILE}" ]] || \
    die "Credentials file not found: ${CREDS_FILE}"

if [[ -z "${CF_HOSTNAME}" ]]; then
    prompt "CF hostname (e.g. qa.andrewbaker.ninja)" CF_HOSTNAME
fi
[[ -z "${CF_HOSTNAME}" ]] && die "CF hostname required."

ok "Tunnel: ${TUNNEL_UUID}"
ok "Hostname: ${CF_HOSTNAME}"

# In inject mode, check if WiFi needs to be configured
if [[ "${FLASH_MODE}" == "false" && -z "${WIFI_SSID}" ]]; then
    FIRSTRUN="${VOLUME}/firstrun.sh"
    if [[ ! -f "${FIRSTRUN}" ]]; then
        die "No firstrun.sh on boot partition.
         Flash with Raspberry Pi Imager (with WiFi + SSH configured), then re-run.
         Or use --flash to do everything from scratch."
    fi
    if grep -qiE "ssid|nmconnection|NetworkManager" "${FIRSTRUN}" 2>/dev/null; then
        info "WiFi already configured by Pi Imager"
    else
        warn "No WiFi config detected in firstrun.sh"
        prompt "WiFi SSID (Enter to skip if Pi Imager handled it)" WIFI_SSID
        [[ -n "${WIFI_SSID}" ]] && prompt_s "WiFi password" WIFI_PASS
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD cloudflared .deb
# ══════════════════════════════════════════════════════════════════════════════
section "cloudflared binary"

DEB_PATH="${CACHE_DIR}/cloudflared-linux-arm64.deb"
DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"

if [[ -f "${DEB_PATH}" ]]; then
    ok "Cached: ${DEB_PATH}"
else
    info "Downloading cloudflared ARM64 (~30 MB)..."
    curl -L --progress-bar "${DEB_URL}" -o "${DEB_PATH}"
    ok "Downloaded"
fi

# ══════════════════════════════════════════════════════════════════════════════
# WRITE FILES to boot partition
# Special-character-safe: passwords go into files, NOT into firstrun.sh code
# ══════════════════════════════════════════════════════════════════════════════
section "Writing to boot partition"

# SSH
touch "${VOLUME}/ssh"
ok "ssh (SSH enabled)"

# Pi user account (flash mode — Pi Imager handles this in inject mode)
if [[ "${FLASH_MODE}" == "true" ]]; then
    PASS_HASH=$(openssl passwd -6 "${PI_PASS}")
    printf '%s:%s\n' "${PI_USER}" "${PASS_HASH}" > "${VOLUME}/userconf.txt"
    ok "userconf.txt (user: ${PI_USER})"
fi

# WiFi connection profile — written as a file, firstrun.sh just copies it
if [[ -n "${WIFI_SSID}" ]]; then
    cat > "${VOLUME}/pi2s3-wifi.nmconnection" << NMEOF
[connection]
id=pi2s3-wifi
type=wifi
autoconnect=true

[wifi]
ssid=${WIFI_SSID}
mode=infrastructure

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=${WIFI_PASS}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
NMEOF
    ok "pi2s3-wifi.nmconnection (SSID: ${WIFI_SSID})"
fi

# cloudflared .deb
cp "${DEB_PATH}" "${VOLUME}/cloudflared-linux-arm64.deb"
ok "cloudflared-linux-arm64.deb"

# Tunnel credentials JSON
cp "${CREDS_FILE}" "${VOLUME}/tunnel.json"
ok "tunnel.json"

# cloudflared config
cat > "${VOLUME}/cloudflared-config.yml" << EOF
tunnel: ${TUNNEL_UUID}
credentials-file: /root/.cloudflared/${TUNNEL_UUID}.json
loglevel: info
ingress:
  - hostname: ${CF_HOSTNAME}
    service: ssh://localhost:22
  - service: http://127.0.0.1:8082
EOF
ok "cloudflared-config.yml"

# ══════════════════════════════════════════════════════════════════════════════
# BUILD / PATCH firstrun.sh
# ══════════════════════════════════════════════════════════════════════════════
section "firstrun.sh"

# The cloudflared snippet to inject.
# Only file copies + standard commands — no embedded passwords.
# TUNNEL_UUID is safe: hex chars and dashes only.
CF_SNIPPET=$(cat << SNIPEOF

# ── pi2s3: cloudflared tunnel setup ──────────────────────────────────────────
logger -t pi2s3-firstboot "Installing cloudflared..."
dpkg -i /boot/firmware/cloudflared-linux-arm64.deb >> /boot/firmware/pi2s3-firstboot.log 2>&1 \\
    || logger -t pi2s3-firstboot "WARN: cloudflared dpkg failed"
mkdir -p /root/.cloudflared /etc/cloudflared
cp /boot/firmware/tunnel.json          /root/.cloudflared/${TUNNEL_UUID}.json
chmod 600                              /root/.cloudflared/${TUNNEL_UUID}.json
cp /boot/firmware/cloudflared-config.yml /etc/cloudflared/config.yml
systemctl enable cloudflared >> /boot/firmware/pi2s3-firstboot.log 2>&1 \\
    || logger -t pi2s3-firstboot "WARN: cloudflared enable failed"
logger -t pi2s3-firstboot "cloudflared setup complete — ${CF_HOSTNAME}"
# ─────────────────────────────────────────────────────────────────────────────
SNIPEOF
)

if [[ -n "${WIFI_SSID}" ]]; then
    WIFI_SNIPPET=$(cat << WSNIPEOF

# ── pi2s3: WiFi setup ─────────────────────────────────────────────────────────
if [[ -f /boot/firmware/pi2s3-wifi.nmconnection ]]; then
    mkdir -p /etc/NetworkManager/system-connections
    cp /boot/firmware/pi2s3-wifi.nmconnection \\
       /etc/NetworkManager/system-connections/pi2s3-wifi.nmconnection
    chmod 600 /etc/NetworkManager/system-connections/pi2s3-wifi.nmconnection
fi
iw reg set ${WIFI_COUNTRY} 2>/dev/null || true
logger -t pi2s3-firstboot "WiFi configured"
# ─────────────────────────────────────────────────────────────────────────────
WSNIPEOF
)
else
    WIFI_SNIPPET=""
fi

if [[ "${FLASH_MODE}" == "true" ]]; then
    # ── Flash mode: write a complete firstrun.sh from scratch ─────────────────
    PI_HOSTNAME="${CF_HOSTNAME%%.*}"   # derive hostname from CF hostname prefix

    cat > "${VOLUME}/firstrun.sh" << 'SHEOF'
#!/bin/bash
# pi2s3 first-boot setup
set -e
exec 1>>/boot/firmware/pi2s3-firstboot.log 2>&1
echo "=== pi2s3 firstrun $(date) ==="
SHEOF

    # Append hostname block
    cat >> "${VOLUME}/firstrun.sh" << EOF

# ── Hostname ──────────────────────────────────────────────────────────────────
echo "${PI_HOSTNAME}" > /etc/hostname
sed -i "s/raspberrypi/${PI_HOSTNAME}/g" /etc/hosts 2>/dev/null || true
logger -t pi2s3-firstboot "Hostname: ${PI_HOSTNAME}"
EOF

    # Append WiFi block (if needed)
    [[ -n "${WIFI_SNIPPET}" ]] && printf '%s\n' "${WIFI_SNIPPET}" >> "${VOLUME}/firstrun.sh"

    # Append cloudflared block
    printf '%s\n' "${CF_SNIPPET}" >> "${VOLUME}/firstrun.sh"

    # Append SSH enable + cleanup
    cat >> "${VOLUME}/firstrun.sh" << 'SHEOF'

# ── SSH ───────────────────────────────────────────────────────────────────────
systemctl enable ssh 2>/dev/null || true

# ── Cleanup (remove self, strip systemd.run from cmdline) ─────────────────────
rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd\.run[^ ]*||g; s|  \+| |g' /boot/firmware/cmdline.txt
echo "=== pi2s3 firstrun done ==="
exit 0
SHEOF

    chmod +x "${VOLUME}/firstrun.sh"

    # Add systemd.run to cmdline.txt (Pi OS Bookworm mechanism)
    CMDLINE=$(cat "${VOLUME}/cmdline.txt" | tr -d '\n')
    if ! grep -q "systemd.run" "${VOLUME}/cmdline.txt"; then
        printf '%s systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot\n' \
            "${CMDLINE}" > "${VOLUME}/cmdline.txt"
    fi
    ok "firstrun.sh written from scratch"

else
    # ── Inject mode: add cloudflared to Pi Imager's existing firstrun.sh ──────
    FIRSTRUN="${VOLUME}/firstrun.sh"

    # Remove any previous pi2s3 block so we don't double-inject
    if grep -q "pi2s3: cloudflared" "${FIRSTRUN}" 2>/dev/null; then
        warn "Removing previous pi2s3 block and re-injecting..."
        python3 - "${FIRSTRUN}" << 'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
content = re.sub(
    r'\n# ── pi2s3: cloudflared.*?# ─{40,}\n',
    '\n',
    content,
    flags=re.DOTALL
)
open(path, 'w').write(content)
PYEOF
    fi

    # Also inject WiFi snippet if we have one
    FULL_INJECT="${WIFI_SNIPPET}${CF_SNIPPET}"

    # Write snippet to a temp file to avoid heredoc escaping issues in Python
    _TMP=$(mktemp)
    printf '%s\n' "${FULL_INJECT}" > "${_TMP}"

    python3 - "${FIRSTRUN}" "${_TMP}" << 'PYEOF'
import sys
path, snippet_path = sys.argv[1], sys.argv[2]
content = open(path).read()
snippet = open(snippet_path).read()

# Insert before Pi Imager's cleanup line (whichever comes first)
inserted = False
for marker in ('rm -f /boot/firmware/firstrun.sh',
               'rm -f /boot/firstrun.sh',
               'exit 0'):
    if marker in content:
        content = content.replace(marker, snippet + '\n' + marker, 1)
        inserted = True
        break

if not inserted:
    content += '\n' + snippet + '\n'

open(path, 'w').write(content)
print("  injected OK")
PYEOF

    rm -f "${_TMP}"
    ok "cloudflared injected into Pi Imager's firstrun.sh"
fi

# ══════════════════════════════════════════════════════════════════════════════
# REMOTE TUNNEL CONFIG
# cloudflared fetches ingress rules from CF's API at startup and IGNORES the
# local config.yml ingress section when a remote config exists.  Without this
# step the catch-all remains http_status:404, so any failover hostname that
# doesn't match a named rule returns 404 instead of serving WordPress.
# ══════════════════════════════════════════════════════════════════════════════
section "Remote tunnel config"

if [[ -z "${CF_API_TOKEN}" ]]; then
    warn "No --cf-api-token supplied — skipping remote tunnel config update."
    warn "cloudflared will use whatever ingress rules are already stored in CF."
    warn "If the catch-all is http_status:404 the tunnel will 404 on unknown hostnames."
    warn "Re-run with --cf-api-token <token> (needs Cloudflare Tunnel:Edit permission)."
else
    # Extract account ID from tunnel credentials JSON
    CF_ACCOUNT_TAG=$(python3 -c "import json; print(json.load(open('${CREDS_FILE}'))['AccountTag'])" 2>/dev/null || echo "")
    [[ -n "${CF_ACCOUNT_TAG}" ]] || die "Could not read AccountTag from ${CREDS_FILE}"

    REMOTE_CFG=$(python3 -c "
import json
cfg = {
    'config': {
        'ingress': [
            {'hostname': '${CF_HOSTNAME}', 'service': 'ssh://localhost:22'},
            {'service': 'http://127.0.0.1:8082'}
        ]
    }
}
print(json.dumps(cfg))
")
    RESULT=$(curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_TAG}/cfd_tunnel/${TUNNEL_UUID}/configurations" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${REMOTE_CFG}")
    python3 -c "
import sys, json
d = json.loads('${RESULT}')
" 2>/dev/null || true
    echo "${RESULT}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d['success']:
    ingress = d['result']['config']['ingress']
    print('  Remote tunnel config updated:')
    for r in ingress:
        h = r.get('hostname', '(catch-all)')
        print(f'    {h} -> {r[\"service\"]}')
else:
    print('  WARN: remote config update failed:', d.get('errors'))
    print('  The tunnel will use the existing remote config — check CF dashboard.')
"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
section "Done"

printf "  ${GREEN}${BOLD}SD card is ready.${NC}\n\n"
printf "  %-18s %s\n" "Boot partition:" "${VOLUME}"
printf "  %-18s %s\n" "CF hostname:"    "${CF_HOSTNAME}"
printf "  %-18s %s\n" "Pi user:"        "${PI_USER}"
echo ""
echo "  Steps:"
echo "  1. Eject:  diskutil eject ${VOLUME}"
echo "  2. Insert SD card into Pi and power on"
echo "  3. Wait ~3 min, then check the CF dashboard:"
echo "     cloudflared tunnel info ${TUNNEL_UUID}"
echo ""
echo "  SSH in via Cloudflare:"
printf "    ssh -o ProxyCommand='cloudflared access ssh --hostname %s' %s@%s\n" \
    "${CF_HOSTNAME}" "${PI_USER}" "${CF_HOSTNAME}"
echo ""
echo "  Add to ~/.ssh/config for convenience:"
printf "    Host %s\n      ProxyCommand cloudflared access ssh --hostname %%h\n      User %s\n" \
    "${CF_HOSTNAME}" "${PI_USER}"
echo ""
echo "  Boot log (first thing to check if tunnel doesn't appear):"
echo "    cat /boot/firmware/pi2s3-firstboot.log   (from Pi after SSH)"
echo ""
echo "  Once in, run the restore:"
echo "    curl -sL pi2s3.com/restore | bash"
echo ""
