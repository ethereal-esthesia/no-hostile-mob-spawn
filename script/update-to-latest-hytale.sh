#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
CURSEFORGE_GAME_ENDPOINT="${CURSEFORGE_GAME_ENDPOINT:-https://legacy.curseforge.com/hytale}"
CURSEFORGE_API_TOKEN="${CURSEFORGE_API_TOKEN:-}"

source "$MOD_DIR/script/properties-lib.sh"

if [ -z "$CURSEFORGE_API_TOKEN" ]; then
  echo "CURSEFORGE_API_TOKEN is required to check CurseForge Hytale versions." >&2
  exit 1
fi

current_mod_version="$(property "$PROPERTIES_FILE" modVersion)"
current_hytale_version="$(property "$PROPERTIES_FILE" hytaleServerVersion)"
current_game_version_id="$(property "$PROPERTIES_FILE" hytaleGameVersionId)"
versions_file="$MOD_DIR/build/curseforge-hytale-versions.json"
latest_file="$MOD_DIR/build/latest-hytale-version.txt"

mkdir -p "$MOD_DIR/build"
curl -fsSL \
  -H "X-Api-Token: $CURSEFORGE_API_TOKEN" \
  "$CURSEFORGE_GAME_ENDPOINT/api/game/versions" \
  > "$versions_file"

python3 - "$versions_file" > "$latest_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1]) as f:
    versions = json.load(f)

def version_name(version):
    return str(version.get("name") or version.get("slug") or "")

def version_key(version):
    parts = []
    for part in re.split(r"([0-9]+|[A-Za-z]+)", version_name(version)):
        if not part or part in ".-+_ ":
            continue
        if part.isdigit():
            parts.append((1, int(part)))
        else:
            parts.append((0, part.lower()))
    return parts

candidates = [
    version for version in versions
    if version.get("id") and version_name(version)
]
if not candidates:
    raise SystemExit("No CurseForge Hytale game versions returned.")

latest = sorted(candidates, key=version_key, reverse=True)[0]
print(latest["id"])
print(version_name(latest))
PY

latest_game_version_id="$(sed -n '1p' "$latest_file")"
latest_hytale_version="$(sed -n '2p' "$latest_file")"

if [ "$current_hytale_version" = "$latest_hytale_version" ] \
  && [ "$current_game_version_id" = "$latest_game_version_id" ]; then
  echo "Hytale pin is current: $current_hytale_version (CurseForge game version $current_game_version_id)"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "changed=false"
      echo "mod_version=$current_mod_version"
      echo "hytale_version=$current_hytale_version"
      echo "game_version_id=$current_game_version_id"
    } >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

next_mod_version="$(bump_patch_version "$current_mod_version")"

python3 - "$PROPERTIES_FILE" "$next_mod_version" "$latest_hytale_version" "$latest_game_version_id" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
updates = {
    "modVersion": sys.argv[2],
    "hytaleServerVersion": sys.argv[3],
    "hytaleGameVersionId": sys.argv[4],
}

lines = path.read_text().splitlines()
seen = set()
for index, line in enumerate(lines):
    key = line.split("=", 1)[0]
    if key in updates:
        lines[index] = f"{key}={updates[key]}"
        seen.add(key)

for key, value in updates.items():
    if key not in seen:
        lines.append(f"{key}={value}")

path.write_text("\n".join(lines) + "\n")
PY

python3 - "$MOD_DIR/package/package.json" "$next_mod_version" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
with path.open() as f:
    package = json.load(f)

package["Version"] = version
with path.open("w") as f:
    json.dump(package, f, indent=2)
    f.write("\n")
PY

echo "Updated Hytale pin: $current_hytale_version -> $latest_hytale_version"
echo "Updated CurseForge game version id: ${current_game_version_id:-unset} -> $latest_game_version_id"
echo "Updated mod version: $current_mod_version -> $next_mod_version"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "changed=true"
    echo "mod_version=$next_mod_version"
    echo "hytale_version=$latest_hytale_version"
    echo "game_version_id=$latest_game_version_id"
  } >> "$GITHUB_OUTPUT"
fi
