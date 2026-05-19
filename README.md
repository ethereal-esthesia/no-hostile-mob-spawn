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
GitHub release.

## License

No Hostile Mob Spawn is released under the GNU General Public License version 3.
