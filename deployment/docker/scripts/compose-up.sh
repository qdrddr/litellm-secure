#!/usr/bin/env bash
# One-knob compose: LITELLM_NONO_MODE=direct (default) | sidecar
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

set -a
[ -f .env ] && . ./.env
set +a

mode="${LITELLM_NONO_MODE:-direct}"
case "${mode}" in
  direct)
    exec docker compose -f docker-compose.yml -f docker-compose.direct.yml "$@"
    ;;
  sidecar)
    exec docker compose -f docker-compose.with-nono-proxy.yml "$@"
    ;;
  *)
    echo "ERROR: LITELLM_NONO_MODE must be 'direct' or 'sidecar' (got '${mode}')" >&2
    exit 1
    ;;
esac
