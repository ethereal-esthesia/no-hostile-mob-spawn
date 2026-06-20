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

Use the `Release for Hytale Version` GitHub workflow to update release pins from
a known Hytale runtime version. The workflow patches `mod.properties` and
`package/package.json`, bumps the patch version when needed, commits those
release metadata changes with `GITHUB_TOKEN`, builds the release artifact, and
creates the GitHub release.

`release-if-hytale-changed.sh` remains available for local/manual release
preparation from a checkout with an installed runtime, but production automation
should dispatch the GitHub workflow rather than pushing commits from the server.

## Prod Hytale Releases

Schedule release checks from any machine with an installed Hytale runtime. The
prod server reports the installed Hytale version to GitHub; GitHub Actions owns
the release metadata commit and GitHub release artifact publication.

```bash
gh workflow run release-for-hytale-version.yml \
  --repo ethereal-esthesia/no-hostile-mob-spawn \
  --ref main \
  -f confirm_release=release \
  -f hytale_version=0.5.6
```

If the requested Hytale version is newer than the pinned
`hytaleServerVersion`, the workflow:

1. Updates `mod.properties`.
2. Bumps the mod patch version.
3. Builds the release artifact.
4. Commits the new release metadata.
5. Creates the GitHub release.

This creates a GitHub release only. Test that build on prod before publishing it
to CurseForge.

The CurseForge project page is:

```text
https://legacy.curseforge.com/hytale/mods/elemental-harmony
```

Required GitHub configuration:

```text
Secret:   CURSEFORGE_API_TOKEN
Variable: CURSEFORGE_PROJECT_ID
```

To publish an already-created GitHub release to CurseForge, run the manual
`Publish Release to CurseForge` workflow with the mod version you tested. The
matching GitHub release must exist first, and the optional Hytale version input
must match the release metadata.

```bash
gh workflow run curseforge-publish.yml \
  --repo ethereal-esthesia/no-hostile-mob-spawn \
  --ref main \
  -f confirm_publish=publish \
  -f mod_version=1.0.8 \
  -f hytale_version=0.5.6
```

After a successful upload, the workflow records
`curseforge-upload-v<modVersion>.json` on that release. If the marker already
exists, later workflow runs fail before uploading another file for the same
version.

## License

No Hostile Mob Spawn is released under the GNU General Public License version 3.
