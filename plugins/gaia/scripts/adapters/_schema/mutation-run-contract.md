# Mutation Adapter Execution Contract

> **Companions:** [`mutation-adapter.schema.json`](./mutation-adapter.schema.json) (machine-verifiable metadata schema).
> **Stability:** Stable. Every mutation adapter under `plugins/gaia/scripts/adapters/mutation-{stack}/` honours this contract.

This document specifies the two entry points every mutation adapter provides: `generate.sh` (mutant production) and `run.sh` (single-mutant execution). The mutation runner (`scripts/mutation-runner.sh`) dispatches to these entry points; review consumers never call them directly.

## 1. generate.sh — Mutant Generation

```
generate.sh --source-dir <dir> --files-from <file> --out-dir <dir>
```

| Flag | Required | Meaning |
|---|---|---|
| `--source-dir <dir>` | yes | Root of the source tree (worktree or throwaway copy). |
| `--files-from <file>` | yes | Newline-delimited list of source files (relative to source-dir) to mutate. |
| `--out-dir <dir>` | yes | Directory to write mutant files and `index.json`. |

### Output

For `patch` format adapters: one `.patch` file per mutant (unified diff, applicable with `patch -p1` using `a/` and `b/` prefix paths) plus an `index.json` manifest.

For `tool-native` format adapters: one JSON batch descriptor per mutant group plus `index.json`.

`index.json` schema:
```json
[
  {
    "mutant_id": "mutant-1",
    "patch_file": "mutant-1.patch",
    "file": "relative/path.sh",
    "line": 42,
    "operator": "comparison flip eq/ne"
  }
]
```

### Exit Code

- `0` — generation completed (zero mutants is valid).
- Non-zero — generation failed; the runner reports affected files as unmutated.

## 2. run.sh — Single-Mutant Execution

```
run.sh --source-dir <dir> --patch-file <patch> --test-command <cmd>
       --output <json> --timeout <seconds>
```

| Flag | Required | Meaning |
|---|---|---|
| `--source-dir <dir>` | yes | Throwaway copy of the source tree. The adapter applies the patch here. Must be inside a `gaia-mutation-` temp root. |
| `--patch-file <patch>` | yes | Path to the unified-diff patch file. |
| `--test-command <cmd>` | yes | Shell command to execute (the covering tests). |
| `--output <json>` | yes | Path to write the JSON result record. |
| `--timeout <seconds>` | yes | Wall-clock budget. On expiry, the test process group is terminated and the mutant is reported as `timeout`. |

### Output Record

```json
{
  "mutant_id": "mutant-1",
  "status": "killed",
  "test_output": "...",
  "file": "relative/path.sh",
  "line": 42,
  "operator": "comparison flip eq/ne",
  "killed_by": ["test name 1"],
  "no_coverage": false,
  "interpreters": ["5.2.37", "3.2.57"]
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `mutant_id` | string | no | Set by the runner if absent. |
| `status` | enum | yes | `killed` (test failed), `survived` (test passed), `timeout` (test exceeded deadline), `error` (adapter failure). |
| `test_output` | string | yes | Truncated tail of test stdout+stderr. Capped at 4 KB. |
| `file` | string | no | Relative path of the mutated file. |
| `line` | integer | no | 1-based line number of the mutation. |
| `operator` | string | no | Human-readable description of the mutation operator. |
| `killed_by` | array of strings | no | Test names that detected the mutant. |
| `no_coverage` | boolean | no | True when no covering test references the mutated file. Set by the runner, not the adapter. |
| `interpreters` | array of strings | no | Version strings of interpreters used. |

### Exit Code

- `0` — the adapter completed execution cleanly, regardless of the mutant outcome (killed, survived, timeout). Exit 0 is the **only** valid clean-run exit.
- Non-zero — adapter execution failed. The runner records the mutant as `error`.

## 3. test_output Truncation

`test_output` is capped to a tail of 4 KB. It never includes environment variables or secrets. It is stored alongside the story's other evidence under test-artifacts.

## 4. tool-native Format

For tools whose mutants cannot be expressed as source patches (e.g., JVM bytecode mutation tools), the mutant file is a JSON batch descriptor and `run.sh` outputs a JSON array of records. The runner accepts both `patch` and `tool-native` shapes based on the adapter manifest's `mutant-format` field.

## 5. Interpreter Shim

Adapters that support multiple interpreters (e.g., the bash adapter running under both bash 5 and bash 3.2) create a PATH shim directory inside the throwaway copy. Scripts started via `#!/usr/bin/env bash` resolve to the selected interpreter. Scripts with a hard-coded `#!/bin/bash` shebang always run under the system bash.
