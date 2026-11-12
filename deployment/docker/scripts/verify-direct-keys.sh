#!/usr/bin/env bash
# Mode 1 (direct): sandboxed LiteLLM must not inherit SBX_REAL_* secrets; phantoms on loopback.
set -euo pipefail

LITELLM_CONTAINER="${LITELLM_CONTAINER:-litellm-secure}"
ENV_PY="/usr/local/lib/litellm-secure/litellm_nono_env.py"
PROFILE_PATH="${NONO_PROFILE_PATH:-/app/.config/nono/profiles/litellm.json}"

if [ "$(docker inspect -f '{{.State.Running}}' "${LITELLM_CONTAINER}" 2>/dev/null || true)" != "true" ]; then
  echo "ERROR: ${LITELLM_CONTAINER} is not running" >&2
  exit 1
fi

docker exec "${LITELLM_CONTAINER}" python3 "${ENV_PY}" preflight
echo "OK: litellm preflight (no bare *_API_KEY secrets on container)"

docker exec "${LITELLM_CONTAINER}" python3 "${ENV_PY}" verify-child "${PROFILE_PATH}"
