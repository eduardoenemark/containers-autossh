# Autossh: SSH Tunnel Manager

A lightweight containerized SSH tunnel manager that runs `autossh` to create and monitor persistent SSH tunnels. The container automatically restarts the SSH session if it dies or stops passing traffic, ensuring continuous connectivity.

## Overview

`autossh` monitors your SSH sessions and restarts them automatically when they fail. It does this by establishing a loop of SSH forwardings and periodically sending test data to verify that traffic is flowing. If the SSH process crashes or stops passing traffic, `autossh` detects it and restarts the session.

This container packages `autossh` alongside useful networking and debugging tools into a ready-to-run image for Podman and Docker.

## Features

- **Automatic tunnel restart** -- Detects dead SSH sessions and restarts them
- **Traffic monitoring** -- Periodically tests data flow through the tunnel
- **Exponential backoff** -- Gradually increases delay between restart attempts on repeated failures
- **Starting gate protection** -- Exits early if initial SSH setup fails (prevents infinite retry loops)
- **Built-in debugging tools** -- Includes `iftop`, `iptraf-ng`, `bmon`, `socat`, and `net-tools`

## Installation

### Build the image

```bash
./build.sh
```

This uses Podman to build the `autossh:1.0` image from the Containerfile.

## Usage

### Single container run

```bash
podman run --rm -it docker.io/eduardoenemark/autossh:1.0 sshpass -p 'PASSWORD' autossh -M 44444 -N -o 'ServerAliveInterval 10' -o 'ServerAliveCountMax 3' root@myvps-domain.com -R 8080:localhost:80
```

The container passes `--wait` to `autossh` by default, which waits for SSH to be fully established before beginning monitoring.

### Docker Compose

```yaml
version: '3.8'
services:
  autossh:
    image: docker.io/eduardoenemark/autossh:1.0
    container_name: autossh
    privileged: true
    network_mode: host
    restart: always
    stop_grace_period: 15s
    environment:
      - AUTOSSH_GATETIME=0
      - AUTOSSH_DEBUG=0
    command: |
      /bin/bash -c "
      sshpass -p 'PASSWORD' autossh -M 44444 -N -o 'ServerAliveInterval 10' -o 'ServerAliveCountMax 3' -o 'ExitOnForwardFailure yes' -o 'StrictHostKeyChecking no' -o 'CheckHostIP no' -o 'TCPKeepAlive yes' -y root@myvps-domain.com -p 22 -R 48383:0.0.0.0:48383 -R 18282:0.0.0.0:18283 -R 500:0.0.0.0:5000 -R 7000:0.0.0.0:7000
      "
    deploy:
      resources:
        limits:
          cpus: 1
          memory: 512m
```

```bash
docker-compose up -d
```

Replace `PASSWORD` with your SSH password and `root@myvps-domain.com` with your remote host. Adjust the `-R` reverse tunnel ports as needed.

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `AUTOSSH_PORT` | Connection monitoring port (overrides `-M`) | Auto-generated |
| `AUTOSSH_POLL` | Poll interval in seconds | 600 (10 minutes) |
| `AUTOSSH_GATETIME` | Time SSH must be up before considered successful | 30 (seconds) |
| `AUTOSSH_MAXLIFETIME` | Maximum seconds autossh should run | Unlimited |
| `AUTOSSH_MAXSTART` | Max number of SSH restart attempts | -1 (unlimited) |
| `AUTOSSH_LOGFILE` | Path to log file instead of syslog | Syslog |
| `AUTOSSH_DEBUG` | Enable debug logging | Disabled |

## Exit Behavior

1. If SSH exits normally (e.g., user typed `exit`), autossh exits too.
2. If autossh receives SIGTERM/SIGINT/SIGKILL, it exits after killing the child SSH process.
3. If autossh receives SIGUSR1, it kills the child and starts a new one.
4. Periodically tests traffic on the monitor port; if failed, restarts SSH.
5. If SSH dies for any other reason, autossh restarts it.

## Included Tools

| Tool | Purpose |
|---|---|
| `autossh` | Core SSH tunnel monitor/restart tool |
| `sshpass` | Non-interactive SSH password authentication |
| `socat` | Bidirectional data relay / socket connector |
| `net-tools` | Traditional networking tools (netstat, etc.) |
| `iputils-ping` | Provides the `ping` command for network diagnostics |
| `iftop` | Real-time bandwidth monitoring |
| `iptraf-ng` | Network traffic monitor |
| `bmon` | Bandwidth monitor |

| netcat-openbsd | Network utility for TCP/UDP connections (nc)

- The container requires **privileged mode** and **host networking** for direct port binding and tunnel manipulation.
- Authentication must be pre-configured (via SSH keys or `sshpass`) -- the container cannot handle interactive password prompts.
- Logs are mounted to `/var/log` for persistence and debugging.

## Author

Eduardo Vieira ([@eduardoenemark](https://t.me/eduardoenemark))

## License

[GPL-3.0-only](LICENSE)
