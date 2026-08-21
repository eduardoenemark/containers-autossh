# ----------------------------------------------------------------------
# Base image – slim Debian (trixie) with the latest security updates
# ----------------------------------------------------------------------
FROM docker.io/debian:trixie-20260518-slim

# ---------------------------------------------------------------
# 1. Environment variables – configure autossh at runtime
# ---------------------------------------------------------------
# repository url
ENV REPO_URL=https://github.com/eduardoenemark/containers-autossh

# build date/time
ARG CREATED_DATETIME
ENV CREATED_DATETIME=${CREATED_DATETIME}

# ------------------------------------------------------------------
# 2. Labels – OCI image metadata + extra documentation labels
# ------------------------------------------------------------------
LABEL org.opencontainers.image.ref.name="autossh" \
      org.opencontainers.image.version="1.1" \
      org.opencontainers.image.authors="@eduardoenemark" \
      org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.title="Autossh: SSH tunnel manager" \
      org.opencontainers.image.description="A tiny container that runs autossh to manage persistent SSH tunnels, with stale-forward cleanup, end-to-end watchdog and log rotation." \
      org.opencontainers.image.created="${CREATED_DATETIME}" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.purpose="Autossh persistent SSH tunnel manager" \
      org.opencontainers.image.vendor="t.me/eduardoenemark" \
      org.opencontainers.image.url="${REPO_URL}" \
      org.opencontainers.image.documentation="${REPO_URL}" \
      maintainer="Eduardo Vieira <eduardoenemark@gmail.com>"

# ------------------------------------------------------------------
# 3. Install required packages
# ------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y autossh sshpass socat netcat-openbsd net-tools iftop iptraf-ng bmon iputils-ping && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /tmp/*

# ------------------------------------------------------------------
# 4. Resilience scripts (entrypoint, probe, stale-forward cleanup)
# ------------------------------------------------------------------
COPY scripts/lib/autossh-lib.sh    /usr/local/lib/autossh-lib.sh
COPY scripts/entrypoint.sh         /usr/local/bin/entrypoint.sh
COPY scripts/tunnel-probe.sh       /usr/local/bin/tunnel-probe.sh
COPY scripts/remote-cleanup.sh     /usr/local/bin/remote-cleanup.sh
COPY scripts/ssh-auth-wrapper.sh   /usr/local/bin/ssh-auth-wrapper
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
               /usr/local/bin/tunnel-probe.sh \
               /usr/local/bin/remote-cleanup.sh \
               /usr/local/bin/ssh-auth-wrapper

# End-to-end liveness check: opens a TCP connection to the forwarded port on
# the remote host through an independent SSH session. With a restart policy,
# this lets the container runtime recover even if autossh itself wedges.
HEALTHCHECK --interval=30s --timeout=15s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/tunnel-probe.sh"]

# ------------------------------------------------------------------
# 5. Entrypoint – env-driven, signal-safe autossh supervisor
#    (all tunables via environment variables; see .env.example)
# ------------------------------------------------------------------
CMD ["/usr/local/bin/entrypoint.sh"]
