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
legacy_suppression="$package_dest/Server/NPC/Spawn/Suppression/Peaceful_No_Hostiles.json"
mob_drops_csv="$package_dest/Reports/Mob_Drops.csv"
mob_only_recipe_items_csv="$package_dest/Reports/Mob_Only_Recipe_Items.csv"
default_world_suppression="$package_dest/Server/Instances/Defaults/Default/resources/SpawnSuppressionController.json"

if [ -n "$assets_zip" ] && [ -f "$assets_zip" ]; then
  "$MOD_SCRIPT_DIR/generate-suppression.py" "$assets_zip" "$package_dest" >/dev/null
else
  package_dest="$MOD_DIR/package"
  hostile_group="$package_dest/Server/NPC/Groups/NoHostileMobSpawn_Hostiles.json"
  suppression="$package_dest/Server/NPC/Spawn/Suppression/No_Hostile_Mob_Spawn.json"
  legacy_suppression="$package_dest/Server/NPC/Spawn/Suppression/Peaceful_No_Hostiles.json"
  mob_drops_csv="$package_dest/Reports/Mob_Drops.csv"
  mob_only_recipe_items_csv="$package_dest/Reports/Mob_Only_Recipe_Items.csv"
  default_world_suppression="$package_dest/Server/Instances/Defaults/Default/resources/SpawnSuppressionController.json"
  echo "Assets.zip not found; validating checked-in package payload."
fi

if [ ! -f "$hostile_group" ]; then
  fail "generated hostile role group is missing: $hostile_group"
fi

if [ ! -f "$suppression" ]; then
  fail "generated suppression config is missing: $suppression"
fi

if [ ! -f "$legacy_suppression" ]; then
  fail "legacy suppression compatibility config is missing: $legacy_suppression"
fi

if [ ! -f "$mob_drops_csv" ]; then
  fail "generated mob drops CSV is missing: $mob_drops_csv"
fi

if [ ! -f "$mob_only_recipe_items_csv" ]; then
  fail "generated mob-only recipe item CSV is missing: $mob_only_recipe_items_csv"
fi

if [ ! -f "$default_world_suppression" ]; then
  fail "generated default world suppression controller is missing: $default_world_suppression"
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

python3 - "$suppression" "$legacy_suppression" "$default_world_suppression" <<'PY'
import json
import sys

required = {"Aggressive", "NoHostileMobSpawn_Hostiles"}
for path in sys.argv[1:3]:
    with open(path) as f:
        document = json.load(f)

    suppressed_groups = set(document.get("SuppressedGroups", []))

    missing = sorted(required - suppressed_groups)
    if missing:
        print(f"{path}: missing required suppressed groups: " + ", ".join(missing), file=sys.stderr)
        raise SystemExit(1)

    if document.get("SuppressionRadius", 0) < 2000:
        print(f"{path}: suppression radius is too small", file=sys.stderr)
        raise SystemExit(1)

with open(sys.argv[3]) as f:
    suppressors = json.load(f).get("SpawnSuppressorMap", {})

if not any(entry.get("Suppression") == "No_Hostile_Mob_Spawn" for entry in suppressors.values()):
    print(f"{sys.argv[3]}: no active No_Hostile_Mob_Spawn suppressor", file=sys.stderr)
    raise SystemExit(1)
PY

python3 - "$package_dest" "$hostile_group" <<'PY'
import json
import sys
from pathlib import Path

package_dest = Path(sys.argv[1])
hostile_group_path = Path(sys.argv[2])
with hostile_group_path.open() as f:
    hostile_roles = set(json.load(f).get("IncludeRoles", []))

spawn_root = package_dest / "Server" / "NPC" / "Spawn"
spawn_paths = sorted(spawn_root.rglob("*.json"))
if len(spawn_paths) < 100:
    print(f"{spawn_root}: expected at least 100 hostile spawn overrides, found {len(spawn_paths)}", file=sys.stderr)
    raise SystemExit(1)

required_paths = [
    spawn_root / "World" / "Void" / "Tier1_Night_NPC1.json",
    spawn_root / "Markers" / "Intelligent" / "Goblin" / "Goblin.json",
    spawn_root / "Beacons" / "Zone1" / "Zone1_Cave" / "Zone1_Cave_Goblin.json",
]
for path in required_paths:
    if not path.is_file():
        print(f"{path}: expected hostile spawn override is missing", file=sys.stderr)
        raise SystemExit(1)

for path in spawn_paths:
    with path.open() as f:
        document = json.load(f)

    npcs = document.get("NPCs", [])
    if not isinstance(npcs, list):
        continue

    for entry in npcs:
        if not isinstance(entry, dict):
            continue

        role_name = entry.get("Id") or entry.get("Name")
        if role_name in hostile_roles:
            print(f"{path}: still references hostile role {role_name}", file=sys.stderr)
            raise SystemExit(1)
PY

echo "NoHostileMobSpawn smoke test passed: $count hostile roles (minimum $MIN_HOSTILE_ROLE_COUNT)."
