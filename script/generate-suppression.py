#!/usr/bin/env python3
import csv
import copy
import fnmatch
import hashlib
import json
import sys
import zipfile
from pathlib import Path, PurePosixPath


SUPPRESSION_RELATIVE_PATHS = [
    Path("Server/NPC/Spawn/Suppression/No_Hostile_Mob_Spawn.json"),
    Path("Server/NPC/Spawn/Suppression/Peaceful_No_Hostiles.json"),
]
WORLD_SUPPRESSOR_RELATIVE_PATHS = [
    Path("Server/Instances/Defaults/Default/resources/SpawnSuppressionController.json"),
    Path("Server/Instances/Defaults/Default_Flat/resources/SpawnSuppressionController.json"),
    Path("Server/Instances/Defaults/Default_Old/resources/SpawnSuppressionController.json"),
    Path("Server/Instances/Defaults/Default_Void/resources/SpawnSuppressionController.json"),
]
WORLD_SUPPRESSOR_ID = "f2187cb4-10df-365e-822a-f509f71cb500"
SUPPRESSION_RADIUS = 2000
HOSTILE_GROUP_NAME = "NoHostileMobSpawn_Hostiles"
HOSTILE_GROUP_RELATIVE_PATH = Path(f"Server/NPC/Groups/{HOSTILE_GROUP_NAME}.json")
SPAWN_PLACEHOLDER_ROLE = "Bat"
SPAWN_PLACEHOLDER_WEIGHT = 1
MOB_DROPS_CSV_RELATIVE_PATH = Path("Reports/Mob_Drops.csv")
MOB_ONLY_RECIPE_ITEMS_CSV_RELATIVE_PATH = Path("Reports/Mob_Only_Recipe_Items.csv")
LEATHER_RECIPE_OVERRIDES_CSV_RELATIVE_PATH = Path("Reports/Leather_Recipe_Overrides.csv")
ALWAYS_SUPPRESS = ["Aggressive", HOSTILE_GROUP_NAME]
CRAFTING_RECIPE_TYPES = {"Crafting", "DiagramCrafting", "StructuralCrafting"}
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
    items = {}
    recipes = {}
    spawns = {}

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
            elif path.parts[:3] == ("Server", "Item", "Items"):
                items[path] = document
            elif path.parts[:3] == ("Server", "Item", "Recipes"):
                recipes[path] = document
            elif path.parts[:3] == ("Server", "NPC", "Spawn"):
                spawns[path] = document

    return roles, groups, drops, items, recipes, spawns


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


def recipe_input_items(recipes):
    item_recipes = {}
    for path, recipe in recipes.items():
        for item in recipe.get("Input", []):
            if not isinstance(item, dict):
                continue

            item_id = item.get("ItemId")
            if not item_id:
                continue

            item_recipes.setdefault(item_id, set()).add(path.stem)

    return item_recipes


def as_list(value):
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        return [value]
    return []


def leather_recipe_item_ids(items):
    leather_item_ids = set()
    for path, item in items.items():
        item_id = path.stem
        tags = item.get("Tags", {})
        tag_type = as_list(tags.get("Type")) if isinstance(tags, dict) else []
        tag_family = as_list(tags.get("Family")) if isinstance(tags, dict) else []

        if item_id.startswith("Ingredient_Leather_") or (
            "Ingredient" in tag_type and "Leather" in tag_family
        ):
            leather_item_ids.add(item_id)

    return leather_item_ids


def is_crafting_recipe(recipe):
    requirements = recipe.get("BenchRequirement", [])
    if not isinstance(requirements, list) or not requirements:
        return True

    requirement_types = {
        requirement.get("Type", "")
        for requirement in requirements
        if isinstance(requirement, dict)
    }
    if requirement_types & CRAFTING_RECIPE_TYPES:
        return True

    return "Processing" not in requirement_types


def recipe_input_item_id(input_item):
    if isinstance(input_item, dict) and isinstance(input_item.get("ItemId"), str):
        return input_item["ItemId"]

    return ""


