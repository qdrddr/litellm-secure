#!/usr/bin/env bash
# Build litellm-secure locally: default pulls ghcr.io/berriai/litellm-non_root, then adds nono overlay.
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <canonical-tag> [--platform linux/arm64|linux/amd64]" >&2
  echo "Example: $(basename "$0") v1.106.8-v0.81.0" >&2
  echo "Env: LITELLM_BASE_IMAGE (override base image)" >&2
  echo "     LITELLM_BUILD_FROM_SOURCE=1 (build litellm/docker/Dockerfile.non_root from submodule)" >&2
  echo "     DOCKER_BUILD_PROGRESS=plain (verbose build logs)" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

REF="$1"
PLATFORM="${LOCAL_DOCKER_PLATFORM:-}"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${PLATFORM}" ]]; then
  case "$(uname -m)" in
    arm64|aarch64) PLATFORM="linux/arm64" ;;
    x86_64|amd64) PLATFORM="linux/amd64" ;;
    *) PLATFORM="linux/amd64" ;;
  esac
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/parse-release-tag.sh
source "${ROOT}/scripts/lib/parse-release-tag.sh"
# shellcheck source=lib/checkout-litellm-submodule.sh
source "${ROOT}/scripts/lib/checkout-litellm-submodule.sh"

parse_release_tag "${REF}"
require_litellm_release_tag

DOCKER_IMAGE="${DOCKER_IMAGE:-bbkudk/litellm-secure}"
DOCKERFILE="${ROOT}/deployment/docker/Dockerfile.template"
DOCKER_CONTEXT="${ROOT}/deployment/docker"
LOCAL_TAG="${LOCAL_IMAGE_TAG:-litellm-secure:local}"
BUILD_PROGRESS_ARGS=()
if [[ "${DOCKER_BUILD_PROGRESS:-}" == plain ]]; then
  BUILD_PROGRESS_ARGS=(--progress=plain)
fi

if [[ -n "${LITELLM_BASE_IMAGE:-}" ]]; then
  BASE_IMAGE="${LITELLM_BASE_IMAGE}"
  echo "Using LITELLM_BASE_IMAGE=${BASE_IMAGE}"
elif [[ "${LITELLM_BUILD_FROM_SOURCE:-}" == "1" ]]; then
  BASE_IMAGE="litellm-secure-base:local"
  checkout_litellm_submodule "${BASE_TAG}" "${ROOT}"
  echo "Building LiteLLM non_root base from submodule at ${LITELLM_RELEASE_TAG} (${PLATFORM})..."
  docker build \
    "${BUILD_PROGRESS_ARGS[@]}" \
    --platform "${PLATFORM}" \
    -f "${ROOT}/litellm/docker/Dockerfile.non_root" \
    --target runtime \
    --build-arg "LITELLM_RELEASE_TAG=${LITELLM_RELEASE_TAG}" \
    -t "${BASE_IMAGE}" \
    "${ROOT}/litellm"
else
  BASE_IMAGE="$(litellm_ghcr_base_image)"
  echo "Pulling GHCR base ${BASE_IMAGE} (${PLATFORM})..."
  docker pull --platform "${PLATFORM}" "${BASE_IMAGE}"
fi

echo "Building nono overlay → ${LOCAL_TAG}..."
docker build \
  "${BUILD_PROGRESS_ARGS[@]}" \
  --platform "${PLATFORM}" \
  -f "${DOCKERFILE}" \
  --build-arg "LITELLM_BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "LITELLM_RELEASE_TAG=${LITELLM_RELEASE_TAG}" \
  --build-arg "NONO_VERSION=${NONO_VERSION}" \
  -t "${LOCAL_TAG}" \
  -t "${DOCKER_IMAGE}:${DOCKER_TAG}" \
  "${DOCKER_CONTEXT}"

export LITELLM_RELEASE_TAG
echo "Built ${LOCAL_TAG} (base ${BASE_IMAGE}, nono ${NONO_VERSION})"
