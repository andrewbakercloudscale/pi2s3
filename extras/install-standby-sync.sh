#!/usr/bin/env bash
# =============================================================
# extras/install-standby-sync.sh — Set up daily hot standby sync
#
# Run ONCE on the STANDBY Pi after completing DR-quickstart Steps 1-9.
#
# What this does:
#   1. Validates hot standby config in config.env
#   2. Mounts the SD card root partition
#   3. Copies pi2s3 tools + config.env onto the SD
#   4. Installs standby-restore-agent.sh and wires it to run on SD boot
#   5. Creates the agent log file + sudoers entry (reboot without password)
#   6. Installs a cron job on the NVMe Pi to run hot-standby-sync.sh
#
# Usage:
#   bash ~/pi2s3/extras/install-standby-sync.sh
#
# To uninstall:
#   bash ~/pi2s3/extras/install-standby-sync.sh --uninstall
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"
CONFIG_FILE="${PARENT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
    echo "  cp ${PARENT_DIR}/config.env.example ${PARENT_DIR}/config.env" >&2
    echo "  nano ${PARENT_DIR}/config.env" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

UNINSTALL=false
[[ "${1:-}" == "--uninstall" ]] && UNINSTALL=true

log()  { echo "  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [WARN] $*"; }

echo "========================================================"
echo "  pi2s3 — hot standby sync installer"
echo "  Standby Pi: $(hostname)"
echo "========================================================"
echo ""

# ── Uninstall ─────────────────────────────────────────────────────────────────
if [[ "${UNINSTALL}" == "true" ]]; then
    echo "Uninstalling standby sync..."
    # Remove cron
    ( crontab -l 2>/dev/null | grep -v 'hot-standby-sync.sh' || true ) | crontab -
    ok "Cron job removed."
    # Remove sudoers entry
    sudo rm -f /etc/sudoers.d/pi2s3-standby-sync
    ok "Sudoers entry removed."
    # Remove log
    sudo rm -f /var/log/pi2s3-standby-sync.log
    ok "Log file removed."
    echo ""
    echo "Uninstall complete. The SD card restore agent is not removed automatically."
    echo "To remove from SD: delete pi2s3/ from the SD root and remove the systemd service."
    exit 0
fi

# ── Validate config ───────────────────────────────────────────────────────────
echo "Validating config..."
ERRORS=0

[[ -z "${S3_BUCKET:-}"  ]] && { warn "S3_BUCKET not set in config.env"; (( ERRORS++ )) || true; }
[[ -z "${S3_REGION:-}"  ]] && { warn "S3_REGION not set in config.env"; (( ERRORS++ )) || true; }

if [[ "${HOT_STANDBY_SYNC_ENABLED:-false}" != "true" ]]; then
    warn "HOT_STANDBY_SYNC_ENABLED is not set to true in config.env"
    warn "Set HOT_STANDBY_SYNC_ENABLED=true then re-run this script."
    (( ERRORS++ )) || true
fi

STANDBY_SYNC_SD_BOOT="${STANDBY_SYNC_SD_BOOT:-/dev/mmcblk0p1}"
STANDBY_SYNC_SD_ROOT="${STANDBY_SYNC_SD_ROOT:-/dev/mmcblk0p2}"
STANDBY_SYNC_CRON="${STANDBY_SYNC_CRON:-*/30 * * * *}"
STANDBY_SYNC_DEVICE="${STANDBY_SYNC_DEVICE:-/dev/nvme0n1}"
STANDBY_SYNC_MARKER_KEY="${STANDBY_SYNC_MARKER_KEY:-standby-sync-ready/latest.json}"

if [[ ! -b "${STANDBY_SYNC_SD_BOOT}" ]]; then
    warn "SD boot partition not found: ${STANDBY_SYNC_SD_BOOT}"
    warn "Insert SD card or set STANDBY_SYNC_SD_BOOT in config.env"
    (( ERRORS++ )) || true
fi

if [[ ! -b "${STANDBY_SYNC_SD_ROOT}" ]]; then
    warn "SD root partition not found: ${STANDBY_SYNC_SD_ROOT}"
    warn "Set STANDBY_SYNC_SD_ROOT in config.env (usually /dev/mmcblk0p2)"
    (( ERRORS++ )) || true
