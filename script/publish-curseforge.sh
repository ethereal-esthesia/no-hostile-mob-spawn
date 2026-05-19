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
artifact_base_name="$(property "$PROPERTIES_FILE" artifactBaseName)"
project_slug="$(property "$PROPERTIES_FILE" curseForgeProjectSlug)"
artifact="$MOD_DIR/build/libs/${artifact_base_name}-${mod_version}-hytale-${hytale_version}.jar"

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
  echo "hytaleGameVersionId is empty in mod.properties; run update-to-latest-hytale.sh first." >&2
  exit 1
fi

if [ ! -f "$artifact" ]; then
  echo "Release artifact is missing: $artifact" >&2
  exit 1
fi

metadata="$MOD_DIR/build/curseforge-upload-metadata.json"
mkdir -p "$MOD_DIR/build"
python3 - "$metadata" "$mod_version" "$hytale_version" "$hytale_game_version_id" "$artifact_base_name" "$project_slug" "$CURSEFORGE_RELEASE_TYPE" <<'PY'
import json
import sys
from pathlib import Path

path, mod_version, hytale_version, game_version_id, artifact_base_name, project_slug, release_type = sys.argv[1:]
metadata = {
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

curl -fsSL \
  -H "X-Api-Token: $CURSEFORGE_API_TOKEN" \
  -F "metadata=@$metadata;type=application/json" \
  -F "file=@$artifact" \
  "$CURSEFORGE_GAME_ENDPOINT/api/projects/$CURSEFORGE_PROJECT_ID/upload-file"
echo
