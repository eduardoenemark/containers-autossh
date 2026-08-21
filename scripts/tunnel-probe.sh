#!/bin/sh
# =============================================================================
# tunnel-probe.sh — end-to-end tunnel liveness probe (exit 0 = healthy)
#
# Opens a real TCP connection to the forwarded port ON THE REMOTE HOST via an
# independent SSH session (remote forwards bind to loopback on the server, so
# the check must run there). Also used as the container HEALTHCHECK.
# =============================================================================
set -u

LIB_DIR="${AUTOSH_LIB_DIR:-/usr/local/lib}"
[ -f "${LIB_DIR}/autossh-lib.sh" ] || exit 2
. "${LIB_DIR}/autossh-lib.sh"

[ -n "${SSH_HOST:-}" ] || exit 2
_PORT="${TUNNEL_HEALTH_PORT:-$(resolve_health_port 2>/dev/null)}"
if [ -z "${_PORT}" ]; then
    # No forward to probe: fall back to "is the remote SSH reachable at all?"
    remote_exec 5 "true" && exit 0 || exit 1
fi

# bash /dev/tcp: succeeds iff a listener accepts on 127.0.0.1:${_PORT} remotely
remote_exec "${PROBE_TIMEOUT:-6}" \
    "bash -c 'exec 3<>/dev/tcp/127.0.0.1/${_PORT}' </dev/null >/dev/null 2>&1"
