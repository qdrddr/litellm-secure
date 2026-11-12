#!/bin/sh
# Baked into bbkudk/litellm-secure: nono-cli wraps LiteLLM proxy (no separate nono sidecar).
# Docker Desktop / Landlock hosts: `nono run` supervises the process and installs credential
# reverse-proxy routes (phantom API keys + localhost base URLs).
# Talos/K8s (Landlock): NONO_K8S_PROXY=1 — skip `nono run`; optional in-container `nono proxy`
# filters egress; LiteLLM binds :4000 directly (see CLIProxyAPI-secure nono-entrypoint.sh).
# Defaults: nono/fixtures/nono_entrypoint.json (override path via NONO_ENTRYPOINT_FIXTURE).
set -eu

_litellm_nono_mode="Direct"
case "${NONO_CREDENTIAL_PROXY:-}" in 1|true|yes|TRUE|YES) _litellm_nono_mode="Sidecar" ;; esac
echo "litellm-secure: ${_litellm_nono_mode} mode" >&2

NONO_ENV_PY="${NONO_ENV_PY:-/usr/local/lib/litellm-secure/litellm_nono_env.py}"
_FIXTURES_DIR="${LITELLM_FIXTURES_DIR:-/usr/local/lib/litellm-secure/fixtures}"
EP_FIXTURE="${NONO_ENTRYPOINT_FIXTURE:-${_FIXTURES_DIR}/nono_entrypoint.json}"
eval "$(python3 "${NONO_ENV_PY}" emit-entrypoint-vars "${EP_FIXTURE}")"

_ep_list() {
  python3 "${NONO_ENV_PY}" emit-entrypoint-list "${EP_FIXTURE}" "$1"
}

STAGE="${ep_paths_stage}"
CONFIG_STAGE="${STAGE}/${ep_paths_config_stage_name}"
DB_FORWARD_PID=""
REDIS_FORWARD_PID=""
CREDENTIAL_FORWARD_PID=""
PGBOUNCER_SUPERVISOR_PID=""
POOLED_URL_FILE="${STAGE}/${ep_paths_pooled_url_basename}"

# nolabs-ai/claude before-hook needs parents present before nono resolves capabilities (HOME=/app).
_litellm_uid="$(id -u)"
for _d in $(_ep_list paths.mkdir); do
  mkdir -p "${_d}" 2>/dev/null || true
done
mkdir -p "${ep_paths_claude_tmp_glob}/claude-${_litellm_uid}" 2>/dev/null || true
chmod "${ep_defaults_chmod_claude_mode}" /app/.claude "${ep_paths_claude_tmp_glob}" 2>/dev/null || true
export TMPDIR="${TMPDIR:-${ep_paths_tmpdir_default}}"

nono_credential_proxy_enabled() {
  case "${NONO_CREDENTIAL_PROXY:-}" in 1|true|yes|TRUE|YES) return 0 ;; esac
  return 1
}

nono_k8s_proxy_enabled() {
  case "${NONO_K8S_PROXY:-}" in 1|true|yes|TRUE|YES) return 0 ;; esac
  return 1
}

start_nono_filter_proxy() {
  PROXY_PORT="${NONO_PROXY_PORT:-${ep_defaults_k8s_filter_proxy_port}}"
  # --no-auth conflicts with --pass (sidecar sets NONO_PROXY_PASS in the pod).
  unset NONO_PROXY_PASS
  nono proxy --port "${PROXY_PORT}" --profile "${NONO_PROFILE:-${ep_defaults_nono_profile_k8s_filter}}" --no-auth &
  export HTTP_PROXY="http://127.0.0.1:${PROXY_PORT}"
  export HTTPS_PROXY="${HTTP_PROXY}"
}

pgbouncer_enabled() {
  case "${LITELLM_PGBOUNCER_ENABLED:-}" in 1|true|yes|TRUE|YES) return 0 ;; esac
  return 1
}

cleanup() {
  if [ -n "${DB_FORWARD_PID}" ]; then
    kill "${DB_FORWARD_PID}" 2>/dev/null || true
  fi
  if [ -n "${REDIS_FORWARD_PID}" ]; then
    kill "${REDIS_FORWARD_PID}" 2>/dev/null || true
  fi
  if [ -n "${CREDENTIAL_FORWARD_PID}" ]; then
    kill "${CREDENTIAL_FORWARD_PID}" 2>/dev/null || true
  fi
  if [ -n "${PGBOUNCER_SUPERVISOR_PID}" ]; then
    kill "${PGBOUNCER_SUPERVISOR_PID}" 2> /dev/null || true
  fi
}
trap cleanup EXIT INT TERM

python3 "${NONO_ENV_PY}" preflight || exit 1

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

