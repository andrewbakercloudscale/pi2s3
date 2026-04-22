#!/usr/bin/env bash
# lib/log.sh — shared logging helpers
# Source this file; do not execute directly.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }
