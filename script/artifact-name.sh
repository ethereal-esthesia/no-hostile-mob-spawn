#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"

source "$MOD_DIR/script/properties-lib.sh"

mod_version="$(property "$PROPERTIES_FILE" modVersion)"
hytale_version="$(property "$PROPERTIES_FILE" hytaleServerVersion)"
artifact_display_name="$(property "$PROPERTIES_FILE" artifactDisplayName)"
artifact_base_name="$(property "$PROPERTIES_FILE" artifactBaseName)"

if [ -z "$mod_version" ] || [ -z "$hytale_version" ]; then
  echo "mod.properties must set modVersion and hytaleServerVersion." >&2
  exit 1
fi

if [ -z "$artifact_display_name" ]; then
  artifact_display_name="$artifact_base_name"
fi

if [ -z "$artifact_display_name" ]; then
  echo "mod.properties must set artifactDisplayName or artifactBaseName." >&2
  exit 1
fi

case "${1:-filename}" in
  display-name)
    printf '%s %s for Hytale %s\n' "$artifact_display_name" "$mod_version" "$hytale_version"
    ;;
  filename)
    printf '%s %s for Hytale %s.jar\n' "$artifact_display_name" "$mod_version" "$hytale_version"
    ;;
  path)
    printf '%s/build/libs/%s %s for Hytale %s.jar\n' "$MOD_DIR" "$artifact_display_name" "$mod_version" "$hytale_version"
    ;;
  *)
    echo "Usage: $(basename "$0") [filename|display-name|path]" >&2
    exit 2
    ;;
esac