fi

if [[ ${ERRORS} -gt 0 ]]; then
    echo ""
    echo "Fix the ${ERRORS} issue(s) above then re-run."
    exit 1
fi

ok "Config valid."
echo ""

# ── Mount SD root and install pi2s3 tools ─────────────────────────────────────
echo "Installing pi2s3 restore tools on SD card..."

SD_ROOT_MNT=$(mktemp -d)
_SD_ROOT_MOUNTED=false

cleanup() {
    [[ "${_SD_ROOT_MOUNTED}" == "true" ]] && sudo umount "${SD_ROOT_MNT}" 2>/dev/null || true
    rm -rf "${SD_ROOT_MNT}"
}
trap cleanup EXIT

sudo mount "${STANDBY_SYNC_SD_ROOT}" "${SD_ROOT_MNT}"
_SD_ROOT_MOUNTED=true
ok "SD root mounted at ${SD_ROOT_MNT}"

# Detect home directory on SD
SD_USER=$(ls "${SD_ROOT_MNT}/home/" 2>/dev/null | head -1 || echo "")
if [[ -z "${SD_USER}" ]]; then
    SD_HOME="${SD_ROOT_MNT}/root"
else
    SD_HOME="${SD_ROOT_MNT}/home/${SD_USER}"
fi
SD_PI2S3_DIR="${SD_HOME}/pi2s3"

log "SD home: ${SD_HOME}"
log "Installing pi2s3 to: ${SD_PI2S3_DIR}"

# Copy pi2s3 scripts to SD
sudo mkdir -p "${SD_PI2S3_DIR}"/{lib,extras/firstboot}
sudo cp "${PARENT_DIR}/pi-image-restore.sh" "${SD_PI2S3_DIR}/"
sudo cp "${PARENT_DIR}/config.env"          "${SD_PI2S3_DIR}/"
sudo cp "${PARENT_DIR}/lib/"*.sh            "${SD_PI2S3_DIR}/lib/"
sudo cp "${SCRIPT_DIR}/post-restore-nvme-boot.sh" \
        "${SD_PI2S3_DIR}/extras/"
sudo cp "${SCRIPT_DIR}/firstboot/standby-restore-agent.sh" \
        "${SD_PI2S3_DIR}/extras/firstboot/"

# Copy post-restore script if configured
if [[ -n "${STANDBY_POST_RESTORE_SCRIPT:-}" && -f "${STANDBY_POST_RESTORE_SCRIPT}" ]]; then
    sudo cp "${STANDBY_POST_RESTORE_SCRIPT}" "${SD_PI2S3_DIR}/extras/"
    ok "Post-restore script copied: $(basename "${STANDBY_POST_RESTORE_SCRIPT}")"
fi

ok "pi2s3 tools installed on SD."

# ── Wire restore agent to run on SD boot ─────────────────────────────────────
echo ""
echo "Wiring restore agent to SD boot sequence..."

SD_AGENT_PATH="${SD_PI2S3_DIR}/extras/firstboot/standby-restore-agent.sh"
# Strip the NVMe-side mount prefix — ExecStart must use the path as it
# appears when the SD card boots (e.g. /home/pi/pi2s3/... not /tmp/tmp.XXXX/...)
SD_AGENT_PATH_ON_CARD="${SD_AGENT_PATH#${SD_ROOT_MNT}}"

# Install as a systemd one-shot service that runs early in boot
SYSTEMD_DIR="${SD_ROOT_MNT}/etc/systemd/system"
sudo mkdir -p "${SYSTEMD_DIR}"

sudo tee "${SYSTEMD_DIR}/pi2s3-standby-restore.service" > /dev/null <<EOF
[Unit]
Description=pi2s3 Standby Restore Agent
DefaultDependencies=no
After=local-fs.target network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${SD_AGENT_PATH_ON_CARD}
RemainAfterExit=yes
StandardOutput=append:/var/log/pi2s3-standby-restore.log
StandardError=append:/var/log/pi2s3-standby-restore.log

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
SD_SYSTEMD_ENABLED="${SD_ROOT_MNT}/etc/systemd/system/multi-user.target.wants"
sudo mkdir -p "${SD_SYSTEMD_ENABLED}"
sudo ln -sf "${SYSTEMD_DIR}/pi2s3-standby-restore.service" \
    "${SD_SYSTEMD_ENABLED}/pi2s3-standby-restore.service" 2>/dev/null || true