# Landlock child may only reach open_port on localhost. Docker DNS hostnames are blocked —
# forward unsandboxed <host>:<port> → 127.0.0.1:<listen_port>.
start_tcp_localhost_forward() {
  label="$1"
  remote_host="$2"
  remote_port="$3"
  listen_port="$4"
  _fwd_attempts="${ep_timings_tcp_forward_ready_attempts}"
  _fwd_sleep="${ep_timings_tcp_forward_ready_sleep_sec}"
  target_ip="$(resolve_host "${remote_host}")" || {
    echo "ERROR: cannot resolve ${label} host=${remote_host}" >&2
    exit 1
  }
  python3 - "${listen_port}" "${target_ip}" "${remote_port}" 1>/dev/null <<'PY' &
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
print(f"tcp-forward: 127.0.0.1:{listen_port} -> {target_host}:{target_port}", file=sys.stderr, flush=True)
while True:
    client, _ = srv.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PY
  _forward_pid=$!
  # Wait until the listen socket accepts connections.
  i=0
  while [ "$i" -lt "${_fwd_attempts}" ]; do
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
    sleep "${_fwd_sleep}"
  done
  if [ "$i" -ge "${_fwd_attempts}" ]; then
    echo "ERROR: localhost forwarder (${label}) on :${listen_port} did not become ready" >&2
    exit 1
  fi
  echo "${label}-forward: 127.0.0.1:${listen_port} -> ${remote_host}:${remote_port}" >&2
  case "${label}" in
    db) DB_FORWARD_PID="${_forward_pid}" ;;
    redis) REDIS_FORWARD_PID="${_forward_pid}" ;;
    credential-proxy) CREDENTIAL_FORWARD_PID="${_forward_pid}" ;;
  esac
}

litellm_entrypoint_path() {
  for _p in $(_ep_list paths.litellm_entrypoints); do
    if [ -f "${_p}" ]; then
      echo "${_p}"
      return 0
    fi
  done
  return 1
}

invoke_litellm_entrypoint() {
  _ep="$1"
  shift
  case "${_ep}" in
    */prod_entrypoint.sh) sh "${_ep}" "$@" ;;
    */component_entrypoint.sh) sh "${_ep}" litellm "$@" ;;
    */docker-entrypoint.sh) sh "${_ep}" proxy "$@" ;;
    *)
      echo "ERROR: unsupported LiteLLM entrypoint ${_ep}" >&2
      exit 1
      ;;
  esac
}

if nono_credential_proxy_enabled; then
  CRED_PROFILE_STAGE="${STAGE}/credentials-profile.json"
  _cred_src=""
  if [ -n "${NONO_CREDENTIALS_PROFILE_PATH:-}" ] && [ -f "${NONO_CREDENTIALS_PROFILE_PATH}" ]; then
    _cred_src="${NONO_CREDENTIALS_PROFILE_PATH}"
  else
    for _p in $(_ep_list paths.credential_profile_candidates); do
      if [ -f "${_p}" ]; then
        _cred_src="${_p}"
        break
      fi
    done
  fi
  if [ -z "${_cred_src}" ]; then
    echo "ERROR: sidecar credentials profile not found — mount litellm-credentials.json on litellm-secure" >&2
    exit 1
  fi
  cp "${_cred_src}" "${CRED_PROFILE_STAGE}"
  case "${NONO_K8S_SIDECAR:-}" in
    1|true|yes|TRUE|YES) _cred_host_default="${ep_defaults_credential_proxy_host_k8s_sidecar}" ;;
    *) _cred_host_default="${ep_defaults_credential_proxy_host_compose}" ;;
  esac
  CRED_PROXY_HOST="${NONO_CREDENTIAL_PROXY_HOST:-${_cred_host_default}}"
  CRED_PROXY_PORT="${NONO_CREDENTIAL_PROXY_PORT:-${ep_defaults_credential_proxy_port}}"
  LOCAL_CRED_PORT="${NONO_LOCAL_CREDENTIAL_PROXY_PORT:-${ep_defaults_local_credential_proxy_port}}"
  start_tcp_localhost_forward "credential-proxy" "${CRED_PROXY_HOST}" "${CRED_PROXY_PORT}" "${LOCAL_CRED_PORT}"
  # Scope credentials profile to Python emit only — must not stay in env for `nono run` (would warn on SBX_REAL_*).
  eval "$(NONO_CREDENTIALS_PROFILE_PATH="${CRED_PROFILE_STAGE}" python3 "${NONO_ENV_PY}" emit-sidecar)"
  unset NONO_CREDENTIALS_PROFILE_PATH 2>/dev/null || true
  echo "credential-proxy: phantoms from PHANTOM_KEY_* / profile via 127.0.0.1:${LOCAL_CRED_PORT}" >&2
fi

