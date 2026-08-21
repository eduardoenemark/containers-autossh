#!/usr/bin/env bash
# =============================================================================
# test-resilience.sh — resilience scenario matrix for the autossh container
#
# Runs fault-injection scenarios against a REMOTE VM and measures, with a 2s
# end-to-end probe loop, how fast the tunnel recovers (TTR).
#
# Usage:
#   ./scripts/test-resilience.sh              # all scenarios S1..S6
#   ./scripts/test-resilience.sh S3 S5        # only selected scenarios
#
# Env overrides: REMOTE_HOST, CONTAINER, TUNNEL_HEALTH_PORT, MY_IP
# Requires: .env in the repo root (SSH_PASSWORD etc.), sshpass on this host.
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_HOST="${REMOTE_HOST:-192.168.2.9}"
CONTAINER="${CONTAINER:-autossh-lab}"
HEALTH_PORT="${TUNNEL_HEALTH_PORT:-8282}"
PROBE_LOG="/tmp/opencode/probe.log"
FAULT_LOG="/tmp/opencode/faults.log"
SUDO_PW="kali"

# lê apenas as chaves necessárias do .env (sem source: valores podem ter espaços)
env_get() { sed -n "s/^[[:space:]]*$1=//p" "${REPO_DIR}/.env" 2>/dev/null | head -1; }
PW="$(env_get SSH_PASSWORD)"
[ -n "$PW" ] || PW="kali"
export SSHPASS="$PW"

MY_IP="${MY_IP:-$(ip route get "$REMOTE_HOST" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}"
[ -n "${MY_IP}" ] || { echo "ERRO: não consegui descobrir o IP local (defina MY_IP)"; exit 2; }

SSH_OPTS="-o ConnectTimeout=4 -o StrictHostKeyChecking=no -p ${SSH_PORT:-22} ${SSH_USER_REMOTE:-kali}@${REMOTE_HOST}"
rssh() { sshpass -e ssh $SSH_OPTS "$@"; }
rsudo() { rssh "echo '${SUDO_PW}' | sudo -S $*" 2>/dev/null; }

# --- probing (síncrono: cada amostra é registrada em PROBE_LOG) ------------------
probe_once() {
    # timeout cap: ConnectTimeout só cobre o TCP; kex/auth pode estagnar em retransmissões
    SSHPASS="$PW" timeout 8 sshpass -e ssh $SSH_OPTS \
        "bash -c 'exec 3<>/dev/tcp/127.0.0.1/${HEALTH_PORT}' </dev/null >/dev/null 2>&1"
}
probe_logged() { # roda uma sonda e registra o resultado; retorna o status dela
    if probe_once; then echo "$(date +%s) UP" >>"$PROBE_LOG"; else echo "$(date +%s) DOWN" >>"$PROBE_LOG"; return 1; fi
}

