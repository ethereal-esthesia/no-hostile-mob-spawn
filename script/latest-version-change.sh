#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="mod.properties"

before="${1:-}"
after="${2:-HEAD}"

is_zero_sha() {
  [[ "$1" =~ ^0+$ ]]
}

version_at() {
  local commit="$1"
  git -C "$MOD_DIR" show "${commit}:${PROPERTIES_FILE}" 2>/dev/null \
    | sed -n 's/^modVersion=//p' \
    | head -n 1
}

emit() {
  local changed="$1"
  local commit="${2:-}"
  local version="${3:-}"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "changed=$changed"
      echo "commit=$commit"
      echo "version=$version"
    } >> "$GITHUB_OUTPUT"
  fi

  printf 'changed=%s\ncommit=%s\nversion=%s\n' "$changed" "$commit" "$version"
}

if [ -z "$before" ] || is_zero_sha "$before"; then
  range="$after"
else
  range="${before}..${after}"
fi

while IFS= read -r commit; do
  [ -n "$commit" ] || continue

  current_version="$(version_at "$commit")"
  [ -n "$current_version" ] || continue

  parent="$(git -C "$MOD_DIR" rev-list --parents -n 1 "$commit" | awk '{print $2}')"
  if [ -z "$parent" ]; then
    emit true "$commit" "$current_version"
    exit 0
  fi

  previous_version="$(version_at "$parent" || true)"
  if [ "$current_version" != "$previous_version" ]; then
    emit true "$commit" "$current_version"
    exit 0
  fi
done < <(git -C "$MOD_DIR" rev-list "$range" -- "$PROPERTIES_FILE" package/package.json)

emit false "" ""
