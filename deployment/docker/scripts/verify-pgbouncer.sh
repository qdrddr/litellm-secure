#!/usr/bin/env bash
# Requires litellm-secure up with LITELLM_PGBOUNCER_ENABLED=true (default in compose).
set -euo pipefail

LITELLM_CONTAINER="${LITELLM_CONTAINER:-litellm-secure}"
PORT="${LITELLM_PGBOUNCER_PORT:-6432}"

if [ -z "$(docker inspect -f '{{.State.Running}}' "${LITELLM_CONTAINER}" 2>/dev/null || true)" ]; then
  echo "ERROR: ${LITELLM_CONTAINER} is not running" >&2
  exit 1
fi

enabled="$(docker exec "${LITELLM_CONTAINER}" sh -c 'printf %s "${LITELLM_PGBOUNCER_ENABLED:-}"')"
case "${enabled}" in
  1|true|yes|TRUE|YES) ;;
  *)
    echo "SKIP: LITELLM_PGBOUNCER_ENABLED is not set on ${LITELLM_CONTAINER}" >&2
    exit 0
    ;;
esac

if ! docker exec "${LITELLM_CONTAINER}" python3 - "${PORT}" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(1.0)
try:
    s.connect(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
then
  echo "FAIL: nothing listening on 127.0.0.1:${PORT} (in-container PgBouncer)" >&2
  docker logs "${LITELLM_CONTAINER}" 2>&1 | rg -i 'pgbouncer' | tail -20 >&2 || true
  exit 1
fi
echo "OK: PgBouncer accepting TCP on 127.0.0.1:${PORT}"

pid="$(docker exec "${LITELLM_CONTAINER}" sh -c "pgrep -f 'litellm --config' | head -1" || true)"
if [ -z "${pid}" ]; then
  echo "ERROR: litellm process not found" >&2
  exit 1
fi

docker exec "${LITELLM_CONTAINER}" python3 - "${pid}" <<'PY'
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

pid = sys.argv[1]
raw = Path(f"/proc/{pid}/environ").read_bytes()
env = {}
for item in raw.split(b"\0"):
    if not item or b"=" not in item:
        continue
    k, v = item.split(b"=", 1)
    env[k.decode()] = v.decode()

url = env.get("DATABASE_URL", "")
if not url:
    print("FAIL: DATABASE_URL unset in litellm child", file=sys.stderr)
    sys.exit(1)
parsed = urlparse(url)
if parsed.hostname not in ("127.0.0.1", "localhost"):
    print(f"FAIL: pooled DATABASE_URL host is {parsed.hostname!r}, expected loopback", file=sys.stderr)
    sys.exit(1)
qs = parse_qs(parsed.query)
if qs.get("pgbouncer", [""])[0].lower() != "true":
    print(f"FAIL: DATABASE_URL missing pgbouncer=true (query={parsed.query!r})", file=sys.stderr)
    sys.exit(1)
if env.get("LITELLM_PGBOUNCER_POOLED_DATABASE_URL", "").lower() not in ("true", "1", "yes"):
    print("FAIL: LITELLM_PGBOUNCER_POOLED_DATABASE_URL not set on worker", file=sys.stderr)
    sys.exit(1)
print(f"OK: child DATABASE_URL -> {parsed.hostname}:{parsed.port or 6432} with pgbouncer=true")
PY
