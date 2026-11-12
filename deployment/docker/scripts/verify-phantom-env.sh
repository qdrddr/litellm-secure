#!/usr/bin/env bash
# Deprecated wrapper — use verify-direct-keys.sh (profile-driven checks for all providers).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "${ROOT}/verify-direct-keys.sh"
