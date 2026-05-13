#!/usr/bin/env bash
# =============================================================
# extras/pi-status-monitor/setup.sh — Install boot status + heartbeat
#
# Installs:
#   /usr/local/bin/pi-boot-status.sh   — full dump on boot
#   /usr/local/bin/pi-heartbeat.sh     — 60-second status line on tty1
#   /etc/systemd/system/pi-boot-status.service
#   /etc/systemd/system/pi-heartbeat.service
#
# Usage:
#   bash extras/pi-status-monitor/setup.sh
#
# To watch the heartbeat after install:
#   journalctl -u pi-heartbeat -f
#
# To run the boot dump manually:
#   sudo pi-boot-status.sh
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

echo "==> Installing Pi status monitor..."

install -m 755 "${SCRIPT_DIR}/pi-boot-status.sh" /usr/local/bin/pi-boot-status.sh
install -m 755 "${SCRIPT_DIR}/pi-heartbeat.sh"   /usr/local/bin/pi-heartbeat.sh
echo "    scripts → /usr/local/bin/"

install -m 644 "${SCRIPT_DIR}/pi-boot-status.service" /etc/systemd/system/pi-boot-status.service
install -m 644 "${SCRIPT_DIR}/pi-heartbeat.service"   /etc/systemd/system/pi-heartbeat.service
echo "    systemd units installed"

systemctl daemon-reload
systemctl enable --now pi-heartbeat.service
systemctl enable pi-boot-status.service
echo "    pi-heartbeat started and enabled"
echo "    pi-boot-status enabled (runs on next boot)"

echo ""
echo "==> Done."
echo ""
echo "    Watch heartbeat:   journalctl -u pi-heartbeat -f"
echo "    Run boot dump now: sudo pi-boot-status.sh"
echo ""
echo "    Optional: set HEARTBEAT_HTTP_URL in /etc/systemd/system/pi-heartbeat.service"
echo "    under [Service] as Environment=HEARTBEAT_HTTP_URL=http://localhost:8080/"
echo "    to probe a local HTTP endpoint each tick."
