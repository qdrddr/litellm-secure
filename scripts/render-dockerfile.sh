#!/usr/bin/env bash
# Render deployment/docker/Dockerfile from Dockerfile.template (optional snapshot for inspection).
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <litellm-image-tag>" >&2
  echo "  Example: $(basename "$0") v1.80.0" >&2
  echo "  Hub tags often look like main-stable — pass the literal tag you build from." >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TAG="$1"
if [[ ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Refusing unsafe tag: ${TAG}" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT}/deployment/docker/Dockerfile.template"
OUT="${ROOT}/deployment/docker/Dockerfile"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: ${TEMPLATE}" >&2
  exit 1
fi

if ! grep -q '^ARG LITELLM_TAG=' "$TEMPLATE"; then
  echo "Template missing ARG LITELLM_TAG= line: ${TEMPLATE}" >&2
  exit 1
fi

sed "s/^ARG LITELLM_TAG=.*/ARG LITELLM_TAG=${TAG}/" "$TEMPLATE" >"$OUT"

echo "Rendered ${OUT} (docker.litellm.ai/berriai/litellm:${TAG})"
