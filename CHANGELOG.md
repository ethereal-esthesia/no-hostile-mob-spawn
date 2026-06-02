# Changelog

## 1.0.6 - 2026-06-02

- Globally disables hostile NPC spawn table entries instead of relying only on a large spawn suppression radius.
- Preserves passive/non-hostile entries in mixed spawn tables.
- Replaces hostile-only spawn tables with unique passive placeholder variants so Hytale's spawning system accepts the override data.
- Adds default-world spawn suppression controller data for generated worlds.
- Expands smoke coverage to verify generated spawn overrides do not reference hostile roles.
