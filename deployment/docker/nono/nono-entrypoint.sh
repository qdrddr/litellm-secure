#!/bin/sh
# Baked into bbkudk/litellm-secure: nono-cli wraps LiteLLM proxy (no separate nono sidecar).
# Docker Desktop / Landlock hosts: `nono run` supervises the process and installs credential
# reverse-proxy routes (phantom API keys + localhost base URLs).
set -eu

STAGE=/app/.staging
CONFIG_STAGE="${STAGE}/config.yaml"
DB_FORWARD_PID=""

mkdir -p "${STAGE}"

cleanup() {
  if [ -n "${DB_FORWARD_PID}" ]; then
    kill "${DB_FORWARD_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Real provider keys must use NONO_* (supervisor / env:// only). Passing OPENAI_API_KEY etc. defeats injection.
for leaked in OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY OR_API_KEY; do
  eval "val=\${${leaked}:-}"
  if [ -n "${val}" ]; then
    case "${leaked}" in
      OR_API_KEY) nono_name="NONO_OPENROUTER_API_KEY" ;;
      OPENROUTER_API_KEY) nono_name="NONO_OPENROUTER_API_KEY" ;;
      *) nono_name="NONO_${leaked}" ;;
    esac
    echo "ERROR: ${leaked} is set on the container. Use ${nono_name} instead — LiteLLM must see phantom tokens only." >&2
    exit 1
  fi
done

# Rewrite the host (and optional port) in a postgres URL. Keeps user/password/path/query intact.
rewrite_db_url_host() {
  url="$1"
  new_host="$2"
  new_port="${3:-}"
  python3 - "$url" "$new_host" "$new_port" <<'PY'
import sys
from urllib.parse import urlparse, urlunparse

url, new_host, new_port = sys.argv[1], sys.argv[2], sys.argv[3]
u = urlparse(url)
if not u.scheme or not u.hostname:
    sys.exit(0)
user = u.username or ""
password = u.password or ""
auth = ""
if user:
    auth = user
    if password is not None and password != "":
        from urllib.parse import quote
        auth = f"{quote(user, safe='')}:{quote(password, safe='')}"
    elif password == "":
        auth = f"{user}:"
    auth += "@"
port = new_port or (str(u.port) if u.port else "")
hostport = new_host if not port else f"{new_host}:{port}"
netloc = f"{auth}{hostport}"
print(urlunparse((u.scheme, netloc, u.path, u.params, u.query, u.fragment)))
PY
}

resolve_host() {
  host="$1"
  python3 - "$host" <<'PY'
import socket, sys
host = sys.argv[1]
try:
    print(socket.gethostbyname(host))
except OSError:
    sys.exit(1)
PY
}

# Landlock child may only reach open_port localhost:5432 (see nono profile). Docker DNS
# hostname `db` and bridge IPs are blocked — forward unsandboxed db → 127.0.0.1:5432.
start_db_localhost_forward() {
  db_host="$1"
  db_port="$2"
  listen_port="$3"
  target_ip="$(resolve_host "${db_host}")" || {
    echo "ERROR: cannot resolve DATABASE_HOST=${db_host}" >&2
    exit 1
  }
  python3 - "${listen_port}" "${target_ip}" "${db_port}" <<'PY' &
import socket, sys, threading

listen_port = int(sys.argv[1])
target_host = sys.argv[2]
target_port = int(sys.argv[3])

def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            src.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            dst.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        src.close()
        dst.close()

def handle(client):
    try:
        upstream = socket.create_connection((target_host, target_port), timeout=10)
    except OSError as exc:
        client.close()
        print(f"db-forward: upstream connect failed: {exc}", file=sys.stderr)
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", listen_port))
srv.listen(128)
print(f"db-forward: 127.0.0.1:{listen_port} -> {target_host}:{target_port}", flush=True)
while True:
    client, _ = srv.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PY
  DB_FORWARD_PID=$!
  # Wait until the listen socket accepts connections.
  i=0
  while [ "$i" -lt 50 ]; do
    if python3 - "${listen_port}" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
    then
      break
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if [ "$i" -ge 50 ]; then
    echo "ERROR: localhost db forwarder on :${listen_port} did not become ready" >&2
    exit 1
  fi
}

if [ -n "${DATABASE_URL:-}" ]; then
  DB_HOST="${DATABASE_HOST:-db}"
  DB_PORT="${DATABASE_PORT:-5432}"
  LOCAL_DB_PORT="${NONO_LOCAL_DB_PORT:-5432}"
  start_db_localhost_forward "${DB_HOST}" "${DB_PORT}" "${LOCAL_DB_PORT}"
  REWRITTEN="$(rewrite_db_url_host "${DATABASE_URL}" "127.0.0.1" "${LOCAL_DB_PORT}")"
  if [ -z "${REWRITTEN}" ]; then
    echo "ERROR: failed to rewrite DATABASE_URL for localhost forwarder" >&2
    exit 1
  fi
  export DATABASE_URL="${REWRITTEN}"
  echo "DATABASE_URL host remapped to 127.0.0.1:${LOCAL_DB_PORT} (nono open_port)" >&2
fi

if [ -n "${DATABASE_URL:-}" ] && [ -x /app/.venv/bin/python ] && [ -f /app/litellm/proxy/prisma_migration.py ]; then
  LITELLM_MIGRATION_DIR="${LITELLM_MIGRATION_DIR:-/tmp/litellm-migrations}" \
    /app/.venv/bin/python /app/litellm/proxy/prisma_migration.py || {
      echo "ERROR: database migration failed (unsandboxed via localhost forwarder)" >&2
      exit 1
    }
fi

# Bind mounts may not be readable under Landlock; stage config into the image tree first.
if [ -f /app/config.yaml ]; then
  cp /app/config.yaml "${CONFIG_STAGE}"
elif [ -f /app/config.example.yaml ]; then
  cp /app/config.example.yaml "${CONFIG_STAGE}"
else
  echo "ERROR: no config at /app/config.yaml or /app/config.example.yaml" >&2
  exit 1
fi

if grep -E '^[[:space:]]*api_base:[[:space:]]*https://(api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com|openrouter\.ai)' \
  "${CONFIG_STAGE}" 2>/dev/null; then
  echo "ERROR: config sets a direct provider api_base — remove it so LiteLLM uses nono OPENAI_BASE_URL / ANTHROPIC_BASE_URL." >&2
  exit 1
fi

# Historical compose alias: `proxy` → litellm CLI (main-stable Hub image layout).
case "${1:-}" in
  proxy)
    shift
    ;;
esac

has_config=false
for arg in "$@"; do
  case "$arg" in
    --config) has_config=true ;;
  esac
done
if [ "$has_config" = false ]; then
  set -- "$@" --config "${CONFIG_STAGE}"
fi

LITELLM_CMD="litellm"
COMPONENT_ENTRYPOINT=/app/docker/component_entrypoint.sh
if [ ! -f "${COMPONENT_ENTRYPOINT}" ] && [ -f /app/docker-entrypoint.sh ]; then
  # Submodule / dev image with multi-component entrypoint.
  COMPONENT_ENTRYPOINT=/app/docker-entrypoint.sh
  LITELLM_CMD="proxy"
fi

# Do not exec: keep this shell as parent so the unsandboxed db forwarder survives.
# NONO_RUN_ARGS: optional extra nono run flags before "--" (word-split; unset or empty = no extra flags).
# shellcheck disable=SC2086
nono run --profile "${NONO_PROFILE:-litellm}" ${NONO_RUN_ARGS:-} -- \
  sh "${COMPONENT_ENTRYPOINT}" "${LITELLM_CMD}" "$@"
