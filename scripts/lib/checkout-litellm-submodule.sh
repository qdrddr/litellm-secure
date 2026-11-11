#!/usr/bin/env bash
# Check out the litellm git submodule at a release tag (e.g. v1.106.8).
set -euo pipefail

checkout_litellm_submodule() {
  local litellm_tag="$1"
  local repo_root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local submodule_dir="${repo_root}/litellm"

  if [[ ! "$litellm_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]; then
    echo "Invalid litellm tag: ${litellm_tag} (expected vX.Y.Z)" >&2
    return 1
  fi

  if ! git -C "${submodule_dir}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "litellm submodule not initialized; run: git submodule update --init litellm" >&2
    return 1
  fi

  git -C "${submodule_dir}" fetch --tags --force origin
  if ! git -C "${submodule_dir}" rev-parse "refs/tags/${litellm_tag}^{commit}" >/dev/null 2>&1; then
    echo "Tag ${litellm_tag} not found in litellm submodule (after fetch)." >&2
    return 1
  fi

  git -C "${submodule_dir}" checkout --force "${litellm_tag}"
  echo "litellm submodule: $(git -C "${submodule_dir}" describe --tags --exact-match 2>/dev/null || git -C "${submodule_dir}" rev-parse --short HEAD) @ $(git -C "${submodule_dir}" rev-parse HEAD)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $(basename "$0") <litellm-tag>   # e.g. v1.106.8" >&2
    exit 1
  fi
  checkout_litellm_submodule "$1"
fi
