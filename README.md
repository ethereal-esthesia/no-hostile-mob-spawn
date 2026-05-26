# No Hostile Mob Spawn

No Hostile Mob Spawn suppresses hostile mob spawns while leaving passive
wildlife available.

## Layout

- `package/` is the Hytale package payload copied into `Server/mods`.
- `script/generate-suppression.py` scans the installed `Assets.zip`, generates
  the `NoHostileMobSpawn_Hostiles` NPC group, and writes the suppression config.
  It also writes the legacy `Peaceful_No_Hostiles` suppression ID so worlds
  previously run with the old package can load persisted spawn markers.
- `script/smoke.sh` verifies the generated hostile group has not unexpectedly
  shrunk by more than 5% from the current baseline.
- `script/build-release.sh` writes a jar-format release package named with the
  mod version and pinned Hytale server version.

## Build

From the repo root:

```bash
./script/generate-packages.sh
```

The repo build step installs this subproject into
`$SERVER_DIRECTORY/Server/mods/NoHostileMobSpawn`, writes a version-pinned
`manifest.json`, and runs the suppression generator against the current
`Assets.zip`.

## Smoke Test

```bash
./mods/NoHostileMobSpawn/script/smoke.sh
```

Override `BASELINE_HOSTILE_ROLE_COUNT` when intentionally updating the hostile
scan baseline.

## Manual Spawn Integration Test

```bash
./mods/NoHostileMobSpawn/script/night-spawn-integration.sh 1777943887064
```

This starts an isolated temporary server, pins the default world to the given
seed, force-loads and ticks a square chunk area, then manually spawns every role
in `NoHostileMobSpawn_Hostiles` plus every preserved mob role from
`Reports/Mob_Drops.csv` at one coordinate. Each entity's transform is checked
before it is removed and the next role is tested. The default force-loaded area
is centered on chunk `33,8` with radius `4`; override it with
`HYTALE_NIGHT_SPAWN_CENTER_CHUNK_X`, `HYTALE_NIGHT_SPAWN_CENTER_CHUNK_Z`, and
`HYTALE_NIGHT_SPAWN_CHUNK_RADIUS`.

The default spawn coordinate is `1062,80,283`; override it with
`HYTALE_NIGHT_SPAWN_SPAWN_X`, `HYTALE_NIGHT_SPAWN_SPAWN_Y`, and
`HYTALE_NIGHT_SPAWN_SPAWN_Z`.

## Release

Release metadata is pinned in `mod.properties`.

```bash
./mods/NoHostileMobSpawn/script/prod-release-if-hytale-changed.sh
./mods/NoHostileMobSpawn/script/test-all.sh
```

The release artifact is written to:

```text
build/libs/NoHostileMobSpawn-<modVersion>-hytale-<hytaleServerVersion>.jar
```

Use `prod-release-if-hytale-changed.sh` on the prod server to update release
pins. Automation runs it without a version argument, so it bumps the patch
version only when prod's installed Hytale runtime changed. Manual runs can pass
`--mod-version <version>` to choose the mod release version explicitly. The
publish workflow uses the commit where `modVersion` changed as the release
target, so later non-version commits in the same push do not become the release
artifact.

## Prod Hytale Releases

Schedule release checks on the prod server rather than in GitHub Actions. The
prod job reads the installed Hytale runtime version, updates this mod's release
pin if needed, runs the full temp-server test suite, commits the pin update, and
pushes it to GitHub.

```bash
./script/prod-release-if-hytale-changed.sh --push
./script/prod-release-if-hytale-changed.sh --mod-version 1.0.3 --push
```

If prod has a newer Hytale runtime than the pinned `hytaleServerVersion`, the
script:

1. Updates `mod.properties`.
2. Bumps the mod patch version.
3. Runs the full `test-all.sh` release path on prod.
4. Commits the new pin.
5. Pushes the version-pin commit when `--push` is provided.
6. Lets GitHub publish the jar from that version-change commit.

Like the push publish workflow, the prod release script targets the commit where
`modVersion` changed rather than whatever commit happens to be newest.

The CurseForge project page is:

```text
https://legacy.curseforge.com/hytale/mods/elemental-harmony
```

Required GitHub configuration:

```text
Secret:   CURSEFORGE_API_TOKEN
Variable: CURSEFORGE_PROJECT_ID
```

To retry the CurseForge upload for the current already-released version without
creating another GitHub release, run the `Publish Current Version to CurseForge`
workflow manually and type `publish`.

## License

No Hostile Mob Spawn is released under the GNU General Public License version 3.
