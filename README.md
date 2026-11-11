# litellm-secure

Docker overlay that runs [LiteLLM](https://github.com/BerriAI/litellm) under [nono](https://nono.sh) **proxy credential injection**. If the proxy process is compromised, real provider API keys are not exposed in its environment or memory — only phantom tokens and localhost reverse-proxy base URLs.

Pattern follows [CLIProxyAPI-secure](https://github.com/qdrddr/CLIProxyAPI-secure) (thin image + `nono run` entrypoint) and adds nono [`network.credentials` / `custom_credentials`](https://nono.sh/docs/cli/features/credential-injection) so keys come from `NONO_*` container env on the supervisor, not from `OPENAI_API_KEY` inside LiteLLM.

## Run

See [deployment/docker/README.md](deployment/docker/README.md).

```bash
cd deployment/docker
cp .env.example .env && cp config.example.yaml config.yaml
docker compose up -d --build
```

## Repository layout

| Path | Purpose |
|------|---------|
| `deployment/docker/` | Dockerfile, compose, nono profile, example config |
| `litellm/` | Upstream LiteLLM submodule (optional; for `LITELLM_BUILD_FROM_SOURCE=1` only) |
| `scripts/` | Release tagging and multi-arch Hub publish |

## Releases

Canonical image tag: `v{litellm-semver}-v{nono-semver}` (e.g. `v1.106.8-v0.81.0`).

- Push that git tag → CI overlays nono on `ghcr.io/berriai/litellm-non_root:<litellm-semver>` and pushes `bbkudk/litellm-secure:<tag>` (Docker Hub credentials on the **build** environment).
- Local build: `./scripts/build-local-image.sh v1.106.8-v0.81.0` (pulls GHCR base; tag `v1.106.8-v0.81.0` → base `v1.106.8`)
- Create tag: `./scripts/publish-release.sh v1.106.8-v0.81.0` (or `git tag -a v1.106.8-v0.81.0 -m '...' && git push origin v1.106.8-v0.81.0`)
