# Adapter Pattern Boundaries — `plugins/gaia/scripts/adapters/`

> **Stability:** Stable contract. Every built-in and custom adapter under this tree honours the layout below.

## Purpose

This directory is the single home for tool integrations that the twelve verdict-producing review and deployment-phase skills shell out to. Keeping every tool behind one contract (a) eliminates the silent-downgrade and false-BLOCKED failure modes that ad-hoc per-skill tool wrappers produced in the V2 surface, and (b) lets `/gaia-list-tools`, `/gaia-tool-info`, and `tool-availability-probe.sh` discover, document, and gate every tool from a single place.

## File Layout (per adapter)

```
plugins/gaia/scripts/adapters/{tool}/
├── adapter.json              # Metadata — provider, category, runtime-profile, timeout, file-extensions
├── run.sh                    # Contract entry — --input/--config/--output/--runtime-profile/--timeout
└── test/
    └── contract.bats         # All-four-state parity test
```

The shared schema, prose contract, and parity-test template live under the meta-directory `_schema/`:

```
plugins/gaia/scripts/adapters/_schema/
├── adapter.schema.json       # Machine-verifiable counterpart of the prose adapter.json table below
├── run-contract.md           # Prose run.sh contract (flag form, exit codes, timeout, probe states)
└── test/
    └── contract.bats         # Reusable four-state parity-test template for new adapters
```

New adapters validate their `adapter.json` against `_schema/adapter.schema.json` and copy `_schema/test/contract.bats` into `{tool}/test/contract.bats` — no per-adapter substitution required (the template reads `provider` and the first file-extension from `adapter.json` at runtime).

`adapter.json` required fields (formalized in [`_schema/adapter.schema.json`](_schema/adapter.schema.json)):

| Field | Type | Notes |
|---|---|---|
| `provider` | string | Binary name (or container image / network endpoint id). Resolved via `command -v` for `subprocess` profile. |
| `category` | enum | `linter` \| `formatter` \| `type-checker` \| `sast` \| `secret-scan` \| `dep-audit` \| `dast` \| `e2e-runner` \| `perf-tool` \| `a11y-scanner` \| `mobile-static` \| `mobile-dynamic` \| `device-farm` |
| `runtime-profile` | enum | `subprocess` (binary on PATH) \| `container` (Docker image) \| `network` (remote SaaS endpoint) |
| `default-timeout-seconds` | integer | Default passed to `tool-availability-probe.sh --timeout` and to `run.sh --timeout`. |
| `file-extensions` | array | Extension allow-list for the not-applicable check. **Empty array = project-scope** (e.g. gitleaks, OWASP Dependency-Check) — applicable iff file-list is non-empty. |
| `version-range` | string | semver range. Informational; not enforced at probe time. |
| `description` | string | One-line human description. |

`run.sh` MUST honour the canonical contract (formalized in [`_schema/run-contract.md`](_schema/run-contract.md)):

```
run.sh --input <file-list> [--config <path>] [--output <path>]
       [--runtime-profile subprocess|container|network] [--timeout <seconds>]
```

`run.sh` flag reference:

| Flag | Required | Description |
|---|---|---|
| `--input <file-list>` | yes | Newline-delimited file list. Empty file ⇒ no applicable inputs (drives `not_applicable`). |
| `--config <path>` | no | Tool-specific config (e.g. `.eslintrc`, `semgrep.yml`). Defaults to project / built-in config. |
| `--output <path>` | no | Where to write the analysis-results fragment. Defaults to stdout. |
| `--runtime-profile subprocess\|container\|network` | no | Overrides `adapter.json :: runtime-profile`. Used by container/network probes. |
| `--timeout <seconds>` | no | Wall-clock budget. Defaults to `adapter.json :: default-timeout-seconds`. SIGTERM then SIGKILL on overrun. |

Exit code semantics: `0` = ran successfully; non-zero = adapter execution failed (the probe captures stderr into `error_detail` and emits `state: ran_and_errored`). Output cross-reference: stdout emits a fragment validating against [`analysis-results.schema.json`](../../schemas/analysis-results.schema.json) under `checks[].findings[]` — adapter authors do NOT redefine finding fields.

## Three-State Availability Probe

`plugins/gaia/scripts/tool-availability-probe.sh` is the deterministic shell+jq classifier. Every adapter invocation flows through the probe. The probe emits one of four states on stdout (single-line JSON object):

| State | Trigger | Exit Code | Verdict-resolver Mapping |
|---|---|---|---|
| `available` | tool on PATH (subprocess) or image present (container) AND file-list matches AND `run.sh` exits 0 | 0 | check.status = `passed` (no contribution) |
| `expected_and_missing` | adapter.json declares provider but `command -v <provider>` fails | 1 | check.status = `errored` -> **BLOCKED** |
| `ran_and_errored` | `run.sh` exits non-zero OR exceeds `--timeout` | 1 | check.status = `errored` -> **BLOCKED** |
| `not_applicable` | file-list has zero entries matching `file-extensions` (or empty file-list for project-scope adapters) | 0 | check.status = `skipped` — does NOT BLOCK |

