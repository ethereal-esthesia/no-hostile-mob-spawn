#!/usr/bin/env python3
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath


sys.dont_write_bytecode = True
SCRIPT_DIR = Path(__file__).resolve().parent
GENERATOR_PATH = SCRIPT_DIR / "generate-suppression.py"
SPEC = importlib.util.spec_from_file_location("generate_suppression", GENERATOR_PATH)
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class HostileRoleClassificationTests(unittest.TestCase):
    def setUp(self):
        self.groups = {
            "Goblin": [
                (
                    PurePosixPath(
                        "Server/NPC/Groups/Intelligent/Aggressive/Goblin/Goblin.json"
                    ),
                    {
                        "IncludeRoles": ["*Goblin_*"],
                        "ExcludeRoles": ["Voidtaken*"],
                    },
                )
            ],
            "Feran": [
                (
                    PurePosixPath(
                        "Server/NPC/Groups/Intelligent/Neutral/Feran.json"
                    ),
                    {"IncludeRoles": ["Feran_*"]},
                )
            ],
        }

    def test_aggressive_group_member_is_hostile_without_attack_fields(self):
        roles = {
            "Goblin_Thief": {
                "AttitudeGroup": "Goblin",
                "DefaultNPCAttitude": "Ignore",
            }
        }

        self.assertIn(
            "Goblin_Thief",
            GENERATOR.generated_hostile_roles(roles, self.groups),
        )

    def test_aggressive_group_exclusions_are_respected(self):
        roles = {"VoidtakenGoblin_Thief": {}}

        self.assertNotIn(
            "VoidtakenGoblin_Thief",
            GENERATOR.generated_hostile_roles(roles, self.groups),
        )

    def test_neutral_group_member_is_not_hostile_by_group_membership(self):
        roles = {"Feran_Cub": {"AttitudeGroup": "Feran"}}

        self.assertNotIn(
            "Feran_Cub",
            GENERATOR.generated_hostile_roles(roles, self.groups),
        )

    def test_generated_marker_preserves_timing_for_newly_classified_role(self):
        roles = {"Goblin_Thief": {"AttitudeGroup": "Goblin"}}
        hostile_roles = set(GENERATOR.generated_hostile_roles(roles, self.groups))
        spawns = {
            PurePosixPath(
                "Server/NPC/Spawn/Markers/Intelligent/Goblin/Goblin_Thief.json"
            ): {
                "NPCs": [
                    {
                        "Name": "Goblin_Thief",
                        "Weight": 100,
                        "SpawnAfterGameTime": "P1D",
                    }
                ]
            }
        }

        generated = list(GENERATOR.filtered_spawn_documents(spawns, hostile_roles))

        self.assertEqual(len(generated), 1)
        entries = generated[0][1]["NPCs"]
        self.assertEqual(len(entries), 1)
        self.assertTrue(
            entries[0]["Name"].startswith("NoHostileMobSpawn_Disabled_")
        )
        self.assertEqual(entries[0]["SpawnAfterGameTime"], "P1D")

    def test_prune_removes_orphaned_spawn_overrides_and_keeps_suppression(self):
        stock_path = PurePosixPath(
            "Server/NPC/Spawn/Markers/Goblin.json"
        )
        with tempfile.TemporaryDirectory() as directory:
            package_dest = Path(directory)
            spawn_root = package_dest / "Server" / "NPC" / "Spawn"
            stock_file = package_dest / stock_path
            orphan_file = spawn_root / "Markers" / "Spawn_Void.json"
            suppression_file = (
                spawn_root / "Suppression" / "No_Hostile_Mob_Spawn.json"
            )
            stock_file.parent.mkdir(parents=True)
            orphan_file.parent.mkdir(parents=True, exist_ok=True)
            suppression_file.parent.mkdir(parents=True)
            stock_file.write_text("{}\n")
            orphan_file.write_text("{}\n")
            suppression_file.write_text("{}\n")

            removed = GENERATOR.prune_orphaned_spawn_documents(
                package_dest, {stock_path: {}}
            )

            self.assertEqual(removed, 1)
            self.assertTrue(stock_file.is_file())
            self.assertFalse(orphan_file.exists())
            self.assertTrue(suppression_file.is_file())


if __name__ == "__main__":
    unittest.main()
