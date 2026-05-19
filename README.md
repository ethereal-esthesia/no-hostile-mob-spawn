# No Hostile Mob Spawn

No Hostile Mob Spawn suppresses hostile mob spawns while leaving passive
wildlife available.

## Layout

- `package/` is the Hytale package payload copied into `Server/mods`.
- `script/generate-suppression.py` scans the installed `Assets.zip`, generates
  the `NoHostileMobSpawn_Hostiles` NPC group, and writes the suppression config.
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

## Release

Release metadata is pinned in `mod.properties`.

```bash
./mods/NoHostileMobSpawn/script/build-release.sh
```

The release artifact is written to:

```text
build/libs/NoHostileMobSpawn-<modVersion>-hytale-<hytaleServerVersion>.jar
```

The `Release` workflow mirrors the Minecraft plugin release shape: run it
manually from `main`, type `release`, and it will smoke test, build the
artifact, create tag `v<modVersion>`, and attach the jar-format package to a
GitHub release. It also publishes that jar to CurseForge when
`CURSEFORGE_API_TOKEN` and the `CURSEFORGE_PROJECT_ID` repository variable are
configured.

## Weekly Hytale Releases

The `Weekly Hytale Release` workflow checks CurseForge's Hytale game-version
list once per week. If CurseForge has a newer Hytale version than the pinned
`hytaleServerVersion`, it:

1. Updates `mod.properties`.
2. Bumps the mod patch version.
3. Runs the smoke/build release path.
4. Commits the new pin.
5. Creates a GitHub release.
6. Publishes the release jar to CurseForge.

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
