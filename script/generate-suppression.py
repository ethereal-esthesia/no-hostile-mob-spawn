#!/usr/bin/env python3
import csv
import fnmatch
import json
import sys
import zipfile
from pathlib import Path, PurePosixPath


SUPPRESSION_RELATIVE_PATH = Path("Server/NPC/Spawn/Suppression/No_Hostile_Mob_Spawn.json")
HOSTILE_GROUP_NAME = "NoHostileMobSpawn_Hostiles"
HOSTILE_GROUP_RELATIVE_PATH = Path(f"Server/NPC/Groups/{HOSTILE_GROUP_NAME}.json")
MOB_DROPS_CSV_RELATIVE_PATH = Path("Reports/Mob_Drops.csv")
ALWAYS_SUPPRESS = ["Aggressive", HOSTILE_GROUP_NAME]
IGNORED_GROUPS = {
    "",
    "?",
    "Capture_Crate",
    "Critters",
    "Empty",
    "Neutral",
    "Passive",
    "Prey",
    "PreyBig",
}
IGNORED_GROUP_PATH_PARTS = {"Livestock", "Tests", "Player", "Self"}


def deep_merge(base, override):
    if isinstance(base, dict) and isinstance(override, dict):
        merged = dict(base)
        for key, value in override.items():
            merged[key] = deep_merge(merged.get(key), value)
        return merged
    return override


def load_json_assets(assets_zip):
    roles = {}
    groups = {}
    drops = {}

    with zipfile.ZipFile(assets_zip) as archive:
        for info in archive.infolist():
            if not info.filename.endswith(".json"):
                continue

            path = PurePosixPath(info.filename)
            try:
                document = json.loads(archive.read(info))
            except json.JSONDecodeError:
                continue

            if path.parts[:3] == ("Server", "NPC", "Roles"):
                roles[path.stem] = document
            elif path.parts[:3] == ("Server", "NPC", "Groups"):
                groups.setdefault(path.stem, []).append((path, document))
            elif path.parts[:2] == ("Server", "Drops"):
                drops[path] = document

    return roles, groups, drops


def collect_parameters(roles, role_name, seen=None):
    seen = seen or set()
    if role_name in seen:
        return {}

    seen.add(role_name)
    role = roles.get(role_name, {})
    params = {}
    references = role.get("Reference", [])
    if isinstance(references, str):
        references = [references]

    for reference in references:
        if isinstance(reference, str):
            params.update(collect_parameters(roles, reference, seen))

    for key, value in role.get("Parameters", {}).items():
        if isinstance(value, dict) and "Value" in value:
            params[key] = value["Value"]

    return params


def compute_values(value, params):
    if isinstance(value, dict):
        if set(value) == {"Compute"}:
            return params.get(value["Compute"], value)
        return {key: compute_values(child, params) for key, child in value.items()}
    if isinstance(value, list):
        return [compute_values(child, params) for child in value]
    return value


def resolve_role(roles, role_name, seen=None):
    seen = seen or set()
    if role_name in seen:
        return {}

    seen.add(role_name)
    role = roles.get(role_name)
    if not role:
        return {}

    resolved = {}
    references = role.get("Reference", [])
    if isinstance(references, str):
        references = [references]

    for reference in references:
        if isinstance(reference, str):
            resolved = deep_merge(resolved, resolve_role(roles, reference, seen))

    if role.get("Type") == "Variant":
        resolved = deep_merge(resolved, role.get("Modify", {}))
    else:
        own_values = {
            key: value
            for key, value in role.items()
            if key not in {"Parameters", "Reference", "Type", "Modify"}
        }
        resolved = deep_merge(resolved, own_values)

    return compute_values(resolved, collect_parameters(roles, role_name))


def group_role_patterns(groups):
    patterns = {}
    for group_name, documents in groups.items():
        patterns[group_name] = []
        for path, document in documents:
            if any(part in IGNORED_GROUP_PATH_PARTS for part in path.parts):
                continue

            include_roles = document.get("IncludeRoles", [])
            if isinstance(include_roles, str):
                include_roles = [include_roles]
            patterns[group_name].extend(
                pattern for pattern in include_roles if isinstance(pattern, str)
            )
    return patterns


def matching_groups(role_name, patterns):
    return {
        group_name
        for group_name, group_patterns in patterns.items()
        if any(fnmatch.fnmatchcase(role_name, pattern) for pattern in group_patterns)
    }


def contains_attack_instruction(value):
    if isinstance(value, dict):
        if value.get("Type") == "Attack":
            return True
        return any(contains_attack_instruction(child) for child in value.values())
    if isinstance(value, list):
        return any(contains_attack_instruction(child) for child in value)
    return False


