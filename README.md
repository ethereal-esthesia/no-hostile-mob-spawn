# No Hostile Mob Spawn

No Hostile Mob Spawn suppresses hostile mob spawns while leaving passive
wildlife available.

The public CurseForge/GitHub release artifact is branded as Elemental Harmony
so players can recognize where the jar came from. The internal Hytale package
name remains `NoHostileMobSpawn` for compatibility with existing server
installs and generated assets.

## Layout

- `package/` is the Hytale package payload copied into `Server/mods`.
- `script/generate-suppression.py` scans the installed `Assets.zip`, generates
  the `NoHostileMobSpawn_Hostiles` NPC group, and writes the suppression config.
  It also writes the legacy `Peaceful_No_Hostiles` suppression ID so worlds
  previously run with the old package can load persisted spawn markers.
- `script/smoke.sh` verifies the generated hostile group has not unexpectedly
  shrunk by more than 5% from the current baseline.
- `script/build-release.sh` writes a jar-format release package named with the
  public Elemental Harmony title, mod version, and pinned Hytale server version.

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
./mods/NoHostileMobSpawn/script/release-if-hytale-changed.sh
./mods/NoHostileMobSpawn/script/test-all.sh
```

The release artifact is written to:

```text
build/libs/Elemental Harmony <modVersion> for Hytale <hytaleServerVersion>.jar
```

Use `release-if-hytale-changed.sh` from a dev or prod checkout to update release
pins. Automation runs it without a version argument, so it bumps the patch
version only when the selected Hytale runtime changed. Manual runs can pass
`--runtime-dir <dir>` to select a specific runtime and `--mod-version <version>`
to choose the mod release version explicitly. The script builds the same release
artifact that GitHub publishes; pass `--full-tests` when you also want the
temporary server integration test. The publish workflow uses the commit where
`modVersion` changed as the release target, so later non-version commits in the
same push do not become the release artifact.

## Prod Hytale Releases

Schedule release checks from any machine with an installed Hytale runtime rather
than in GitHub Actions. The job reads the selected Hytale runtime version,
updates this mod's release pin if needed, builds the release artifact, commits
the pin update, and pushes it to GitHub.

```bash
./script/release-if-hytale-changed.sh --push
./script/release-if-hytale-changed.sh --runtime-dir ~/dev/hytale-server/.local/hytale-game --push
./script/release-if-hytale-changed.sh --mod-version 1.0.3 --push
```

If the selected runtime is newer than the pinned `hytaleServerVersion`, the
script:

1. Updates `mod.properties`.
2. Bumps the mod patch version.
3. Builds the release artifact.
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
Secret:   CURSEFORGE_CORE_API_TOKEN (optional when CURSEFORGE_API_TOKEN also works with the Core API)
Variable: CURSEFORGE_PROJECT_ID
```

After a successful CurseForge upload, the workflow records
`curseforge-upload-v<modVersion>.json` on the matching GitHub release. The
publish script also queries CurseForge's file API for the exact release jar name
before uploading. The macOS and Linux release scripts use the same check when
they run with `--push`, so they refuse to create and push a release pin if
CurseForge already has that file. To intentionally upload another CurseForge file
for the same version, run the manual `Publish Current Version to CurseForge`
workflow, type `publish`, and type `republish` in the duplicate override field,
or set `CURSEFORGE_ALLOW_DUPLICATE=republish` for a direct script run.

## License

No Hostile Mob Spawn is released under the GNU General Public License version 3.
