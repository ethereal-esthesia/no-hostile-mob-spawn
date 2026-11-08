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
  echo "NoHostileMobSpawn suppression integration test failed: $*" >&2
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

Starts an isolated temporary Hytale server, validates every generated hostile
spawn override, then verifies that the runtime applies suppression to hostile
spawn-marker configurations while allowing a preserved-role probe.

Environment:
  HYTALE_NIGHT_SPAWN_SEED             Seed when [seed] is omitted.
  HYTALE_NIGHT_SPAWN_READY_SECONDS    Seconds to wait for boot. Default: 180.
  HYTALE_NIGHT_SPAWN_FORCE_LOAD_SECONDS
                                      Seconds to wait for chunk force-load. Default: 120.
  HYTALE_NIGHT_SPAWN_CENTER_CHUNK_X    Center chunk X to force-load. Default: 33.
  HYTALE_NIGHT_SPAWN_CENTER_CHUNK_Z    Center chunk Z to force-load. Default: 8.
  HYTALE_NIGHT_SPAWN_CHUNK_RADIUS      Chunk radius around center to force-load. Default: 4.
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
import com.hypixel.hytale.component.Ref;
import com.hypixel.hytale.component.Store;
import com.hypixel.hytale.component.query.Query;
import com.hypixel.hytale.server.core.modules.entity.component.TransformComponent;
import com.hypixel.hytale.server.core.plugin.JavaPlugin;
import com.hypixel.hytale.server.core.plugin.JavaPluginInit;
import com.hypixel.hytale.server.core.universe.Universe;
import com.hypixel.hytale.server.core.universe.world.World;
import com.hypixel.hytale.server.core.universe.world.chunk.ChunkColumn;
import com.hypixel.hytale.server.core.universe.world.chunk.WorldChunk;
import com.hypixel.hytale.server.core.universe.world.chunk.section.BlockSection;
import com.hypixel.hytale.server.core.universe.world.events.AllWorldsLoadedEvent;
import com.hypixel.hytale.server.core.universe.world.storage.ChunkStore;
import com.hypixel.hytale.server.core.universe.world.storage.EntityStore;
import com.hypixel.hytale.server.spawning.assets.spawnmarker.config.SpawnMarker;
import com.hypixel.hytale.server.spawning.assets.spawnsuppression.SpawnSuppression;
import com.hypixel.hytale.server.spawning.spawnmarkers.SpawnMarkerEntity;
import com.hypixel.hytale.server.spawning.suppression.SpawnSuppressorEntry;
import com.hypixel.hytale.server.spawning.suppression.component.SpawnSuppressionController;
import com.hypixel.hytale.server.npc.NPCPlugin;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
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
        ChunkStore chunksStore = world.getChunkStore();
        Store<ChunkStore> store = chunksStore.getStore();
        List<CompletableFuture<WorldChunk>> retainedFutures = new ArrayList<>();
        int chunkCount = 0;

        for (int x = centerX - radius; x <= centerX + radius; x++) {
            for (int z = centerZ - radius; z <= centerZ + radius; z++) {
                long index = ChunkUtil.indexChunk(x, z);
                chunkCount++;
                CompletableFuture<Ref<ChunkStore>> loadFuture = chunksStore.getChunkReferenceAsync(index);
                retainedFutures.add(loadFuture.thenCompose(reference -> {
                    CompletableFuture<WorldChunk> retainedFuture = new CompletableFuture<>();
                    Runnable retainChunk = () -> {
                        try {
                            if (reference == null || !reference.isValid()) {
                                throw new IllegalStateException(
                                        "loaded chunk reference is no longer valid: "
                                                + ChunkUtil.xOfChunkIndex(index) + ","
                                                + ChunkUtil.zOfChunkIndex(index));
                            }
                            WorldChunk chunk = store.getComponent(reference, WorldChunk.getComponentType());
                            if (chunk == null) {
                                throw new IllegalStateException(
                                        "loaded chunk is no longer available: "
                                                + ChunkUtil.xOfChunkIndex(index) + ","
                                                + ChunkUtil.zOfChunkIndex(index));
                            }
                            chunk.addKeepLoaded();
                            retainedFuture.complete(chunk);
                        } catch (RuntimeException exception) {
                            retainedFuture.completeExceptionally(exception);
                        }
                    };

                    if (world.isInThread()) {
                        retainChunk.run();
                    } else {
                        world.execute(retainChunk);
                    }
                    return retainedFuture;
                }));
            }
        }

        int totalChunkCount = chunkCount;
        CompletableFuture
                .allOf(retainedFutures.toArray(CompletableFuture[]::new))
                .thenRunAsync(() -> {
                    for (CompletableFuture<WorldChunk> retainedFuture : retainedFutures) {
                        forceBlockTicks(store, retainedFuture.join());
                    }
                    getLogger().at(Level.INFO).log("[NoHostileMobSpawnTest] Force-loaded " + totalChunkCount
                            + " chunks around " + centerX + "," + centerZ
                            + " radius " + radius + " in world " + world.getName() + ".");
                    verifySpawnSuppression(world, centerX, centerZ, radius);
                }, world)
                .exceptionally(throwable -> {
                    getLogger().at(Level.SEVERE).withCause(throwable)
                            .log("[NoHostileMobSpawnTest] Runtime suppression integration test failed.");
                    return null;
                });
    }

    private void verifySpawnSuppression(World world, int centerX, int centerZ, int radius) {
        List<String> suppressedRoles;
        List<String> preservedRoles;
        try {
            suppressedRoles = readRoles(Path.of(requiredEnv("NO_HOSTILE_TEST_ROLES_FILE")));
            preservedRoles = readRoles(Path.of(requiredEnv("NO_HOSTILE_TEST_PRESERVED_ROLES_FILE")));
        } catch (Exception exception) {
            throw new IllegalStateException("could not read generated role lists", exception);
        }

        Set<String> suppressedRoleSet = new HashSet<>(suppressedRoles);
        Set<String> overlappingRoles = new HashSet<>(suppressedRoleSet);
        overlappingRoles.retainAll(preservedRoles);
        if (!overlappingRoles.isEmpty()) {
            throw new IllegalStateException("roles are both suppressed and preserved: " + overlappingRoles);
        }
        if (!suppressedRoleSet.contains("Bear_Grizzly")) {
            throw new IllegalStateException("confirmed hostile role Bear_Grizzly is missing from the suppression group");
        }

        NPCPlugin npcPlugin = NPCPlugin.get();
        for (String role : suppressedRoles) {
            if (npcPlugin.getIndex(role) < 0) {
                throw new IllegalStateException("suppressed role is missing from the runtime: " + role);
            }
        }
        for (String role : preservedRoles) {
            if (npcPlugin.getIndex(role) < 0) {
                throw new IllegalStateException("preserved role is missing from the runtime: " + role);
            }
        }

        SpawnSuppression suppression =
                SpawnSuppression.getAssetMap().getAsset("No_Hostile_Mob_Spawn");
        if (suppression == null) {
            throw new IllegalStateException("runtime did not load No_Hostile_Mob_Spawn");
        }
        if (!suppression.isSuppressSpawnMarkers() || suppression.getRadius() < 2000.0
                || suppression.getSuppressedGroupIds().length < 2) {
            throw new IllegalStateException("runtime suppression settings are incomplete");
        }

        UUID suppressorId = UUID.fromString("f2187cb4-10df-365e-822a-f509f71cb500");
        Store<EntityStore> entityStore = world.getEntityStore().getStore();
        SpawnSuppressionController controller = entityStore.getResource(SpawnSuppressionController.getResourceType());
        if (controller == null) {
            throw new IllegalStateException("runtime spawn suppression controller is unavailable");
        }
        SpawnSuppressorEntry suppressor = controller.getSpawnSuppressorMap().get(suppressorId);
        if (suppressor == null || !"No_Hostile_Mob_Spawn".equals(suppressor.getSuppressionId())) {
            throw new IllegalStateException("world did not register the No_Hostile_Mob_Spawn suppressor");
        }
        Vector3d expectedSuppressorPosition = new Vector3d(0.0, 128.0, 0.0);
        if (suppressor.getPosition().distance(expectedSuppressorPosition) > 0.01) {
            throw new IllegalStateException("world registered the suppressor at an unexpected position");
        }
        Vector3d testPosition = new Vector3d(
                (centerX * ChunkUtil.SIZE) + ChunkUtil.SIZE / 2.0,
                80.0,
                (centerZ * ChunkUtil.SIZE) + ChunkUtil.SIZE / 2.0);
        if (testPosition.distance(suppressor.getPosition()) > suppression.getRadius()) {
            throw new IllegalStateException("test chunks are outside the configured suppression radius");
        }

        SpawnMarker hostileProbe = SpawnMarker.getAssetMap()
                .getAsset("NoHostileMobSpawn_Integration_Hostile_Probe");
        SpawnMarker preservedProbe = SpawnMarker.getAssetMap()
                .getAsset("NoHostileMobSpawn_Integration_Preserved_Probe");
        if (hostileProbe == null || preservedProbe == null) {
            throw new IllegalStateException("runtime did not load both suppression probe markers");
        }
        verifySuppressionProbe(hostileProbe, suppressedRoleSet, suppression, true);
        verifySuppressionProbe(preservedProbe, new HashSet<>(preservedRoles), suppression, false);

        int minX = (centerX - radius) * ChunkUtil.SIZE;
        int maxX = (centerX + radius + 1) * ChunkUtil.SIZE;
        int minZ = (centerZ - radius) * ChunkUtil.SIZE;
        int maxZ = (centerZ + radius + 1) * ChunkUtil.SIZE;
        int[] markerStats = new int[2];
        entityStore.forEachChunk(
                Query.and(SpawnMarkerEntity.getComponentType(), TransformComponent.getComponentType()),
                (chunk, commandBuffer) -> {
            for (int index = 0; index < chunk.size(); index++) {
                SpawnMarkerEntity marker = chunk.getComponent(index, SpawnMarkerEntity.getComponentType());
                if (marker == null) {
                    continue;
                }

                TransformComponent transform = chunk.getComponent(index, TransformComponent.getComponentType());
                if (transform == null) {
                    continue;
                }
                Vector3d position = transform.getPosition();
                if (position.x < minX || position.x >= maxX || position.z < minZ || position.z >= maxZ) {
                    continue;
                }

                markerStats[0]++;
                SpawnMarker markerConfig = marker.getCachedMarker();
                if (markerConfig == null) {
                    markerConfig = SpawnMarker.getAssetMap().getAsset(marker.getSpawnMarkerId());
                }
                if (markerConfig == null || markerConfig.getWeightedConfigurations() == null) {
                    throw new IllegalStateException(
                            "loaded spawn marker has no configuration: " + marker.getSpawnMarkerId());
                }

                markerConfig.getWeightedConfigurations().forEach(configuration -> {
                    markerStats[1]++;
                    String role = configuration.getNpc();
                    if (suppressedRoleSet.contains(role)) {
                        throw new IllegalStateException("loaded spawn marker still offers hostile role " + role
                                + " through " + marker.getSpawnMarkerId());
                    }
                        });

                if (marker.isSuppressedBy(suppression)
                        && (marker.getSuppressedBy() == null || !marker.getSuppressedBy().contains(suppressorId))) {
                    throw new IllegalStateException(
                            "hostile spawn marker was not registered with its active suppressor");
                }
            }
        });
        getLogger().at(Level.INFO).log("[NoHostileMobSpawnTest] Runtime suppression integration test passed: "
                + suppressedRoles.size() + " hostile roles, " + preservedRoles.size()
                + " preserved roles, " + markerStats[0] + " live spawn markers, "
                + markerStats[1] + " live spawn options; hostile marker probe suppressed and preserved probe allowed.");
    }

    private void verifySuppressionProbe(
            SpawnMarker markerConfig,
            Set<String> expectedRoles,
            SpawnSuppression suppression,
            boolean expectSuppressed) {
        SpawnMarkerEntity marker = new SpawnMarkerEntity();
        marker.setSpawnMarker(markerConfig);
        Set<String> configuredRoles = new HashSet<>();
        markerConfig.getWeightedConfigurations().forEach(configuration -> configuredRoles.add(configuration.getNpc()));
        boolean containsExpectedRole = expectedRoles.stream().anyMatch(configuredRoles::contains);
        if (!containsExpectedRole) {
            throw new IllegalStateException(
                    "runtime probe marker does not reference an expected role: " + markerConfig.getId());
        }

        if (marker.isSuppressedBy(suppression) != expectSuppressed) {
            throw new IllegalStateException(
                    "runtime suppression result was incorrect for probe marker " + markerConfig.getId());
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

    private static void forceBlockTicks(Store<ChunkStore> store, WorldChunk chunk) {
        ChunkColumn column = store.getComponent(chunk.getReference(), ChunkColumn.getComponentType());
        if (column == null) {
            throw new IllegalStateException("chunk has no section column: " + chunk.getX() + "," + chunk.getZ());
        }

        Ref<ChunkStore>[] sections = column.getSections();
        for (int sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
            Ref<ChunkStore> sectionRef = sections[sectionIndex];
            if (sectionRef == null) {
                continue;
            }

            BlockSection section = store.getComponent(sectionRef, BlockSection.getComponentType());
            if (section == null) {
                continue;
            }

            for (int x = 0; x < ChunkUtil.SIZE; x++) {
                for (int y = 0; y < ChunkUtil.SIZE; y++) {
                    for (int z = 0; z < ChunkUtil.SIZE; z++) {
                        section.setTicking(x, y, z, true);
                    }
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
    "Type": "Encrypted",
    "Path": "auth.enc"
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

python3 - "$runtime_dir/Assets.zip" "$work_dir/NoHostileMobSpawn" "$MOD_SCRIPT_DIR/generate-suppression.py" <<'PY'
import importlib.util
import json
import sys
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
assets_zip = Path(sys.argv[1])
package_dir = Path(sys.argv[2])
script_path = Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("generate_suppression", script_path)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

roles, groups, _, _, _, source_spawns = generator.load_json_assets(assets_zip)
hostile_roles = generator.generated_hostile_roles(roles, groups)
with (package_dir / generator.HOSTILE_GROUP_RELATIVE_PATH).open() as f:
    generated_roles = json.load(f).get("IncludeRoles", [])
if generated_roles != hostile_roles:
    raise SystemExit("generated hostile role group differs from runtime classification")
if "Bear_Grizzly" not in hostile_roles:
    raise SystemExit("confirmed hostile role Bear_Grizzly is missing from the generated group")

expected_spawn_documents = {
    path: document
    for path, document, _, _, _ in generator.filtered_spawn_documents(source_spawns, hostile_roles)
}
spawn_root = package_dir / "Server" / "NPC" / "Spawn"
actual_spawn_paths = {
    Path(path.relative_to(package_dir).as_posix())
    for path in spawn_root.rglob("*.json")
    if "/Suppression/" not in path.relative_to(package_dir).as_posix()
}
if actual_spawn_paths != set(expected_spawn_documents):
    raise SystemExit("generated spawn override set differs from hostile-role filtering")
for relative_path, expected_document in expected_spawn_documents.items():
    with (package_dir / relative_path).open() as f:
        actual_document = json.load(f)
    if actual_document != expected_document:
        raise SystemExit(f"{relative_path}: generated override did not preserve/filter source entries correctly")

suppression_path = package_dir / generator.SUPPRESSION_RELATIVE_PATHS[0]
with suppression_path.open() as f:
    suppression = json.load(f)
if (
    suppression.get("SuppressionRadius", 0) < generator.SUPPRESSION_RADIUS
    or not suppression.get("SuppressSpawnMarkers")
    or not {"Aggressive", generator.HOSTILE_GROUP_NAME}.issubset(suppression.get("SuppressedGroups", []))
):
    raise SystemExit("generated suppression asset is missing required hostile suppression settings")

with zipfile.ZipFile(assets_zip) as archive:
    source_spawn_paths = {
        Path(name)
        for name in archive.namelist()
        if name.startswith("Server/NPC/Spawn/") and name.endswith(".json")
    }
if not expected_spawn_documents or not source_spawn_paths:
    raise SystemExit("runtime contains no spawn marker assets to validate")

print(
    f"Verified generated suppression assets: {len(hostile_roles)} hostile roles, "
    f"{len(expected_spawn_documents)} exact spawn overrides."
)
PY

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

python3 - "$work_dir/NoHostileMobSpawn" "$hostile_group" "$preserved_group" <<'PY'
import json
import sys
from pathlib import Path

package_dir = Path(sys.argv[1])
with Path(sys.argv[2]).open() as f:
    hostile_roles = set(json.load(f).get("IncludeRoles", []))
with Path(sys.argv[3]).open() as f:
    preserved_roles = sorted(set(json.load(f).get("IncludeRoles", [])))
if "Bear_Grizzly" not in hostile_roles:
    raise SystemExit("confirmed hostile role Bear_Grizzly is missing from the test role list")
preserved_probe_role = next((role for role in preserved_roles if role not in hostile_roles), None)
if preserved_probe_role is None:
    raise SystemExit("no preserved role is available for the runtime suppression probe")

probe_dir = package_dir / "Server" / "NPC" / "Spawn" / "Markers"
probe_dir.mkdir(parents=True, exist_ok=True)
probe_settings = {
    "Model": "NPC_Spawn_Marker",
    "NPCs": [{"Weight": 1, "Name": None, "RealtimeRespawnTime": 420}],
    "ExclusionRadius": 20,
    "RealtimeRespawn": True,
    "MaxDropHeight": 4,
    "DeactivationDistance": 150,
}
for marker_name, role_name in (
    ("NoHostileMobSpawn_Integration_Hostile_Probe", "Bear_Grizzly"),
    ("NoHostileMobSpawn_Integration_Preserved_Probe", preserved_probe_role),
):
    document = dict(probe_settings)
    document["NPCs"] = [{"Weight": 1, "Name": role_name, "RealtimeRespawnTime": 420}]
    with (probe_dir / f"{marker_name}.json").open("w") as f:
        json.dump(document, f, indent=2)
        f.write("\n")
print(f"Created runtime suppression probes for Bear_Grizzly and {preserved_probe_role}.")
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
    version = marker.removeprefix("hytale:").split(":", 1)[0]

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

mkdir -p "$server_dir/universe/worlds/default/resources"
cp \
  "$work_dir/NoHostileMobSpawn/Server/Instances/Defaults/Default/resources/SpawnSuppressionController.json" \
  "$server_dir/universe/worlds/default/resources/SpawnSuppressionController.json"

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

if ! wait_for_log "Hytale Server Booted" "$ready_seconds"; then
  tail -n 80 "$server_log" >&2 || true
  fail "server did not finish booting within ${ready_seconds}s"
fi

if ! wait_for_log "\\[NoHostileMobSpawnTest\\] Force-loaded" "$force_load_seconds"; then
  tail -n 120 "$server_log" >&2 || true
  fail "test chunk loader did not force-load chunks within ${force_load_seconds}s"
fi

if ! wait_for_log "\\[NoHostileMobSpawnTest\\] Runtime suppression integration test" "$ready_seconds"; then
  tail -n 120 "$server_log" >&2 || true
  fail "runtime suppression test did not complete within ${ready_seconds}s"
fi

if rg -q "\\[NoHostileMobSpawnTest\\] Runtime suppression integration test failed" "$server_log"; then
  tail -n 120 "$server_log" >&2 || true
  fail "runtime suppression test failed"
fi

echo "NoHostileMobSpawn suppression integration test passed."