Output JSON shape (validates against `plugins/gaia/schemas/probe-output.schema.json`):

```json
{"state":"<state>","skip_reason":<string|null>,"error_detail":<string|null>,"failure_kind":<enum|null>}
```

The `failure_kind` enum field was added later. Domain: `tool_missing`, `version_mismatch`, `runtime_crash`, `timeout`, or `null`. See `_schema/run-contract.md` §5.1 for the state-to-failure_kind mapping. The field is additive — callers reading `state`/`skip_reason`/`error_detail` keep working unchanged.

The probe is **deterministic** — identical inputs (same `--adapter-dir`, same `--file-list`, same env apart from PATH) produce byte-identical output every time.

## `contract.bats` Parity

Every built-in adapter MUST ship a `test/contract.bats` that exercises **all four states** against fixture inputs. The shared helper `_contract-helper.bash` provides:

- `contract_setup` / `contract_teardown` — per-test temp dir, resolves the probe path.
- `assert_files_exist` — verifies adapter.json and run.sh are present and well-formed.
- `assert_state <provider> <expected-state> <ext-or-EMPTY_FILE_LIST> <patched-rc> <patched-stderr> <patched-sleep> [extra-flags…]` — invokes the probe under controlled conditions and asserts the resulting state.
- `assert_fragment_shape` — verifies the probe stdout JSON has the canonical 3 keys.

Using the helper, a typical adapter `contract.bats` is ~50 lines and contains exactly five tests: file-layout sanity + the four states. New adapters MUST follow this pattern. The canonical reference implementation lives at [`_schema/test/contract.bats`](_schema/test/contract.bats) — copy it into `{tool}/test/contract.bats` and rename the descriptors from `adapter contract:` to `{tool} contract:`. No other edits are required.

## Built-in Adapters Shipped (Phase-5 Static Set)

| Adapter | Category | File Extensions | Project-Scope | Status |
|---|---|---|---|---|
| [`semgrep`](semgrep/) | sast | `.py .js .ts .tsx .jsx .go .java .rb .php` | no | shipped |
| [`gitleaks`](gitleaks/) | secret-scan | (project-scope) | yes | shipped |
| [`radon`](radon/) | linter | `.py` | no | shipped |
| [`gocyclo`](gocyclo/) | linter | `.go` | no | shipped |
| [`eslint-plugin-sonarjs`](eslint-plugin-sonarjs/) | linter | `.ts .tsx .js .jsx` | no | shipped |

Phase-8 deployment adapters and Phase-9 mobile adapters land in subsequent stories.

## Custom Adapters

Custom adapters live under `custom/adapters/{tool}/` (project root) and follow the **same** layout. The probe and verdict resolver do not distinguish between built-in and custom — the contract is uniform. Custom adapters take precedence over built-in adapters of the same provider (`tools.{category}.provider:` > regime > base).

## Cascade-skill to Re-shard Contract

> This contract is unrelated to the adapter pattern above. It is documented
> here because BOUNDARIES.md is the agreed home for cross-skill stability
> contracts pending a future BOUNDARIES home reorganization.

Editing a monolith document (`.gaia/artifacts/planning-artifacts/prd.md`,
`.gaia/artifacts/planning-artifacts/architecture.md`,
`.gaia/artifacts/planning-artifacts/epics-and-stories.md`) MUST be followed by a
re-shard so the per-section shards under the matching shard directory
(`prd/`, `architecture/`, `epics/`) stay aligned with the monolith. The
contract is enforced as a documented post-step in five cascade skills:

| Cascade skill | Re-shard step | Monolith touched | Shard directory |
|---|---|---|---|
| `/gaia-add-feature` | Step 8c | classification-dependent (PRD, architecture, epics-and-stories) | matching shard dirs |
| `/gaia-edit-prd` | Step 8 | `prd.md` | `.gaia/artifacts/planning-artifacts/prd/` |
| `/gaia-edit-arch` | Step 9 | `architecture.md` | `.gaia/artifacts/planning-artifacts/architecture/` |
| `/gaia-add-stories` | Step 10 | `epics-and-stories.md` | `.gaia/artifacts/planning-artifacts/epics/` |
| `/gaia-create-story` | Step 6b | `epics-and-stories.md` (via `transition-story-status.sh`) | `.gaia/artifacts/planning-artifacts/epics/` |

Each cascade skill invokes `/gaia-shard-doc <monolith>` after the monolith
write completes, then runs `check-monolith-shard-sync.sh` to surface any
residual drift. The check is advisory (always exits 0); WARNING lines
are surfaced to the user but do not halt the skill.

The `--monolith-only` flag on each cascade skill is the documented
opt-out: the user takes responsibility for re-running `/gaia-shard-doc`
(or merging shards back to the monolith) before commit. Use this flag
only for atomic same-PR edits where the re-shard will land in the same
commit.

`/gaia-shard-doc` itself is unchanged by this contract — it is the
deterministic re-shard implementation cascade skills invoke. Skills
that did not previously declare the post-step continue to function for
backwards compatibility (additive change).

Refs:

- `plugins/gaia/scripts/check-monolith-shard-sync.sh` — advisory drift detector.
