#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
CURSEFORGE_GAME_ENDPOINT="${CURSEFORGE_GAME_ENDPOINT:-https://www.curseforge.com}"
CURSEFORGE_API_TOKEN="${CURSEFORGE_API_TOKEN:-}"
CURSEFORGE_PROJECT_ID="${CURSEFORGE_PROJECT_ID:-}"
CURSEFORGE_RELEASE_TYPE="${CURSEFORGE_RELEASE_TYPE:-release}"

source "$MOD_DIR/script/properties-lib.sh"

mod_version="$(property "$PROPERTIES_FILE" modVersion)"
hytale_version="$(property "$PROPERTIES_FILE" hytaleServerVersion)"
hytale_game_version_id="$(property "$PROPERTIES_FILE" hytaleGameVersionId)"
hytale_game_version_name="$(property "$PROPERTIES_FILE" hytaleGameVersionName)"
artifact="$("$MOD_DIR/script/artifact-name.sh" path)"
artifact_display_name="$("$MOD_DIR/script/artifact-name.sh" display-name)"

if [ -z "$CURSEFORGE_API_TOKEN" ]; then
  echo "CURSEFORGE_API_TOKEN is required to publish to CurseForge." >&2
  exit 1
fi

if [ -z "$CURSEFORGE_PROJECT_ID" ]; then
  echo "CURSEFORGE_PROJECT_ID is required to publish to CurseForge." >&2
  echo "Find it on the CurseForge project overview page and add it as a GitHub repository variable." >&2
  exit 1
fi

if [ -z "$hytale_game_version_id" ]; then
  echo "hytaleGameVersionId is empty in mod.properties; CurseForge uploads require the numeric Hytale game version ID." >&2
  exit 1
fi

if [ ! -f "$artifact" ]; then
  echo "Release artifact is missing: $artifact" >&2
  exit 1
fi

echo "Using CurseForge game version ID $hytale_game_version_id for ${hytale_game_version_name:-Hytale $hytale_version}."

metadata="$MOD_DIR/build/curseforge-upload-metadata.json"
mkdir -p "$MOD_DIR/build"
python3 - "$metadata" "$mod_version" "$hytale_version" "$hytale_game_version_id" "$artifact_display_name" "$CURSEFORGE_RELEASE_TYPE" <<'PY'
import json
import sys
from pathlib import Path

path, mod_version, hytale_version, game_version_id, artifact_display_name, release_type = sys.argv[1:]
metadata = {
    "changelog": f"Release {mod_version} for Hytale {hytale_version}.\n\nRetested and updated version ID metadata.",
    "changelogType": "markdown",
    "displayName": artifact_display_name,
    "gameVersions": [int(game_version_id)],
    "releaseType": release_type,
}
Path(path).write_text(json.dumps(metadata, indent=2) + "\n")
PY

echo "CurseForge upload metadata:"
cat "$metadata"

response_file="$MOD_DIR/build/curseforge-upload-response.json"
status_code="$(
  curl -sS \
    -o "$response_file" \
    -w "%{http_code}" \
    -H "X-Api-Token: $CURSEFORGE_API_TOKEN" \
    -F "metadata=<$metadata;type=application/json" \
    -F "file=@$artifact" \
    "$CURSEFORGE_GAME_ENDPOINT/api/projects/$CURSEFORGE_PROJECT_ID/upload-file"
)"

cat "$response_file"
echo

case "$status_code" in
  2??)
    ;;
  *)
    echo "CurseForge upload failed with HTTP $status_code." >&2
    exit 1
    ;;
esac
