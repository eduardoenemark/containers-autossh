# Shared helpers for the autossh image (POSIX sh, dash-compatible)
# Sourced by entrypoint.sh / tunnel-probe.sh / remote-cleanup.sh

log() { echo "[autossh] $*" >&2; }

# Execute a command on the remote host using SSH. Auth comes from env:
#   SSH_KEY_FILE set  -> key auth (IdentitiesOnly, no password)
#   else              -> sshpass with SSHPASS=$SSH_PASSWORD
# Usage: remote_exec <connect-timeout-seconds> <command-string...>
remote_exec() {
    _tmo="${1:-6}"; shift
    [ -n "${SSH_HOST:-}" ] || return 2

    _opts="-o ConnectTimeout=${_tmo} \
-o StrictHostKeyChecking=${SSH_STRICT_HOSTKEY:-accept-new} \
-o CheckHostIP=no \
-p ${SSH_PORT:-22}"
    _target="${SSH_USER:-root}@${SSH_HOST}"

    if [ -n "${SSH_KEY_FILE:-}" ]; then
        # shellcheck disable=SC2086
        ssh -i "${SSH_KEY_FILE}" -o IdentitiesOnly=yes \
            -o PasswordAuthentication=no ${_opts} "${_target}" "$@"
    else
        [ -n "${SSH_PASSWORD:-}" ] || return 2
        # shellcheck disable=SC2086
        env SSHPASS="${SSH_PASSWORD}" sshpass -e ssh ${_opts} "${_target}" "$@"
    fi
}

# Print the port the watchdog/healthcheck should probe on the remote side:
#   1. explicit TUNNEL_HEALTH_PORT if set, else
#   2. first listen port of a -R forward found in TUNNELS, else empty
resolve_health_port() {
    if [ -n "${TUNNEL_HEALTH_PORT:-}" ]; then
        printf '%s\n' "${TUNNEL_HEALTH_PORT}"
        return 0
    fi
    _prev=""
    for _tok in ${TUNNELS:--R 8282:localhost:8282}; do
        if [ "${_prev}" = "-R" ]; then
            case "${_tok}" in
                \[*)          # bracketed bind address, e.g. [::1]:8282:...
                    _p="${_tok#*\]}"; _p="${_p#:}" ;;
                \*:*)         # wildcard bind prefix, e.g. *:8282:host:port
                    _p="${_tok#\*:}" ;;
                *)            : ;;
            esac
            _p="${_p%%:*}"    # listen port = part before the next colon
            case "${_p:-}" in
                ''|*[!0-9]*) : ;;
                *) printf '%s\n' "${_p}"; return 0 ;;
            esac
        fi
        _prev="${_tok}"
    done
    return 1
}