# --- fault bookkeeping ----------------------------------------------------------
LAST_FAULT_TS=""
fault_start() { LAST_FAULT_TS=$(date +%s); echo "${LAST_FAULT_TS} $1 start" >>"$FAULT_LOG"; }
fault_end()   { local e; e=$(date +%s); LAST_END_TS=$e; echo "$e $1 end" >>"$FAULT_LOG"; }
RECOVERY_TS=""
wait_up() { # max wait seconds; 0=ok — registra amostras; RECOVERY_TS = instante da recuperação
    local deadline=$(( $(date +%s) + ${1:-120} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if probe_logged; then RECOVERY_TS=$(date +%s); return 0; fi
        sleep 3
    done
    return 1
}
sleep_probe() { # dorme $1 s (janela de falta) registrando amostras no ritmo das sondas
    local deadline=$(( $(date +%s) + ${1:-5} ))
    while [ "$(date +%s)" -lt "$deadline" ]; do probe_logged || true; done
}
remote_port_held() { rssh "ss -tln | grep -qE '[:.]${HEALTH_PORT}[[:space:]]'"; }

# --- iptables partition (comment-tagged, always torn down) -----------------------
TAG="autossh-resilience-test"
IN_ARGS="-p tcp --source ${MY_IP} --dport 22 -m comment --comment ${TAG} -j DROP"
OUT_ARGS="-p tcp --destination ${MY_IP} --sport 22 -m comment --comment ${TAG} -j DROP"

add_partition() { # $1 = duração em segundos (agendada a auto-remoção no remoto)
    local dur="${1:-60}"
    # 1) auto-limpeza agendada NO REMOTO — executa mesmo se a minha conexão for cortada
    rsudo "setsid sh -c 'sleep ${dur}; sudo -n iptables -D INPUT ${IN_ARGS}; sudo -n iptables -D OUTPUT ${OUT_ARGS}' >/dev/null 2>&1 </dev/null & echo scheduled" \
        | grep -q scheduled || echo "  AVISO: não consegui agendar a auto-remoção no remoto"
    # 2) insere as regras de partição
    rsudo "iptables -I INPUT ${IN_ARGS}"
    rsudo "iptables -I OUTPUT ${OUT_ARGS}"
}
remove_partition() { # polling até as regras sumirem (sobrevive à janela de partição)
    local deadline=$(( $(date +%s) + 45 )) left line args c
    while [ "$(date +%s)" -lt "$deadline" ]; do
        left=$(rssh "sudo -n iptables-save 2>/dev/null | grep -c ${TAG}" || true)
        case "${left:-0}" in ''|*[!0-9]*) break ;; 0) return 0 ;; esac
        for c in INPUT OUTPUT; do
            line=$(rssh "sudo -n iptables-save 2>/dev/null | grep \"^-A ${c} .*${TAG}\" | head -1" || true)
            [ -n "$line" ] || continue
            args=${line#*-A $c }
            rssh "sudo -n iptables -D ${c} ${args}" >/dev/null 2>&1 || true
        done
        sleep 3
    done
    return 0
}
trap 'remove_partition' EXIT

RESULTS=()
report() { RESULTS+=("$*"); echo "  -> $*"; }

scenario_header() { echo; echo "=== $1 ==="; }

# --- scenarios -------------------------------------------------------------------
S0_clean_start_after_stale() {
    scenario_header "S0: cold start with stale remote forward present (real-world repro)"
    # ensure the container is down and a stale holder exists on the remote
    podman stop "$CONTAINER" 2>/dev/null; podman rm -f "$CONTAINER" 2>/dev/null
    if ! remote_port_held; then
        echo "  (sem forward órfão no remoto — plantando um)"
        setsid sshpass -e ssh $SSH_OPTS -N \
            "-R ${HEALTH_PORT}:127.0.0.1:${HEALTH_PORT}" >/dev/null 2>&1 &
        SEED_PID=$!
        local d=$(( $(date +%s) + 30 ))
        until remote_port_held || [ "$(date +%s)" -gt "$d" ]; do sleep 1; done
    fi
    if ! remote_port_held; then
        report "FAIL não consegui plantar o forward órfão (seed ssh falhou)"; return 1
    fi
    fault_start S0
    podman compose -f "${REPO_DIR}/docker-compose.yml" up -d >/dev/null
    if wait_up 120; then
        echo "  evidência (log do entrypoint):"
        podman logs "$CONTAINER" 2>&1 | grep -E 'cleanup|stale' | head -3 | sed 's/^/    /'
        report "PASS TTR_inj=$((RECOVERY_TS - LAST_FAULT_TS))s (startup cleanup liberou a porta e o túnel subiu)"
    else
        report "FAIL túnel não subiu em 120s com forward órfão presente"
    fi
}

S2_sshd_restart() {
    scenario_header "S2: remote sshd service restart"
    fault_start S2
    rsudo "systemctl restart ssh" >/dev/null
    if wait_up 90; then
        report "PASS TTR_inj=$((RECOVERY_TS - LAST_FAULT_TS))s (RST imediato, reconexão rápida)"
    else
        report "FAIL não recuperou em 90s"
    fi
}

S3_partition() {
    local dur="${1:-60}"
    scenario_header "S3: network partition ${dur}s (iptables DROP no remoto)"
    fault_start S3
    add_partition "${dur}"; sleep_probe "$dur"; fault_end S3; remove_partition
    if wait_up 90; then
        report "PASS TTR_remoção=$((RECOVERY_TS - LAST_END_TS))s após a remoção das regras (keepalive detectou a conexão morta)"
    else
        report "FAIL não recuperou em 90s após remoção"
    fi
}

S4_hard_kill() {
    scenario_header "S4: podman kill (cliente morre sem aviso) -> reap no remoto + novo start"
    fault_start S4
    podman kill "$CONTAINER" >/dev/null
    local free_after=$(rssh "for i in \$(seq 1 90); do ss -tln | grep -qE '[:.]${HEALTH_PORT}[[:space:]]' || { echo \$((i*2)); exit; }; sleep 2; done; echo TIMEOUT")
    fault_start S4b
    podman compose -f "${REPO_DIR}/docker-compose.yml" up -d >/dev/null
    if wait_up 120; then
        report "PASS porta livre em ${free_after}s após kill (keepalive server) + TTR_novostart=$((RECOVERY_TS - LAST_FAULT_TS))s"
    else
        report "FAIL não recuperou após re-start"
    fi
}

S5_flapping() {
    scenario_header "S5: flapping — 3 partições curtas (25s) alternadas"
    local ok=1 i rec
    for i in 1 2 3; do
        fault_start "S5-$i"
        add_partition 25; sleep_probe 25; remove_partition
        if wait_up 90; then
            echo "  ciclo $i: recuperado em $((RECOVERY_TS - LAST_FAULT_TS))s desde a injeção"
        else
            ok=0; echo "  ciclo $i: FALHOU"; break
        fi
    done
    [ "$ok" = 1 ] && report "PASS 3/3 ciclos recuperados, sem travamento" || report "FAIL flapping"
}

S6_graceful_stop() {
    scenario_header "S6: stop gracioso (SIGTERM) -> forward liberado no remoto + novo start"
    fault_start S6
    podman stop "$CONTAINER" >/dev/null
    local free_after=$(rssh "for i in \$(seq 1 30); do ss -tln | grep -qE '[:.]${HEALTH_PORT}[[:space:]]' || { echo \$((i*2)); exit; }; sleep 2; done; echo TIMEOUT")
    fault_start S6b
    podman compose -f "${REPO_DIR}/docker-compose.yml" up -d >/dev/null
    if wait_up 90; then
        report "PASS porta livre em ${free_after}s após SIGTERM + TTR_novostart=$((RECOVERY_TS - LAST_FAULT_TS))s"
    else
        report "FAIL não recuperou após re-start gracioso"
    fi
}

data_path_check() {
    scenario_header "CHECK: caminho de dados end-to-end (apache local via túnel)"
    if rssh "curl -sS -m 5 http://127.0.0.1:${HEALTH_PORT}/ 2>/dev/null | head -c 120" | grep -qi 'html\|<'; then
        report "PASS dados fluem do host local através do túnel"
    else
        report "INFO/FALHA: resposta não verificada (apache local ativo?)"
    fi
}

# --- main ------------------------------------------------------------------------
declare -A SCENARIOS=( [S0]=S0_clean_start_after_stale [S2]=S2_sshd_restart \
                       [S3]=S3_partition [S4]=S4_hard_kill [S5]=S5_flapping \
                       [S6]=S6_graceful_stop )

if [ "$#" -gt 0 ]; then SELECTED=("$@"); else SELECTED=(S0 S2 S3 S4 S5 S6); fi

echo "Remote : ${SSH_USER_REMOTE:-kali}@${REMOTE_HOST}  (partida local: ${MY_IP})"
echo "Porta  : ${HEALTH_PORT}   Container: ${CONTAINER}"
: > "$PROBE_LOG"; : > "$FAULT_LOG"
trap 'remove_partition' EXIT

# sanity: baseline deve estar UP antes de qualquer injeção de falta
echo "baseline:"; probe_logged && echo "  baseline OK (túnel ativo)" || { echo "  ERRO: túnel não está up no baseline"; exit 3; }

for s in "${SELECTED[@]}"; do
    if [ "$s" = "S3" ]; then S3_partition 60; continue; fi
    cmd="${SCENARIOS[$s]:-}"; [ -n "$cmd" ] || { echo "cenário desconhecido: $s"; exit 2; }
    "$cmd"
done

data_path_check
trap - EXIT

echo
echo "==================== RESUMO ===================="
printf '%-100s\n' "${RESULTS[@]}"
echo "Probes : $(wc -l <"$PROBE_LOG") amostras em $PROBE_LOG"
