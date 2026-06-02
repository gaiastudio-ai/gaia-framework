# migrate-config-split fixtures — E28-S143

Fixtures for the `migrate-config-split.sh` bats suite. Each fixture represents
one input shape to the migration script (Task 6 of E28-S143):

- **mixed-global.yaml** — Fixture 1: standard `global.yaml` with both shared and
  local keys. Round-trip equivalence must hold (AC5).
- **local-only-global.yaml** — Fixture 2: `global.yaml` that contains only
  machine-local keys; the produced `config/project-config.yaml` should be
  minimal (no shared keys to emit).
- **shared-only-global.yaml** — Fixture 3: `global.yaml` containing only
  team-shared keys; the rewritten `global.yaml` should be minimal after migration.

The classification table lives in
`gaia-public/plugins/gaia/config/MIGRATION-from-global-yaml.md` and the schema in
`gaia-public/plugins/gaia/config/project-config.schema.yaml`. Fixture values are
chosen to exercise the local-overrides-shared precedence rule (ADR-044).

These fixtures are consumed by `tests/migrate-config-split.bats`.
