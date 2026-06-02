#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
CURSEFORGE_GAME_ENDPOINT="${CURSEFORGE_GAME_ENDPOINT:-https://www.curseforge.com}"
CURSEFORGE_API_TOKEN="${CURSEFORGE_API_TOKEN:-}"
CURSEFORGE_PROJECT_ID="${CURSEFORGE_PROJECT_ID:-}"
CURSEFORGE_FILE_ID="${CURSEFORGE_FILE_ID:-}"
CURSEFORGE_GAME_VERSION_ID="${CURSEFORGE_GAME_VERSION_ID:-}"
CURSEFORGE_CHANGELOG_ONLY="${CURSEFORGE_CHANGELOG_ONLY:-false}"

source "$MOD_DIR/script/properties-lib.sh"

hytale_version="$(property "$PROPERTIES_FILE" hytaleServerVersion)"
mod_version="$(property "$PROPERTIES_FILE" modVersion)"
hytale_game_version_id="${CURSEFORGE_GAME_VERSION_ID:-$(property "$PROPERTIES_FILE" hytaleGameVersionId)}"
hytale_game_version_name="$(property "$PROPERTIES_FILE" hytaleGameVersionName)"

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

if [ "$CURSEFORGE_CHANGELOG_ONLY" != "true" ] && [ -z "$hytale_game_version_id" ]; then
  echo "hytaleGameVersionId is empty in mod.properties; CurseForge file updates require the numeric Hytale game version ID." >&2
  exit 1
fi

if [ "$CURSEFORGE_CHANGELOG_ONLY" = "true" ]; then
  echo "Updating CurseForge changelog only."
else
  echo "Using CurseForge game version ID $hytale_game_version_id for ${hytale_game_version_name:-Hytale $hytale_version}."
fi

metadata="$MOD_DIR/build/curseforge-update-metadata.json"
mkdir -p "$MOD_DIR/build"
python3 - "$metadata" "$CURSEFORGE_FILE_ID" "$hytale_game_version_id" "$mod_version" "$hytale_version" "$MOD_DIR/CHANGELOG.md" "$CURSEFORGE_CHANGELOG_ONLY" <<'PY'
import json
import re
import sys
from pathlib import Path

path, file_id, game_version_id, mod_version, hytale_version, changelog_path, changelog_only = sys.argv[1:]

def changelog_for_version(path, version):
    changelog = Path(path)
    if not changelog.exists():
        return f"Release {version} for Hytale {hytale_version}."

    text = changelog.read_text()
    pattern = re.compile(
        rf"^##\s+{re.escape(version)}(?:\s+-\s+[^\n]*)?\n(?P<body>.*?)(?=^##\s+|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        return f"Release {version} for Hytale {hytale_version}."

    body = match.group("body").strip()
    if not body:
        return f"Release {version} for Hytale {hytale_version}."
    return f"## {version}\n\n{body}"

metadata = {
    "changelog": changelog_for_version(changelog_path, mod_version),
    "changelogType": "markdown",
    "fileID": int(file_id),
}
if changelog_only != "true":
    metadata["gameVersions"] = [int(game_version_id)]
Path(path).write_text(json.dumps(metadata, indent=2) + "\n")
PY

echo "CurseForge update metadata:"
cat "$metadata"

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