if [ -n "${DATABASE_URL:-}" ]; then
  DB_HOST="${NONO_DB_UPSTREAM_HOST:-${DATABASE_HOST:-${ep_defaults_database_host}}}"
  DB_PORT="${DATABASE_PORT:-${ep_defaults_database_port}}"
  LOCAL_DB_PORT="${NONO_LOCAL_DB_PORT:-${ep_defaults_local_db_port}}"
  _ORIGINAL_DATABASE_URL="${DATABASE_URL}"
  start_tcp_localhost_forward "db" "${DB_HOST}" "${DB_PORT}" "${LOCAL_DB_PORT}"
  REWRITTEN="$(rewrite_db_url_host "${DATABASE_URL}" "127.0.0.1" "${LOCAL_DB_PORT}")"
  if [ -z "${REWRITTEN}" ]; then
    echo "ERROR: failed to rewrite DATABASE_URL for localhost forwarder" >&2
    exit 1
  fi
  export DATABASE_URL="${REWRITTEN}"
  export DATABASE_HOST="127.0.0.1"
  export DATABASE_PORT="${LOCAL_DB_PORT}"
  echo "DATABASE_URL host remapped to 127.0.0.1:${LOCAL_DB_PORT} (nono open_port)" >&2
fi

REDIS_UPSTREAM_HOST="${NONO_REDIS_UPSTREAM_HOST:-${REDIS_HOST:-}}"
REDIS_UPSTREAM_PORT="${NONO_REDIS_UPSTREAM_PORT:-${REDIS_PORT:-${ep_defaults_redis_port}}}"
LOCAL_REDIS_PORT="${NONO_LOCAL_REDIS_PORT:-${ep_defaults_local_redis_port}}"
if [ -n "${REDIS_UPSTREAM_HOST}" ]; then
  if nono_k8s_proxy_enabled; then
    # Workers are not under nono run; direct Valkey keeps Redis pub/sub (auth-cache invalidation) alive.
    export REDIS_HOST="${REDIS_UPSTREAM_HOST}"
    export REDIS_PORT="${REDIS_UPSTREAM_PORT}"
    echo "REDIS direct ${REDIS_HOST}:${REDIS_PORT} (NONO_K8S_PROXY; no loopback forward)" >&2
  else
    start_tcp_localhost_forward "redis" "${REDIS_UPSTREAM_HOST}" "${REDIS_UPSTREAM_PORT}" "${LOCAL_REDIS_PORT}"
    export REDIS_HOST="127.0.0.1"
    export REDIS_PORT="${LOCAL_REDIS_PORT}"
    echo "REDIS remapped to 127.0.0.1:${LOCAL_REDIS_PORT} (nono open_port)" >&2
  fi
fi

if [ -n "${DATABASE_URL:-}" ] && [ -x /app/.venv/bin/python ]; then
  # Unsandboxed DB setup only. Do not call prisma_migration.py here — it also runs
  # `prisma generate`, which chmods site-packages and fails under Landlock / RO venv.
  # PgBouncer must not start here — it would exit when this process returns.
  LITELLM_MIGRATION_DIR="${LITELLM_MIGRATION_DIR:-${ep_defaults_migration_dir}}" \
  DISABLE_SCHEMA_UPDATE="${NONO_PREFLIGHT_DISABLE_SCHEMA_UPDATE:-false}" \
  LITELLM_PGBOUNCER_ENABLED=false \
    /app/.venv/bin/python -c '
from litellm.proxy.proxy_cli import run_server
run_server(("--skip_server_startup",), standalone_mode=False)
' || {
      echo "ERROR: database migration failed (unsandboxed via localhost forwarder)" >&2
      exit 1
    }
  export DISABLE_SCHEMA_UPDATE="${ep_defaults_disable_schema_update_after_migrate}"
fi

