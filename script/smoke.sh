#!/bin/bash
set -euo pipefail

MOD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$MOD_SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MOD_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/script/common.sh" ]; then
  source "$REPO_ROOT/script/common.sh"
fi

BASELINE_HOSTILE_ROLE_COUNT="${BASELINE_HOSTILE_ROLE_COUNT:-247}"
MIN_HOSTILE_ROLE_COUNT=$(((BASELINE_HOSTILE_ROLE_COUNT * 95 + 99) / 100))
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/no-hostile-mob-spawn-smoke.XXXXXX")"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "NoHostileMobSpawn smoke test failed: $*" >&2
  exit 1
}

assets_zip="${HYTALE_ASSETS_ZIP:-}"
if [ -z "$assets_zip" ] && [ -n "${SERVER_DIRECTORY:-}" ]; then
  assets_zip="$SERVER_DIRECTORY/Assets.zip"
fi
package_dest="$work_dir/NoHostileMobSpawn"
hostile_group="$package_dest/Server/NPC/Groups/NoHostileMobSpawn_Hostiles.json"
suppression="$package_dest/Server/NPC/Spawn/Suppression/No_Hostile_Mob_Spawn.json"
mob_drops_csv="$package_dest/Reports/Mob_Drops.csv"

if [ -n "$assets_zip" ] && [ -f "$assets_zip" ]; then
  "$MOD_SCRIPT_DIR/generate-suppression.py" "$assets_zip" "$package_dest" >/dev/null
else
  package_dest="$MOD_DIR/package"
  hostile_group="$package_dest/Server/NPC/Groups/NoHostileMobSpawn_Hostiles.json"
  suppression="$package_dest/Server/NPC/Spawn/Suppression/No_Hostile_Mob_Spawn.json"
  mob_drops_csv="$package_dest/Reports/Mob_Drops.csv"
  echo "Assets.zip not found; validating checked-in package payload."
fi

if [ ! -f "$hostile_group" ]; then
  fail "generated hostile role group is missing: $hostile_group"
fi

if [ ! -f "$suppression" ]; then
  fail "generated suppression config is missing: $suppression"
fi

if [ ! -f "$mob_drops_csv" ]; then
  fail "generated mob drops CSV is missing: $mob_drops_csv"
fi

count="$(python3 - "$hostile_group" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    roles = json.load(f).get("IncludeRoles", [])

print(len(roles))
PY
)"

if [ "$count" -lt "$MIN_HOSTILE_ROLE_COUNT" ]; then
  fail "hostile role group shrank to $count; expected at least $MIN_HOSTILE_ROLE_COUNT (95% of $BASELINE_HOSTILE_ROLE_COUNT)"
fi

python3 - "$suppression" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    suppressed_groups = set(json.load(f).get("SuppressedGroups", []))

required = {"Aggressive", "NoHostileMobSpawn_Hostiles"}
missing = sorted(required - suppressed_groups)
if missing:
    print("missing required suppressed groups: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
PY

echo "NoHostileMobSpawn smoke test passed: $count hostile roles (minimum $MIN_HOSTILE_ROLE_COUNT)."
