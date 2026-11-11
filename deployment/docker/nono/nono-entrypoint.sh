#!/bin/sh
# Baked into bbkudk/litellm-secure: nono-cli wraps LiteLLM proxy (no separate nono sidecar).
# Docker Desktop / Landlock hosts: `nono run` supervises the process and installs credential
# reverse-proxy routes (phantom API keys + localhost base URLs).
set -eu

STAGE=/app/.staging
CONFIG_STAGE="${STAGE}/config.yaml"

mkdir -p "${STAGE}"

# Real provider keys must use NONO_* (supervisor / env:// only). Passing OPENAI_API_KEY etc. defeats injection.
for leaked in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY OR_API_KEY; do
  eval "val=\${${leaked}:-}"
  if [ -n "${val}" ]; then
    case "${leaked}" in
      OR_API_KEY) nono_name="NONO_OPENROUTER_API_KEY" ;;
      OPENROUTER_API_KEY) nono_name="NONO_OPENROUTER_API_KEY" ;;
      *) nono_name="NONO_${leaked}" ;;
    esac
    echo "ERROR: ${leaked} is set on the container. Use ${nono_name} instead — LiteLLM must see phantom tokens only." >&2
    exit 1
  fi
done

# Docker DNS (e.g. host `db`) is unavailable inside the landlock child — resolve while unsandboxed.
resolve_db_host_in_url() {
  url="$1"
  host="$2"
  python3 - "$url" "$host" <<'PY'
import socket, sys
url, host = sys.argv[1], sys.argv[2]
try:
    ip = socket.gethostbyname(host)
except OSError:
    sys.exit(0)
print(url.replace(f"@{host}:", f"@{ip}:", 1))
PY
}

if [ -n "${DATABASE_URL:-}" ]; then
  DB_HOST="${DATABASE_HOST:-db}"
  RESOLVED="$(resolve_db_host_in_url "${DATABASE_URL}" "${DB_HOST}")"
  if [ -n "${RESOLVED}" ] && [ "${RESOLVED}" != "${DATABASE_URL}" ]; then
    export DATABASE_URL="${RESOLVED}"
  fi
fi

if [ -n "${DATABASE_URL:-}" ] && [ -x /app/.venv/bin/python ] && [ -f /app/litellm/proxy/prisma_migration.py ]; then
  LITELLM_MIGRATION_DIR="${LITELLM_MIGRATION_DIR:-/tmp/litellm-migrations}" \
    /app/.venv/bin/python /app/litellm/proxy/prisma_migration.py || {
      echo "ERROR: database migration failed (unsandboxed)" >&2
      exit 1
    }
fi

# Bind mounts may not be readable under Landlock; stage config into the image tree first.
if [ -f /app/config.yaml ]; then
  cp /app/config.yaml "${CONFIG_STAGE}"
elif [ -f /app/config.example.yaml ]; then
  cp /app/config.example.yaml "${CONFIG_STAGE}"
else
  echo "ERROR: no config at /app/config.yaml or /app/config.example.yaml" >&2
  exit 1
fi

if grep -E '^[[:space:]]*api_base:[[:space:]]*https://(api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|openrouter\.ai)' \
  "${CONFIG_STAGE}" 2>/dev/null; then
  echo "ERROR: config sets a direct provider api_base — remove it so LiteLLM uses nono OPENAI_BASE_URL / ANTHROPIC_BASE_URL." >&2
  exit 1
fi

# Historical compose alias: `proxy` → litellm CLI (main-stable Hub image layout).
case "${1:-}" in
  proxy)
    shift
    ;;
esac

has_config=false
for arg in "$@"; do
  case "$arg" in
    --config) has_config=true ;;
  esac
done
if [ "$has_config" = false ]; then
  set -- "$@" --config "${CONFIG_STAGE}"
fi

LITELLM_CMD="litellm"
COMPONENT_ENTRYPOINT=/app/docker/component_entrypoint.sh
if [ ! -f "${COMPONENT_ENTRYPOINT}" ] && [ -f /app/docker-entrypoint.sh ]; then
  # Submodule / dev image with multi-component entrypoint.
  COMPONENT_ENTRYPOINT=/app/docker-entrypoint.sh
  LITELLM_CMD="proxy"
fi

# NONO_RUN_ARGS: optional extra nono run flags before "--" (word-split; unset or empty = no extra flags).
# shellcheck disable=SC2086
exec nono run --profile "${NONO_PROFILE:-litellm}" ${NONO_RUN_ARGS:-} -- \
  sh "${COMPONENT_ENTRYPOINT}" "${LITELLM_CMD}" "$@"
