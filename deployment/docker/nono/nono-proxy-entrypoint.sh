#!/bin/sh
# Sidecar credential proxy: real LLM keys in SBX_REAL_* (see litellm-credentials.json env:// refs).
set -eu

export HOME="${NONO_PROXY_HOME:-/tmp}"
mkdir -p "${HOME}/.local/state/nono" 2>/dev/null || true

# Must differ from LiteLLM (4000); required when nono-proxy and litellm share a pod network (K8s).
PORT="${NONO_PROXY_LISTEN_PORT:-4010}"

exec nono proxy \
  --listen 0.0.0.0 \
  --port "${PORT}" \
  --pass "${NONO_PROXY_PASS:?NONO_PROXY_PASS required}" \
  --profile "${NONO_CREDENTIALS_PROFILE:-/profiles/litellm-credentials.json}"
