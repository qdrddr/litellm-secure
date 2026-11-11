#!/usr/bin/env bash
# Plan verification #3: entrypoint rejects direct provider api_base (egress bypass).
set -euo pipefail

IMAGE="${LITELLM_IMAGE:-litellm-secure:local-test}"
FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.negative-egress.example.yaml"

if [ ! -f "${FIXTURE}" ]; then
  echo "ERROR: missing ${FIXTURE}" >&2
  exit 1
fi

out="$(docker run --rm \
  -e LITELLM_MASTER_KEY=sk-test-master-key-for-reject-check \
  -e NONO_OPENAI_API_KEY=sk-fake \
  -v "${FIXTURE}:/app/config.yaml:ro" \
  --entrypoint /usr/local/bin/nono-entrypoint.sh \
  "${IMAGE}" \
  --config /app/.staging/config.yaml 2>&1 || true)"

if echo "${out}" | grep -q 'direct provider api_base'; then
  echo "OK: entrypoint rejected bypass config"
else
  echo "FAIL: expected api_base rejection; output:" >&2
  echo "${out}" | tail -20 >&2
  exit 1
fi
