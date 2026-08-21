# Autossh: SSH Tunnel Manager

A lightweight containerized SSH tunnel manager that runs `autossh` to create and monitor persistent SSH tunnels, wrapped in a resilient entrypoint that also recovers from failure modes plain autossh cannot.

## Overview

`autossh` monitors your SSH session and restarts it automatically when it fails or stops passing traffic. This image goes one step further: the container's **entrypoint** (`scripts/entrypoint.sh`) supervises autossh and adds:

- **Stale-forward cleanup at startup** — kills whatever is squatting on the forwarded port on the remote host before connecting. This breaks the classic crash loop where a dead client left its `sshd` session holding the port, so every new connection dies with `remote port forwarding failed for listen port ...`.
- **End-to-end watchdog** — periodically opens a real TCP connection to the forwarded port *on the remote side* via an independent SSH session. After N consecutive failures it re-runs the stale-forward cleanup automatically (no container restart needed).
- **Container HEALTHCHECK** — the same probe (`tunnel-probe.sh`) is the image healthcheck, so with `restart: unless-stopped` the runtime recovers even if autossh itself wedges. Defense in depth: autossh watches ssh; the watchdog watches the tunnel; the runtime watches everything else.
- **Size-based log rotation** — `AUTOSSH_LOGFILE` is rotated to `.1` when it exceeds `AUTOSSH_LOG_MAX_BYTES`.
- **Signal-safe shutdown** — SIGTERM/SIGINT are forwarded to the ssh tree, so graceful stops release the remote forward immediately instead of leaving orphans.

### Failure modes handled (and why)

| Failure | Detection | Recovery |
|---|---|---|
| SSH process dies | autossh (waitpid) | immediate restart with exponential backoff |
| Dead connection, no RST (silent partition) | `ServerAliveInterval/CountMax` (~3×interval) + autossh monitor port | autossh reconnects |
| Stale remote forward holds the port (`remote port forwarding failed`) | startup check / watchdog probe fails ×N | `fuser -k` on the remote port via an independent SSH session, then autossh retries succeed |
| autossh itself wedges | container HEALTHCHECK (3× failures) | runtime restarts the container; entrypoint re-runs cleanup |
| Client killed without notice (`kill -9`, power loss) | server-side `ClientAliveInterval` on the remote sshd | sshd reaps the dead session within ~interval×count, port freed |

## Installation

### Build the image

```bash
./build.sh          # builds autossh:1.1 (name/version come from OCI labels)
```

Options:

| Flag | Effect |
|---|---|
| `--rm` | remove containers based on the image before building |
| `--push` | push the image after a successful build (requires registry login) |
| `IMAGE=meu/autossh:2.0 ./build.sh` | override the computed `name:version` tag |

### Docker Compose / Podman Compose

A ready-to-run, fully env-driven stack is provided in `docker-compose.yml` — since v1.1 there is **no `command:` block**; everything comes from environment variables (see `.env.example`):

```bash
cp .env.example .env   # adjust SSH host/user/password/tunnels
podman compose up -d
podman compose logs -f autossh     # entrypoint/watchdog log
tail -f $(podman volume inspect autossh-logs --format '{{.Mountpoint}}')/autossh.log
podman compose down
```

The service runs with host networking (required so the tunnel binds on the host NIC), `restart: unless-stopped`, CPU/memory caps via `deploy.resources` and persists logs in the named volume `autossh-logs`. `privileged` is **not** required.

### Recommended server-side tuning (both ends)

So a dead client's forward is reaped quickly instead of lingering for hours, add to `/etc/ssh/sshd_config.d/20-tunnel-keepalive.conf` on the remote host and reload:

```
ClientAliveInterval 30
ClientAliveCountMax 2
```

## Configuration (environment variables)

