#!/usr/bin/env bash
# Parse publish CLI args. Requires parse-release-tag.sh sourced first.
set -euo pipefail

resolve_release_tag_args() {
  local app="" nono="" positional=""

  RESOLVE_FROM_SUBMODULE=0
  NONO_VERSION="${NONO_VERSION:-0.81.0}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)
        [[ $# -ge 2 ]] || { echo "Missing value for --app" >&2; return 1; }
        app="$2"
        shift 2
        ;;
      --nono)
        [[ $# -ge 2 ]] || { echo "Missing value for --nono" >&2; return 1; }
        nono="$2"
        shift 2
        ;;
      -h | --help) return 2 ;;
      -*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        [[ -z "$positional" ]] || { echo "Unexpected extra argument: $1" >&2; return 1; }
        positional="$1"
        shift
        ;;
    esac
  done

  [[ -z "$app" || -z "$positional" ]] || { echo "Use --app or a positional tag, not both." >&2; return 1; }

  [[ -n "$nono" ]] && NONO_VERSION="$nono"

  if [[ -n "$app" ]]; then
    export NONO_VERSION
    canonical_release_tag "$app" "${NONO_VERSION#v}"
    RELEASE_REF="$DOCKER_TAG"
    export RELEASE_REF
    return 0
  fi

  if [[ -n "$positional" ]]; then
    parse_release_tag "$positional"
    RELEASE_REF="$DOCKER_TAG"
    export RELEASE_REF
    return 0
  fi

  RESOLVE_FROM_SUBMODULE=1
  export RESOLVE_FROM_SUBMODULE NONO_VERSION
  return 0
}
