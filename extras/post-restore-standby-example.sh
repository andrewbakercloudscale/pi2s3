#!/usr/bin/env bash
# =============================================================
# extras/post-restore-standby-example.sh
#
# Post-restore customisation template for a hot standby Pi.
# Runs inside the restored filesystem (on the NVMe) after each
# daily sync, before the Pi reboots into the fresh image.
#
# Set in config.env on the STANDBY Pi:
#   STANDBY_POST_RESTORE_SCRIPT="~/pi2s3/extras/post-restore-standby-example.sh"
#
# The restored root is mounted at $RESTORE_ROOT (also $1).
# This script runs from the SD card environment, not from NVMe.
# =============================================================
set -euo pipefail

RESTORE_ROOT="${RESTORE_ROOT:-${1:?RESTORE_ROOT is not set}}"
echo "==> Standby post-restore: ${RESTORE_ROOT}"

# ── 1. Set standby hostname ────────────────────────────────────────────────────
# The restored image contains the production hostname. Rename so the standby
# announces itself correctly on the network.
#
# STANDBY_HOSTNAME="pi-standby"
# echo "${STANDBY_HOSTNAME}" | sudo tee "${RESTORE_ROOT}/etc/hostname" > /dev/null
# sudo sed -i "s/$(hostname)/${STANDBY_HOSTNAME}/g" "${RESTORE_ROOT}/etc/hosts" 2>/dev/null || true
# echo "    Hostname: ${STANDBY_HOSTNAME}"

# ── 2. Swap Cloudflare tunnel to the standby UUID ─────────────────────────────
# The restored image has the PRODUCTION tunnel credentials baked in.
# Replace them with the standby tunnel's credentials before reboot.
#
# Get the credentials file from:
#   cloudflared tunnel create andrewninja-pi-qa        (if not already done)
#   cat ~/.cloudflared/<STANDBY_TUNNEL_UUID>.json       (copy this file to the Pi)
#
# STANDBY_TUNNEL_UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# STANDBY_TUNNEL_CREDS="/path/to/${STANDBY_TUNNEL_UUID}.json"  # on the SD/Mac
#
# if [[ -n "${STANDBY_TUNNEL_UUID:-}" && -f "${STANDBY_TUNNEL_CREDS:-}" ]]; then
#     CF_DIR="${RESTORE_ROOT}/root/.cloudflared"
#     sudo mkdir -p "${CF_DIR}"
#     sudo cp "${STANDBY_TUNNEL_CREDS}" "${CF_DIR}/${STANDBY_TUNNEL_UUID}.json"
#     sudo sed -i "s/tunnel: .*/tunnel: ${STANDBY_TUNNEL_UUID}/" "${CF_DIR}/config.yml"
#     sudo sed -i "s|credentials-file:.*|credentials-file: /root/.cloudflared/${STANDBY_TUNNEL_UUID}.json|" \
#         "${CF_DIR}/config.yml"
#     echo "    CF tunnel swapped to standby UUID: ${STANDBY_TUNNEL_UUID}"
# fi

# ── 3. Update .env values ─────────────────────────────────────────────────────
# Swap any site-specific env vars that differ between prod and standby.
#
# ENV_FILE="${RESTORE_ROOT}/path/to/your/app/.env"
# if [[ -f "${ENV_FILE}" ]]; then
#     sudo sed -i 's|SITE_URL=.*|SITE_URL=https://standby.yourdomain.com|' "${ENV_FILE}"
#     echo "    .env updated."
# fi

# ── 4. Regenerate SSH host keys ────────────────────────────────────────────────
# Prevents host-key conflicts between the prod Pi and standby Pi.
# Uncomment if you SSH directly to both and don't want known_hosts conflicts.
#
# sudo rm -f "${RESTORE_ROOT}"/etc/ssh/ssh_host_*
# echo "    SSH host keys removed — will regenerate on first boot."

# ── 5. Wire NVMe boot (always run this for hot standby syncs) ─────────────────
# Updates /etc/fstab PARTUUIDs and cmdline.txt root= for this SD hardware.
# Required on every sync because the SD card may differ from the one used
# when the original backup was taken.
PI2S3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${PI2S3_DIR}/extras/post-restore-nvme-boot.sh" ]]; then
    bash "${PI2S3_DIR}/extras/post-restore-nvme-boot.sh"
    echo "    NVMe boot wired."
fi

echo "==> Standby post-restore complete."
