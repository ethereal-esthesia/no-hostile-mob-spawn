#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<EOF
Usage: $0 [--mod-version VERSION] [--hytale-version VERSION] [--push]

Runs on the prod server. Updates the Hytale release pin from the installed
runtime, runs the full test suite, commits the version-pin change, and
optionally pushes it to GitHub.
EOF
}

fail() {
  echo "NoHostileMobSpawn prod release failed: $*" >&2
  exit 1
}

push=0
update_args=()

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
"$MOD_DIR/script/ci-use-prod-hytale-runtime.sh"
if [ "${#update_args[@]}" -gt 0 ]; then
  "$MOD_DIR/script/update-to-latest-hytale.sh" "${update_args[@]}"
else
  "$MOD_DIR/script/update-to-latest-hytale.sh"
fi

if git diff --quiet -- mod.properties package/package.json; then
  echo "No Hytale release update needed."
  exit 0
fi

"$MOD_DIR/script/test-all.sh"

mod_version="$(./script/project-version.sh)"
hytale_version="$(./script/hytale-version.sh)"

git add mod.properties package/package.json
git commit -m "Release $mod_version for Hytale $hytale_version"

echo "Created release pin commit:"
git --no-pager log --oneline -1

if [ "$push" -eq 1 ]; then
  git push origin HEAD:main
  echo "Pushed release pin update to main."
else
  echo "Push skipped. Run this to publish:"
  echo "  git push origin HEAD:main"
fi

echo "Previous HEAD: $before"