if pgbouncer_enabled; then
  PGBOUNCER_SUPERVISOR="${ep_paths_pgbouncer_supervisor}"
  if [ ! -f "${PGBOUNCER_SUPERVISOR}" ]; then
    echo "ERROR: ${PGBOUNCER_SUPERVISOR} missing (image too old for in-container PgBouncer)" >&2
    exit 1
  fi
  rm -f "${POOLED_URL_FILE}"
  DB_TARGET_IP="$(resolve_host "${DB_HOST}")" || {
    echo "ERROR: cannot resolve DB host for PgBouncer upstream (${DB_HOST})" >&2
    exit 1
  }
  export PGBOUNCER_UPSTREAM_DATABASE_URL="$(rewrite_db_url_host "${_ORIGINAL_DATABASE_URL}" "${DB_TARGET_IP}" "${DB_PORT}")"
  POOL_PORT="${LITELLM_PGBOUNCER_PORT:-${ep_defaults_pgbouncer_port}}"
  _pg_attempts="${ep_timings_pgbouncer_ready_attempts}"
  _pg_sleep="${ep_timings_pgbouncer_ready_sleep_sec}"
  echo "pgbouncer: upstream -> ${DB_TARGET_IP}:${DB_PORT} (direct; sandboxed workers use :${POOL_PORT})" >&2
  /app/.venv/bin/python "${PGBOUNCER_SUPERVISOR}" --pooled-url-file "${POOLED_URL_FILE}" &
  PGBOUNCER_SUPERVISOR_PID=$!
  i=0
  while [ "$i" -lt "${_pg_attempts}" ]; do
    if [ -f "${POOLED_URL_FILE}" ]; then
      if python3 - "${POOL_PORT}" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
      then
        break
      fi
    fi
    if ! kill -0 "${PGBOUNCER_SUPERVISOR_PID}" 2>/dev/null; then
      echo "ERROR: PgBouncer supervisor exited during startup" >&2
      exit 1
    fi
    i=$((i + 1))
    sleep "${_pg_sleep}"
  done
  if [ "$i" -ge "${_pg_attempts}" ]; then
    echo "ERROR: PgBouncer did not become ready on 127.0.0.1:${POOL_PORT}" >&2
    exit 1
  fi
  export DATABASE_URL="$(cat "${POOLED_URL_FILE}")"
  export LITELLM_PGBOUNCER_POOLED_DATABASE_URL=true
  export LITELLM_PGBOUNCER_ENABLED=false
  echo "pgbouncer: workers use loopback :${POOL_PORT} (supervisor pid ${PGBOUNCER_SUPERVISOR_PID})" >&2
fi

# Bind mounts may not be readable under Landlock; stage config into the image tree first.
_config_src=""
for _cfg in $(_ep_list paths.config_sources); do
  if [ -f "${_cfg}" ]; then
    _config_src="${_cfg}"
    break
  fi
done
if [ -z "${_config_src}" ]; then
  echo "ERROR: no config found (see fixture paths.config_sources)" >&2
  exit 1
fi
cp "${_config_src}" "${CONFIG_STAGE}"
export CONFIG_FILE_PATH="${CONFIG_STAGE}"

# Proxy mode: keep loopback DB/Redis/PgBouncer/credential-forward off HTTP_PROXY.
_nono_no_proxy="$(python3 "${NONO_ENV_PY}" emit-entrypoint-no-proxy-value "${EP_FIXTURE}")"
export NO_PROXY="${_nono_no_proxy}${NO_PROXY:+,}${NO_PROXY:-}"
if nono_k8s_proxy_enabled; then
  export NO_PROXY="${NO_PROXY},${ep_no_proxy_k8s_proxy_append}"
fi

if grep -E "${ep_config_guard_forbidden_direct_api_base_regex}" \
  "${CONFIG_STAGE}" 2>/dev/null; then
  echo "ERROR: config sets a direct provider api_base — remove it so LiteLLM uses nono OPENAI_BASE_URL / ANTHROPIC_BASE_URL." >&2
  exit 1
fi

# Historical compose alias: `proxy` → litellm CLI (main-stable Hub image layout).
case "${1:-}" in
  "${ep_paths_cli_command_alias}")
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

_LITELLM_EP="$(litellm_entrypoint_path)" || {
  echo "ERROR: no LiteLLM entrypoint found (see fixture paths.litellm_entrypoints)" >&2
  exit 1
}

# Do not exec: keep this shell as parent so the unsandboxed db forwarder survives.
if nono_k8s_proxy_enabled; then
  if [ -n "${NONO_PROXY_PORT:-}" ]; then
    start_nono_filter_proxy
  fi
  invoke_litellm_entrypoint "${_LITELLM_EP}" "$@"
  exit $?
fi

# NONO_RUN_ARGS: optional extra nono run flags before "--" (word-split; unset or empty = no extra flags).
_run_nono_litellm() {
  case "${_LITELLM_EP}" in
    */prod_entrypoint.sh)
      # shellcheck disable=SC2086
      nono run --profile "${NONO_PROFILE:-${ep_defaults_nono_profile}}" ${NONO_RUN_ARGS:-} -- \
        sh "${_LITELLM_EP}" "$@"
      ;;
    */component_entrypoint.sh)
      # shellcheck disable=SC2086
      nono run --profile "${NONO_PROFILE:-${ep_defaults_nono_profile}}" ${NONO_RUN_ARGS:-} -- \
        sh "${_LITELLM_EP}" litellm "$@"
      ;;
    */docker-entrypoint.sh)
      # shellcheck disable=SC2086
      nono run --profile "${NONO_PROFILE:-${ep_defaults_nono_profile}}" ${NONO_RUN_ARGS:-} -- \
        sh "${_LITELLM_EP}" proxy "$@"
      ;;
    *)
      echo "ERROR: unsupported LiteLLM entrypoint ${_LITELLM_EP}" >&2
      exit 1
      ;;
  esac
}
_run_nono_litellm "$@"
