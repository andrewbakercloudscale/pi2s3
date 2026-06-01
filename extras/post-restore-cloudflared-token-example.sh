#!/usr/bin/env bash
# =============================================================
# extras/post-restore-cloudflared-token-example.sh
#   Post-restore template: preserve a TOKEN-BASED Cloudflare tunnel
#
# Use this when the target Pi runs cloudflared as:
#     cloudflared tunnel run --token <TOKEN>
# inside a systemd unit, with NO /etc/cloudflared/config.yml.
# (This is the current Cloudflare default — "remotely-managed" tunnels
#  whose ingress rules live in the dashboard.)
#
# WHY THIS MATTERS
#   A restore overwrites the target's filesystem with the SOURCE image,
#   including the source's cloudflared unit/tunnel. If the source and
#   target use DIFFERENT tunnels (e.g. restoring a PROD image onto a QA
#   box that must keep serving its OWN tunnel), the restored box boots on
#   the WRONG tunnel — and every hostname pointing at the target's tunnel
#   (including the SSH hostname you manage it through) goes dark.
#
#   The credentials-file example (post-restore-example.sh) does NOT help
#   here: with `--token`, cloudflared ignores config.yml for tunnel
#   selection. You must replace the systemd UNIT (the token lives in it).
#
# Called by pi-image-restore.sh:
#   bash pi-image-restore.sh --date latest --device /dev/nvme0n1 --yes \
#     --post-restore ~/post-restore-keep-my-tunnel.sh
#
# The restored root is mounted at $RESTORE_ROOT (also $1).
# Edit, rename for your use case, and keep it out of the repo (it carries
# a tunnel token).
# =============================================================
set -euo pipefail

RESTORE_ROOT="${RESTORE_ROOT:-${1:?RESTORE_ROOT is not set}}"

echo "==> Post-restore (keep token tunnel) on: ${RESTORE_ROOT}"

# Source of the token unit, in preference order:
#   1. A file you staged on the restoring machine (push it in beforehand).
#   2. The running system's own unit (a recovery/SD boot carries it).
CF_UNIT_SRC="${CF_UNIT_SRC:-/tmp/keep-cloudflared.service}"
[[ -f "${CF_UNIT_SRC}" ]] || CF_UNIT_SRC="/etc/systemd/system/cloudflared.service"

if [[ -f "${CF_UNIT_SRC}" ]] && grep -q -- '--token' "${CF_UNIT_SRC}"; then
    sudo cp "${CF_UNIT_SRC}" "${RESTORE_ROOT}/etc/systemd/system/cloudflared.service"

    # Enable at boot (multi-user.target wants/ symlink).
    sudo mkdir -p "${RESTORE_ROOT}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /etc/systemd/system/cloudflared.service \
        "${RESTORE_ROOT}/etc/systemd/system/multi-user.target.wants/cloudflared.service"

    # Carry over any drop-ins (e.g. wait-for-network.conf).
    if [[ -d /etc/systemd/system/cloudflared.service.d ]]; then
        sudo mkdir -p "${RESTORE_ROOT}/etc/systemd/system/cloudflared.service.d"
        sudo cp -f /etc/systemd/system/cloudflared.service.d/*.conf \
            "${RESTORE_ROOT}/etc/systemd/system/cloudflared.service.d/" 2>/dev/null || true
    fi

    # A leftover config.yml with `tunnel:`/`credentials-file:` conflicts with
    # `--token` (cloudflared refuses to start). Remove it so --token is unambiguous.
    sudo rm -f "${RESTORE_ROOT}/etc/cloudflared/config.yml"

    echo "    cloudflared: restored image pinned to the token tunnel; config.yml removed"
else
    echo "    ERROR: no token-based cloudflared unit at ${CF_UNIT_SRC}" >&2
    echo "           Refusing to continue — the restored Pi would boot on the" >&2
    echo "           source image's tunnel and you could lose remote access." >&2
    exit 1
fi

# ── SSH host keys + sshd enabled ────────────────────────────────────────────
# Regenerate so the restored Pi doesn't share host keys with the source, AND
# ensure sshd is enabled — without this, HTTP works but SSH (and the CF SSH
# tunnel above) goes dark after restore.
echo "==> SSH: regenerating host keys..."
sudo rm -f "${RESTORE_ROOT}"/etc/ssh/ssh_host_* 2>/dev/null || true
if sudo ssh-keygen -A -f "${RESTORE_ROOT}" >/dev/null 2>&1; then
    echo "    SSH host keys: regenerated."
else
    echo "    WARNING: ssh-keygen -A failed — run 'sudo ssh-keygen -A' after first boot." >&2
fi
for _svc in ssh sshd; do
    _unit="${RESTORE_ROOT}/lib/systemd/system/${_svc}.service"
    [[ -f "${_unit}" ]] || _unit="${RESTORE_ROOT}/usr/lib/systemd/system/${_svc}.service"
    if [[ -f "${_unit}" ]]; then
        sudo mkdir -p "${RESTORE_ROOT}/etc/systemd/system/multi-user.target.wants"
        sudo ln -sf "/lib/systemd/system/${_svc}.service" \
            "${RESTORE_ROOT}/etc/systemd/system/multi-user.target.wants/${_svc}.service" 2>/dev/null || true
        echo "    sshd: enabled at boot (${_svc}.service)."
        break
    fi
done

echo "==> Post-restore (keep token tunnel): done"
