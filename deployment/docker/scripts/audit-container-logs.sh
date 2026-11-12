#!/usr/bin/env bash
# Fail e2e/CI on fatal startup patterns; report known benign noise separately.
set -euo pipefail

LITELLM_CONTAINER="${LITELLM_CONTAINER:-litellm-secure}"
PROXY_CONTAINER="${NONO_PROXY_CONTAINER:-litellm-nono-proxy}"
LOGS="$(docker logs "${LITELLM_CONTAINER}" 2>&1 || true)"

fail_patterns=(
  'Sandbox initialization failed'
  'Refusing to grant'
  'pgbouncer could not start'
  'status -11'
  'evdns_base_new failed'
  'Database migration cannot proceed'
  'Database setup failed'
  'Command exited with code 1'
)

warn_patterns=(
  'sandbox-writable'
  'Failed to generate migration diff'
  'Error trying to read Prisma schema file'
  'distro "wolfi"'
  'trusted_proxy_ranges is not set'
  'server conn crashed'
)

echo "---- audit: ${LITELLM_CONTAINER} (last 120 lines) ----"
echo "${LOGS}" | tail -120

fatal=0
for pat in "${fail_patterns[@]}"; do
  if echo "${LOGS}" | grep -Fq "${pat}"; then
    echo "FAIL: log contains fatal pattern: ${pat}" >&2
    fatal=1
  fi
done

for pat in "${warn_patterns[@]}"; do
  if echo "${LOGS}" | grep -Fq "${pat}"; then
    echo "WARN: log contains: ${pat}" >&2
  fi
done

if docker inspect "${PROXY_CONTAINER}" >/dev/null 2>&1; then
  plogs="$(docker logs "${PROXY_CONTAINER}" 2>&1 | tail -40 || true)"
  echo "---- audit: ${PROXY_CONTAINER} (last 40 lines) ----"
  echo "${plogs}"
fi

[ "${fatal}" -eq 0 ] || exit 1
echo "OK: log audit (no fatal patterns)"
