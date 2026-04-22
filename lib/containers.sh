#!/usr/bin/env bash
# lib/containers.sh — shared Docker container helpers
# Source this file; do not execute directly.

# find_db_container — scan running containers for a mariadb/mysql image.
# Prints the container name to stdout, or nothing if none found.
find_db_container() {
    command -v docker &>/dev/null || return 0
    docker info &>/dev/null 2>&1 || return 0
    docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
        | grep -iE '\bmariadb\b|\bmysql\b' | awk '{print $1}' | head -1 || true
}

# read_container_db_password container_name
# Reads MYSQL_ROOT_PASSWORD or MARIADB_ROOT_PASSWORD from the container's env.
# Prints the password to stdout, or nothing if unavailable.
read_container_db_password() {
    local _ctr="$1"
    [[ -z "${_ctr}" ]] && return 0
    docker exec "${_ctr}" env 2>/dev/null \
        | grep -E "^MYSQL_ROOT_PASSWORD=|^MARIADB_ROOT_PASSWORD=" \
        | cut -d= -f2- | head -1 || true
}
