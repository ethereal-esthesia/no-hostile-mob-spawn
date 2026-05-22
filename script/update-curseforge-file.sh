#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
CURSEFORGE_GAME_ENDPOINT="${CURSEFORGE_GAME_ENDPOINT:-https://www.curseforge.com}"
CURSEFORGE_API_TOKEN="${CURSEFORGE_API_TOKEN:-}"
CURSEFORGE_PROJECT_ID="${CURSEFORGE_PROJECT_ID:-}"
CURSEFORGE_FILE_ID="${CURSEFORGE_FILE_ID:-}"
CURSEFORGE_RELEASE_TYPE="${CURSEFORGE_RELEASE_TYPE:-release}"

source "$MOD_DIR/script/properties-lib.sh"

mod_version="$(property "$PROPERTIES_FILE" modVersion)"
hytale_version="$(property "$PROPERTIES_FILE" hytaleServerVersion)"
hytale_game_version_id="$(property "$PROPERTIES_FILE" hytaleGameVersionId)"
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
  echo "hytaleGameVersionId is empty in mod.properties." >&2
  exit 1
fi

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
