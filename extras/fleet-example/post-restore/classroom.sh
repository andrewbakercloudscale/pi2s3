#!/usr/bin/env bash
# post-restore/classroom.sh — Post-restore customisation for classroom Pis
#
# Runs inside the restored filesystem before reboot.
# $1 / $RESTORE_ROOT = mount point of the restored root partition.
#
# This script is called by pi-image-restore.sh via --post-restore.
# Edit the variables below for your environment.
set -euo pipefail

RESTORE_ROOT="${RESTORE_ROOT:-${1:?RESTORE_ROOT is not set}}"

# Derive a per-Pi hostname from the last octet of the IP assigned at boot.
# Falls back to a default if IP can't be determined.
PI_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet )[\d.]+' || echo "")
if [[ -n "${PI_IP}" ]]; then
    LAST_OCTET="${PI_IP##*.}"
    NEW_HOSTNAME="pi-classroom-$(printf '%02d' "${LAST_OCTET}")"
else
    NEW_HOSTNAME="pi-classroom"
fi

echo "==> Post-restore: classroom"
echo "    Hostname: ${NEW_HOSTNAME}"

# 1. Hostname
echo "${NEW_HOSTNAME}" | sudo tee "${RESTORE_ROOT}/etc/hostname" > /dev/null
sudo sed -i "s/raspberrypi/${NEW_HOSTNAME}/g" "${RESTORE_ROOT}/etc/hosts" 2>/dev/null || true

# 2. Remove previous Cloudflare tunnel credentials — each classroom Pi
#    should get its own tunnel configured on first boot. If you have
#    pre-provisioned tunnel credentials, copy them here instead.
#    sudo rm -f "${RESTORE_ROOT}/root/.cloudflared"/*.json

# 3. Regenerate SSH host keys on first boot (avoids key conflicts between Pis)
sudo rm -f "${RESTORE_ROOT}"/etc/ssh/ssh_host_*
echo "    SSH host keys cleared — will regenerate on first boot."

echo "==> Post-restore complete: ${NEW_HOSTNAME}"
