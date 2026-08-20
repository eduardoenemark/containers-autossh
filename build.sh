#!/usr/bin/env bash
# =============================================================================
# build.sh — constrói a imagem autossh com Podman (ou Docker, se PREFERIDO)
#
# Uso:
#   ./build.sh                 # lê nome/versão do Containerfile e constrói
#   ./build.sh --rm            # remove containers da imagem antes de buildar
#   ./build.sh --push          # empurra a imagem após o build (requer login)
#   IMAGE=meu/autossh:2.0 ./build.sh   # força nome:versão da tag
# =============================================================================
set -euo pipefail

CONTAINER_FILE="${CONTAINER_FILE:-Containerfile}"
TAG_OVERRIDE="${IMAGE:-}"
PUSH=0
PRUNE_BEFORE_BUILD=0

for arg in "$@"; do
  case "${arg}" in
    --push) PUSH=1 ;;
    --rm)   PRUNE_BEFORE_BUILD=1 ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opção desconhecida: ${arg} (veja --help)" >&2; exit 2 ;;
  esac
done

# --- Detecta runtime de containers -------------------------------------------
if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
elif command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
else
  echo "ERRO: nem podman nem docker encontrados no PATH." >&2
  exit 1
fi

if [[ ! -f "${CONTAINER_FILE}" ]]; then
  echo "ERRO: ${CONTAINER_FILE} não encontrado em $(pwd)." >&2
  exit 1
fi

# --- Nome e versão vindos dos labels OCI do Containerfile ---------------------
NAME="$(awk '
  BEGIN { to_remove_regex = ".*=|[\"\\\\/]+| +$|^ +" }
  /org.opencontainers.image.ref.name/{gsub(to_remove_regex,"", $0); name=$0}
  END{print name}' "${CONTAINER_FILE}")"

VERSION="$(awk '
  BEGIN { to_remove_regex = ".*=|[\"\\\\/]+| +$|^ +" }
  /org.opencontainers.image.version/{gsub(to_remove_regex,"", $0); version=$0}
  END{print version}' "${CONTAINER_FILE}")"

if [[ -z "${NAME}" || -z "${VERSION}" ]]; then
  echo "ERRO: não consegui extrair nome/versão dos labels do ${CONTAINER_FILE}." >&2
  exit 1
fi

TAG="${TAG_OVERRIDE:-${NAME}:${VERSION}}"
CREATED_DATETIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Runtime : ${RUNTIME}"
echo "Imagem  : ${TAG}"
echo "Arquivo : ${CONTAINER_FILE}"
echo

if [[ "${PRUNE_BEFORE_BUILD}" -eq 1 ]]; then
  echo "Removendo containers da imagem anterior..."
  "${RUNTIME}" ps -a --format '{{.ID}} {{.Image}}' | awk -v img="${TAG}" '$2==img {print $1}' \
    | xargs -r -n1 "${RUNTIME}" rm -f || true
fi

echo "Construindo..."
"${RUNTIME}" build \
  --platform linux/amd64 \
  --build-arg CREATED_DATETIME="${CREATED_DATETIME}" \
  --tag "${TAG}" \
  --file "${CONTAINER_FILE}" \
  .

echo
echo "Imagem pronta: ${TAG}"
"${RUNTIME}" images --filter "reference=${TAG}"

if [[ "${PUSH}" -eq 1 ]]; then
  echo
  echo "Empurrando ${TAG}..."
  "${RUNTIME}" push "${TAG}"
fi
