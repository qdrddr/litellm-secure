#!/usr/bin/env bash
# Create canonical git tag v{litellm}-v{nono} and push (triggers .github/workflows/release-docker.yml).
#
# ./scripts/publish-release.sh --app v1.80.0 --nono 0.81.0
# ./scripts/publish-release.sh v1.80.0-v0.81.0
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") --app <litellm-semver-tag> [--nono <semver>]" >&2
  echo "       $(basename "$0") <canonical-tag>" >&2
  echo "  Example: $(basename "$0") v1.80.0-v0.81.0" >&2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/parse-release-tag.sh
source "${ROOT}/scripts/lib/parse-release-tag.sh"
# shellcheck source=lib/resolve-release-args.sh
source "${ROOT}/scripts/lib/resolve-release-args.sh"

if ! resolve_release_tag_args "$@"; then
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    usage
  fi
  exit "$rc"
fi

if [[ "${RESOLVE_FROM_SUBMODULE:-0}" == "1" ]]; then
  echo "Pass --app vX.Y.Z or a canonical tag vX.Y.Z-vA.B.C (no submodule auto-tag for LiteLLM Hub images)." >&2
  usage
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit or stash changes before tagging ${RELEASE_REF}." >&2
  exit 1
fi

if git rev-parse "refs/tags/${RELEASE_REF}" >/dev/null 2>&1; then
  echo "Tag ${RELEASE_REF} already exists locally." >&2
  exit 1
fi

git tag -a "${RELEASE_REF}" -m "Release ${RELEASE_REF}"
git push origin "${RELEASE_REF}"

echo "Pushed tag ${RELEASE_REF} — Docker build workflow should run on GitHub."
