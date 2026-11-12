# LiteLLM + Nono (proxy credential injection)

Thin Docker overlay on [LiteLLM](https://github.com/BerriAI/litellm). The proxy runs under [`nono run`](https://nono.sh/docs/cli/features/credential-injection) so **real provider API keys never enter the sandbox**.

## Quick start

```bash
cd deployment/docker
cp .env.example .env
cp .env.secrets.example .env.secrets
# Edit .env (ops + Postgres) and .env.secrets (NONO_* provider keys)
./scripts/compose-up.sh up -d
```

### Two nono modes (one env switch)

Set `LITELLM_NONO_MODE` in `.env` (default `direct`), or export it for a one-off:

| Mode | Command | Where `NONO_*` lives |
|------|---------|------------------------|
| **1 — Direct** | `./scripts/compose-up.sh up -d` | `litellm-secure` via `.env.secrets` (`nono run` + `litellm.json`) |
| **2 — Sidecar** | `LITELLM_NONO_MODE=sidecar ./scripts/compose-up.sh up -d` | `nono-proxy` only (`.env.secrets`); Postgres + LiteLLM in `docker-compose.with-nono-proxy.yml` |

Equivalent sidecar stack without the helper script:

```bash
docker compose -f docker-compose.with-nono-proxy.yml up -d
```

Mode 2 also needs `NONO_PROXY_PASS` in `.env`. Verify: `./scripts/verify-sidecar-keys.sh`.

Kubernetes / Talos (sidecar pod, `NONO_CREDENTIAL_PROXY_HOST=127.0.0.1`): [../k8s/README.md](../k8s/README.md).

Compose mounts `config.example.yaml` by default so a fresh clone starts without `config.yaml`. For a local model list, copy the example and point compose at it:

```bash
cp config.example.yaml config.yaml   # edit model_list / router_settings
echo 'LITELLM_CONFIG_PATH=./config.yaml' >> .env
docker compose up -d --force-recreate litellm
curl -sS http://localhost:4000/health/liveliness
```

Chat completion (requires a valid `NONO_OPENROUTER_API_KEY` for OpenRouter models):

```bash
curl -sS http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"openrouter-gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

## Env conventions (no per-provider names in the image)

| Prefix | Role |
|--------|------|
| `NONO_*` / `NONO_REAL_*` | Real keys for nono (`env://` in your credentials profile). `NONO_REAL_*` is mapped to `NONO_*` on the sidecar proxy. |
| `PHANTOM_KEY_*` | Strip prefix → export to the sandbox child (e.g. `PHANTOM_KEY_OPENROUTER_API_KEY`). |
| `PHANTOM_URL_*` | Strip prefix → loopback base URLs for sidecar mode. |

Sidecar mode fills missing phantoms from `litellm-credentials.json` (`env_var` + route path) and `NONO_PROXY_PASS`. Provider names stay in the profile JSON you edit by hand.

## Security model

| Secret | Where it lives | Seen by LiteLLM? |
|--------|----------------|------------------|
| `NONO_OPENAI_API_KEY` (etc.) | Container env (supervisor) | No — resolved by nono via `env://` |
| `OPENAI_API_KEY` | Set by nono for the child | Phantom token only |
| `OPENAI_BASE_URL` | Set by nono | `http://127.0.0.1:PORT/openai` |
| `NONO_OPENROUTER_API_KEY` | Container env (supervisor) | No — same pattern as other providers |
| `OPENROUTER_API_KEY` / `OPENROUTER_BASE_URL` | Set by nono for child | Phantom token + loopback `/openrouter` |
| `LITELLM_MASTER_KEY` | Container env | Yes (proxy virtual-key auth) |

`docker-compose.yml` always includes Postgres (Admin UI requires it). Set `POSTGRES_PASSWORD`, `LITELLM_SALT_KEY`, and the other `POSTGRES_*` / `DATABASE_*` values in `.env` (see `.env.example`). Changing `POSTGRES_PASSWORD` after the volume was first created does nothing — reset with `docker compose down -v` if auth fails (`P1000`).

**Prisma / DB schema:** The GHCR base image already includes a generated Prisma client. `DISABLE_SCHEMA_UPDATE=true` on the proxy plus `general_settings.disable_prisma_schema_update: true` in config prevent the **sandboxed** process from running `prisma generate` (it would try to chmod files under `/app/.venv`, which Landlock blocks). Migrations run **once per start** in `nono-entrypoint.sh` before `nono run`, on loopback `DATABASE_URL`. A one-time `PermissionError` on `schema.prisma` in logs is harmless after this split; if you need a full migrate on a fresh DB, temporarily set `disable_prisma_schema_update: false` in config for the first boot only.

The entrypoint forwards `db:5432` to `127.0.0.1:5432` before `nono run` so Landlock `open_port: [5432]` can reach Postgres (bridge IPs are blocked). Prisma’s query engine is pinned to `LITELLM_PRISMA_ENGINE_PORT` (default `51245`) because Landlock rejects ephemeral `bind('', 0)`. Keep `STORE_MODEL_IN_DB=False` so provider keys stay in config phantoms only.

**In-container PgBouncer** (`LITELLM_PGBOUNCER_ENABLED`, default `true`): LiteLLM’s built-in pooler listens on loopback `:6432`. It cannot run inside the Landlock sandbox (`evdns` / SIGSEGV), so `nono-entrypoint.sh` starts `pgbouncer_supervisor.py` **unsandboxed** (like the DB TCP forwarder), rewrites `DATABASE_URL` to `?pgbouncer=true`, and sets `LITELLM_PGBOUNCER_ENABLED=false` on the sandboxed proxy so it does not start a second pooler. Nono profiles allow `open_port: 6432` for the worker → pooler hop. CI: `./scripts/verify-pgbouncer.sh`.

**Nono `PATH entry sandbox-writable`:** `/app/.venv` was `filesystem.allow` (rw) while `.venv/bin` is first on `PATH`. Profiles now use `filesystem.read` for `/app/.venv`, `/app/litellm`, `/app/docker`, and `/opt/prisma` so only intentional writable dirs stay on `allow`.

**Log audit in e2e:** `./scripts/audit-container-logs.sh` tails litellm (and sidecar proxy) logs and fails on fatal startup patterns. Benign noise includes Prisma wolfi→debian warnings and failed sandboxed `migrate diff` (migrations already ran unsandboxed in the entrypoint).

Upstream requests: LiteLLM sends the phantom key to the localhost reverse proxy; nono injects `Authorization: Bearer sk-...` (or `x-api-key`) before TLS to the real provider.

**Do not** paste provider keys into the Admin UI or enable DB-stored credentials with real keys — they are decrypted inside the sandbox. Use `config.yaml` with `os.environ/OPENAI_API_KEY` and keep `STORE_MODEL_IN_DB=False` unless you extend the design.

**Do not** set `api_base: https://api.openai.com` in config — that bypasses nono routes. Omit `api_base` so LiteLLM uses nono-provided `OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL`.

Credential injection requires `nono run` with Landlock (Docker Desktop on macOS, modern Linux). Mode 2 adds a **standalone** [`nono proxy`](https://nono.sh/docs/cli/features/networking) container; LiteLLM still runs under `nono run` but without local `custom_credentials`.

## Files

- `Dockerfile.template` — nono overlay on `ghcr.io/berriai/litellm-non_root` (runtime user `65534` / `HOME=/app`, same as base)
- `nono/nono-entrypoint.sh` — stage config, `exec nono run`
- `nono/profiles/litellm.json` — filesystem allowlist + `custom_credentials` for OpenAI / Anthropic / Gemini
- `config.example.yaml` — models referencing `os.environ/*` phantoms

## Verification

See [scripts/README.md](scripts/README.md). Quick path:

```bash
./scripts/smoke-health.sh
./scripts/verify-phantom-env.sh
./scripts/verify-config-reject.sh
# With a real NONO_OPENAI_API_KEY:
./scripts/verify-chat-completion.sh
VERIFY_STREAM=1 ./scripts/verify-chat-completion.sh
```

Release tags: `v{litellm}-v{nono}` — `./scripts/publish-release.sh` + `scripts/build-and-push-image.sh`.

Build the image locally (pulls `ghcr.io/berriai/litellm-non_root:v1.106.8` for tag `v1.106.8-v0.81.0`):

```bash
../../scripts/build-local-image.sh v1.106.8-v0.81.0
LITELLM_IMAGE=litellm-secure:local docker compose up -d
```

Optional submodule compile: `LITELLM_BUILD_FROM_SOURCE=1 ../../scripts/build-local-image.sh v1.106.8-v0.81.0`
