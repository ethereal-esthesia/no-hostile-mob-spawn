#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<EOF
Usage: $0 [--mod-version VERSION] [--hytale-version VERSION] [--runtime-dir DIR] [--full-tests] [--check-ready] [--push]

Updates the Hytale release pin from an installed runtime, builds the release
artifact, commits the version-pin change, and optionally pushes it to GitHub.
When the Hytale pin changes and --mod-version is omitted, the mod patch version
is bumped automatically.

  --check-ready  Validate that the checkout and runtime are usable, then exit.
EOF
}

fail() {
  echo "NoHostileMobSpawn release failed: $*" >&2
  exit 1
}

notify_validation_needed() {
  local mod_version="$1"
  local hytale_version="$2"
  local commit_sha="$3"
  local notify_script="${HYTALE_MOD_VALIDATION_NOTIFY_SCRIPT:-$MOD_DIR/../../script/server/notify.sh}"
  local message=""

  if [ ! -x "$notify_script" ]; then
    return 0
  fi

  if [ "$push" -eq 1 ]; then
    message="Mod plugin version needs validation: NoHostileMobSpawn $mod_version for Hytale $hytale_version ($commit_sha) was published."
  else
    message="Mod plugin version needs validation: NoHostileMobSpawn $mod_version for Hytale $hytale_version ($commit_sha) is ready before publishing."
  fi

  "$notify_script" info "$message" >/dev/null 2>&1 || true
}

push=0
full_tests=0
check_ready=0
update_args=()
runtime_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --push)
      push=1
      shift
      ;;
    --full-tests)
      full_tests=1
      shift
      ;;
    --check-ready)
      check_ready=1
      shift
      ;;
    --runtime-dir)
      runtime_dir="${2:-}"
      [ -n "$runtime_dir" ] || fail "--runtime-dir requires DIR"
      shift 2
      ;;
    --mod-version|--hytale-version)
      [ -n "${2:-}" ] || fail "$1 requires a value"
      update_args+=("$1" "$2")
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

cd "$MOD_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "working tree has uncommitted changes"
fi

before="$(git rev-parse HEAD)"

if [ -n "$runtime_dir" ]; then
  export HYTALE_PROD_RUNTIME_DIRECTORY="$runtime_dir"
  export SERVER_DIRECTORY="$runtime_dir"
fi

"$MOD_DIR/script/ci-use-prod-hytale-runtime.sh"

if [ "$check_ready" -eq 1 ]; then
  if [ "$push" -eq 1 ]; then
    git push --dry-run origin HEAD:main >/dev/null
  fi
  echo "NoHostileMobSpawn release check is ready."
  exit 0
fi

if [ "${#update_args[@]}" -gt 0 ]; then
  "$MOD_DIR/script/update-to-latest-hytale.sh" "${update_args[@]}"
else
  "$MOD_DIR/script/update-to-latest-hytale.sh"
fi

if git diff --quiet -- mod.properties package/package.json; then
  echo "No Hytale release update needed."
  exit 0
fi

if [ "$push" -eq 1 ]; then
  "$MOD_DIR/script/check-curseforge-upload.sh"
fi

if [ "$full_tests" -eq 1 ]; then
  "$MOD_DIR/script/test-all.sh"
else
  "$MOD_DIR/script/build-release.sh"
fi

mod_version="$(./script/project-version.sh)"
hytale_version="$(./script/hytale-version.sh)"

git add mod.properties package/package.json
git commit -m "Release $mod_version for Hytale $hytale_version"
release_commit="$(git rev-parse --short HEAD)"

echo "Created release pin commit:"
git --no-pager log --oneline -1

if [ "$push" -eq 1 ]; then
  git push origin HEAD:main
  echo "Pushed release pin update to main."
  notify_validation_needed "$mod_version" "$hytale_version" "$release_commit"
else
  notify_validation_needed "$mod_version" "$hytale_version" "$release_commit"
  echo "Push skipped. Run this to publish:"
  echo "  git push origin HEAD:main"
fi

echo "Previous HEAD: $before"
