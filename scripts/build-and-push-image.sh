#!/usr/bin/env bash
# Build and push LiteLLM + nono sandbox image (requires: docker login).
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <canonical-git-tag>" >&2
  echo "Example: $(basename "$0") v1.80.0-v0.81.0" >&2
  echo "Env: DOCKER_IMAGE (default bbkudk/litellm-secure), LITELLM_TAG (default BASE_TAG without leading v)" >&2
  echo "     DOCKER_PLATFORMS (default linux/amd64,linux/arm64), BUILDX_BUILDER (optional)" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/parse-release-tag.sh
source "${ROOT}/scripts/lib/parse-release-tag.sh"
DOCKERFILE="${ROOT}/deployment/docker/Dockerfile.template"
DOCKER_CONTEXT="${ROOT}/deployment/docker"
DOCKER_IMAGE="${DOCKER_IMAGE:-bbkudk/litellm-secure}"

parse_release_tag "$1"

LITELLM_TAG="${LITELLM_TAG:-${BASE_TAG}}"

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

echo "Building ${IMAGE_REF} (litellm tag ${LITELLM_TAG}, nono ${NONO_VERSION}) for ${PLATFORMS}"

docker buildx build \
  --platform "${PLATFORMS}" \
  -f "${DOCKERFILE}" \
  --build-arg "LITELLM_TAG=${LITELLM_TAG}" \
  --build-arg "NONO_VERSION=${NONO_VERSION}" \
  -t "${IMAGE_REF}" \
  --push \
  "${DOCKER_CONTEXT}"

echo "Pushed ${IMAGE_REF}"
