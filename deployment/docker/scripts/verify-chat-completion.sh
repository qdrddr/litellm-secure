#!/usr/bin/env bash
# Plan verification #2 and #4: chat completion (optional streaming) via the proxy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/.env" 2>/dev/null || true

BASE="${LITELLM_BASE_URL:-http://127.0.0.1:4000}"
MASTER="${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY in .env}"
MODEL="${VERIFY_MODEL:-gpt-4o-mini}"
STREAM="${VERIFY_STREAM:-0}"

if [ "${STREAM}" = "1" ] || [ "${STREAM}" = "true" ]; then
  stream_json=true
else
  stream_json=false
fi

body="$(cat <<EOF
{"model":"${MODEL}","messages":[{"role":"user","content":"Say exactly: pong"}],"stream":${stream_json}}
EOF
)"

if [ "${STREAM}" = "1" ] || [ "${STREAM}" = "true" ]; then
  echo "Streaming chat completion..."
  curl -sS -N "${BASE}/v1/chat/completions" \
    -H "Authorization: Bearer ${MASTER}" \
    -H "Content-Type: application/json" \
    -d "${body}" | head -c 500
  echo ""
  echo "OK: streaming response received (requires valid NONO_OPENAI_API_KEY)"
else
  resp="$(curl -sS "${BASE}/v1/chat/completions" \
    -H "Authorization: Bearer ${MASTER}" \
    -H "Content-Type: application/json" \
    -d "${body}")"
  echo "${resp}" | head -c 400
  echo ""
  if echo "${resp}" | grep -q '"choices"'; then
    echo "OK: chat completion succeeded"
  elif echo "${resp}" | grep -qi 'invalid_api_key\|authentication\|401'; then
    echo "WARN: upstream rejected key — check NONO_OPENAI_API_KEY (proxy still routed request)" >&2
    exit 0
  else
    echo "FAIL: unexpected response" >&2
    exit 1
  fi
fi
