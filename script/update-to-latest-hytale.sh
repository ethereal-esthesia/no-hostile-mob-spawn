#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
PACKAGE_JSON="$MOD_DIR/package/package.json"

source "$MOD_DIR/script/properties-lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $0 [--mod-version VERSION] [--hytale-version VERSION]

Updates the release pin from the Hytale runtime installed on this server.
Automation bumps the patch version when the Hytale pin changes. Manual runs can
pass --mod-version VERSION to choose the mod release version explicitly.
EOF
}

fail() {
  echo "NoHostileMobSpawn Hytale release update failed: $*" >&2
  exit 1
}

requested_mod_version=""
requested_hytale_version="${HYTALE_RELEASE_VERSION:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --mod-version)
      requested_mod_version="${2:-}"
      [ -n "$requested_mod_version" ] || fail "--mod-version requires VERSION"
      shift 2
      ;;
    --hytale-version)
      requested_hytale_version="${2:-}"
      [ -n "$requested_hytale_version" ] || fail "--hytale-version requires VERSION"
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

if [ -n "$requested_mod_version" ] \
  && [[ ! "$requested_mod_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  fail "mod version must be numeric semver MAJOR.MINOR.PATCH: $requested_mod_version"
fi

runtime_version_from_marker() {
  local marker_file="$1"
  local marker=""

  [ -f "$marker_file" ] || return 1
  marker="$(cat "$marker_file")"

  case "$marker" in
    hytale:*)
      printf '%s\n' "$marker" | awk -F: '{print $2}'
      ;;
    none|"")
      return 1
      ;;
    *)
      printf '%s\n' "$marker"
      ;;
  esac
}

runtime_version_from_jar() {
  local runtime_dir="$1"
  local server_jar="$runtime_dir/Server/HytaleServer.jar"

  [ -f "$server_jar" ] || return 1
  unzip -p "$server_jar" META-INF/MANIFEST.MF \
    | tr -d '\r' \
    | awk -F': ' '$1 == "Implementation-Version" {print substr($0, length($1) + 3); exit}'
}

resolve_hytale_version() {
  local marker_file=""
  local version=""

  if [ -n "$requested_hytale_version" ]; then
    printf '%s\n' "$requested_hytale_version"
    return 0
  fi

  marker_file="${HYTALE_VERSION_FILE:-}"
  if [ -z "$marker_file" ] && [ -n "${SERVER_DIRECTORY:-}" ]; then
    marker_file="$SERVER_DIRECTORY/.runtime/hytale-version.txt"
  fi

  if [ -n "$marker_file" ]; then
    version="$(runtime_version_from_marker "$marker_file" || true)"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  if [ -n "${SERVER_DIRECTORY:-}" ]; then
    version="$(runtime_version_from_jar "$SERVER_DIRECTORY" || true)"
    if [ -n "$version" ]; then
      printf '%s\n' "$version"
      return 0
    fi
  fi

  return 1
}

current_mod_version="$(property "$PROPERTIES_FILE" modVersion)"
current_hytale_version="$(property "$PROPERTIES_FILE" hytaleServerVersion)"
current_game_version_id="$(property "$PROPERTIES_FILE" hytaleGameVersionId)"
current_game_version_name="$(property "$PROPERTIES_FILE" hytaleGameVersionName)"
latest_hytale_version="$(resolve_hytale_version || true)"
latest_game_version_id="${HYTALE_GAME_VERSION_ID:-$current_game_version_id}"
latest_game_version_name="${HYTALE_GAME_VERSION_NAME:-$current_game_version_name}"

[ -n "$current_mod_version" ] || fail "modVersion is missing from mod.properties"
[ -n "$current_hytale_version" ] || fail "hytaleServerVersion is missing from mod.properties"
[ -n "$latest_hytale_version" ] || fail "could not resolve installed Hytale version"

next_mod_version="${requested_mod_version:-}"
if [ -z "$next_mod_version" ] && [ "$current_hytale_version" != "$latest_hytale_version" ]; then
  next_mod_version="$(bump_patch_version "$current_mod_version")"
fi
next_mod_version="${next_mod_version:-$current_mod_version}"

if [ "$current_hytale_version" = "$latest_hytale_version" ] \
  && [ "$current_mod_version" = "$next_mod_version" ] \
  && [ "$current_game_version_id" = "$latest_game_version_id" ] \
  && [ "$current_game_version_name" = "$latest_game_version_name" ]; then
  echo "Hytale release pin is current: $current_hytale_version (mod $current_mod_version)"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "changed=false"
      echo "mod_version=$current_mod_version"
      echo "hytale_version=$current_hytale_version"
      echo "game_version_id=$current_game_version_id"
      echo "game_version_name=$current_game_version_name"
    } >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

python3 - "$PROPERTIES_FILE" "$PACKAGE_JSON" "$next_mod_version" "$latest_hytale_version" "$latest_game_version_id" "$latest_game_version_name" <<'PY'
import json
import sys
from pathlib import Path

properties_path = Path(sys.argv[1])
package_path = Path(sys.argv[2])
updates = {
    "modVersion": sys.argv[3],
    "hytaleServerVersion": sys.argv[4],
    "hytaleGameVersionId": sys.argv[5],
    "hytaleGameVersionName": sys.argv[6],
}

lines = properties_path.read_text().splitlines()
seen = set()
for index, line in enumerate(lines):
    key = line.split("=", 1)[0]
    if key in updates:
        lines[index] = f"{key}={updates[key]}"
        seen.add(key)

for key, value in updates.items():
    if key not in seen:
        lines.append(f"{key}={value}")

properties_path.write_text("\n".join(lines) + "\n")

with package_path.open() as f:
    package = json.load(f)

package["Version"] = updates["modVersion"]
with package_path.open("w") as f:
    json.dump(package, f, indent=2)
    f.write("\n")
PY

if [ "$current_hytale_version" != "$latest_hytale_version" ]; then
  echo "Updated Hytale pin: $current_hytale_version -> $latest_hytale_version"
else
  echo "Hytale pin unchanged: $current_hytale_version"
fi

if [ "$current_mod_version" != "$next_mod_version" ]; then
  echo "Updated mod version: $current_mod_version -> $next_mod_version"
else
  echo "Mod version unchanged: $current_mod_version"
fi

if [ "$current_game_version_id" != "$latest_game_version_id" ]; then
  echo "Updated CurseForge game version id: ${current_game_version_id:-unset} -> $latest_game_version_id"
fi

if [ "$current_game_version_name" != "$latest_game_version_name" ]; then
  echo "Updated CurseForge game version name: ${current_game_version_name:-unset} -> $latest_game_version_name"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "changed=true"
    echo "mod_version=$next_mod_version"
    echo "hytale_version=$latest_hytale_version"
    echo "game_version_id=$latest_game_version_id"
    echo "game_version_name=$latest_game_version_name"
  } >> "$GITHUB_OUTPUT"
fi
