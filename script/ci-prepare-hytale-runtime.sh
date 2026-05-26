#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "NoHostileMobSpawn CI runtime prep failed: $*" >&2
  exit 1
}

runtime_url="${HYTALE_RUNTIME_ARCHIVE_URL:-}"
auth_header="${HYTALE_RUNTIME_ARCHIVE_AUTH_HEADER:-}"
expected_sha256="${HYTALE_RUNTIME_ARCHIVE_SHA256:-}"
runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
download_dir="$runner_temp/no-hostile-hytale-runtime"
archive_path="$download_dir/hytale-runtime.zip"
extract_dir="$download_dir/extract"
runtime_dir="$runner_temp/hytale-game"

[ -n "$runtime_url" ] || fail "HYTALE_RUNTIME_ARCHIVE_URL is required"

mkdir -p "$download_dir"
rm -rf "$extract_dir" "$runtime_dir"

curl_args=(-fsSL --retry 3 --connect-timeout 20 -o "$archive_path")
if [ -n "$auth_header" ]; then
  curl_args+=(-H "$auth_header")
fi
curl "${curl_args[@]}" "$runtime_url"

if [ -n "$expected_sha256" ]; then
  actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    fail "runtime archive SHA-256 mismatch: expected $expected_sha256, got $actual_sha256"
  fi
fi

mkdir -p "$extract_dir"
unzip -q "$archive_path" -d "$extract_dir"

runtime_root=""
if [ -f "$extract_dir/Assets.zip" ] && [ -f "$extract_dir/Server/HytaleServer.jar" ]; then
  runtime_root="$extract_dir"
else
  while IFS= read -r jar_path; do
    candidate="${jar_path%/Server/HytaleServer.jar}"
    if [ -f "$candidate/Assets.zip" ]; then
      runtime_root="$candidate"
      break
    fi
  done < <(find "$extract_dir" -type f -path '*/Server/HytaleServer.jar' | sort)
fi

[ -n "$runtime_root" ] || fail "archive must contain Assets.zip and Server/HytaleServer.jar"

mkdir -p "$runtime_dir"
cp -R "$runtime_root"/. "$runtime_dir"/

[ -f "$runtime_dir/Assets.zip" ] || fail "missing extracted Assets.zip"
[ -f "$runtime_dir/Server/HytaleServer.jar" ] || fail "missing extracted Server/HytaleServer.jar"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "SERVER_DIRECTORY=$runtime_dir"
    echo "HYTALE_ASSETS_ZIP=$runtime_dir/Assets.zip"
  } >> "$GITHUB_ENV"
fi

echo "Prepared Hytale runtime: $runtime_dir"
