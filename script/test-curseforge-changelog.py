#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
HELPER_PATH = SCRIPT_DIR / "curseforge_changelog.py"
SPEC = importlib.util.spec_from_file_location("curseforge_changelog", HELPER_PATH)
CHANGELOG = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGELOG)


class CurseForgeChangelogTests(unittest.TestCase):
    def test_selects_current_version_section_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CHANGELOG.md"
            path.write_text(
                "# Changelog\n\n"
                "## 1.0.26 - 2026-11-01\n\n"
                "- Current release fix.\n\n"
                "## 1.0.25 - 2026-10-01\n\n"
                "- Previous release change.\n"
            )

            result = CHANGELOG.changelog_for_version(path, "1.0.26", "0.7.5")

        self.assertEqual(result, "## 1.0.26\n\n- Current release fix.")
        self.assertNotIn("Previous release change", result)

    def test_falls_back_when_version_section_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CHANGELOG.md"
            path.write_text("# Changelog\n\n## 1.0.6 - 2026-06-02\n")

            result = CHANGELOG.changelog_for_version(path, "1.0.25", "0.7.5")

        self.assertEqual(result, "Release 1.0.25 for Hytale 0.7.5.")


if __name__ == "__main__":
    unittest.main()
