#!/usr/bin/env bash
# Local CI-style smoke for direct + sidecar (pinned image tags).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
# shellcheck source=/dev/null
set -a; [ -f .env ] && . ./.env; set +a

export LITELLM_IMAGE="${LITELLM_IMAGE:-litellm-secure:local}"
export LITELLM_PULL_POLICY="${LITELLM_PULL_POLICY:-never}"
export LITELLM_RELEASE_TAG="${LITELLM_RELEASE_TAG:-v1.106.8}"
export NONO_VERSION="${NONO_VERSION:-0.81.0}"
MODEL="${VERIFY_MODEL:-openrouter/deep-seek-v4-flash-0731}"
BASE="${LITELLM_BASE_URL:-http://127.0.0.1:4000}"

wait_healthy() {
  local i st
  for i in $(seq 1 50); do
    st="$(docker inspect -f '{{.State.Health.Status}}' litellm-secure 2>/dev/null || echo missing)"
    [ "${st}" = healthy ] && return 0
    sleep 5
  done
  docker logs litellm-secure 2>&1 | tail -40 >&2
  return 1
}

admin_login() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/login" \
    -F "username=admin" -F "password=${LITELLM_MASTER_KEY}")"
  [ "${code}" = "303" ] || { echo "FAIL: admin login HTTP ${code}" >&2; return 1; }
  echo "OK: admin UI login (303)"
}

chat_completion() {
  local resp
  resp="$(curl -sS "${BASE}/v1/chat/completions" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: pong\"}],\"stream\":false}")"
  echo "${resp}" | head -c 200
  echo ""
  echo "${resp}" | grep -q '"choices"' || { echo "FAIL: chat completion" >&2; return 1; }
  echo "OK: chat completion (${MODEL})"
}

test_mode() {
  local mode="$1"
  echo "========== mode=${mode} =========="
  LITELLM_NONO_MODE="${mode}" ./scripts/compose-up.sh down 2>/dev/null || true
  LITELLM_NONO_MODE="${mode}" ./scripts/compose-up.sh up -d --force-recreate
  wait_healthy
  ./scripts/smoke-health.sh
  ./scripts/verify-pgbouncer.sh
  admin_login
  if [ "${mode}" = sidecar ]; then
    ./scripts/verify-sidecar-keys.sh
  fi
  chat_completion
}

test_mode direct
test_mode sidecar
echo "========== ALL MODES PASSED =========="
