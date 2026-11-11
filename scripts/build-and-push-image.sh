#!/usr/bin/env bash
# Build and push LiteLLM + nono sandbox image (requires: docker login).
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <canonical-git-tag>" >&2
  echo "Example: $(basename "$0") v1.80.0-v0.81.0" >&2
  echo "Env: DOCKER_IMAGE (default bbkudk/litellm-secure)" >&2
  echo "     DOCKER_PLATFORMS (default linux/amd64,linux/arm64), BUILDX_BUILDER (optional)" >&2
  echo "     LITELLM_BASE_IMAGE (override base; default ghcr.io/berriai/litellm-non_root:<semver from tag>)" >&2
  echo "     LITELLM_BUILD_FROM_SOURCE=1 (build litellm/docker/Dockerfile.non_root from submodule)" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/parse-release-tag.sh
source "${ROOT}/scripts/lib/parse-release-tag.sh"
# shellcheck source=lib/checkout-litellm-submodule.sh
source "${ROOT}/scripts/lib/checkout-litellm-submodule.sh"
DOCKERFILE="${ROOT}/deployment/docker/Dockerfile.template"
DOCKER_CONTEXT="${ROOT}/deployment/docker"
DOCKER_IMAGE="${DOCKER_IMAGE:-bbkudk/litellm-secure}"
LITELLM_NON_ROOT_DOCKERFILE="${ROOT}/litellm/docker/Dockerfile.non_root"

parse_release_tag "$1"
require_litellm_release_tag

if [[ ! "$NONO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Refusing unsafe NONO_VERSION: ${NONO_VERSION}" >&2
  exit 1
fi

IMAGE_REF="${DOCKER_IMAGE}:${DOCKER_TAG}"
PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER="${BUILDX_BUILDER:-litellm-secure-builder}"

if docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  docker buildx use "$BUILDER"
else
  docker buildx create --name "$BUILDER" --use
fi

if [[ -n "${LITELLM_BASE_IMAGE:-}" ]]; then
  BASE_IMAGE_REF="${LITELLM_BASE_IMAGE}"
  echo "Using LITELLM_BASE_IMAGE=${BASE_IMAGE_REF}"
elif [[ "${LITELLM_BUILD_FROM_SOURCE:-}" == "1" ]]; then
  checkout_litellm_submodule "${BASE_TAG}" "${ROOT}"
  BASE_IMAGE_REF="${DOCKER_IMAGE}-litellm-src:${DOCKER_TAG}"
  echo "Building LiteLLM non_root base from submodule ${LITELLM_RELEASE_TAG} → ${BASE_IMAGE_REF}"
  docker buildx build \
    --platform "${PLATFORMS}" \
    -f "${LITELLM_NON_ROOT_DOCKERFILE}" \
    --target runtime \
    --build-arg "LITELLM_RELEASE_TAG=${LITELLM_RELEASE_TAG}" \
    -t "${BASE_IMAGE_REF}" \
    --push \
    "${ROOT}/litellm"
else
  BASE_IMAGE_REF="$(litellm_ghcr_base_image)"
  echo "Using GHCR base ${BASE_IMAGE_REF} (no submodule compile)"
fi

echo "Building ${IMAGE_REF} (base ${BASE_IMAGE_REF}, nono ${NONO_VERSION}) for ${PLATFORMS}"

docker buildx build \
  --platform "${PLATFORMS}" \
  -f "${DOCKERFILE}" \
  --build-arg "LITELLM_BASE_IMAGE=${BASE_IMAGE_REF}" \
  --build-arg "LITELLM_RELEASE_TAG=${LITELLM_RELEASE_TAG}" \
  --build-arg "NONO_VERSION=${NONO_VERSION}" \
  -t "${IMAGE_REF}" \
  --push \
  "${DOCKER_CONTEXT}"

echo "Pushed ${IMAGE_REF}"
