# Mode 2 — Nono sidecar (`nono proxy`)

Two containers: **`nono-proxy`** holds real **`SBX_REAL_*`** credentials and runs `nono proxy` on port **4010** (not 4000 — LiteLLM owns **4000**); **`litellm-secure`** runs under `nono run` with [`litellm-sandbox.json`](deployment/docker/nono/profiles/litellm-sandbox.json) only — **no provider secrets** on the LiteLLM container.

**Best for:** stricter separation (keys never on the app container), or Kubernetes/Talos ([deployment/k8s/README.md](deployment/k8s/README.md)).

## Prerequisites

Same as direct, plus in **`.env`**:

```bash
NONO_PROXY_PASS=<long random shared secret>   # nono proxy --pass and litellm phantom auth
LITELLM_NONO_MODE=sidecar                     # optional if you pass mode on the command line
```

Provider keys **only** in **`.env.secrets`** (loaded into **`nono-proxy`**, not litellm). Profile routes: [`litellm-credentials.json`](deployment/docker/nono/profiles/litellm-credentials.json) (edit by hand when adding providers).

Pin versions (no `:latest`):

```bash
export LITELLM_IMAGE=bbkudk/litellm-secure:v1.106.8-v0.81.0
export LITELLM_RELEASE_TAG=v1.106.8
export NONO_VERSION=0.81.0   # ghcr.io/nolabs-ai/nono:0.81.0
```

## Start

```bash
LITELLM_NONO_MODE=sidecar ./scripts/compose-up.sh up -d
```

Equivalent:

```bash
docker compose -f docker-compose.with-nono-proxy.yml up -d
```

Stack: **Postgres** + **litellm-nono-proxy** + **litellm-secure**.

## How it works (short)

1. `nono-proxy` injects real credentials upstream.
2. Entrypoint TCP-forwards `nono-proxy:4010` (Compose) or `127.0.0.1:4010` (K8s same pod) → `127.0.0.1:18080` inside litellm (Landlock `open_port`).
3. Phantoms for LiteLLM come from `PHANTOM_KEY_*` / `PHANTOM_URL_*` or defaults from the credentials profile + `NONO_PROXY_PASS`.

## Use

| Item | Value |
|------|--------|
| LiteLLM API / UI | `http://localhost:4000` (**litellm-secure**); credential proxy (debug) `http://localhost:4010` (**nono-proxy**) |
| Auth header | `Authorization: Bearer $LITELLM_MASTER_KEY` |
| Admin UI | http://localhost:4000/ui — user **`admin`**, password **`LITELLM_MASTER_KEY`** |

Same chat `curl` as [DIRECT.md](DIRECT.md).

## Verify

```bash
./scripts/smoke-health.sh
./scripts/verify-sidecar-keys.sh
VERIFY_MODEL=openrouter/deep-seek-v4-flash-0731 ./scripts/verify-chat-completion.sh
```

Hub image smoke (both modes): from `deployment/docker`:

```bash
docker pull bbkudk/litellm-secure:v1.106.8-v0.81.0
LITELLM_IMAGE=bbkudk/litellm-secure:v1.106.8-v0.81.0 LITELLM_PULL_POLICY=missing ./scripts/e2e-both-modes.sh
```

## Switch back to direct

```bash
LITELLM_NONO_MODE=direct ./scripts/compose-up.sh down
LITELLM_NONO_MODE=direct ./scripts/compose-up.sh up -d
```

More detail: [deployment/docker/README.md](deployment/docker/README.md).