def remove_leather_recipe_inputs(recipe, leather_item_ids):
    inputs = recipe.get("Input", [])
    if not isinstance(inputs, list) or not is_crafting_recipe(recipe):
        return None

    leather_inputs = [
        input_item
        for input_item in inputs
        if recipe_input_item_id(input_item) in leather_item_ids
    ]
    if not leather_inputs:
        return None

    kept_inputs = [
        input_item
        for input_item in inputs
        if recipe_input_item_id(input_item) not in leather_item_ids
    ]
    status = "modified" if kept_inputs else "all_leather_preserved"
    if status != "modified":
        return {
            "recipe": recipe,
            "status": status,
            "removed_input_count": 0,
            "leather_item_ids": sorted(
                {recipe_input_item_id(input_item) for input_item in leather_inputs}
            ),
            "remaining_item_ids": [],
        }

    modified_recipe = copy.deepcopy(recipe)
    modified_recipe["Input"] = kept_inputs
    return {
        "recipe": modified_recipe,
        "status": status,
        "removed_input_count": len(inputs) - len(kept_inputs),
        "leather_item_ids": sorted(
            {recipe_input_item_id(input_item) for input_item in leather_inputs}
        ),
        "remaining_item_ids": sorted(
            {
                recipe_input_item_id(input_item)
                for input_item in kept_inputs
                if recipe_input_item_id(input_item)
            }
        ),
    }


def leather_recipe_scan_rows(items, recipes, leather_item_ids):
    for path, recipe in recipes.items():
        result = remove_leather_recipe_inputs(recipe, leather_item_ids)
        if not result:
            continue

        yield {
            "path": path,
            "document": result["recipe"],
            "source_type": "standalone_recipe",
            **result,
        }

    for path, item in items.items():
        recipe = item.get("Recipe")
        if not isinstance(recipe, dict):
            continue

        result = remove_leather_recipe_inputs(recipe, leather_item_ids)
        if not result:
            continue

        document = item
        if result["status"] == "modified":
            document = copy.deepcopy(item)
            document["Recipe"] = result["recipe"]

        yield {
            "path": path,
            "document": document,
            "source_type": "embedded_item_recipe",
            **result,
        }


def write_leather_recipe_overrides_csv(rows, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "source_type",
        "status",
        "path",
        "removed_input_count",
        "leather_item_ids",
        "remaining_item_ids",
    ]

    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "source_type": row["source_type"],
                    "status": row["status"],
                    "path": str(row["path"]),
                    "removed_input_count": row["removed_input_count"],
                    "leather_item_ids": ";".join(row["leather_item_ids"]),
                    "remaining_item_ids": ";".join(row["remaining_item_ids"]),
                }
            )


def dropped_items_by_source(drops):
    non_mob_items = set()

    for path, document in drops.items():
        if path.parts[:3] == ("Server", "Drops", "NPCs"):
            continue

        for row in iter_drop_item_rows(path.stem, path, document):
            non_mob_items.add(row["item_id"])

    return non_mob_items


def write_mob_only_recipe_items_csv(roles, drops, hostile_roles, recipes, path):
    path.parent.mkdir(parents=True, exist_ok=True)

    item_recipes = recipe_input_items(recipes)
    mob_drop_rows = list(iter_mob_drop_rows(roles, drops, hostile_roles))
    role_sources_by_item = {}
    status_by_item = {}
    for row in mob_drop_rows:
        item_id = row["item_id"]
        role_sources_by_item.setdefault(item_id, set()).add(row["role_name"])
        status_by_item.setdefault(item_id, set()).add(row["mob_status"])

    role_linked_mob_items = set(role_sources_by_item)
    non_mob_items = dropped_items_by_source(drops)
    blocked_item_ids = sorted(
        item_id
        for item_id in item_recipes
        if item_id in role_linked_mob_items and item_id not in non_mob_items
    )

    fieldnames = [
        "item_id",
        "mob_status",
        "suppressed_mob_count",
        "preserved_mob_count",
        "recipe_count",
        "recipes",
        "suppressed_mobs",
        "preserved_mobs",
    ]

    rows = []
    hostile_role_set = set(hostile_roles)
    for item_id in blocked_item_ids:
        roles_for_item = sorted(role_sources_by_item.get(item_id, set()))
        suppressed_mobs = [role for role in roles_for_item if role in hostile_role_set]
        preserved_mobs = [role for role in roles_for_item if role not in hostile_role_set]
        statuses = status_by_item.get(item_id, set())
        if statuses == {"suppressed"}:
            status = "missing"
        elif "preserved" in statuses:
            status = "preserved"
        else:
            status = "unknown"

        rows.append(
            {
                "item_id": item_id,
                "mob_status": status,
                "suppressed_mob_count": len(suppressed_mobs),
                "preserved_mob_count": len(preserved_mobs),
                "recipe_count": len(item_recipes[item_id]),
                "recipes": ";".join(sorted(item_recipes[item_id])),
                "suppressed_mobs": ";".join(suppressed_mobs),
                "preserved_mobs": ";".join(preserved_mobs),
            }
        )

    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    missing_count = sum(1 for row in rows if row["mob_status"] == "missing")
    preserved_count = sum(1 for row in rows if row["mob_status"] == "preserved")
    return len(rows), missing_count, preserved_count


