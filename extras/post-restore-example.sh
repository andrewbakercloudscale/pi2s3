#!/usr/bin/env bash
# =============================================================
# extras/post-restore-example.sh — Post-restore customisation template
#
# Runs inside the restored filesystem before reboot.
# Called by pi-image-restore.sh when you pass --post-restore:
#
#   bash pi-image-restore.sh \
#     --date latest --device /dev/nvme0n1 \
#     --post-restore ~/post-restore-office.sh
#
# The restored root is mounted at $RESTORE_ROOT (also $1).
# Edit this file, rename it for your use case, and keep it out of the repo.
# =============================================================
set -euo pipefail

RESTORE_ROOT="${RESTORE_ROOT:-${1:?RESTORE_ROOT is not set}}"

echo "==> Post-restore running on: ${RESTORE_ROOT}"

# ── 1. Change hostname ──────────────────────────────────────────────────────
NEW_HOSTNAME="pi-office"
echo "${NEW_HOSTNAME}" | sudo tee "${RESTORE_ROOT}/etc/hostname" > /dev/null
sudo sed -i "s/raspberrypi/${NEW_HOSTNAME}/g" "${RESTORE_ROOT}/etc/hosts" 2>/dev/null || true
echo "    Hostname set to: ${NEW_HOSTNAME}"

# ── 2. Swap Cloudflare tunnel credentials ──────────────────────────────────
# Replace this with the path to your office tunnel's JSON credentials file.
# You can get it from: https://one.dash.cloudflare.com → Tunnels → your tunnel → credential file
#
# CF_TUNNEL_CREDENTIALS="/path/to/office-tunnel.json"
# CF_TUNNEL_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#
# if [[ -f "${CF_TUNNEL_CREDENTIALS}" ]]; then
#     CF_CRED_DIR="${RESTORE_ROOT}/root/.cloudflared"
#     sudo mkdir -p "${CF_CRED_DIR}"
#     sudo cp "${CF_TUNNEL_CREDENTIALS}" "${CF_CRED_DIR}/${CF_TUNNEL_ID}.json"
#     echo "    CF tunnel credentials installed."
#
#     # Update the tunnel ID in config.yml
#     sudo sed -i "s/tunnel: .*/tunnel: ${CF_TUNNEL_ID}/" "${CF_CRED_DIR}/config.yml" 2>/dev/null || true
#     sudo sed -i "s|credentials-file: .*|credentials-file: /root/.cloudflared/${CF_TUNNEL_ID}.json|" \
#         "${CF_CRED_DIR}/config.yml" 2>/dev/null || true
#     echo "    CF config.yml updated."
# fi

# ── 3. Update .env variables ───────────────────────────────────────────────
# Swap any site-specific values in your app's .env file.
#
# ENV_FILE="${RESTORE_ROOT}/home/pi/myapp/.env"
# if [[ -f "${ENV_FILE}" ]]; then
#     sudo sed -i 's|SITE_URL=.*|SITE_URL=https://office.example.com|' "${ENV_FILE}"
#     sudo sed -i 's|HOSTNAME=.*|HOSTNAME=pi-office|' "${ENV_FILE}"
#     echo "    .env updated."
# fi

# ── 4. Regenerate SSH host keys (avoids host key conflicts with original) ──
# Uncomment if you want the clone to have different SSH host keys.
#
# sudo rm -f "${RESTORE_ROOT}"/etc/ssh/ssh_host_*
# echo "    SSH host keys removed — will regenerate on first boot."

echo "==> Post-restore complete."
