# Mode 1 — Direct (`nono run`)

One container runs LiteLLM under **`nono run`**. Real provider keys live in **supervisor env** as **`SBX_REAL_*`** in `.env.secrets` (not `NONO_*`, which is reserved for nono itself); the sandboxed LiteLLM process only sees **phantom** keys and loopback `*_BASE_URL` from the [`litellm.json`](deployment/docker/nono/profiles/litellm.json) profile.

**Best for:** local Docker on macOS/Linux where Landlock works in a single container (simplest compose).

## Prerequisites

```bash
cd deployment/docker
cp .env.example .env
cp .env.secrets.example .env.secrets
# Edit .env: LITELLM_MASTER_KEY, LITELLM_SALT_KEY, POSTGRES_PASSWORD, NONO_PROXY_PASS (unused in direct)
# Edit .env.secrets: SBX_REAL_OPENROUTER_API_KEY (and other SBX_REAL_* as needed)
```

Optional: `cp config.example.yaml config.yaml` and set `LITELLM_CONFIG_PATH=./config.yaml` in `.env`.

Pin the image (no `:latest`):

```bash
export LITELLM_IMAGE=bbkudk/litellm-secure:v1.106.8-v0.81.0
export LITELLM_RELEASE_TAG=v1.106.8
export NONO_VERSION=0.81.0
```

## Start

```bash
# default, or explicitly:
LITELLM_NONO_MODE=direct ./scripts/compose-up.sh up -d
```

Stack: **Postgres** + **litellm-secure** (nono overlay on `ghcr.io/berriai/litellm-non_root:v1.106.8`).

## Use

| Item | Value |
|------|--------|
| Proxy API | `http://localhost:4000` |
| Auth header | `Authorization: Bearer $LITELLM_MASTER_KEY` |
| Admin UI | http://localhost:4000/ui — user **`admin`**, password **`LITELLM_MASTER_KEY`** (form POST `/login`) |

Example chat:

```bash
curl -sS http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"openrouter/deep-seek-v4-flash-0731","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

## Verify

```bash
./scripts/smoke-health.sh
./scripts/verify-direct-keys.sh
VERIFY_MODEL=openrouter/deep-seek-v4-flash-0731 ./scripts/verify-chat-completion.sh
```

Both modes: `LITELLM_IMAGE=bbkudk/litellm-secure:v1.106.8-v0.81.0 ./scripts/e2e-both-modes.sh`

## Env conventions

- **`SBX_REAL_*` in `.env.secrets`** — real keys for `env://` in the nono profile (add providers in [`litellm.json`](deployment/docker/nono/profiles/litellm.json) by hand).
- **`PHANTOM_KEY_*` / `PHANTOM_URL_*`** — optional overrides; usually not needed in direct mode.

More detail: [deployment/docker/README.md](deployment/docker/README.md).
