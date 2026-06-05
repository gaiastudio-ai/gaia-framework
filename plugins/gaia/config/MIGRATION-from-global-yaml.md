# Migration — `_gaia/_config/global.yaml` → `project-config.yaml`

**Status:** Active — split in progress, legacy `global.yaml` remains in place until the cleanup pass.

This document enumerates every field currently declared in `_gaia/_config/global.yaml` and assigns each a migration disposition:

- **moved-to-project-config** — relocates to `gaia-framework/plugins/gaia/config/project-config.yaml`. Per-project, team-shared, committed to git.
- **stays-in-global** — remains in `_gaia/_config/global.yaml` as a machine-local or user-scoped setting. Gitignored under the new plugin layout.
- **deprecated** — no longer used by GAIA Native; scheduled for removal in the cleanup pass.

The legacy `_gaia/_config/global.yaml` is NOT modified or deleted by the config-split stories. Deletion is scheduled for the cleanup pass after all consumers are migrated.

## Precedence (Config Split invariant)

When the same key appears in both `global.yaml` (local) and `config/project-config.yaml` (shared), the local value wins.

This sentence appears verbatim in `project-config.schema.yaml` — identical wording across both artifacts prevents drift. The rule is enforced by `resolve-config.sh` as a generic two-file merge: the resolver reads the shared file first, then overlays the machine-local file. No schema-specific code is required in the resolver.

### Worked example — shared default with local override

A team commits `gaia-framework/plugins/gaia/config/project-config.yaml` so every developer on the project inherits the same default `project_path`:

```yaml
# gaia-framework/plugins/gaia/config/project-config.yaml (team-shared, committed)
project_path: /srv/ci/gaia-framework/gaia-framework
framework_version: 1.127.2-rc.1
date: 2026-04-17
```

An individual operator working on a fork points their local clone at a different tree by setting the same key in their machine-local file:

```yaml
# _gaia/_config/global.yaml (machine-local, gitignored)
project_path: /Users/alex/Dev/gaia-enterprise
```

`resolve-config.sh` reads both files, applies the local-overrides-shared rule, and emits:

```
project_path='/Users/alex/Dev/gaia-enterprise'
framework_version='1.127.2-rc.1'
date='2026-04-17'
```

The shared default (`framework_version`, `date`) passes through unchanged; the overridden key (`project_path`) carries the local value. Teammates who do not override keep the committed shared default.

## Field disposition table

