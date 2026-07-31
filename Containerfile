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
      org.opencontainers.image.version="1.0" \
      org.opencontainers.image.authors="@eduardoenemark" \
      org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.title="Autossh: SSH tunnel manager" \
      org.opencontainers.image.description="A tiny container that runs autossh to manage persistent SSH tunnels on ${AUTOSH_PORT}." \
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
# 4. Declare runtime volumes – useful for persistence & debugging
# ------------------------------------------------------------------
VOLUME ["/var/log"]

# ------------------------------------------------------------------
# 5. Entrypoint – pass args to autossh
# ------------------------------------------------------------------
CMD [ "--wait" ]
