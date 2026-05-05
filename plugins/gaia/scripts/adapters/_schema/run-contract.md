# `run.sh` Execution Contract — Tool Adapter Framework

> **Story:** E70-S1 — Adapter pattern formalization.
> **Decisions:** ADR-077 (Three-Tier Review Pipeline), ADR-078 (Tool Adapter Framework), ADR-042 (Scripts-over-LLM).
> **Companions:** [`adapter.schema.json`](./adapter.schema.json) (machine-verifiable metadata schema), [`test/contract.bats`](./test/contract.bats) (parity test template).
> **Stability:** Stable. Every built-in and custom adapter under `plugins/gaia/scripts/adapters/{tool}/run.sh` honours this contract.

This document is the prose counterpart to the machine-verifiable `adapter.schema.json`. It specifies the canonical `run.sh` flag-form interface, stdout/stderr split, exit-code semantics, and timeout enforcement that every adapter implements. Together, the schema and this contract form the Tool Adapter Framework's stable integration surface.

## 1. Canonical Flag-Form Interface

```
run.sh --input <file-list>
       [--config <path>]
       [--output <path>]
       [--runtime-profile subprocess|container|network]
       [--timeout <seconds>]
```

| Flag | Required | Meaning |
|---|---|---|
| `--input <file-list>` | yes | Path to a newline-delimited file list. The adapter scans only paths listed here. Empty file means "no applicable inputs" (drives `not_applicable`). |
| `--config <path>` | no | Tool-specific config file (e.g. `.eslintrc`, `semgrep.yml`). When omitted, the adapter falls back to the project's repo-root config or the tool's built-in defaults. |
| `--output <path>` | no | Where to write the stdout JSON fragment. When omitted, the fragment goes to stdout. |
| `--runtime-profile subprocess\|container\|network` | no | Overrides `adapter.json :: runtime-profile`. Used by the probe to satisfy availability tests in container/network profiles. |
| `--timeout <seconds>` | no | Wall-clock budget enforced by the adapter (and the probe). Defaults to `adapter.json :: default-timeout-seconds`. See §4. |

All flags use long-form only (no short aliases). Flag order is not significant.

## 2. stdout / stderr Contract

| Stream | Use |
|---|---|
| **stdout** | A single analysis-results fragment — JSON validating against [`analysis-results.schema.json`](../../schemas/analysis-results.schema.json) at the level of one element of the top-level `checks[]` array. Specifically: a `{ "name", "status", "findings": [...] }` object whose `findings[]` items conform to `checks[].findings[]` in that schema. **No log lines, no progress chatter, no human prose on stdout.** |
| **stderr** | Diagnostic and progress messages only — tool stderr, command lines, retry notices. The probe captures stderr into `error_detail` when `run.sh` exits non-zero. |

### 2.1 Finding Object Cross-Reference

Adapters MUST NOT redefine the finding object. The canonical fields are defined once, in [`analysis-results.schema.json`](../../schemas/analysis-results.schema.json) under `checks[].findings[]`:

| Field | Type | Required | Notes |
|---|---|---|---|
| `file` | string | yes (when applicable) | Path relative to project root. |
| `line` | integer ≥ 0 | yes (when applicable) | 1-based; 0 allowed for project-scope findings without a line. |
| `severity` | string | yes | Adapter-defined severity vocabulary (e.g. `error`, `warning`, `info`). |
| `rule` | string | yes | Adapter-defined rule id (e.g. `S100`, `python.lang.security.audit.dangerous-system-call`). |
| `message` | string | yes | Human-readable finding description. |
| `blocking` | boolean | yes | Whether this finding contributes to a `failed` check status. |
| `column`, `end_line`, `snippet`, `cwe`, `fix_suggestion` | various | no | Optional finding-detail fields per the canonical schema. |

The `adapter.schema.json` does NOT redefine these fields. New adapters reuse the canonical shape verbatim.

## 3. Exit-Code Semantics

| Exit code | Meaning | Probe state | check.status |
|---|---|---|---|
| `0` | Adapter ran successfully (regardless of whether findings were emitted). | `available` | `passed` (no findings) or `failed` (blocking findings present) |
| non-zero | Adapter execution failed — tool crashed, config invalid, timeout exceeded, etc. The probe captures stderr into `error_detail` and emits state `ran_and_errored`. | `ran_and_errored` | `errored` → BLOCKED |

`0` does NOT mean "no findings". An adapter with blocking findings still exits `0`; the verdict resolver derives `failed` from `findings[].blocking`. Non-zero exit always means the adapter itself failed to complete.

