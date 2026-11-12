#!/bin/sh
# Sidecar credential proxy: real LLM keys in SBX_REAL_* (see litellm-credentials.json env:// refs).
# Defaults: nono/fixtures/nono_proxy_entrypoint.json (ghcr.io/nolabs-ai/nono has no python3).
set -eu

PROXY_FIXTURE="${NONO_PROXY_ENTRYPOINT_FIXTURE:-/nono/fixtures/nono_proxy_entrypoint.json}"

# Read a string field from the fixture "defaults" object (no python/jq in upstream nono image).
_proxy_fixture_default() {
  _key="$1"
  _fallback="$2"
  if [ ! -f "${PROXY_FIXTURE}" ]; then
    printf '%s\n' "${_fallback}"
    return
  fi
  _v="$(sed -n "s/.*\"${_key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "${PROXY_FIXTURE}" 2>/dev/null | head -1)"
  if [ -n "${_v}" ]; then
    printf '%s\n' "${_v}"
  else
    printf '%s\n' "${_fallback}"
  fi
}

_PROXY_HOME="$(_proxy_fixture_default proxy_home /tmp)"
_PROXY_STATE_SUBDIR="$(_proxy_fixture_default proxy_state_subdir .local/state/nono)"
_LISTEN_ADDRESS="$(_proxy_fixture_default listen_address 0.0.0.0)"
_LISTEN_PORT_DEFAULT="$(_proxy_fixture_default listen_port 4010)"
_CREDENTIALS_PROFILE="$(_proxy_fixture_default credentials_profile /profiles/litellm-credentials.json)"

export HOME="${NONO_PROXY_HOME:-${_PROXY_HOME}}"
mkdir -p "${HOME}/${_PROXY_STATE_SUBDIR}" 2>/dev/null || true

# Must differ from LiteLLM (4000); required when nono-proxy and litellm share a pod network (K8s).
PORT="${NONO_PROXY_LISTEN_PORT:-${_LISTEN_PORT_DEFAULT}}"

exec nono proxy \
  --listen "${_LISTEN_ADDRESS}" \
  --port "${PORT}" \
  --pass "${NONO_PROXY_PASS:?NONO_PROXY_PASS required}" \
  --profile "${NONO_CREDENTIALS_PROFILE:-${_CREDENTIALS_PROFILE}}"
