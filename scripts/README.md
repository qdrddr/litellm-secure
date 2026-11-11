# Release scripts

Canonical Docker Hub / git tag: **`v{litellm}-v{nono}`** (example: `v1.80.0-v0.81.0`).

- `lib/parse-release-tag.sh` — parse canonical tags
- `render-dockerfile.sh <litellm-hub-tag>` — write `deployment/docker/Dockerfile` from template
- `build-and-push-image.sh v1.80.0-v0.81.0` — multi-arch build and push
- `publish-release.sh --app v1.80.0 --nono 0.81.0` — git tag + push (triggers CI)

Default `LITELLM_TAG` is the LiteLLM portion of the release tag (e.g. `v1.106.8` for `v1.106.8-v0.81.0`). Override with `LITELLM_TAG=main-stable` if the Hub uses a different tag.
