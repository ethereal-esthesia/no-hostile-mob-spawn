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
./mods/NoHostileMobSpawn/script/set-release-version.sh --patch
./mods/NoHostileMobSpawn/script/test-all.sh
```

The release artifact is written to:

```text
build/libs/NoHostileMobSpawn-<modVersion>-hytale-<hytaleServerVersion>.jar
```

Use `set-release-version.sh` to intentionally change the code release version;
commit and push that version change to `main` to publish. The publish workflow
uses the commit where `modVersion` changed as the release target, so later
non-version commits in the same push do not become the release artifact.
Pushes to `main`, version-change publishes, manual releases, manual CurseForge
publishes, and weekly releases run `test-all.sh` before a jar can be published.
The manual `Release Dry Run` workflow verifies the same test/build path without
creating a tag, GitHub release, or CurseForge upload.

## Weekly Hytale Releases

The `Weekly Hytale Release` workflow checks CurseForge's Hytale game-version
list once per week. If CurseForge has a newer Hytale version than the pinned
`hytaleServerVersion`, it:

1. Updates `mod.properties`.
2. Bumps the mod patch version.
3. Runs the full `test-all.sh` release path.
4. Commits the new pin.
5. Creates a GitHub release.
6. Publishes the release jar to CurseForge.

Like the push publish workflow, the weekly workflow targets the commit where
`modVersion` changed rather than whatever commit happens to be newest.

The CurseForge project page is:

```text
https://legacy.curseforge.com/hytale/mods/elemental-harmony
```

Required GitHub configuration:

```text
Secret:   CURSEFORGE_API_TOKEN
Secret:   HYTALE_RUNTIME_ARCHIVE_URL
Secret:   HYTALE_RUNTIME_ARCHIVE_SHA256
Secret:   HYTALE_RUNTIME_ARCHIVE_AUTH_HEADER (optional)
Variable: CURSEFORGE_PROJECT_ID
```

To retry the CurseForge upload for the current already-released version without
creating another GitHub release, run the `Publish Current Version to CurseForge`
workflow manually and type `publish`.

## License

No Hostile Mob Spawn is released under the GNU General Public License version 3.
