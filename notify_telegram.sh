#!/usr/bin/env bash
set -Eeuo pipefail

NEW_PATH='/usr/local/sbin/ssh-login-alert'

if [[ ! -x $NEW_PATH ]]; then
    printf 'ERROR: %s is not installed or not executable.\n' "$NEW_PATH" >&2
    exit 1
fi

exec "$NEW_PATH" "$@"