| # | Field | Disposition | Rationale |
|---|-------|-------------|-----------|
| 1 | `framework_name` | stays-in-global | Framework identity — constant across all projects. |
| 2 | `framework_version` | moved-to-project-config | Projects pin the framework version they target. |
| 3 | `user_name` | moved-to-project-config | Team display name is shared; per-operator override stays in machine-local `global.yaml` per the precedence rule. |
| 4 | `communication_language` | moved-to-project-config | Team default is shared; per-operator override stays in machine-local `global.yaml` per the precedence rule. |
| 5 | `document_output_language` | stays-in-global | User preference — varies per operator, not a project setting. |
| 6 | `user_skill_level` | stays-in-global | User preference — varies per operator, not a project setting. |
| 7 | `project_name` | deprecated | Redundant with directory name; no consumer in GAIA Native. |
| 8 | `project_root` | moved-to-project-config | Per-project absolute path to the framework root. Machine-local override via `global.yaml` wins. |
| 9 | `project_path` | moved-to-project-config | Core per-project setting. Machine-local override via `global.yaml` wins. |
| 10 | `output_folder` | deprecated | Replaced by per-artifact paths; no GAIA Native consumer. |
| 11 | `planning_artifacts` | project-overridable | Default `.gaia/artifacts/planning-artifacts` (relative to `project_root`); projects may override. See [§ Artifact Paths (project-overridable)](#artifact-paths-project-overridable). |
| 12 | `implementation_artifacts` | project-overridable | Default `.gaia/artifacts/implementation-artifacts`; project-overridable. See [§ Artifact Paths (project-overridable)](#artifact-paths-project-overridable). |
| 13 | `test_artifacts` | project-overridable | Default `.gaia/artifacts/test-artifacts`; project-overridable. See [§ Artifact Paths (project-overridable)](#artifact-paths-project-overridable). |
| 14 | `creative_artifacts` | project-overridable | Default `.gaia/artifacts/creative-artifacts`; project-overridable. See [§ Artifact Paths (project-overridable)](#artifact-paths-project-overridable). |
| 15 | `sizing_map` | project-overridable | Story-size to points mapping. `project > global` precedence: when `project-config.yaml` defines `sizing_map:`, those values override the framework defaults (S=2, M=5, L=8, XL=13); when absent, `resolve-config.sh sizing_map` emits the framework defaults. Absence is the documented new-project behavior. |
| 16 | `problem_solving` | stays-in-global | Framework-wide knob (context budget); not per-project. |
| 17 | `installed_path` | stays-in-global | Machine-local absolute path to `_gaia/` — encodes operator filesystem and cannot be meaningfully shared. Declared in schema so CI fixtures can set it deterministically; in practice the machine-local value always wins. |
| 18 | `config_path` | deprecated | Derivable from `installed_path`; no explicit consumer. |
| 19 | `memory_path` | stays-in-global | Machine-local absolute path to `_memory/` — encodes operator filesystem. Declared in schema for fixture determinism; machine-local override wins in practice. |
| 20 | `checkpoint_path` | stays-in-global | Machine-local absolute path to checkpoint directory. Same rationale as `memory_path`. |
| 21 | `val_integration` | moved-to-project-config | Per-project Val agent knobs. |
| 22 | `ci_cd` | moved-to-project-config | Per-project CI/CD promotion chain. |
| 23 | `test_execution_bridge` | moved-to-project-config | Team-wide test bridge enablement. Same enablement across all teammates so CI and local runs behave identically. |
| 24 | `adr_registry` | stays-in-global | Pointer to the canonical ADR registry (table in `.gaia/artifacts/planning-artifacts/architecture.md`) and the standalone-memo glob. Per-project but encoded as repo-relative paths; the field exists so tooling can locate the registry without hardcoding the path. |

## Fields new to `project-config.yaml` (no predecessor in `global.yaml`)

| Field | Rationale |
|-------|-----------|
| `date` | ISO-8601 revision stamp — enforced for audit by resolve-config.sh. |
| `testing` | Testing integration config (framework, bridge, coverage) — new in GAIA Native. |
| `sprint` | Sprint configuration (active sprint, sizing overrides) — shared team config. |
| `review_gate` | Review Gate configuration — shared team config. |
| `team_conventions` | Team-wide naming / commit / code-style conventions — shared team config. |
| `agent_customizations` | Project-wide agent `.customize.yaml` overrides — shared team config. |

## Disposition summary

- **moved-to-project-config:** 16 fields
- **stays-in-global:** 8 fields
- **deprecated:** 3 fields
- **new (no predecessor):** 6 fields

> Disposition note: `sizing_map` was reclassified from `stays-in-global` to `moved-to-project-config` (a.k.a. project-overridable). The block follows the `project > global` precedence rule; absence in `project-config.yaml` falls back to the framework defaults (S=2, M=5, L=8, XL=13) emitted by `resolve-config.sh sizing_map`.

> Disposition note: `planning_artifacts`, `implementation_artifacts`, `test_artifacts`, and `creative_artifacts` were reclassified from `deprecated` to `moved-to-project-config` (project-overridable). They follow the `project > global` precedence rule; absence in `project-config.yaml` falls back to the framework defaults (`.gaia/artifacts/planning-artifacts`, `.gaia/artifacts/implementation-artifacts`, `.gaia/artifacts/test-artifacts`, `.gaia/artifacts/creative-artifacts`) composed under `project_root` by `resolve-config.sh`. See [§ Artifact Paths (project-overridable)](#artifact-paths-project-overridable) for defaults, override semantics, and a worked example.

Total legacy fields accounted for: 23 (every top-level key currently in `_gaia/_config/global.yaml`).

## Artifact Paths (project-overridable)

The four artifact-path keys — `planning_artifacts`, `implementation_artifacts`, `test_artifacts`, and `creative_artifacts` — locate the canonical `docs/*` subdirectories that GAIA writes planning, implementation, test, and creative artifacts to. Added to `project-config.yaml`, they replace the hardcoded `{project-root}/docs/<dir>` paths previously baked into skills and scripts.

### Defaults

Each key's default resolves relative to `project_root` and matches the live values in `gaia-framework/plugins/gaia/config/project-config.yaml`:

| Key                         | Default                        | Description                                                                |
|-----------------------------|--------------------------------|----------------------------------------------------------------------------|
| `planning_artifacts`        | `.gaia/artifacts/planning-artifacts`      | PRDs, architecture docs, epics-and-stories, test plans, threat models.     |
| `implementation_artifacts`  | `.gaia/artifacts/implementation-artifacts`| Story files, dev notes, retrospectives, change logs.                       |
| `test_artifacts`            | `.gaia/artifacts/test-artifacts`          | ATDD scenarios, test reports, traceability matrices, gap analyses.        |
| `creative_artifacts`        | `.gaia/artifacts/creative-artifacts`      | Brainstorms, design-thinking outputs, innovation strategies, pitch decks.  |

### Override semantics

The four keys follow the `project > global` precedence rule (Config Split — Local vs Shared). When `project-config.yaml` declares any of these keys, the project value overrides the framework default; when absent, `resolve-config.sh` composes the default under `project_root` (`{project_root}/docs/<dir>`). The same precedence governs every other shared/local pair documented above — artifact paths are not a special case.

The resolver emits the merged value verbatim. An override of `planning_artifacts: planning/` flows through unchanged — the resolver does NOT re-prefix it with `project_root`. Operators are responsible for choosing values that make sense in their project layout (relative to `project_root` is the convention; absolute paths work but discourage portability).

### Worked example — overriding `planning_artifacts`

A project that wants planning artifacts at the repo root under `planning/` instead of the default `.gaia/artifacts/planning-artifacts/` adds the override to its team-shared config:

```yaml
# gaia-framework/plugins/gaia/config/project-config.yaml (team-shared, committed)
planning_artifacts: planning/
```

The resolver's positional flat-key query returns the override verbatim:

```bash
$ resolve-config.sh planning_artifacts
planning/
```

The same override pattern applies to `implementation_artifacts`, `test_artifacts`, and `creative_artifacts` — each has its own positional-query alias and follows the identical project-over-global precedence.

## Schema enforcement

`resolve-config.sh` reads `project-config.schema.yaml` and rejects any key in `project-config.yaml` not declared in the schema with exit code 2. This is the hard guarantee that the split is clean — legacy fields cannot silently leak into the new surface.

## Reconciliation with the initial disposition map

The initial disposition map was finalized with three changes:

1. **`user_name` and `communication_language`** moved from stays-in-global to moved-to-project-config — both are shared team defaults; per-operator overrides stay in machine-local `global.yaml` under the precedence rule.
2. **`installed_path`, `memory_path`, `checkpoint_path`** re-classified as stays-in-global. The initial map marked these moved-to-project-config; in practice they encode the operator's filesystem and always win via the machine-local override. They remain declared in the schema so CI fixtures and test harnesses can set them deterministically, but the committed shared file should not hardcode operator paths.
3. **`test_execution_bridge`** newly enumerated — it was present in `global.yaml` after the initial map shipped and required a disposition row for full coverage.

The precedence rule and worked example are net-new in the finalization pass.
