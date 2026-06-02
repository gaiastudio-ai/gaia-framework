# Round-trip fixtures — E28-S141

Fixtures that exercise the ADR-044 config-split contract end to end.

## Files

| File | Role |
|------|------|
| `shared-project-config.yaml` | Team-shared side — represents `gaia-public/plugins/gaia/config/project-config.yaml` that every teammate inherits. |
| `local-global.yaml` | Machine-local side — represents `_gaia/_config/global.yaml` with a per-operator override. |
| `expected-resolved.yaml` | Expected merged output — what `resolve-config.sh` should emit when given the pair, with the local value winning on `project_path`. |

## Precedence rule

When the same key appears in both `global.yaml` (local) and `config/project-config.yaml` (shared), the local value wins.

In this fixture, `project_path` is declared in both files. The shared file uses the team default (`/srv/ci/gaia-public/gaia-public`); the local file overrides to an individual operator's clone (`/Users/alex/Dev/gaia-enterprise`). The expected-resolved output carries the local value — shared defaults pass through for every other key because the local file did not override them.

## How tests consume these fixtures

- **AC5 scenario 5 (round-trip merge — local overrides shared):** Compare the `project_path` row in `expected-resolved.yaml` against `local-global.yaml` — they must match, and both must differ from the shared file. This is enforced by `tests/e28-s141-schema-coverage.bats:AC5 expected-resolved fixture shows project_path as local value`.
- **AC5 scenario 6 (shared-only field passes through):** `framework_version`, `date`, and the path fields not overridden by local pass through from the shared file into the expected-resolved output.
- **AC5 scenario 7 (no resolver code changes required):** `resolve-config.sh` is run against `expected-resolved.yaml` staged as a skill-dir `project-config.yaml`. The resolver must exit 0 without any E28-S9 source modifications, proving the split is generic — the resolver does not encode field-specific logic. This is enforced by `tests/e28-s141-schema-coverage.bats:AC5 expected-resolved fixture passes resolve-config.sh without errors`.

## Status of two-file merge in `resolve-config.sh`

At the time E28-S141 merges, `resolve-config.sh` (E28-S9) reads a single config file and applies `GAIA_*` environment overrides. The full two-file merge (shared + local) is implemented by **E28-S142**. E28-S141 ships these fixtures as the authoritative specification for that merge; the round-trip test verifies the resolver accepts the post-merge shape generically today, so when E28-S142 lands it wires up the merge with no schema changes.

See the Findings section of `docs/implementation-artifacts/E28-S141-define-config-project-config-yaml-schema.md` for the handoff note.