| Variable | Description | Default |
|---|---|---|
| `SSH_HOST` / `SSH_PORT` / `SSH_USER` | remote SSH endpoint | – / `22` / `root` (`SSH_HOST` required) |
| `SSH_PASSWORD` | password auth via sshpass (set this **or** `SSH_KEY_FILE`) | – |
| `SSH_KEY_FILE` | path to a private key **inside the container** (mount it read-only); disables password auth | – |
| `SSH_CONNECT_TIMEOUT` | TCP connect timeout per attempt (s) — keeps retries fast when the host is unreachable | `10` |
| `TUNNELS` | any ssh `-R`/`-L`/`-D` spec(s), space-separated | `-R 8282:localhost:8282` |
| `TUNNEL_HEALTH_PORT` | remote-side port for watchdog/healthcheck; empty = inferred from the first `-R` in `TUNNELS` | inferred |
| `AUTOSSH_MONITOR_PORT` | local port autossh uses to test traffic (`-M`) | `20001` |
| `AUTOSSH_GATETIME` | `0` = never give up, retry forever | `0` |
| `AUTOSSH_POLL` | seconds between traffic/watchdog probes | `30` |
| `SERVER_ALIVE_INTERVAL` / `SERVER_ALIVE_COUNT_MAX` | ssh keepalive — dead connections detected in ~interval×count | `10` / `3` |
| `AUTOSSH_CLEANUP_STALE` | `1` = one-shot stale-forward cleanup at startup | `1` |
| `REMOTE_SUDO_PASSWORD` | sudo password used by `fuser -k` on the remote (sshd sessions are invisible to plain users — root is required). Leave empty when using `CLEANUP_USE_SUDO` | – |
| `CLEANUP_USE_SUDO` | `1` = use passwordless `sudo -n` on the remote (needs a sudoers NOPASSWD entry for `fuser`) | `0` |
| `WATCHDOG_FAIL_THRESHOLD` | consecutive probe failures before auto-cleanup on the remote | `2` |
| `AUTOSSH_LOGFILE` | autossh log path (also rotated) | `/var/log/autossh.log` |
| `AUTOSSH_LOG_MAX_BYTES` | rotate when larger than this (~5 MB) | `5242880` |

### Single container run (no compose)

```bash
podman run -d --name autossh \
  -e SSH_HOST=myvps.example.com -e SSH_USER=root -e SSH_PASSWORD='SECRET' \
  -e TUNNELS='-R 8080:localhost:80' -e AUTOSSH_GATETIME=0 \
  autossh:1.1
```

Or with explicit args (bypasses the entrypoint):

```bash
podman run --rm -it autossh:1.1 sshpass -p 'PASSWORD' autossh -M 20001 -N -o ServerAliveInterval=10 -o ServerAliveCountMax=3 root@myvps-domain.com -R 8080:localhost:80
```

## Exit Behavior

1. If SSH exits normally, autossh exits too; the entrypoint propagates the status so `restart:` policies kick in.
2. SIGTERM/SIGINT to the container are forwarded to the ssh tree (graceful stop releases remote forwards immediately).
3. Periodic traffic test on the monitor port; failure restarts SSH with backoff.
4. Watchdog: N failed end-to-end probes trigger a remote stale-forward cleanup while autossh keeps retrying.
5. Healthcheck failures for long enough make the runtime restart the container (last-resort recovery).

## Included Tools

| Tool | Purpose |
|---|---|
| `autossh` | Core SSH tunnel monitor/restart tool |
| `sshpass` | Non-interactive SSH password authentication |
| `socat`, `netcat-openbsd`, `net-tools` | Data relay / socket checks (incl. healthcheck fallback) |
| `iftop`, `iptraf-ng`, `bmon`, `iputils-ping` | Bandwidth/traffic diagnostics |

## Resilience Test Suite

`scripts/test-resilience.sh` runs a fault-injection matrix against the remote VM and measures time-to-recovery with a 2 s end-to-end probe loop:

- **S0** cold start with a stale forward squatting on the port (real-world crash-loop repro)
- **S2** remote `sshd` service restart
- **S3** network partition for 60 s (iptables DROP, auto-teardown)
- **S4** `podman kill` — client dies without notice; measures how fast the server reaps the orphaned forward
- **S5** flapping: three short partitions in a row (no wedging)
- **S6** graceful stop/start (forward released immediately on SIGTERM)

```bash
./scripts/test-resilience.sh            # all scenarios
./scripts/test-resilience.sh S3 S4      # selected ones
REMOTE_HOST=192.168.2.9 ./scripts/test-resilience.sh S0
```

## Notes & Limitations

- **Host networking is required** (the tunnel must bind on the host NIC); `privileged` is not needed since v1.1.
- The stale-forward cleanup kills whatever listens on `TUNNEL_HEALTH_PORT` on the remote — don't run two different tunnels sharing that port from different clients.
- Password auth keeps the secret in env/`.env`; for production prefer SSH keys (see `SSH_KEY_FILE`).
- Remote forwards bind to loopback on the server by default (OpenSSH ≥ 7.6), which is why the probe runs *on* the remote host via an independent session rather than dialing it from outside.
