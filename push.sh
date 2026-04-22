#!/usr/bin/env bash
# =============================================================
# push.sh — Push local commits to GitHub, then deploy to Pi
#
# Usage:
#   bash push.sh           # push + deploy to Pi
#   bash push.sh --no-deploy  # push only (skip Pi deploy)
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-deploy) DEPLOY=false ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [--no-deploy]"; exit 1 ;;
    esac
    shift
done

echo ""
echo "── pi2s3 push ──"
echo ""

# ── Git status ────────────────────────────────────────────────────────────────
BRANCH=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD)
AHEAD=$(git -C "${SCRIPT_DIR}" rev-list @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ' || echo "?")

echo "  Branch:  ${BRANCH}"
echo "  Commits: ${AHEAD} ahead of origin"
echo ""

if [[ "${AHEAD}" == "0" ]]; then
    echo "  Nothing to push — already up to date."
    echo ""
else
    echo "  Pushing..."
    git -C "${SCRIPT_DIR}" push
    echo "  Pushed."
    echo ""
fi

# ── Pi deploy ─────────────────────────────────────────────────────────────────
if [[ "${DEPLOY}" == "true" ]]; then
    bash "${SCRIPT_DIR}/deploy-pi.sh"
fi
