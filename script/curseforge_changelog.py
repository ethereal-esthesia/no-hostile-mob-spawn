import re
from pathlib import Path


def changelog_for_version(changelog_path, version, hytale_version):
    changelog = Path(changelog_path)
    if not changelog.exists():
        return f"Release {version} for Hytale {hytale_version}."

    pattern = re.compile(
        rf"^##\s+{re.escape(version)}(?:\s+-\s+[^\n]*)?\n(?P<body>.*?)(?=^##\s+|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(changelog.read_text())
    if not match:
        return f"Release {version} for Hytale {hytale_version}."

    body = match.group("body").strip()
    if not body:
        return f"Release {version} for Hytale {hytale_version}."
    return f"## {version}\n\n{body}"
