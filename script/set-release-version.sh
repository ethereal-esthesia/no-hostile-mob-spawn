#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
PACKAGE_JSON="$MOD_DIR/package/package.json"

source "$MOD_DIR/script/properties-lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $0 VERSION
       $0 --patch

Updates mod.properties modVersion and package/package.json Version together.
Commit and push the resulting change to publish that version from GitHub.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

current_version="$(property "$PROPERTIES_FILE" modVersion)"
case "${1:-}" in
  --patch)
    next_version="$(bump_patch_version "$current_version")"
    ;;
  "")
    usage
    exit 2
    ;;
  *)
    next_version="$1"
    ;;
esac

if [[ ! "$next_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  echo "Release version must be numeric semver MAJOR.MINOR.PATCH: $next_version" >&2
  exit 1
fi

python3 - "$PROPERTIES_FILE" "$PACKAGE_JSON" "$next_version" <<'PY'
import json
import sys
from pathlib import Path

properties_path = Path(sys.argv[1])
package_path = Path(sys.argv[2])
version = sys.argv[3]

lines = properties_path.read_text().splitlines()
updated = False
for index, line in enumerate(lines):
    if line.startswith("modVersion="):
        lines[index] = f"modVersion={version}"
        updated = True
        break

if not updated:
    lines.append(f"modVersion={version}")

properties_path.write_text("\n".join(lines) + "\n")

with package_path.open() as f:
    package = json.load(f)

package["Version"] = version
with package_path.open("w") as f:
    json.dump(package, f, indent=2)
    f.write("\n")
PY

echo "Updated release version: $current_version -> $next_version"