ok "Systemd service installed and enabled on SD."

# ── Allow pi2s3 user to mount SD and reboot without password ─────────────────
echo ""
echo "Configuring sudoers on NVMe (allow mount + reboot for cron)..."

CURRENT_USER="${SUDO_USER:-$(id -un)}"
sudo tee /etc/sudoers.d/pi2s3-standby-sync > /dev/null <<EOF
# pi2s3 hot standby sync — allows cron to mount SD card and reboot
${CURRENT_USER} ALL=(ALL) NOPASSWD: /bin/mount ${STANDBY_SYNC_SD_BOOT} *
${CURRENT_USER} ALL=(ALL) NOPASSWD: /bin/umount ${STANDBY_SYNC_SD_BOOT}
${CURRENT_USER} ALL=(ALL) NOPASSWD: /sbin/reboot
${CURRENT_USER} ALL=(ALL) NOPASSWD: /bin/reboot
EOF
sudo chmod 440 /etc/sudoers.d/pi2s3-standby-sync

ok "Sudoers entry written: /etc/sudoers.d/pi2s3-standby-sync"

# ── Create log file ───────────────────────────────────────────────────────────
sudo touch /var/log/pi2s3-standby-sync.log
sudo chown "${CURRENT_USER}:${CURRENT_USER}" /var/log/pi2s3-standby-sync.log 2>/dev/null || \
    sudo chmod 640 /var/log/pi2s3-standby-sync.log
ok "Log file: /var/log/pi2s3-standby-sync.log"

# ── Unmount SD ────────────────────────────────────────────────────────────────
sudo umount "${SD_ROOT_MNT}"
_SD_ROOT_MOUNTED=false
ok "SD card unmounted."

# ── Install cron job on NVMe ──────────────────────────────────────────────────
echo ""
echo "Installing cron job on standby NVMe..."

SYNC_SCRIPT="${SCRIPT_DIR}/hot-standby-sync.sh"
CRON_LINE="${STANDBY_SYNC_CRON} bash ${SYNC_SCRIPT} >> /var/log/pi2s3-standby-sync.log 2>&1"

if crontab -l 2>/dev/null | grep -qF 'hot-standby-sync.sh'; then
    ( crontab -l 2>/dev/null | grep -v 'hot-standby-sync.sh' || true
      echo "${CRON_LINE}" ) | crontab -
    ok "Cron job updated."
else
    ( crontab -l 2>/dev/null || true
      echo "${CRON_LINE}" ) | crontab -
    ok "Cron job installed: ${STANDBY_SYNC_CRON}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo "  Hot standby sync installed."
echo ""
echo "  Schedule:    ${STANDBY_SYNC_CRON} (checks every 30 min)"
echo "  Sync device: ${STANDBY_SYNC_DEVICE}"
echo "  S3 marker:   s3://${S3_BUCKET}/${STANDBY_SYNC_MARKER_KEY}"
echo "  Log:         /var/log/pi2s3-standby-sync.log"
echo ""
echo "  When the primary Pi finishes a backup:"
echo "    1. DNS fails back to primary"
echo "    2. Primary writes sync marker to S3"
echo "    3. This Pi detects marker, writes trigger to SD, reboots"
echo "    4. SD restore agent restores NVMe from S3 (~30 min)"
echo "    5. Pi reboots into fresh NVMe, ready for failover"
echo ""
if [[ -n "${STANDBY_POST_RESTORE_SCRIPT:-}" ]]; then
    echo "  Post-restore: ${STANDBY_POST_RESTORE_SCRIPT}"
else
    echo "  Post-restore: not set"
    echo "  TIP: set STANDBY_POST_RESTORE_SCRIPT in config.env to"
    echo "       auto-configure the tunnel UUID after each sync."
    echo "       Template: extras/post-restore-standby-example.sh"
fi
echo "========================================================"
