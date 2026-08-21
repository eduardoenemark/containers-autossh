#!/bin/sh
# ssh-auth-wrapper.sh — stand-in for "ssh" used via AUTOSSH_PATH so that EVERY
# autossh (re)connect attempt authenticates through sshpass, not just the first
# one (autossh re-execs plain `ssh` internally on each restart).
[ -n "${SSH_PASSWORD:-}" ] || { echo "SSH_PASSWORD not set" >&2; exit 2; }
exec env SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "$@"
