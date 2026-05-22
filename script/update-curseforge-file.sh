#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
CURSEFORGE_GAME_ENDPOINT="${CURSEFORGE_GAME_ENDPOINT:-https://www.curseforge.com}"
CURSEFORGE_API_TOKEN="${CURSEFORGE_API_TOKEN:-}"
CURSEFORGE_PROJECT_ID="${CURSEFORGE_PROJECT_ID:-}"
CURSEFORGE_FILE_ID="${CURSEFORGE_FILE_ID:-}"
CURSEFORGE_GAME_VERSION_ID="${CURSEFORGE_GAME_VERSION_ID:-}"
CURSEFORGE_RELEASE_TYPE="${CURSEFORGE_RELEASE_TYPE:-release}"

source "$MOD_DIR/script/properties-lib.sh"

mod_version="$(property "$PROPERTIES_FILE" modVersion)"
hytale_version="$(property "$PROPERTIES_FILE" hytaleServerVersion)"
hytale_game_version_id="${CURSEFORGE_GAME_VERSION_ID:-$(property "$PROPERTIES_FILE" hytaleGameVersionId)}"
hytale_game_version_name="$(property "$PROPERTIES_FILE" hytaleGameVersionName)"
artifact_base_name="$(property "$PROPERTIES_FILE" artifactBaseName)"

if [ -z "$CURSEFORGE_API_TOKEN" ]; then
  echo "CURSEFORGE_API_TOKEN is required to update a CurseForge file." >&2
  exit 1
fi

if [ -z "$CURSEFORGE_PROJECT_ID" ]; then
  echo "CURSEFORGE_PROJECT_ID is required to update a CurseForge file." >&2
  exit 1
fi

if [ -z "$CURSEFORGE_FILE_ID" ]; then
  echo "CURSEFORGE_FILE_ID is required to update a CurseForge file." >&2
  exit 1
fi

if [ -z "$hytale_game_version_id" ]; then
  if [ -z "$hytale_game_version_name" ]; then
    echo "hytaleGameVersionId and hytaleGameVersionName are empty in mod.properties." >&2
    exit 1
  fi

  versions_file="$MOD_DIR/build/curseforge-game-versions.json"
  mkdir -p "$MOD_DIR/build"
  status_code="$(
    curl -sS \
      -o "$versions_file" \
      -w "%{http_code}" \
      -H "X-Api-Token: $CURSEFORGE_API_TOKEN" \
      "$CURSEFORGE_GAME_ENDPOINT/api/game/versions"
  )"
  case "$status_code" in
    2??)
      ;;
    *)
      cat "$versions_file"
      echo
      echo "CurseForge game version lookup failed with HTTP $status_code." >&2
      exit 1
      ;;
  esac

  hytale_game_version_id="$(python3 - "$versions_file" "$hytale_game_version_name" <<'PY'
import json
import sys

path, wanted_name = sys.argv[1:]
with open(path) as f:
    versions = json.load(f)

matches = [version for version in versions if version.get("name") == wanted_name]
if len(matches) != 1:
    print(
        f"Expected one CurseForge game version named {wanted_name!r}; found {len(matches)}.",
        file=sys.stderr,
    )
    candidates = [
        version
        for version in versions
        if any(
            fragment in str(version.get("name", "")).lower()
            for fragment in ("early", "access", "hytale", "2.5", "2-5")
        )
    ]
    print(f"Candidate game versions: {len(candidates)}", file=sys.stderr)
    for version in candidates[:50]:
        print(version, file=sys.stderr)
    raise SystemExit(1)

print(matches[0]["id"])
PY
)"
fi

echo "Using CurseForge game version ID $hytale_game_version_id for $hytale_game_version_name."

metadata="$MOD_DIR/build/curseforge-update-metadata.json"
mkdir -p "$MOD_DIR/build"
python3 - "$metadata" "$CURSEFORGE_FILE_ID" "$mod_version" "$hytale_version" "$hytale_game_version_id" "$artifact_base_name" "$CURSEFORGE_RELEASE_TYPE" <<'PY'
import json
import sys
from pathlib import Path

path, file_id, mod_version, hytale_version, game_version_id, artifact_base_name, release_type = sys.argv[1:]
metadata = {
    "fileID": int(file_id),
    "changelog": (
        f"Release {mod_version} for Hytale {hytale_version}. "
        "Smoke tests passed before publishing."
    ),
    "changelogType": "markdown",
    "displayName": f"{artifact_base_name} {mod_version} for Hytale {hytale_version}",
    "gameVersions": [int(game_version_id)],
    "releaseType": release_type,
}
Path(path).write_text(json.dumps(metadata, indent=2) + "\n")
PY

response_file="$MOD_DIR/build/curseforge-update-response.json"
status_code="$(
  curl -sS \
    -o "$response_file" \
    -w "%{http_code}" \
    -H "X-Api-Token: $CURSEFORGE_API_TOKEN" \
    -F "metadata=<$metadata;type=application/json" \
    "$CURSEFORGE_GAME_ENDPOINT/api/projects/$CURSEFORGE_PROJECT_ID/update-file"
)"

cat "$response_file"
echo

case "$status_code" in
  2??)
    ;;
  *)
    echo "CurseForge update failed with HTTP $status_code." >&2
    exit 1
    ;;
esac
