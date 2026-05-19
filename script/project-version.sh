#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sed -n 's/^modVersion=//p' "$MOD_DIR/mod.properties" | head -n 1
