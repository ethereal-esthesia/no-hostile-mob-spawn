#!/usr/bin/env bash
set -euo pipefail

REPO="ethereal-esthesia/no-hostile-mob-spawn"

usage() {
  echo "Usage: $0 <tested-mod-version>" >&2
  echo "Example: $0 1.0.26" >&2
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

version="${1#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid mod version: $1" >&2
  usage
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required to dispatch the CurseForge publish workflow." >&2
  exit 1
fi

tag="v${version}"
if ! release_assets="$(gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name')"; then
  echo "GitHub release $tag was not found or is not accessible." >&2
  exit 1
fi

marker="curseforge-upload-v${version}.json"
if printf '%s\n' "$release_assets" | grep -Fxq "$marker"; then
  echo "CurseForge upload marker already exists on $tag; refusing to publish it again." >&2
  exit 1
fi

if ! printf '%s\n' "$release_assets" | grep -Eq "^Elemental\\.Harmony\\.${version//./\\.}\\.for\\.Hytale\\..+\\.jar$"; then
  echo "GitHub release $tag does not contain its expected Elemental Harmony JAR." >&2
  exit 1
fi

gh workflow run curseforge-publish.yml \
  --repo "$REPO" \
  --ref main \
  -f confirm_publish=publish \
  -f "mod_version=$version"

echo "Dispatched CurseForge publish for $tag."
echo "Watch: gh run list --repo $REPO --workflow curseforge-publish.yml --limit 3"
