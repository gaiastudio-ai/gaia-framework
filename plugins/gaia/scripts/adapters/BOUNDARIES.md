# Adapter Pattern Boundaries — `plugins/gaia/scripts/adapters/`

> **Story:** E66-S2 — `tool-availability-probe.sh` three-state probe + per-adapter `contract.bats`.
> **Decisions:** ADR-077 (Three-Tier Review Pipeline), ADR-078 (Tool Adapter Framework), ADR-042 (Scripts-over-LLM).
> **Stability:** Stable contract. Every built-in and custom adapter under this tree honours the layout below.

## Purpose

This directory is the single home for tool integrations that the twelve verdict-producing review and deployment-phase skills shell out to. Keeping every tool behind one contract (a) eliminates the silent-downgrade and false-BLOCKED failure modes that ad-hoc per-skill tool wrappers produced in the V2 surface, and (b) lets `/gaia-list-tools`, `/gaia-tool-info`, and `tool-availability-probe.sh` discover, document, and gate every tool from a single place.

## File Layout (per adapter)

```
plugins/gaia/scripts/adapters/{tool}/
├── adapter.json              # Metadata — provider, category, runtime-profile, timeout, file-extensions
├── run.sh                    # Contract entry — --input/--config/--output/--runtime-profile/--timeout
└── test/
    └── contract.bats         # All-four-state parity test (NFR-RSV2-11)
```

`adapter.json` required fields:

| Field | Type | Notes |
|---|---|---|
| `provider` | string | Binary name (or container image / network endpoint id). Resolved via `command -v` for `subprocess` profile. |
| `category` | enum | `linter` \| `formatter` \| `type-checker` \| `sast` \| `secret-scan` \| `dep-audit` \| `dast` \| `e2e-runner` \| `perf-tool` \| `a11y-scanner` \| `mobile-static` \| `mobile-dynamic` \| `device-farm` |
| `runtime-profile` | enum | `subprocess` (binary on PATH) \| `container` (Docker image) \| `network` (remote SaaS endpoint) |
| `default-timeout-seconds` | integer | Default passed to `tool-availability-probe.sh --timeout` and to `run.sh --timeout`. |
| `file-extensions` | array | Extension allow-list for the not-applicable check. **Empty array = project-scope** (e.g. gitleaks, OWASP Dependency-Check) — applicable iff file-list is non-empty. |
| `version-range` | string | semver range. Informational; not enforced at probe time. |
| `description` | string | One-line human description. |

`run.sh` MUST honour the canonical contract:

```
run.sh --input <file-list> [--config <path>] [--output <path>]
       [--runtime-profile subprocess|container|network] [--timeout <seconds>]
```

Exit code semantics: `0` = ran successfully; non-zero = adapter execution failed (the probe captures stderr into `error_detail` and emits `state: ran_and_errored`).

## Three-State Availability Probe

`plugins/gaia/scripts/tool-availability-probe.sh` is the deterministic shell+jq classifier per ADR-078 / FR-RSV2-18 / NFR-RSV2-9. Every adapter invocation flows through the probe. The probe emits one of four states on stdout (single-line JSON object):

| State | Trigger | Exit Code | Verdict-resolver Mapping |
|---|---|---|---|
| `available` | tool on PATH (subprocess) or image present (container) AND file-list matches AND `run.sh` exits 0 | 0 | check.status = `passed` (no contribution) |
| `expected_and_missing` | adapter.json declares provider but `command -v <provider>` fails | 1 | check.status = `errored` -> **BLOCKED** |
| `ran_and_errored` | `run.sh` exits non-zero OR exceeds `--timeout` | 1 | check.status = `errored` -> **BLOCKED** |
| `not_applicable` | file-list has zero entries matching `file-extensions` (or empty file-list for project-scope adapters) | 0 | check.status = `skipped` — does NOT BLOCK |

Output JSON shape (validates against `plugins/gaia/schemas/probe-output.schema.json`):

```json
{"state":"<state>","skip_reason":<string|null>,"error_detail":<string|null>}
```

The probe is **deterministic** (NFR-RSV2-9) — identical inputs (same `--adapter-dir`, same `--file-list`, same env apart from PATH) produce byte-identical output every time.

## `contract.bats` Parity (NFR-RSV2-11)

Every built-in adapter MUST ship a `test/contract.bats` that exercises **all four states** against fixture inputs. The shared helper `_contract-helper.bash` provides:

- `contract_setup` / `contract_teardown` — per-test temp dir, resolves the probe path.
- `assert_files_exist` — verifies adapter.json and run.sh are present and well-formed.
- `assert_state <provider> <expected-state> <ext-or-EMPTY_FILE_LIST> <patched-rc> <patched-stderr> <patched-sleep> [extra-flags…]` — invokes the probe under controlled conditions and asserts the resulting state.
- `assert_fragment_shape` — verifies the probe stdout JSON has the canonical 3 keys.

Using the helper, a typical adapter `contract.bats` is ~50 lines and contains exactly five tests: file-layout sanity + the four states. New adapters MUST follow this pattern.

## Built-in Adapters Shipped (Phase-5 Static Set)

| Adapter | Category | File Extensions | Project-Scope | Status |
|---|---|---|---|---|
| [`semgrep`](semgrep/) | sast | `.py .js .ts .tsx .jsx .go .java .rb .php` | no | shipped (E66-S2) |
| [`gitleaks`](gitleaks/) | secret-scan | (project-scope) | yes | shipped (E66-S2) |
| [`radon`](radon/) | linter | `.py` | no | shipped (E66-S2) |
| [`gocyclo`](gocyclo/) | linter | `.go` | no | shipped (E66-S2) |
| [`eslint-plugin-sonarjs`](eslint-plugin-sonarjs/) | linter | `.ts .tsx .js .jsx` | no | shipped (E66-S2) |

Phase-8 deployment adapters and Phase-9 mobile adapters land in subsequent stories under E66 / E70.

## Custom Adapters

Custom adapters live under `custom/adapters/{tool}/` (project root) and follow the **same** layout. The probe and verdict resolver do not distinguish between built-in and custom — the contract is uniform. Custom adapters take precedence over built-in adapters of the same provider per ADR-078 tool-selection precedence (`tools.{category}.provider:` > regime > base).

## Refs

- ADR-077 §3.6 — three-tier review pipeline pulls every tool through the adapter contract.
- ADR-078 §1 — adapter pattern + three-state probe motivation.
- ADR-042 — Scripts-over-LLM. Adapters are deterministic shell, not LLM calls.
- FR-RSV2-17, FR-RSV2-18, FR-RSV2-19, FR-RSV2-20 — adapter pattern PRD requirements.
- NFR-RSV2-9 — probe correctness invariants.
- NFR-RSV2-11 — `contract.bats` per built-in adapter.
