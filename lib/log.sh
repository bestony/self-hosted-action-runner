#!/usr/bin/env bash
# Shared logging helper for the container entrypoint and its libraries.
#
# Usage: log <debug|info|warn|error> <message...>
#
# LOG_LEVEL sets the minimum level that is printed (default: info).
# Each line starts with an ISO-8601 UTC timestamp. Warnings and errors go to
# stderr, all other levels go to stdout.

_log_level_value() {
    case "$1" in
        [Dd][Ee][Bb][Uu][Gg]) echo 1 ;;
        [Ii][Nn][Ff][Oo])     echo 2 ;;
        [Ww][Aa][Rr][Nn]*)    echo 3 ;;
        [Ee][Rr][Rr]*)        echo 4 ;;
        *) echo 2 ;;
    esac
}

log() {
    local level="$1"
    shift
    local msg="$*"

    local current_val msg_val
    current_val=$(_log_level_value "${LOG_LEVEL:-info}")
    msg_val=$(_log_level_value "$level")
    if [ "$msg_val" -lt "$current_val" ]; then
        return 0
    fi

    local tag
    case "$msg_val" in
        1) tag="DEBUG" ;;
        3) tag="WARN" ;;
        4) tag="ERROR" ;;
        *) tag="INFO" ;;
    esac

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    if [ "$msg_val" -ge 3 ]; then
        echo "${ts} [${tag}] ${msg}" >&2
    else
        echo "${ts} [${tag}] ${msg}"
    fi
}
