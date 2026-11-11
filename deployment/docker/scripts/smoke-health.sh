#!/usr/bin/env bash
# Requires litellm-secure stack up on localhost:4000.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/.env" 2>/dev/null || true

BASE="${LITELLM_BASE_URL:-http://127.0.0.1:4000}"
MASTER="${LITELLM_MASTER_KEY:?set LITELLM_MASTER_KEY in .env}"

code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/health/liveliness")"
echo "health/liveliness → ${code}"
[ "${code}" = "200" ]

code="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${MASTER}" \
  "${BASE}/v1/models")"
echo "v1/models → ${code}"
[ "${code}" = "200" ]

echo "OK"
