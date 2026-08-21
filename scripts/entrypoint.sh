#!/bin/sh
# =============================================================================
# entrypoint.sh — resilient supervisor for autossh (POSIX sh)
#
# Responsibilities beyond plain `autossh`:
#   1. signal-safe shutdown (forwards SIGTERM/SIGINT to the ssh tree)
#   2. one-shot cleanup of stale remote port forwards at startup
#   3. background watchdog: if end-to-end probes keep failing, kill the
#      process that is squatting on the forwarded port on the remote host
#      (the "remote port forwarding failed" crash-loop breaker)
#   4. simple size-based log rotation for AUTOSSH_LOGFILE
#
# Everything is configured via environment variables (see .env.example).
# =============================================================================
set -u

LIB_DIR="${AUTOSH_LIB_DIR:-/usr/local/lib}"
[ -f "${LIB_DIR}/autossh-lib.sh" ] || { echo "missing ${LIB_DIR}/autossh-lib.sh" >&2; exit 1; }
. "${LIB_DIR}/autossh-lib.sh"

[ -n "${SSH_HOST:-}" ] || { log "ERROR: SSH_HOST is not set"; exit 2; }
if [ -z "${SSH_KEY_FILE:-}" ] && [ -z "${SSH_PASSWORD:-}" ]; then
    log "ERROR: set SSH_PASSWORD or mount a key and set SSH_KEY_FILE"
    exit 2
fi

SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
MONITOR_PORT="${AUTOSSH_MONITOR_PORT:-20001}"
POLL="${AUTOSSH_POLL:-30}"
ALIVE_INTERVAL="${SERVER_ALIVE_INTERVAL:-10}"
ALIVE_COUNT_MAX="${SERVER_ALIVE_COUNT_MAX:-3}"
CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
LOGFILE="${AUTOSSH_LOGFILE:-/var/log/autossh.log}"
TUNNELS="${TUNNELS:--R 8282:localhost:8282}"
CLEANUP_STALE="${AUTOSSH_CLEANUP_STALE:-1}"
LOG_MAX_BYTES="${AUTOSSH_LOG_MAX_BYTES:-5242880}"
WATCHDOG_FAIL_THRESHOLD="${WATCHDOG_FAIL_THRESHOLD:-2}"

HEALTH_PORT="$(resolve_health_port || true)"
if [ -n "${HEALTH_PORT}" ]; then
    log "tunnel health port (remote side): ${HEALTH_PORT}"
else
    log "WARNING: no -R forward found and TUNNEL_HEALTH_PORT unset; watchdog disabled"
fi

# --- build the autossh argument vector via positional params -----------------
set -- autossh \
    -M "${MONITOR_PORT}" \
    -N \
    -o ServerAliveInterval="${ALIVE_INTERVAL}" \
    -o ServerAliveCountMax="${ALIVE_COUNT_MAX}" \
    -o ConnectTimeout="${CONNECT_TIMEOUT}" \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking="${SSH_STRICT_HOSTKEY:-accept-new}" \
    -o CheckHostIP=no \
    -o TCPKeepAlive=yes \
    -o GSSAPIAuthentication=no \
    "${SSH_USER}@${SSH_HOST}" \
    -p "${SSH_PORT}"
for _t in ${TUNNELS}; do set -- "$@" "${_t}"; done

# Key auth: inject key options right after "autossh" (tokens are all single words,
# safe to re-split).
if [ -n "${SSH_KEY_FILE:-}" ]; then
    _all="$*"
    # shellcheck disable=SC2086
    set -- autossh -i "${SSH_KEY_FILE}" -o IdentitiesOnly=yes -o PasswordAuthentication=no ${_all#autossh }
fi

# In password mode point autossh at the auth wrapper so every (re)connect —
# not only the first one — goes through sshpass.
if [ -n "${SSH_KEY_FILE:-}" ]; then
    : # key auth: plain ssh is fine
else
    export AUTOSSH_PATH=/usr/local/bin/ssh-auth-wrapper
fi

log "starting: $*"

# --- background helper: size-based log rotation -------------------------------
(   while :; do
        sleep 300
        [ -f "${LOGFILE}" ] || continue
        _sz="$(wc -c <"${LOGFILE}")" 2>/dev/null || continue
        if [ "${_sz:-0}" -gt "${LOG_MAX_BYTES}" ]; then
            mv -f "${LOGFILE}" "${LOGFILE}.1" \
                && log "log rotated: ${LOGFILE} -> ${LOGFILE}.1 (${_sz} bytes)"
        fi
    done ) &
ROTATE_PID=$!

# --- background helper: end-to-end watchdog -----------------------------------
(   _fails=0
    while :; do
        sleep "${POLL}"
        if [ -z "${HEALTH_PORT}" ]; then continue; fi
        if TUNNEL_HEALTH_PORT="${HEALTH_PORT}" \
                /usr/local/bin/tunnel-probe.sh >/dev/null 2>&1; then
            _fails=0
        else
            _fails=$((_fails + 1))
            log "watchdog: tunnel probe failed (${_fails}/${WATCHDOG_FAIL_THRESHOLD})"
            if [ "${_fails}" -ge "${WATCHDOG_FAIL_THRESHOLD}" ]; then
                log "watchdog: cleaning stale remote forward on port ${HEALTH_PORT}"
                TUNNEL_HEALTH_PORT="${HEALTH_PORT}" \
                    /usr/local/bin/remote-cleanup.sh || true
                _fails=0
            fi
        fi
    done ) &
WATCHDOG_PID=$!

# --- one-shot cleanup of stale forwarders before the first connection --------
if [ -n "${HEALTH_PORT}" ] && [ "${CLEANUP_STALE}" = "1" ]; then
    log "startup: checking for stale remote forward on port ${HEALTH_PORT}"
    if TUNNEL_HEALTH_PORT="${HEALTH_PORT}" /usr/local/bin/remote-cleanup.sh; then
        log "startup: no stale forward found (or already released)"
    else
        log "startup: could not verify/clear port ${HEALTH_PORT} remotely (continuing anyway)"
    fi
fi

# --- run autossh in the foreground with signal forwarding ---------------------
AUTOPID=""
on_term() {
    # propagate TERM downward and let pid1 die immediately — waiting on the child
    # here can stall (dash trap/wait interplay); podman reaps via cgroup/grace.
    log "received termination signal; stopping ssh tree"
    kill TERM "${ROTATE_PID}" "${WATCHDOG_PID}" 2>/dev/null
    [ -n "${AUTOPID}" ] && kill TERM "${AUTOPID}" 2>/dev/null
    exit 0
}
trap on_term TERM INT

"$@" &
AUTOPID=$!
wait "${AUTOPID}"
_rc=$?
kill "${ROTATE_PID}" "${WATCHDOG_PID}" 2>/dev/null
log "autossh exited with status ${_rc}"
exit "${_rc}"
