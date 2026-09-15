#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEFAULT_CONFIG='/etc/ssh-login-alert.conf'
MAX_FIELD_LENGTH=256

log_notice() {
    if command -v logger >/dev/null 2>&1; then
        logger -t ssh-login-alert -- "$*" || true
    fi
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

sanitize_field() {
    local value=${1:-}
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//$'\t'/ }
    printf '%s' "${value:0:MAX_FIELD_LENGTH}"
}

render_message() {
    local login_user remote_host pam_service pam_tty host_label event_time
    login_user=$(sanitize_field "$1")
    remote_host=$(sanitize_field "$2")
    pam_service=$(sanitize_field "$3")
    pam_tty=$(sanitize_field "$4")
    host_label=$(sanitize_field "$5")
    event_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    [[ -n $remote_host ]] || remote_host='unknown'
    [[ -n $pam_tty ]] || pam_tty='unknown'

    printf 'SSH login detected\nHost: %s\nUser: %s\nRemote: %s\nService: %s\nTTY: %s\nTime (UTC): %s' \
        "$host_label" \
        "$login_user" \
        "$remote_host" \
        "$pam_service" \
        "$pam_tty" \
        "$event_time"
}

get_host_label() {
    local host_label
    host_label=$(hostname -f 2>/dev/null || true)
    if [[ -z $host_label ]]; then
        host_label=$(hostname 2>/dev/null || printf 'unknown')
    fi
    sanitize_field "$host_label"
}

read_config() {
    local config_file=$1 line key value mode owner

    [[ -f $config_file ]] || fatal "Configuration file not found: $config_file"
    [[ ! -L $config_file ]] || fatal "Configuration file must not be a symbolic link: $config_file"

    owner=$(stat -c '%u' -- "$config_file")
    [[ $owner == '0' ]] || fatal 'Configuration file must be owned by root.'

    mode=$(stat -c '%a' -- "$config_file")
    [[ $mode =~ ^[0-7]{3,4}$ ]] || fatal 'Unable to validate configuration file mode.'
    if (( (8#$mode & 077) != 0 )); then
        fatal 'Configuration file must not be readable or writable by group/others. Use mode 0600.'
    fi

    TELEGRAM_BOT_TOKEN=''
    TELEGRAM_CHAT_ID=''
    CURL_CONNECT_TIMEOUT='2'
    CURL_MAX_TIME='5'

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -n $line ]] || continue
        [[ $line == \#* ]] && continue
        [[ $line == *=* ]] || fatal "Invalid configuration line: $line"

        key=${line%%=*}
        value=${line#*=}
        case $key in
            TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN=$value ;;
            TELEGRAM_CHAT_ID) TELEGRAM_CHAT_ID=$value ;;
            CURL_CONNECT_TIMEOUT) CURL_CONNECT_TIMEOUT=$value ;;
            CURL_MAX_TIME) CURL_MAX_TIME=$value ;;
            *) fatal "Unknown configuration key: $key" ;;
        esac
    done < "$config_file"

    [[ $TELEGRAM_BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] \
        || fatal 'TELEGRAM_BOT_TOKEN has an invalid format.'
    [[ $TELEGRAM_CHAT_ID =~ ^-?[0-9]+$ ]] \
        || fatal 'TELEGRAM_CHAT_ID must be a numeric Telegram chat ID.'
    [[ $CURL_CONNECT_TIMEOUT =~ ^[1-9][0-9]*$ ]] \
        || fatal 'CURL_CONNECT_TIMEOUT must be a positive integer.'
    [[ $CURL_MAX_TIME =~ ^[1-9][0-9]*$ ]] \
        || fatal 'CURL_MAX_TIME must be a positive integer.'
    ((CURL_MAX_TIME >= CURL_CONNECT_TIMEOUT)) \
        || fatal 'CURL_MAX_TIME must be greater than or equal to CURL_CONNECT_TIMEOUT.'
}

send_worker() {
    local login_user=$1 remote_host=$2 pam_service=$3 pam_tty=$4 config_file=$5
    local host_label message curl_config

    command -v curl >/dev/null 2>&1 || fatal 'curl is required.'
    command -v stat >/dev/null 2>&1 || fatal 'stat is required.'

    read_config "$config_file"
    host_label=$(get_host_label)
    message=$(render_message "$login_user" "$remote_host" "$pam_service" "$pam_tty" "$host_label")

    curl_config=$(mktemp "${TMPDIR:-/tmp}/ssh-login-alert-curl.XXXXXXXX")
    chmod 0600 "$curl_config"
    trap 'rm -f -- "${curl_config:-}"' EXIT HUP INT TERM

    # Keep the bot token out of the curl command line and process arguments.
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" > "$curl_config"

    if ! curl \
        --config "$curl_config" \
        --silent \
        --show-error \
        --fail-with-body \
        --request POST \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --output /dev/null; then
        log_notice "Telegram delivery failed for SSH login event: user=$(sanitize_field "$login_user") remote=$(sanitize_field "$remote_host")"
        return 1
    fi

    log_notice "Telegram SSH login alert delivered: user=$(sanitize_field "$login_user") remote=$(sanitize_field "$remote_host")"
}

enqueue_pam_event() {
    local self_path login_user remote_host pam_service pam_tty

    # pam_exec may call the program for multiple PAM event types. Only an
    # authenticated SSH session opening should generate an alert.
    [[ ${PAM_TYPE:-} == 'open_session' ]] || exit 0
    [[ ${PAM_SERVICE:-} == 'sshd' ]] || exit 0

    login_user=$(sanitize_field "${PAM_USER:-unknown}")
    remote_host=$(sanitize_field "${PAM_RHOST:-unknown}")
    pam_service=$(sanitize_field "${PAM_SERVICE:-sshd}")
    pam_tty=$(sanitize_field "${PAM_TTY:-unknown}")

    command -v systemd-run >/dev/null 2>&1 || {
        log_notice 'systemd-run is unavailable; SSH login alert was skipped.'
        exit 0
    }

    self_path=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
    [[ -x $self_path ]] || {
        log_notice "Notifier is not executable: $self_path"
        exit 0
    }

    # Never make SSH authentication wait on DNS, Telegram, or external network
    # state. The transient service reads credentials later from the root-only
    # configuration file.
    if ! systemd-run \
        --quiet \
        --collect \
        --no-block \
        --property=Type=exec \
        -- \
        "$self_path" \
        --worker \
        --user "$login_user" \
        --remote "$remote_host" \
        --service "$pam_service" \
        --tty "$pam_tty" \
        --config "$DEFAULT_CONFIG"; then
        log_notice 'Unable to enqueue SSH login alert transient service.'
    fi

    # This hook is intended for a PAM "session optional pam_exec.so" rule.
    # Delivery failures must never reject or delay an SSH login.
    exit 0
}

worker_mode() {
    local login_user='' remote_host='' pam_service='sshd' pam_tty='' config_file=$DEFAULT_CONFIG

    while (($# > 0)); do
        case $1 in
            --user) (($# >= 2)) || fatal '--user requires a value.'; login_user=$2; shift 2 ;;
            --remote) (($# >= 2)) || fatal '--remote requires a value.'; remote_host=$2; shift 2 ;;
            --service) (($# >= 2)) || fatal '--service requires a value.'; pam_service=$2; shift 2 ;;
            --tty) (($# >= 2)) || fatal '--tty requires a value.'; pam_tty=$2; shift 2 ;;
            --config) (($# >= 2)) || fatal '--config requires a value.'; config_file=$2; shift 2 ;;
            *) fatal "Unknown worker option: $1" ;;
        esac
    done

    [[ -n $login_user ]] || fatal '--user is required in worker mode.'
    send_worker "$login_user" "$remote_host" "$pam_service" "$pam_tty" "$config_file"
}

preview_mode() {
    local login_user='' remote_host='' pam_service='sshd' pam_tty='ssh' host_label='example-host'

    while (($# > 0)); do
        case $1 in
            --user) (($# >= 2)) || fatal '--user requires a value.'; login_user=$2; shift 2 ;;
            --remote) (($# >= 2)) || fatal '--remote requires a value.'; remote_host=$2; shift 2 ;;
            --service) (($# >= 2)) || fatal '--service requires a value.'; pam_service=$2; shift 2 ;;
            --tty) (($# >= 2)) || fatal '--tty requires a value.'; pam_tty=$2; shift 2 ;;
            --host) (($# >= 2)) || fatal '--host requires a value.'; host_label=$2; shift 2 ;;
            *) fatal "Unknown preview option: $1" ;;
        esac
    done

    [[ -n $login_user ]] || fatal '--user is required in preview mode.'
    render_message "$login_user" "$remote_host" "$pam_service" "$pam_tty" "$host_label"
    printf '\n'
}

case ${1:-} in
    --worker)
        shift
        worker_mode "$@"
        ;;
    --preview)
        shift
        preview_mode "$@"
        ;;
    -h|--help)
        cat <<'EOF'
Usage:
  ssh-login-alert.sh                 Run as a PAM session hook.
  ssh-login-alert.sh --preview ...   Render a sample notification without network access.

PAM integration (review and back up /etc/pam.d/sshd first):
  session optional pam_exec.so quiet /usr/local/sbin/ssh-login-alert

The PAM path only enqueues a transient systemd worker and always returns success.
EOF
        ;;
    '')
        enqueue_pam_event
        ;;
    *)
        fatal "Unknown mode: $1"
        ;;
esac
