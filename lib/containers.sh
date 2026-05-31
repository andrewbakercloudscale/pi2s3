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

# container_db_engine container_name
# Inspects a container's image and prints the DB engine it runs.
# Prints "postgres" for any postgres/postgresql image, "mysql" otherwise.
container_db_engine() {
    local _img
    _img=$(docker inspect --format '{{.Config.Image}}' "$1" 2>/dev/null || true)
    if grep -qiE 'postgres|postgresql' <<<"${_img}"; then
        echo "postgres"
    else
        echo "mysql"
    fi
}

# find_db — detect a running database, in a container OR natively on the host.
# Prints "<engine> <container>" where engine ∈ mysql|postgres and <container>
# is the container name (empty for a native/host install). Prints nothing if no
# supported database is found.
#
# Detection order: Docker containers first (covers the common Compose setup),
# then native host processes (mariadbd/mysqld → mysql, postgres → postgres).
# "mysql" covers both MySQL and MariaDB — they share the FLUSH TABLES syntax.
find_db() {
    # 1. Docker containers
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        local _line _name _img
        _line=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
            | grep -iE '\bmariadb\b|\bmysql\b|\bpostgres\b|\bpostgresql\b' | head -1 || true)
        if [[ -n "${_line}" ]]; then
            _name=$(awk '{print $1}' <<<"${_line}")
            _img=$(awk '{print $2}' <<<"${_line}")
            if grep -qiE 'postgres|postgresql' <<<"${_img}"; then
                echo "postgres ${_name}"
            else
                echo "mysql ${_name}"
            fi
            return 0
        fi
    fi
    # 2. Native host processes (no container)
    if pgrep -x mariadbd &>/dev/null || pgrep -x mysqld &>/dev/null; then
        echo "mysql "
        return 0
    fi
    if pgrep -x postgres &>/dev/null; then
        echo "postgres "
        return 0
    fi
    return 0
}
