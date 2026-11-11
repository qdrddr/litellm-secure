#!/bin/sh
# Sidecar credential proxy: map NONO_REAL_* → NONO_* (no Python — stock nono image is minimal).
set -eu

PORT="${NONO_PROXY_LISTEN_PORT:-4000}"

for _var in $(env | sed -n 's/^\(NONO_REAL_[^=]*\)=.*/\1/p'); do
  _suffix="${_var#NONO_REAL_}"
  _target="NONO_${_suffix}"
  eval "_real=\${${_var}:-}"
  eval "_cur=\${${_target}:-}"
  if [ -n "${_real}" ] && [ -z "${_cur}" ]; then
    export "${_target}=${_real}"
  fi
done

exec nono proxy \
  --listen 0.0.0.0 \
  --port "${PORT}" \
  --pass "${NONO_PROXY_PASS:?NONO_PROXY_PASS required}" \
  --profile "${NONO_CREDENTIALS_PROFILE:-/profiles/litellm-credentials.json}"
