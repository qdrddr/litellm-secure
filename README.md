# litellm-secure

Docker overlay that runs [LiteLLM](https://github.com/BerriAI/litellm) (no_root) under [nono](https://nono.sh) sandbox and with **proxy credential injection**. Real provider API keys stay outside the sandboxed LiteLLM — phantom tokens and loopback base URLs only.

Credential injection uses nono [`custom_credentials`](https://nono.sh/docs/cli/features/credential-injection).

## Two deployment modes

| Mode | Guide | Summary |
|------|--------|---------|
| **Direct** | [DIRECT.md](DIRECT.md) | One container: `nono run` + `SBX_REAL_*` on litellm-secure (supervisor only) |
| **Sidecar** | [NONO-SIDECAR.md](NONO-SIDECAR.md) | `nono-proxy` + litellm-secure; secrets only on the proxy |

From `deployment/docker`: `cp .env.example .env`, `cp .env.secrets.example .env.secrets`, then `./scripts/compose-up.sh up -d` (or `LITELLM_NONO_MODE=sidecar` for sidecar). See [deployment/docker/README.md](deployment/docker/README.md) for compose, security model, and verification scripts.

## Releases

Canonical tag: `v{litellm}-v{nono}` (e.g. `v1.106.8-v0.81.0` → image `bbkudk/litellm-secure:v1.106.8-v0.81.0`, LiteLLM base `ghcr.io/berriai/litellm-non_root:v1.106.8`, nono base `ghcr.io/nolabs-ai/nono:0.81.0`).

| Path | Purpose |
|------|---------|
| `deployment/docker/` | Dockerfile, compose, nono profiles, scripts |
| `scripts/` | `build-local-image.sh`, release tagging, Hub publish |
| `litellm/` | Upstream submodule (optional `LITELLM_BUILD_FROM_SOURCE=1`) |