def is_hostile_spawn_role(role_name, role, params, patterns):
    attitude_group = role.get("AttitudeGroup")
    role_groups = matching_groups(role_name, patterns)
    has_hostile_group = (
        isinstance(attitude_group, str)
        and attitude_group not in IGNORED_GROUPS
        or bool(role_groups - IGNORED_GROUPS)
    )
    has_direct_attack = bool(role.get("Attack") or params.get("Attack") or role.get("_CombatConfig"))
    has_nested_attack = contains_attack_instruction(role)
    default_hostile = role.get("DefaultPlayerAttitude") == "Hostile"

    return (
        default_hostile and (has_direct_attack or has_hostile_group)
    ) or (
        has_direct_attack and has_hostile_group
    ) or (
        has_nested_attack and bool(role_groups & {"Void"})
    )


def generated_hostile_roles(roles, groups):
    patterns = group_role_patterns(groups)
    hostile_roles = []
    for role_name in roles:
        if role_name.startswith(("Template_", "Component_", "Test_")):
            continue

        role = resolve_role(roles, role_name)
        params = collect_parameters(roles, role_name)
        if not is_hostile_spawn_role(role_name, role, params, patterns):
            continue

        hostile_roles.append(role_name)

    return sorted(hostile_roles)


def iter_drop_item_rows(drop_id, path, document):
    def visit(value, container_path, inherited_weight):
        if isinstance(value, dict):
            container_type = value.get("Type", "")
            weight = value.get("Weight", inherited_weight)
            item = value.get("Item")

            if isinstance(item, dict) and item.get("ItemId"):
                yield {
                    "drop_id": drop_id,
                    "drop_path": str(path),
                    "container_path": container_path,
                    "container_type": container_type,
                    "weight": weight if weight is not None else "",
                    "item_id": item.get("ItemId", ""),
                    "quantity_min": item.get("QuantityMin", ""),
                    "quantity_max": item.get("QuantityMax", ""),
                }

            containers = value.get("Containers", [])
            if isinstance(containers, list):
                for index, child in enumerate(containers):
                    child_path = f"{container_path}/Containers[{index}]"
                    yield from visit(child, child_path, weight)

    yield from visit(document.get("Container", document), "Container", None)


def iter_mob_drop_rows(roles, drops, hostile_roles):
    drops_by_id = {path.stem: (path, document) for path, document in drops.items()}
    hostile_role_set = set(hostile_roles)

    for role_name in sorted(roles):
        if role_name.startswith(("Template_", "Component_", "Test_")):
            continue

        role = resolve_role(roles, role_name)
        drop_list = role.get("DropList")
        if not isinstance(drop_list, str) or not drop_list:
            continue

        drop = drops_by_id.get(drop_list)
        if not drop:
            continue

        drop_path, document = drop
        status = "suppressed" if role_name in hostile_role_set else "preserved"
        for row in iter_drop_item_rows(drop_list, drop_path, document):
            row = {
                "role_name": role_name,
                "mob_status": status,
                **row,
            }
            yield row


def write_mob_drops_csv(roles, drops, hostile_roles, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "role_name",
        "mob_status",
        "drop_id",
        "drop_path",
        "container_path",
        "container_type",
        "weight",
        "item_id",
        "quantity_min",
        "quantity_max",
    ]
    rows = list(iter_mob_drop_rows(roles, drops, hostile_roles))

    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    return (
        len(rows),
        len({row["item_id"] for row in rows}),
        len({row["role_name"] for row in rows}),
    )


def main():
    if len(sys.argv) != 3:
        print("usage: generate-suppression.py ASSETS_ZIP PACKAGE_DEST", file=sys.stderr)
        return 2

    assets_zip = Path(sys.argv[1])
    package_dest = Path(sys.argv[2])
    if not assets_zip.is_file():
        print(f"Error: Assets.zip not found: {assets_zip}", file=sys.stderr)
        return 1

    roles, groups, drops = load_json_assets(assets_zip)
    hostile_roles = generated_hostile_roles(roles, groups)
    hostile_group_path = package_dest / HOSTILE_GROUP_RELATIVE_PATH
    suppression_path = package_dest / SUPPRESSION_RELATIVE_PATH
    mob_drops_csv_path = package_dest / MOB_DROPS_CSV_RELATIVE_PATH
    hostile_group_path.parent.mkdir(parents=True, exist_ok=True)
    suppression_path.parent.mkdir(parents=True, exist_ok=True)

    with hostile_group_path.open("w") as f:
        json.dump({"IncludeRoles": hostile_roles}, f, indent=2)
        f.write("\n")

    with suppression_path.open("w") as f:
        json.dump(
            {
                "SuppressionRadius": 2000,
                "SuppressedGroups": ALWAYS_SUPPRESS,
                "SuppressSpawnMarkers": True,
            },
            f,
            indent=2,
        )
        f.write("\n")

    print(
        f"Generated NoHostileMobSpawn hostile role group: "
        f"{HOSTILE_GROUP_NAME} ({len(hostile_roles)} roles)"
    )
    drop_row_count, unique_drop_item_count, mob_count = write_mob_drops_csv(
        roles,
        drops,
        hostile_roles,
        mob_drops_csv_path,
    )
    print(
        f"Generated Hytale mob drop CSV: {MOB_DROPS_CSV_RELATIVE_PATH} "
        f"({drop_row_count} rows, {unique_drop_item_count} unique items, "
        f"{mob_count} mobs)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
