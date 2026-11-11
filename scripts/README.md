# Release scripts

Canonical Docker Hub / git tag: **`v{litellm}-v{nono}`** (example: `v1.106.8-v0.81.0`).

- `lib/parse-release-tag.sh` — parse canonical tags; `litellm_ghcr_base_image()` → `ghcr.io/berriai/litellm-non_root:vX.Y.Z`
- `lib/checkout-litellm-submodule.sh` — only when `LITELLM_BUILD_FROM_SOURCE=1`
- `build-local-image.sh <canonical-tag>` — pull GHCR non_root base + nono overlay (local tag `litellm-secure:local`)
- `build-and-push-image.sh <canonical-tag>` — same for CI/release (multi-arch push to Docker Hub)
- `render-dockerfile.sh <base-image-ref>` — write `deployment/docker/Dockerfile` from template
- `publish-release.sh` — create git tag + push (triggers [`.github/workflows/release-docker.yml`](../.github/workflows/release-docker.yml))

**Default base:** tag `v1.106.8-v0.81.0` → `ghcr.io/berriai/litellm-non_root:v1.106.8`. No LiteLLM compile in CI.

**Overrides:**

- `LITELLM_BASE_IMAGE=...` — explicit `FROM`
- `LITELLM_BUILD_FROM_SOURCE=1` — build `litellm/docker/Dockerfile.non_root` from submodule instead of GHCR