def spawn_entry_role(entry):
    if not isinstance(entry, dict):
        return ""

    for key in ("Id", "Name"):
        value = entry.get(key)
        if isinstance(value, str):
            return value

    return ""


def spawn_entry_role_key(entry):
    if isinstance(entry, dict) and isinstance(entry.get("Name"), str):
        return "Name"

    return "Id"


def disabled_spawn_role_name(path):
    digest = hashlib.sha1(str(path).encode("utf-8")).hexdigest()[:12]
    return f"NoHostileMobSpawn_Disabled_{digest}"


def disabled_spawn_entry(source_entry, role_key, disabled_role_name):
    entry = {
        "Weight": SPAWN_PLACEHOLDER_WEIGHT,
        role_key: disabled_role_name,
    }

    if isinstance(source_entry, dict):
        for key in (
            "SpawnAfterGameTime",
            "SpawnBeforeGameTime",
            "RealtimeRespawnTime",
        ):
            if key in source_entry:
                entry[key] = source_entry[key]

    return entry


def filtered_spawn_documents(spawns, hostile_roles):
    hostile_role_set = set(hostile_roles)
    for path, document in spawns.items():
        npcs = document.get("NPCs")
        if not isinstance(npcs, list):
            continue

        kept = [
            entry
            for entry in npcs
            if spawn_entry_role(entry) not in hostile_role_set
        ]
        removed_count = len(npcs) - len(kept)
        if removed_count == 0:
            continue

        filtered_document = dict(document)
        disabled_role_name = ""
        if not kept:
            role_key = "Id"
            source_entry = {}
            for entry in npcs:
                if isinstance(entry, dict):
                    role_key = spawn_entry_role_key(entry)
                    source_entry = entry
                    break

            disabled_role_name = disabled_spawn_role_name(path)
            kept = [disabled_spawn_entry(source_entry, role_key, disabled_role_name)]

        filtered_document["NPCs"] = kept

        yield path, filtered_document, removed_count, len(npcs), disabled_role_name


