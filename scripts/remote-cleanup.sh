#!/bin/sh
# =============================================================================
# remote-cleanup.sh — kill whatever is squatting on the forwarded port on the
# remote host (stale sshd session left behind by a crashed client).
#
# Exit codes: 0 = port free (nothing to do, or successfully released)
#             1 = still held after cleanup attempt
#             2 = configuration/auth error (could not even reach the host)
# =============================================================================
set -u

LIB_DIR="${AUTOSH_LIB_DIR:-/usr/local/lib}"
[ -f "${LIB_DIR}/autossh-lib.sh" ] || exit 2
. "${LIB_DIR}/autossh-lib.sh"

[ -n "${SSH_HOST:-}" ] || { log "cleanup: SSH_HOST not set"; exit 2; }
_PORT="${TUNNEL_HEALTH_PORT:-$(resolve_health_port 2>/dev/null)}"
if [ -z "${_PORT}" ]; then
    log "cleanup: no health/forward port resolvable; nothing to do"
    exit 0
fi

# sshd session processes run setuid'd-down (non-dumpable), so even the same
# user cannot see their socket fds with fuser. Use sudo on the remote when
# configured; otherwise fall back to plain fuser (works for non-sshd holders).
SUDO_PREFIX=""
if [ -n "${REMOTE_SUDO_PASSWORD:-}" ]; then
    SUDO_PREFIX="echo '${REMOTE_SUDO_PASSWORD}' | sudo -S"
elif [ "${CLEANUP_USE_SUDO:-0}" = "1" ]; then
    SUDO_PREFIX="sudo -n"
fi

_remote_cmd="${SUDO_PREFIX} fuser -k -n tcp ${_PORT} >/dev/null 2>&1
sleep 1
if ss -tln | grep -qE '[:.]${_PORT}[[:space:]]'; then
    echo HELD
else
    echo FREE
fi"

_out="$(remote_exec 8 "${_remote_cmd}")" || { log "cleanup: cannot reach ${SSH_HOST} (auth/network error)"; exit 2; }
case "${_out}" in
    *FREE*) log "cleanup: remote port ${_PORT} is free"; exit 0 ;;
    *HELD*) log "cleanup: remote port ${_PORT} STILL HELD after fuser -k"; exit 1 ;;
    *)      log "cleanup: unexpected probe output from remote: ${_out:-<empty>}"; exit 1 ;;
esac
