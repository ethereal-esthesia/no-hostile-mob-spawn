#!/usr/bin/env bash

property() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

bump_patch_version() {
  local version="$1"
  local major=""
  local minor=""
  local patch=""
  local rest=""

  IFS=. read -r major minor patch rest <<< "$version"
  if [ -z "${major:-}" ] || [ -z "${minor:-}" ] || [ -z "${patch:-}" ] || [ -n "${rest:-}" ]; then
    echo "Cannot auto-bump non-semver modVersion: $version" >&2
    return 1
  fi

  printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
}
