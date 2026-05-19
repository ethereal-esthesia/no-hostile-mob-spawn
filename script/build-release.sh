#!/usr/bin/env bash
set -euo pipefail

MOD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$MOD_SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$MOD_DIR/package"
BUILD_DIR="$MOD_DIR/build"
STAGING_DIR="$BUILD_DIR/release-package"
LIBS_DIR="$BUILD_DIR/libs"
PROPERTIES_FILE="$MOD_DIR/mod.properties"

property() {
  local key="$1"
  sed -n "s/^${key}=//p" "$PROPERTIES_FILE" | head -n 1
}

mod_version="$(property modVersion)"
hytale_version="$(property hytaleServerVersion)"
artifact_base_name="$(property artifactBaseName)"

if [ -z "$mod_version" ] || [ -z "$hytale_version" ] || [ -z "$artifact_base_name" ]; then
  echo "mod.properties must set modVersion, hytaleServerVersion, and artifactBaseName." >&2
  exit 1
fi

package_version="$(python3 - "$PACKAGE_DIR/package.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    print(json.load(f).get("Version", ""))
PY
)"

if [ "$package_version" != "$mod_version" ]; then
  echo "package.json Version ($package_version) does not match mod.properties modVersion ($mod_version)." >&2
  exit 1
fi

"$MOD_SCRIPT_DIR/smoke.sh"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$LIBS_DIR"
rsync -a \
  --exclude '.DS_Store' \
  --exclude 'package.json' \
  --exclude 'manifest.json' \
  --exclude 'hytale-version.txt' \
  "$PACKAGE_DIR/" "$STAGING_DIR/"

python3 - "$PACKAGE_DIR" "$STAGING_DIR" "$artifact_base_name" "$hytale_version" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
fallback_name = sys.argv[3]
hytale_version = sys.argv[4]

with (source / "package.json").open() as f:
    manifest = json.load(f)

manifest.setdefault("Group", "Codex")
manifest.setdefault("Name", fallback_name)
manifest.setdefault("Version", "1.0.0")
manifest["ServerVersion"] = hytale_version

with (dest / "manifest.json").open("w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")

with (dest / "hytale-version.txt").open("w") as f:
    f.write(hytale_version + "\n")
PY

artifact="$LIBS_DIR/${artifact_base_name}-${mod_version}-hytale-${hytale_version}.jar"
rm -f "$artifact"
(
  cd "$STAGING_DIR"
  jar cf "$artifact" .
)

echo "$artifact"
