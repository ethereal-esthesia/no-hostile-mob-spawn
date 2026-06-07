#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPERTIES_FILE="$MOD_DIR/mod.properties"
CURSEFORGE_CORE_API_ENDPOINT="${CURSEFORGE_CORE_API_ENDPOINT:-https://api.curseforge.com}"
CURSEFORGE_API_TOKEN="${CURSEFORGE_API_TOKEN:-}"
CURSEFORGE_CORE_API_TOKEN="${CURSEFORGE_CORE_API_TOKEN:-$CURSEFORGE_API_TOKEN}"
CURSEFORGE_PROJECT_ID="${CURSEFORGE_PROJECT_ID:-}"
CURSEFORGE_ALLOW_DUPLICATE="${CURSEFORGE_ALLOW_DUPLICATE:-}"
CURSEFORGE_REQUIRE_DUPLICATE_CHECK="${CURSEFORGE_REQUIRE_DUPLICATE_CHECK:-0}"

source "$MOD_DIR/script/properties-lib.sh"

artifact_name="$("$MOD_DIR/script/artifact-name.sh" filename)"

case "$CURSEFORGE_ALLOW_DUPLICATE" in
  1|true|TRUE|republish)
    echo "Skipping CurseForge duplicate check because CURSEFORGE_ALLOW_DUPLICATE=$CURSEFORGE_ALLOW_DUPLICATE."
    exit 0
    ;;
esac

if [ -z "$CURSEFORGE_PROJECT_ID" ]; then
  echo "CURSEFORGE_PROJECT_ID is required to check CurseForge for duplicate files." >&2
  exit 1
fi

if [ -z "$CURSEFORGE_CORE_API_TOKEN" ]; then
  echo "CURSEFORGE_CORE_API_TOKEN is required to check CurseForge for duplicate files." >&2
  echo "Set CURSEFORGE_CORE_API_TOKEN, or set CURSEFORGE_API_TOKEN if the same key works for the CurseForge Core API." >&2
  exit 1
fi

mkdir -p "$MOD_DIR/build"
response_file="$MOD_DIR/build/curseforge-files-response.json"
status_file="$MOD_DIR/build/curseforge-files-status.txt"

set +e
python3 - "$CURSEFORGE_CORE_API_ENDPOINT" "$CURSEFORGE_PROJECT_ID" "$CURSEFORGE_CORE_API_TOKEN" "$artifact_name" "$response_file" "$status_file" <<'PY'
import json
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

endpoint, project_id, token, artifact_name, response_path, status_path = sys.argv[1:]
response_file = Path(response_path)
status_file = Path(status_path)

base_url = endpoint.rstrip("/")
page_size = 50
index = 0
matched = None
latest_payload = {}

while True:
    query = urlencode({"index": index, "pageSize": page_size})
    url = f"{base_url}/v1/mods/{project_id}/files?{query}"
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "x-api-key": token,
        },
    )

    try:
        with urlopen(request, timeout=20) as response:
            body = response.read()
            status_file.write_text(str(response.status) + "\n")
    except HTTPError as exc:
        response_file.write_bytes(exc.read())
        status_file.write_text(str(exc.code) + "\n")
        print(f"CurseForge duplicate check failed with HTTP {exc.code}.", file=sys.stderr)
        sys.exit(1)
    except URLError as exc:
        status_file.write_text("url_error\n")
        print(f"CurseForge duplicate check failed: {exc.reason}", file=sys.stderr)
        sys.exit(1)

    response_file.write_bytes(body)
    payload = json.loads(body.decode("utf-8"))
    latest_payload = payload
    files = payload.get("data") or []

    for file_info in files:
        if file_info.get("fileName") == artifact_name:
            matched = file_info
            break

    if matched:
        break

    pagination = payload.get("pagination") or {}
    result_count = int(pagination.get("resultCount") or len(files))
    total_count = int(pagination.get("totalCount") or 0)
    next_index = index + result_count

    if result_count <= 0 or (total_count and next_index >= total_count) or next_index >= 10_000:
        break

    index = next_index

if matched:
    file_id = matched.get("id", "unknown")
    display_name = matched.get("displayName") or artifact_name
    print(
        f"CurseForge already has {artifact_name} "
        f"(file id {file_id}, display name {display_name}).",
        file=sys.stderr,
    )
    sys.exit(2)

checked_count = (latest_payload.get("pagination") or {}).get("totalCount")
if checked_count is None:
    checked_count = len(latest_payload.get("data") or [])
print(f"CurseForge duplicate check passed for {artifact_name}; checked {checked_count} file(s).")
PY
check_status="$?"
set -e

case "$check_status" in
  0)
    ;;
  2)
    echo "Refusing to upload duplicate CurseForge artifact: $artifact_name" >&2
    echo "Set CURSEFORGE_ALLOW_DUPLICATE=republish only when intentionally creating another file for this version." >&2
    exit 1
    ;;
  *)
    if [ "$CURSEFORGE_REQUIRE_DUPLICATE_CHECK" = "1" ]; then
      exit 1
    fi
    echo "Warning: CurseForge duplicate check could not complete; continuing because CURSEFORGE_REQUIRE_DUPLICATE_CHECK is not 1." >&2
    ;;
esac
