#!/usr/bin/env bash
# =============================================================
# extras/setup-netboot.sh — Configure Pi 5 EEPROM for HTTP netboot
#
# Adds HTTP boot as a fallback in the Pi 5 boot order, pointing at
# boot.pi2s3.com (CloudFront → S3). When the Pi has no NVMe attached
# (or the NVMe is blank), it automatically boots the pi2s3 restore
# environment and streams your backup from S3.
#
# Run this once on each Pi you want to be recovery-ready:
#   bash ~/pi2s3/extras/setup-netboot.sh
#
# Modes:
#   (no args)      Add HTTP fallback after NVMe (recommended)
#   --force        HTTP boot first (for immediate recovery boot)
#   --disable      Remove HTTP from boot order
#   --show         Show current EEPROM boot config and exit
#
# Boot order values (Pi 5):
#   1 = SD card    4 = USB    6 = NVMe    7 = HTTP    f = restart
# =============================================================
set -euo pipefail

[[ "$(uname -m)" == "aarch64" ]] || { echo "ERROR: This script must run on the Raspberry Pi."; exit 1; }
command -v rpi-eeprom-config &>/dev/null || { echo "ERROR: rpi-eeprom-config not found. Install: sudo apt install rpi-eeprom"; exit 1; }

HTTP_HOST="boot.pi2s3.com"
HTTP_PATH="/"

MODE="fallback"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)   MODE="force" ;;
        --disable) MODE="disable" ;;
        --show)    MODE="show" ;;
        --host)    shift; HTTP_HOST="${1:?--host requires a value}" ;;
        --host=*)  HTTP_HOST="${1#--host=}" ;;
        --help)
            echo "Usage: $0 [--force | --disable | --show] [--host <hostname>]"
            echo "  (no args)  Add HTTP fallback after NVMe (recommended)"
            echo "  --force    HTTP boot first — for immediate recovery"
            echo "  --disable  Remove HTTP from boot order"
            echo "  --show     Print current EEPROM config and exit"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

echo ""
echo "  pi2s3 — EEPROM netboot configuration"
echo ""

CURRENT=$(sudo rpi-eeprom-config)
echo "  Current EEPROM config:"
echo "${CURRENT}" | sed 's/^/    /'
echo ""

[[ "${MODE}" == "show" ]] && exit 0

case "${MODE}" in
    fallback)
        # NVMe → HTTP → USB → SD → restart
        NEW_BOOT_ORDER="0xf7641"
        echo "  Mode: HTTP fallback (boots NVMe normally; HTTP if NVMe missing)"
        ;;
    force)
        # HTTP → NVMe → restart
        NEW_BOOT_ORDER="0xf76"
        echo "  Mode: HTTP first (next boot will go to pi2s3 recovery)"
        echo "  NOTE: change back to fallback mode after recovery is complete."
        ;;
    disable)
        # NVMe → USB → SD → restart (no HTTP)
        NEW_BOOT_ORDER="0xf641"
        echo "  Mode: disable HTTP boot"
        ;;
esac

echo "  New BOOT_ORDER: ${NEW_BOOT_ORDER}"
echo "  HTTP_HOST:      ${HTTP_HOST}"
echo ""
read -r -p "  Apply? [y/N] " answer
[[ "${answer,,}" == "y" ]] || { echo "  Aborted."; exit 0; }

# Write new config via temp file
TMPCONF=$(mktemp)
trap "rm -f '${TMPCONF}'" EXIT

echo "${CURRENT}" \
    | grep -v "^BOOT_ORDER" \
    | grep -v "^HTTP_HOST" \
    | grep -v "^HTTP_PATH" \
    > "${TMPCONF}"

if [[ "${MODE}" != "disable" ]]; then
    {
        echo "BOOT_ORDER=${NEW_BOOT_ORDER}"
        echo "HTTP_HOST=${HTTP_HOST}"
        echo "HTTP_PATH=${HTTP_PATH}"
    } >> "${TMPCONF}"
else
    echo "BOOT_ORDER=${NEW_BOOT_ORDER}" >> "${TMPCONF}"
fi

sudo rpi-eeprom-config --apply "${TMPCONF}"

echo ""
echo "  EEPROM updated. Reboot to apply:"
echo "    sudo reboot"
echo ""
if [[ "${MODE}" == "force" ]]; then
    echo "  After recovery, run this again without --force to restore"
    echo "  normal NVMe-first boot order."
    echo ""
fi
