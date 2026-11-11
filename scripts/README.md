# Release scripts

Canonical Docker Hub / git tag: **`v{litellm}-v{nono}`** (example: `v1.80.0-v0.81.0`).

- `lib/parse-release-tag.sh` — parse canonical tags
- `checkout-litellm-submodule.sh <vX.Y.Z>` — check out `litellm/` submodule at that tag
- `build-local-image.sh <canonical-tag>` — submodule checkout + build LiteLLM from source + nono overlay (`--load` locally); sets **`LITELLM_RELEASE_TAG`** on both base and overlay images
- `build-and-push-image.sh <canonical-tag>` — same for CI/release (multi-arch push); requires **`LITELLM_RELEASE_TAG`** (derived from the canonical tag)
- `render-dockerfile.sh <base-image-ref>` — write `deployment/docker/Dockerfile` from template
- `build-and-push-image.sh v1.80.0-v0.81.0` — multi-arch build and push
- `publish-release.sh --app v1.80.0 --nono 0.81.0` — git tag + push (triggers CI)

Default `LITELLM_TAG` is the LiteLLM portion of the release tag (e.g. `v1.106.8` for `v1.106.8-v0.81.0`). Override with `LITELLM_TAG=main-stable` if the Hub uses a different tag.