def main():
    if len(sys.argv) != 3:
        print("usage: generate-suppression.py ASSETS_ZIP PACKAGE_DEST", file=sys.stderr)
        return 2

    assets_zip = Path(sys.argv[1])
    package_dest = Path(sys.argv[2])
    if not assets_zip.is_file():
        print(f"Error: Assets.zip not found: {assets_zip}", file=sys.stderr)
        return 1

    roles, groups, drops, items, recipes, spawns = load_json_assets(assets_zip)
    hostile_roles = generated_hostile_roles(roles, groups)
    spawn_documents = list(filtered_spawn_documents(spawns, hostile_roles))
    leather_item_ids = leather_recipe_item_ids(items)
    leather_recipe_rows = list(leather_recipe_scan_rows(items, recipes, leather_item_ids))
    leather_recipe_documents = [
        row for row in leather_recipe_rows if row["status"] == "modified"
    ]
    hostile_group_path = package_dest / HOSTILE_GROUP_RELATIVE_PATH
    suppression_paths = [package_dest / path for path in SUPPRESSION_RELATIVE_PATHS]
    world_suppressor_paths = [
        package_dest / path for path in WORLD_SUPPRESSOR_RELATIVE_PATHS
    ]
    mob_drops_csv_path = package_dest / MOB_DROPS_CSV_RELATIVE_PATH
    mob_only_recipe_items_csv_path = package_dest / MOB_ONLY_RECIPE_ITEMS_CSV_RELATIVE_PATH
    leather_recipe_overrides_csv_path = (
        package_dest / LEATHER_RECIPE_OVERRIDES_CSV_RELATIVE_PATH
    )
    hostile_group_path.parent.mkdir(parents=True, exist_ok=True)
    for generated_path in suppression_paths + world_suppressor_paths:
        generated_path.parent.mkdir(parents=True, exist_ok=True)

    with hostile_group_path.open("w") as f:
        json.dump({"IncludeRoles": hostile_roles}, f, indent=2)
        f.write("\n")

    suppression_document = {
        "SuppressionRadius": SUPPRESSION_RADIUS,
        "SuppressedGroups": ALWAYS_SUPPRESS,
        "SuppressSpawnMarkers": True,
    }
    for suppression_path in suppression_paths:
        with suppression_path.open("w") as f:
            json.dump(suppression_document, f, indent=2)
            f.write("\n")

    world_suppressor_document = {
        "SpawnSuppressorMap": {
            WORLD_SUPPRESSOR_ID: {
                "Position": {
                    "X": 0.0,
                    "Y": 128.0,
                    "Z": 0.0,
                },
                "Suppression": "No_Hostile_Mob_Spawn",
            }
        }
    }
    for world_suppressor_path in world_suppressor_paths:
        with world_suppressor_path.open("w") as f:
            json.dump(world_suppressor_document, f, indent=2)
            f.write("\n")

    disabled_role_names = sorted(
        {
            disabled_role_name
            for _, _, _, _, disabled_role_name in spawn_documents
            if disabled_role_name
        }
    )
    for disabled_role_name in disabled_role_names:
        output_path = (
            package_dest
            / "Server"
            / "NPC"
            / "Roles"
            / "NoHostileMobSpawn"
            / f"{disabled_role_name}.json"
        )
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with output_path.open("w") as f:
            json.dump(
                {
                    "Type": "Variant",
                    "Reference": SPAWN_PLACEHOLDER_ROLE,
                    "Modify": {},
                },
                f,
                indent=2,
            )
            f.write("\n")

    for spawn_path, spawn_document, _, _, _ in spawn_documents:
        output_path = package_dest / spawn_path
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with output_path.open("w") as f:
            json.dump(spawn_document, f, indent=2)
            f.write("\n")

    for row in leather_recipe_documents:
        output_path = package_dest / row["path"]
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with output_path.open("w") as f:
            json.dump(row["document"], f, indent=2)
            f.write("\n")

    print(
        f"Generated NoHostileMobSpawn hostile role group: "
        f"{HOSTILE_GROUP_NAME} ({len(hostile_roles)} roles)"
    )
    disabled_spawn_count = sum(
        1
        for _, _, removed_count, original_count, _ in spawn_documents
        if removed_count == original_count
    )
    removed_spawn_entry_count = sum(
        removed_count for _, _, removed_count, _, _ in spawn_documents
    )
    print(
        "Generated hostile spawn overrides: "
        f"{len(spawn_documents)} assets, {removed_spawn_entry_count} entries removed, "
        f"{disabled_spawn_count} assets disabled"
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
    item_count, missing_item_count, preserved_item_count = write_mob_only_recipe_items_csv(
        roles,
        drops,
        hostile_roles,
        recipes,
        mob_only_recipe_items_csv_path,
    )
    print(
        f"Generated mob-only recipe item CSV: {MOB_ONLY_RECIPE_ITEMS_CSV_RELATIVE_PATH} "
        f"({item_count} items, {missing_item_count} missing, "
        f"{preserved_item_count} preserved)"
    )
    write_leather_recipe_overrides_csv(
        leather_recipe_rows,
        leather_recipe_overrides_csv_path,
    )
    removed_leather_input_count = sum(
        row["removed_input_count"] for row in leather_recipe_documents
    )
    preserved_all_leather_count = sum(
        1 for row in leather_recipe_rows if row["status"] == "all_leather_preserved"
    )
    print(
        f"Generated leather-free recipe overrides: "
        f"{len(leather_recipe_documents)} assets, "
        f"{removed_leather_input_count} leather inputs removed, "
        f"{preserved_all_leather_count} all-leather recipes preserved, "
        f"{len(leather_item_ids)} leather item types detected"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
