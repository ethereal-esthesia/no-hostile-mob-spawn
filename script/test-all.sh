#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$MOD_DIR"
  bash -n script/*.sh
  ./script/build-release.sh
  ./script/night-spawn-integration.sh "${HYTALE_NIGHT_SPAWN_SEED:-1777943887064}"
)
