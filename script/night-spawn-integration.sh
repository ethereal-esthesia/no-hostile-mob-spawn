#!/bin/bash
set -euo pipefail

MOD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$MOD_SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MOD_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/script/common.sh" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/script/common.sh"
fi

fail() {
  echo "NoHostileMobSpawn manual spawn integration test failed: $*" >&2
  exit 1
}

if ! declare -F ensure_command >/dev/null 2>&1; then
  ensure_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
      fail "missing required command: $cmd"
    fi
  }
fi

if ! declare -F ensure_java >/dev/null 2>&1; then
  ensure_java() {
    JAVA_CMD="${JAVA_CMD:-java}"
    ensure_command "$JAVA_CMD"
  }
fi

usage() {
  cat >&2 <<EOF
Usage: $0 [seed]

Starts a temporary Hytale server, force-loads the target chunk, then manually
spawns each suppressed role and each preserved mob role at one coordinate. Each
spawn is verified at that coordinate and removed before the next role is tested.

Environment:
  HYTALE_NIGHT_SPAWN_SEED             Seed when [seed] is omitted.
  HYTALE_NIGHT_SPAWN_READY_SECONDS    Seconds to wait for boot. Default: 180.
  HYTALE_NIGHT_SPAWN_FORCE_LOAD_SECONDS
                                      Seconds to wait for chunk force-load. Default: 120.
  HYTALE_NIGHT_SPAWN_CENTER_CHUNK_X    Center chunk X to force-load. Default: 33.
  HYTALE_NIGHT_SPAWN_CENTER_CHUNK_Z    Center chunk Z to force-load. Default: 8.
  HYTALE_NIGHT_SPAWN_CHUNK_RADIUS      Chunk radius around center to force-load. Default: 4.
  HYTALE_NIGHT_SPAWN_SPAWN_X           Manual spawn test X. Default: 1062.
  HYTALE_NIGHT_SPAWN_SPAWN_Y           Manual spawn test Y. Default: 80.
  HYTALE_NIGHT_SPAWN_SPAWN_Z           Manual spawn test Z. Default: 283.
  HYTALE_NIGHT_SPAWN_POSITION_TOLERANCE
                                      Maximum position delta. Default: 0.01.
  HYTALE_NIGHT_SPAWN_BIND             Bind address. Default: 127.0.0.1:15520.
  HYTALE_NIGHT_SPAWN_KEEP_WORK_DIR    Set to 1 to keep the temp runtime.
  HYTALE_NIGHT_SPAWN_SOURCE_RUNTIME   Runtime root to clone. Default: SERVER_DIRECTORY.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

seed="${1:-${HYTALE_NIGHT_SPAWN_SEED:-1777943887064}}"
ready_seconds="${HYTALE_NIGHT_SPAWN_READY_SECONDS:-180}"
force_load_seconds="${HYTALE_NIGHT_SPAWN_FORCE_LOAD_SECONDS:-120}"
center_chunk_x="${HYTALE_NIGHT_SPAWN_CENTER_CHUNK_X:-33}"
center_chunk_z="${HYTALE_NIGHT_SPAWN_CENTER_CHUNK_Z:-8}"
chunk_radius="${HYTALE_NIGHT_SPAWN_CHUNK_RADIUS:-4}"
spawn_x="${HYTALE_NIGHT_SPAWN_SPAWN_X:-1062}"
spawn_y="${HYTALE_NIGHT_SPAWN_SPAWN_Y:-80}"
spawn_z="${HYTALE_NIGHT_SPAWN_SPAWN_Z:-283}"
position_tolerance="${HYTALE_NIGHT_SPAWN_POSITION_TOLERANCE:-0.01}"
bind_address="${HYTALE_NIGHT_SPAWN_BIND:-127.0.0.1:15520}"
keep_work_dir="${HYTALE_NIGHT_SPAWN_KEEP_WORK_DIR:-0}"
source_runtime="${HYTALE_NIGHT_SPAWN_SOURCE_RUNTIME:-$SERVER_DIRECTORY}"
source_server_dir="$source_runtime/Server"
source_assets_zip="$source_runtime/Assets.zip"
source_server_jar="$source_server_dir/HytaleServer.jar"
source_server_aot="$source_server_dir/HytaleServer.aot"

[[ "$seed" =~ ^-?[0-9]+$ ]] || fail "seed must be an integer: $seed"
[[ "$ready_seconds" =~ ^[0-9]+$ ]] || fail "ready seconds must be an integer: $ready_seconds"
[[ "$force_load_seconds" =~ ^[0-9]+$ ]] || fail "force-load seconds must be an integer: $force_load_seconds"
[[ "$center_chunk_x" =~ ^-?[0-9]+$ ]] || fail "center chunk X must be an integer: $center_chunk_x"
[[ "$center_chunk_z" =~ ^-?[0-9]+$ ]] || fail "center chunk Z must be an integer: $center_chunk_z"
[[ "$chunk_radius" =~ ^[0-9]+$ ]] || fail "chunk radius must be an integer: $chunk_radius"
[[ "$spawn_x" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || fail "spawn X must be a number: $spawn_x"
[[ "$spawn_y" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || fail "spawn Y must be a number: $spawn_y"
[[ "$spawn_z" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || fail "spawn Z must be a number: $spawn_z"
[[ "$position_tolerance" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "position tolerance must be a number: $position_tolerance"

[ -f "$source_assets_zip" ] || fail "Assets.zip not found: $source_assets_zip"
[ -f "$source_server_jar" ] || fail "HytaleServer.jar not found: $source_server_jar"

ensure_command python3
ensure_command rg
ensure_command rsync
ensure_java

if [ -x "${JAVA_CMD%/java}/javac" ]; then
  JAVAC_CMD="${JAVA_CMD%/java}/javac"
elif command -v javac >/dev/null 2>&1; then
  JAVAC_CMD="$(command -v javac)"
else
  fail "missing required command: javac"
fi

if [ -x "${JAVA_CMD%/java}/jar" ]; then
  JAR_CMD="${JAVA_CMD%/java}/jar"
elif command -v jar >/dev/null 2>&1; then
  JAR_CMD="$(command -v jar)"
else
  fail "missing required command: jar"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/no-hostile-night-spawn.XXXXXX")"
runtime_dir="$work_dir/hytale-game"
server_dir="$runtime_dir/Server"
server_log="$work_dir/server.log"
command_fifo="$work_dir/server.stdin"
hostile_group="$work_dir/NoHostileMobSpawn/Server/NPC/Groups/NoHostileMobSpawn_Hostiles.json"
preserved_group="$work_dir/NoHostileMobSpawn/Server/NPC/Groups/NoHostileMobSpawn_Preserved_Mobs.json"
server_pid=""
fifo_keepalive_pid=""

cleanup() {
  set +e

  if [ -n "$server_pid" ] && kill -0 "$server_pid" >/dev/null 2>&1; then
    if [ -p "$command_fifo" ]; then
      printf '/stop\n' >"$command_fifo" &
      wait $! >/dev/null 2>&1 || true
      sleep 5
    fi
  fi

  if [ -n "$server_pid" ] && kill -0 "$server_pid" >/dev/null 2>&1; then
    kill "$server_pid" >/dev/null 2>&1 || true
    sleep 3
  fi

  if [ -n "$server_pid" ] && kill -0 "$server_pid" >/dev/null 2>&1; then
    kill -9 "$server_pid" >/dev/null 2>&1 || true
  fi

  if [ -n "$fifo_keepalive_pid" ] && kill -0 "$fifo_keepalive_pid" >/dev/null 2>&1; then
    kill "$fifo_keepalive_pid" >/dev/null 2>&1 || true
  fi

  if [ "$keep_work_dir" = "1" ]; then
    echo "Kept temp runtime: $work_dir" >&2
  else
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT INT TERM

link_or_copy() {
  local source="$1"
  local dest="$2"

  if ! ln "$source" "$dest" 2>/dev/null; then
    ln -s "$source" "$dest"
  fi
}

send_command() {
  local command="$1"

  [ -p "$command_fifo" ] || fail "server command FIFO is missing: $command_fifo"
  printf '%s\n' "$command" >"$command_fifo"
}

wait_for_log() {
  local pattern="$1"
  local timeout="$2"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    if [ -f "$server_log" ] && rg -q "$pattern" "$server_log"; then
      return 0
    fi

    if [ -n "$server_pid" ] && ! kill -0 "$server_pid" >/dev/null 2>&1; then
      return 1
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  return 1
}

build_chunk_loader_plugin() {
  local source_root="$work_dir/chunk-loader-src"
  local classes_dir="$work_dir/chunk-loader-classes"
  local package_dir="$source_root/com/etherealesthesia/hytale/nohostilemobspawn/test"
  local source_file="$package_dir/TestChunkLoaderPlugin.java"
  local manifest_file="$work_dir/manifest.json"
  local output_jar="$server_dir/mods/NoHostileMobSpawnTestChunkLoader.jar"

  mkdir -p "$package_dir" "$classes_dir"

  cat >"$source_file" <<'JAVA'
package com.etherealesthesia.hytale.nohostilemobspawn.test;

import com.hypixel.hytale.math.util.ChunkUtil;
import com.hypixel.hytale.math.vector.Rotation3f;
import com.hypixel.hytale.component.Ref;
import com.hypixel.hytale.component.RemoveReason;
import com.hypixel.hytale.component.Store;
import com.hypixel.hytale.server.core.modules.entity.component.TransformComponent;
import com.hypixel.hytale.server.core.plugin.JavaPlugin;
import com.hypixel.hytale.server.core.plugin.JavaPluginInit;
import com.hypixel.hytale.server.core.universe.Universe;
import com.hypixel.hytale.server.core.universe.world.World;
import com.hypixel.hytale.server.core.universe.world.chunk.WorldChunk;
import com.hypixel.hytale.server.core.universe.world.events.AllWorldsLoadedEvent;
import com.hypixel.hytale.server.core.universe.world.npc.INonPlayerCharacter;
import com.hypixel.hytale.server.core.universe.world.storage.EntityStore;
import com.hypixel.hytale.server.npc.NPCPlugin;
import it.unimi.dsi.fastutil.Pair;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.logging.Level;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.joml.Vector3d;

public final class TestChunkLoaderPlugin extends JavaPlugin {
    public TestChunkLoaderPlugin(JavaPluginInit init) {
        super(init);
    }

    @Override
    protected void start() {
        getEventRegistry().registerGlobal(AllWorldsLoadedEvent.class, event -> forceLoadConfiguredChunks());
    }

    private void forceLoadConfiguredChunks() {
        World world = Universe.get().getDefaultWorld();
        int centerX = intEnv("NO_HOSTILE_TEST_CENTER_CHUNK_X", 33);
        int centerZ = intEnv("NO_HOSTILE_TEST_CENTER_CHUNK_Z", 8);
        int radius = Math.max(0, intEnv("NO_HOSTILE_TEST_CHUNK_RADIUS", 4));
        List<CompletableFuture<WorldChunk>> futures = new ArrayList<>();

        for (int x = centerX - radius; x <= centerX + radius; x++) {
            for (int z = centerZ - radius; z <= centerZ + radius; z++) {
                futures.add(world.getChunkAsync(ChunkUtil.indexChunk(x, z)));
            }
        }

        CompletableFuture
                .allOf(futures.toArray(CompletableFuture[]::new))
                .thenRun(() -> world.execute(() -> {
                    keepLoadedAndTicking(world, centerX, centerZ, radius, futures);
                    runManualSpawnProbe(world);
                }))
                .exceptionally(throwable -> {
                    getLogger().at(Level.SEVERE).withCause(throwable)
                            .log("[NoHostileMobSpawnTest] Failed to force-load chunks.");
                    return null;
                });
    }

    private void keepLoadedAndTicking(
            World world,
            int centerX,
            int centerZ,
            int radius,
            List<CompletableFuture<WorldChunk>> futures) {
        int loaded = 0;

        for (CompletableFuture<WorldChunk> future : futures) {
            WorldChunk chunk = future.getNow(null);
            if (chunk == null) {
                continue;
            }

            chunk.addKeepLoaded();
            forceBlockTicks(chunk);
            loaded++;
        }

        getLogger().at(Level.INFO).log("[NoHostileMobSpawnTest] Force-loaded " + loaded
                + " chunks around " + centerX + "," + centerZ
                + " radius " + radius + " in world " + world.getName() + ".");
    }

    private void runManualSpawnProbe(World world) {
        List<String> suppressedRoles;
        List<String> preservedRoles;
        try {
            suppressedRoles = readRoles(Path.of(requiredEnv("NO_HOSTILE_TEST_ROLES_FILE")));
            preservedRoles = readRoles(Path.of(requiredEnv("NO_HOSTILE_TEST_PRESERVED_ROLES_FILE")));
        } catch (Exception exception) {
            failManualProbe("could not read role list: " + exception.getMessage(), exception);
            return;
        }

        Vector3d expected = new Vector3d(
                doubleEnv("NO_HOSTILE_TEST_SPAWN_X", 1062.0),
                doubleEnv("NO_HOSTILE_TEST_SPAWN_Y", 80.0),
                doubleEnv("NO_HOSTILE_TEST_SPAWN_Z", 283.0));
        Rotation3f rotation = new Rotation3f(0.0f, 0.0f, 0.0f);
        double tolerance = doubleEnv("NO_HOSTILE_TEST_POSITION_TOLERANCE", 0.01);
        Store<EntityStore> store = world.getEntityStore().getStore();
        int suppressedCount = probeRoles("suppressed", suppressedRoles, store, expected, rotation, tolerance);
        if (suppressedCount < 0) {
            return;
        }

        int preservedCount = probeRoles("preserved", preservedRoles, store, expected, rotation, tolerance);
        if (preservedCount < 0) {
            return;
        }

        getLogger().at(Level.INFO).log("[NoHostileMobSpawnTest] Manual spawn probe passed: tested "
                + suppressedCount + " suppressed roles and " + preservedCount
                + " preserved mob roles at " + expected + ".");
    }

    private int probeRoles(
            String label,
            List<String> roles,
            Store<EntityStore> store,
            Vector3d expected,
            Rotation3f rotation,
            double tolerance) {
        int tested = 0;

        for (String role : roles) {
            Pair<Ref<EntityStore>, INonPlayerCharacter> spawned = null;
            Ref<EntityStore> ref = null;

            try {
                spawned = NPCPlugin.get().spawnNPC(store, role, null, expected, rotation);
                if (spawned == null || spawned.first() == null || !spawned.first().isValid()) {
                    failManualProbe(label + " role did not spawn: " + role, null);
                    return -1;
                }

                ref = spawned.first();
                TransformComponent transform = store.getComponent(ref, TransformComponent.getComponentType());
                if (transform == null) {
                    failManualProbe("spawned " + label + " role has no transform: " + role, null);
                    return -1;
                }

                Vector3d actual = transform.getPosition();
                if (actual == null || actual.distance(expected) > tolerance) {
                    failManualProbe("spawned " + label + " role moved or spawned at the wrong position: " + role
                            + " expected=" + expected + " actual=" + actual, null);
                    return -1;
                }

                tested++;
            } catch (Exception exception) {
                failManualProbe("exception while spawning " + label + " role: " + role
                        + ": " + exception.getMessage(), exception);
                return -1;
            } finally {
                if (ref != null && ref.isValid()) {
                    store.removeEntity(ref, RemoveReason.REMOVE);
                }
            }
        }

        return tested;
    }

    private void failManualProbe(String message, Throwable throwable) {
        if (throwable == null) {
            getLogger().at(Level.SEVERE).log("[NoHostileMobSpawnTest] Manual spawn probe failed: " + message);
        } else {
            getLogger().at(Level.SEVERE).withCause(throwable)
                    .log("[NoHostileMobSpawnTest] Manual spawn probe failed: " + message);
        }
    }

    private static List<String> readRoles(Path path) throws IOException {
        String json = Files.readString(path);
        Matcher matcher = Pattern.compile("\"([^\"]+)\"").matcher(json);
        List<String> roles = new ArrayList<>();
        while (matcher.find()) {
            String value = matcher.group(1);
            if (!"IncludeRoles".equals(value)) {
                roles.add(value);
            }
        }
        return roles;
    }

    private static void forceBlockTicks(WorldChunk chunk) {
        for (int x = 0; x < ChunkUtil.SIZE; x++) {
            for (int y = 0; y < ChunkUtil.HEIGHT; y++) {
                for (int z = 0; z < ChunkUtil.SIZE; z++) {
                    chunk.setTicking(x, y, z, true);
                }
            }
        }
    }

    private static int intEnv(String name, int fallback) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            return fallback;
        }

        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }

    private static double doubleEnv(String name, double fallback) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            return fallback;
        }

        try {
            return Double.parseDouble(value);
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }

    private static String requiredEnv(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("missing environment variable " + name);
        }
        return value;
    }
}
JAVA

  cat >"$manifest_file" <<EOF
{
  "Group": "Codex",
  "Name": "NoHostileMobSpawnTestChunkLoader",
  "Version": "1.0.0",
  "Description": "Temporary integration-test chunk loader.",
  "Main": "com.etherealesthesia.hytale.nohostilemobspawn.test.TestChunkLoaderPlugin"
}
EOF

  "$JAVAC_CMD" -cp "$server_dir/HytaleServer.jar" -d "$classes_dir" "$source_file"
  "$JAR_CMD" --create --file "$output_jar" -C "$classes_dir" .
  "$JAR_CMD" --update --file "$output_jar" -C "$work_dir" "$(basename "$manifest_file")"
}

mkdir -p "$server_dir" "$server_dir/logs" "$server_dir/mods" "$server_dir/universe/worlds/default" "$runtime_dir/logs"
link_or_copy "$source_assets_zip" "$runtime_dir/Assets.zip"
link_or_copy "$source_server_jar" "$server_dir/HytaleServer.jar"
if [ -f "$source_server_aot" ]; then
  link_or_copy "$source_server_aot" "$server_dir/HytaleServer.aot"
fi

cat >"$runtime_dir/jvm.options" <<EOF
-Xms${HYTALE_NIGHT_SPAWN_MIN_RAM:-2G}
-Xmx${HYTALE_NIGHT_SPAWN_MAX_RAM:-4G}
EOF

cat >"$server_dir/config.json" <<'EOF'
{
  "Version": 4,
  "ServerName": "NoHostileMobSpawn Test Server",
  "MOTD": "Temporary integration test server",
  "Password": "",
  "MaxPlayers": 8,
  "MaxViewRadius": 12,
  "Defaults": {
    "World": "default",
    "GameMode": "Adventure"
  },
  "ConnectionTimeouts": {},
  "RateLimit": {},
  "Modules": {},
  "LogLevels": {},
  "Mods": {},
  "DisplayTmpTagsInStrings": false,
  "PlayerStorage": {
    "Type": "Hytale"
  },
  "AuthCredentialStore": {
    "Type": "Json",
    "Path": "auth.json"
  },
  "Update": {},
  "Backup": {},
  "WorldMap": {}
}
EOF

python3 - "$source_server_dir/universe/worlds/default/config.json" "$server_dir/universe/worlds/default/config.json" "$seed" <<'PY'
import base64
import json
import sys
import uuid
from pathlib import Path

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
seed = int(sys.argv[3])

if source.exists():
    with source.open() as f:
        config = json.load(f)
else:
    config = {
        "Version": 4,
        "WorldGen": {"Type": "Hytale", "Name": "Default", "Version": "0.0.0"},
        "WorldMap": {"Type": "WorldGen"},
        "ChunkStorage": {"Type": "Hytale"},
        "ChunkConfig": {},
        "RequiredPlugins": {},
        "ResourceStorage": {"Type": "Hytale"},
        "Plugin": {},
    }

config["UUID"] = {"$binary": base64.b64encode(uuid.uuid4().bytes).decode("ascii"), "$type": "04"}
config["Seed"] = seed
config["IsTicking"] = True
config["IsBlockTicking"] = True
config["IsGameTimePaused"] = True
config["GameTime"] = "0001-01-01T00:00:00Z"
config["IsSpawningNPC"] = True
config["IsSpawnMarkersEnabled"] = True
config["IsAllNPCFrozen"] = False
config["GameplayConfig"] = config.get("GameplayConfig", "Default")
config["DeleteOnUniverseStart"] = False
config["DeleteOnRemove"] = False

dest.parent.mkdir(parents=True, exist_ok=True)
with dest.open("w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY

"$MOD_SCRIPT_DIR/generate-suppression.py" "$runtime_dir/Assets.zip" "$work_dir/NoHostileMobSpawn" >/dev/null

python3 - "$runtime_dir/Assets.zip" "$work_dir/NoHostileMobSpawn/Reports/Mob_Drops.csv" "$preserved_group" <<'PY'
import csv
import json
import sys
import zipfile
from pathlib import Path, PurePosixPath

assets_zip = Path(sys.argv[1])
mob_drops = Path(sys.argv[2])
preserved_group = Path(sys.argv[3])
roles = set()
role_types = {}

with zipfile.ZipFile(assets_zip) as archive:
    for info in archive.infolist():
        path = PurePosixPath(info.filename)
        if path.parts[:3] != ("Server", "NPC", "Roles") or path.suffix != ".json":
            continue

        try:
            document = json.loads(archive.read(info))
        except json.JSONDecodeError:
            continue

        role_types[path.stem] = document.get("Type", "")

with mob_drops.open(newline="") as f:
    for row in csv.DictReader(f):
        role_name = row.get("role_name")
        if (
            row.get("mob_status") == "preserved"
            and role_name
            and role_types.get(role_name) != "Abstract"
        ):
            roles.add(role_name)

preserved_group.parent.mkdir(parents=True, exist_ok=True)
with preserved_group.open("w") as f:
    json.dump({"IncludeRoles": sorted(roles)}, f, indent=2)
    f.write("\n")
PY

rsync -a \
  --exclude 'package.json' \
  "$work_dir/NoHostileMobSpawn/" "$server_dir/mods/NoHostileMobSpawn/"

python3 - "$MOD_DIR/package/package.json" "$server_dir/mods/NoHostileMobSpawn/manifest.json" "${HYTALE_VERSION_FILE:-}" <<'PY'
import json
import sys
from pathlib import Path

package_json = Path(sys.argv[1])
manifest_json = Path(sys.argv[2])
version_file = Path(sys.argv[3]) if sys.argv[3] else None

with package_json.open() as f:
    manifest = json.load(f)

version = ""
if version_file and version_file.exists():
    marker = version_file.read_text().strip()
    version = marker.split(":", 1)[1] if marker.startswith("hytale:") else marker

def server_version_range(value):
    if value.startswith(("=", "^", "~")) or value.endswith(".x"):
        return value
    return f"={value}"

manifest.setdefault("Group", "Codex")
manifest.setdefault("Name", "NoHostileMobSpawn")
manifest.setdefault("Version", "1.0.0")
if version:
    manifest["ServerVersion"] = server_version_range(version)

with manifest_json.open("w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

build_chunk_loader_plugin

mkfifo "$command_fifo"
tail -f /dev/null >"$command_fifo" &
fifo_keepalive_pid="$!"

(
  cd "$server_dir"
  export NO_HOSTILE_TEST_CENTER_CHUNK_X="$center_chunk_x"
  export NO_HOSTILE_TEST_CENTER_CHUNK_Z="$center_chunk_z"
  export NO_HOSTILE_TEST_CHUNK_RADIUS="$chunk_radius"
  export NO_HOSTILE_TEST_ROLES_FILE="$hostile_group"
  export NO_HOSTILE_TEST_PRESERVED_ROLES_FILE="$preserved_group"
  export NO_HOSTILE_TEST_SPAWN_X="$spawn_x"
  export NO_HOSTILE_TEST_SPAWN_Y="$spawn_y"
  export NO_HOSTILE_TEST_SPAWN_Z="$spawn_z"
  export NO_HOSTILE_TEST_POSITION_TOLERANCE="$position_tolerance"
  exec "$JAVA_CMD" "@../jvm.options" -jar HytaleServer.jar \
    --assets "$runtime_dir/Assets.zip" \
    --auth-mode offline \
    --bind "$bind_address" \
    --disable-sentry \
    --disable-file-watcher \
    <"$command_fifo"
) >"$server_log" 2>&1 &
server_pid="$!"

echo "Started temporary Hytale server PID $server_pid"
echo "Runtime: $work_dir"
echo "Seed: $seed"
echo "Bind: $bind_address"
echo "Force-loaded chunks: center ${center_chunk_x},${center_chunk_z} radius ${chunk_radius}"
echo "Manual spawn coordinate: ${spawn_x},${spawn_y},${spawn_z}"

if ! wait_for_log "Hytale Server Booted" "$ready_seconds"; then
  tail -n 80 "$server_log" >&2 || true
  fail "server did not finish booting within ${ready_seconds}s"
fi

if ! wait_for_log "\\[NoHostileMobSpawnTest\\] Force-loaded" "$force_load_seconds"; then
  tail -n 120 "$server_log" >&2 || true
  fail "test chunk loader did not force-load chunks within ${force_load_seconds}s"
fi

if ! wait_for_log "\\[NoHostileMobSpawnTest\\] Manual spawn probe (passed|failed)" "$ready_seconds"; then
  tail -n 120 "$server_log" >&2 || true
  fail "manual spawn probe did not complete within ${ready_seconds}s"
fi

if rg -q "\\[NoHostileMobSpawnTest\\] Manual spawn probe failed" "$server_log"; then
  tail -n 120 "$server_log" >&2 || true
  fail "manual spawn probe failed"
fi

echo "NoHostileMobSpawn manual spawn integration test passed."
