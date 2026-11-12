#!/usr/bin/env bash
# Sidecar mode: litellm child must not have NONO_* / NONO_REAL_* secrets; loopback BASE_URL from profile.
set -euo pipefail

LITELLM_CONTAINER="${LITELLM_CONTAINER:-litellm-secure}"
PROXY_CONTAINER="${NONO_PROXY_CONTAINER:-litellm-nono-proxy}"
ENV_PY="/usr/local/lib/litellm-secure/litellm_nono_env.py"
PROFILE_PATH="${NONO_CREDENTIALS_PROFILE_PATH:-/app/credentials-sidecar-profile.json}"

if [ -z "$(docker inspect -f '{{.State.Running}}' "${LITELLM_CONTAINER}" 2>/dev/null || true)" ]; then
  echo "ERROR: ${LITELLM_CONTAINER} is not running" >&2
  exit 1
fi

docker exec "${LITELLM_CONTAINER}" python3 "${ENV_PY}" preflight
echo "OK: litellm preflight (no NONO_* / NONO_REAL_* provider secrets)"

has_proxy_secret=false
while IFS= read -r line; do
  case "${line}" in
    NONO_*=*|NONO_REAL_*=*)
      has_proxy_secret=true
      echo "OK: ${line%%=*} present on ${PROXY_CONTAINER}"
      break
      ;;
  esac
done < <(docker exec "${PROXY_CONTAINER}" env | grep -E '^(NONO_|NONO_REAL_)' || true)

if [ "${has_proxy_secret}" = false ]; then
  echo "WARN: no NONO_* / NONO_REAL_* on ${PROXY_CONTAINER}" >&2
fi

pid="$(docker exec "${LITELLM_CONTAINER}" sh -c "pgrep -f 'litellm --config' | head -1" || true)"
if [ -z "${pid}" ]; then
  echo "ERROR: litellm process not found" >&2
  exit 1
fi

docker exec "${LITELLM_CONTAINER}" python3 - "${PROFILE_PATH}" "${pid}" <<'PY'
import json, os, sys
from pathlib import Path

profile_path, pid = sys.argv[1], sys.argv[2]
profile = json.loads(Path(profile_path).read_text())
custom = (profile.get("network") or {}).get("custom_credentials") or {}

def child_env(pid):
    raw = Path(f"/proc/{pid}/environ").read_bytes()
    out = {}
    for item in raw.split(b"\0"):
        if not item or b"=" not in item:
            continue
        k, v = item.split(b"=", 1)
        out[k.decode()] = v.decode()
    return out

env = child_env(pid)
for route, spec in custom.items():
    if not isinstance(spec, dict):
        continue
    env_var = spec.get("env_var")
    if not env_var:
        continue
    key = env.get(env_var, "")
    base = env_var[:-8] + "_BASE_URL" if env_var.endswith("_API_KEY") else env_var + "_BASE_URL"
    base_url = env.get(base, "")
    print(f"{env_var} (child prefix): {key[:20]}...")
    print(f"{base} (child): {base_url or '<unset>'}")
    if not base_url.startswith(("http://127.0.0.1:", "http://localhost:")):
        print(f"FAIL: {base} should target loopback credential forwarder", file=sys.stderr)
        sys.exit(1)
PY

echo "OK: sidecar phantom routing looks correct"
