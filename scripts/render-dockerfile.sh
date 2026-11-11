#!/usr/bin/env bash
# Render deployment/docker/Dockerfile from Dockerfile.template (optional snapshot for inspection).
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <litellm-base-image-ref> [nono-version]" >&2
  echo "  Example: $(basename "$0") litellm-secure-base:local 0.81.0" >&2
  echo "  Default base: ghcr.io/berriai/litellm-non_root:<LITELLM_RELEASE_TAG> (see scripts/build-local-image.sh)" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

BASE_IMAGE="$1"
NONO_VERSION="${2:-0.81.0}"

if [[ "$BASE_IMAGE" == *$'\n'* || "$BASE_IMAGE" == *$'\r'* ]]; then
  echo "Refusing unsafe base image ref" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT}/deployment/docker/Dockerfile.template"
OUT="${ROOT}/deployment/docker/Dockerfile"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: ${TEMPLATE}" >&2
  exit 1
fi

sed \
  -e "s|^ARG LITELLM_BASE_IMAGE=.*|ARG LITELLM_BASE_IMAGE=${BASE_IMAGE}|" \
  -e "s|^ARG NONO_VERSION=.*|ARG NONO_VERSION=${NONO_VERSION}|" \
  "$TEMPLATE" >"$OUT"

echo "Rendered ${OUT} (FROM ${BASE_IMAGE}, nono ${NONO_VERSION})"