## 4. Timeout Enforcement

When `--timeout <seconds>` is supplied (or sourced from `adapter.json :: default-timeout-seconds`), `run.sh` enforces it via the standard `timeout(1)` two-phase signal mechanism:

1. After `<seconds>` of wall-clock, send `SIGTERM` to the underlying tool process group. Allow a short grace period (default 5s) for graceful shutdown.
2. If the process is still alive after the grace period, send `SIGKILL`.

A timeout MUST surface to the probe as a non-zero exit, which the probe maps to state `ran_and_errored` with `error_detail` describing the timeout. Adapters MUST NOT swallow timeout signals or return `0` after a timeout.

## 5. Four-State Availability Probe

Every adapter is invoked through `tool-availability-probe.sh` (E66-S2). The probe emits one of four states on stdout (single-line JSON validating against [`probe-output.schema.json`](../../schemas/probe-output.schema.json)):

| State | Trigger | Verdict-resolver Mapping |
|---|---|---|
| `available` | Tool on PATH (subprocess) or image present (container) AND file-list matches `file-extensions` AND `run.sh` exits `0` | `check.status = passed` (no contribution to BLOCKED) |
| `expected_and_missing` | `adapter.json :: provider` declared but `command -v <provider>` fails (subprocess) or container image absent | `check.status = errored` → **BLOCKED** |
| `ran_and_errored` | `run.sh` exits non-zero OR exceeds `--timeout` | `check.status = errored` → **BLOCKED** |
| `not_applicable` | File-list has zero entries matching `file-extensions` (or empty file-list for project-scope adapters with empty `file-extensions`) | `check.status = skipped` — does NOT BLOCK |

### 5.1 Probe Output JSON Shape

```json
{"state":"<state>","skip_reason":<string|null>,"error_detail":<string|null>,"failure_kind":<enum|null>}
```

Exactly four keys, no extras (`additionalProperties: false`). `skip_reason` is non-null when `state == not_applicable`; `error_detail` is non-null when `state == ran_and_errored`; both null otherwise. This is enforced by `probe-output.schema.json`.

`failure_kind` (E66-S6) is the structured classification of the failure mode. Domain: `tool_missing`, `version_mismatch`, `runtime_crash`, `timeout`, or `null`.

| state | rc / trigger | failure_kind |
|---|---|---|
| `available` | run.sh exit 0 | `null` |
| `not_applicable` | no matching files | `null` |
| `expected_and_missing` | provider not on PATH | `tool_missing` |
| `ran_and_errored` | rc 124 / 143 (timeout wrapper) | `timeout` |
| `ran_and_errored` | other non-zero rc | `runtime_crash` |
| _(reserved)_ | future version-check stage | `version_mismatch` |

The field is additive: callers reading `state`/`skip_reason`/`error_detail` keep working unchanged. New callers branch on `failure_kind` for structured decisions instead of regex-parsing `error_detail`.

The probe is **deterministic** (NFR-RSV2-9): identical inputs (`--adapter-dir`, `--file-list`, env apart from PATH) produce byte-identical output every time.

## 6. Adapter Layout (per ADR-078)

```
plugins/gaia/scripts/adapters/{tool}/
├── adapter.json              # Validates against _schema/adapter.schema.json
├── run.sh                    # Honours this contract
└── test/
    └── contract.bats         # Mirrors _schema/test/contract.bats template
```

The adapter directory is the minimum unit of deployment. New adapters copy the `_schema/test/contract.bats` template into `{tool}/test/contract.bats` and rely on `_contract-helper.bash` for the parameterized four-state assertions.

## Refs

- ADR-077 §3.6 — three-tier review pipeline pulls every tool through the adapter contract.
- ADR-078 §1 — adapter pattern + four-state probe motivation.
- ADR-042 — Scripts-over-LLM. Adapters are deterministic shell, not LLM calls.
- FR-RSV2-17 — adapter pattern PRD requirement.
- FR-RSV2-18 — four-state availability probe.
- FR-RSV2-19 — `contract.bats` per built-in adapter.
- NFR-RSV2-3 — deterministic adapter output.
- NFR-RSV2-9 — probe correctness invariants.
- NFR-RSV2-11 — adapter backward-compat / parity test.
- [`analysis-results.schema.json`](../../schemas/analysis-results.schema.json) — canonical finding object schema.
- [`probe-output.schema.json`](../../schemas/probe-output.schema.json) — probe output schema.
