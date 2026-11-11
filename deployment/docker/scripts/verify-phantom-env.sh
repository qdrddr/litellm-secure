#!/usr/bin/env bash
# Plan verification #1: sandboxed LiteLLM must not see NONO_* values in OPENAI_API_KEY.
set -euo pipefail

CONTAINER="${LITELLM_CONTAINER:-litellm-secure}"

nono_val="$(docker exec "${CONTAINER}" printenv NONO_OPENAI_API_KEY 2>/dev/null || true)"
if [ -z "${nono_val}" ]; then
  echo "SKIP: NONO_OPENAI_API_KEY unset on container (set it to test phantom isolation)" >&2
  exit 0
fi

pid="$(docker exec "${CONTAINER}" sh -c "pgrep -f '/app/.venv/bin/litellm --config' | head -1" || true)"
if [ -z "${pid}" ]; then
  echo "ERROR: litellm process not found in ${CONTAINER}" >&2
  exit 1
fi

child_openai="$(docker exec "${CONTAINER}" sh -c "tr '\\0' '\\n' < /proc/${pid}/environ | sed -n 's/^OPENAI_API_KEY=//p'")"
child_base="$(docker exec "${CONTAINER}" sh -c "tr '\\0' '\\n' < /proc/${pid}/environ | sed -n 's/^OPENAI_BASE_URL=//p'")"

echo "NONO_OPENAI_API_KEY (supervisor): ${nono_val:0:12}..."
echo "OPENAI_API_KEY (litellm child):   ${child_openai:0:40}..."
echo "OPENAI_BASE_URL (litellm child):  ${child_base:-<unset>}"

if [ "${child_openai}" = "${nono_val}" ]; then
  echo "FAIL: child OPENAI_API_KEY equals NONO_OPENAI_API_KEY (real key leaked)" >&2
  exit 1
fi

if [ -z "${child_openai}" ]; then
  echo "FAIL: OPENAI_API_KEY missing in child (credential route may be misconfigured)" >&2
  exit 1
fi

case "${child_base}" in
  http://127.0.0.1:*|http://localhost:* ) ;;
  *)
    echo "FAIL: OPENAI_BASE_URL should point at nono reverse proxy on loopback, got: ${child_base:-<unset>}" >&2
    exit 1
    ;;
esac

echo "OK: phantom credential routing looks correct"
