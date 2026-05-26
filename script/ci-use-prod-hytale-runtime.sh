#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "NoHostileMobSpawn prod runtime prep failed: $*" >&2
  exit 1
}

MOD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$MOD_SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MOD_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/script/common.sh" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/script/common.sh"
fi

candidate_runtime_dirs=()
for candidate in \
  "${HYTALE_PROD_RUNTIME_DIRECTORY:-}" \
  "${SERVER_DIRECTORY:-}" \
  "$HOME/prod/hytale-server" \
  "$HOME/dev/hytale-server/.local/hytale-game" \
  "/Users/shane/prod/hytale-server" \
  "/Users/shane/dev/hytale-server/.local/hytale-game"
do
  [ -n "$candidate" ] || continue
  candidate_runtime_dirs+=("$candidate")
done

runtime_dir=""
for candidate in "${candidate_runtime_dirs[@]}"; do
  if [ -f "$candidate/Assets.zip" ] && [ -f "$candidate/Server/HytaleServer.jar" ]; then
    runtime_dir="$candidate"
    break
  fi
done

if [ -z "$runtime_dir" ]; then
  {
    echo "Checked runtime directories:"
    printf '  %s\n' "${candidate_runtime_dirs[@]}"
  } >&2
  fail "could not find Assets.zip and Server/HytaleServer.jar on this runner"
fi

export SERVER_DIRECTORY="$runtime_dir"
export HYTALE_ASSETS_ZIP="$runtime_dir/Assets.zip"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "SERVER_DIRECTORY=$SERVER_DIRECTORY"
    echo "HYTALE_ASSETS_ZIP=$HYTALE_ASSETS_ZIP"
  } >> "$GITHUB_ENV"
fi

echo "Using Hytale runtime: $runtime_dir"
