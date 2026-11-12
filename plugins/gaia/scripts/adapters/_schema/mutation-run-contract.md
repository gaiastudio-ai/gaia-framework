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
- Non-zero, or no valid `index.json` — generation failed; the runner adds one `error` record for that file. Its stderr goes to the runner's stderr, not into the record.
- An `index.json` entry the runner cannot plan from (a bad `mutant_id` or `line`, a missing or absent mutant file) — the runner adds one `error` record for that file, runs none of its mutants, and the gate is `errored`.

`mutant_id` only has to be unique within the adapter's output for one file. The runner prefixes it with a hash of the file path, so ids in the evidence are unique across files and stable across runs.

## 2. run.sh — Single-Mutant Execution

```
run.sh --source-dir <dir> --patch-file <patch> --test-command <cmd>
       --output <json> --timeout <seconds>
```

| Flag | Required | Meaning |
|---|---|---|
| `--source-dir <dir>` | yes | Throwaway copy of the source tree. The adapter applies the patch here. Must be inside a `gaia-mutation-` temp root. |
| `--patch-file <patch>` | yes | Path to the unified-diff patch file. A zero-byte file means "no mutation": run the tests as they are. The runner uses it for the baseline. |
| `--test-command <cmd>` | yes | Shell command to execute (the covering tests), with `--source-dir` as its working directory and as `PROJECT_PATH`. |
| `--output <json>` | yes | Path to write the JSON result record. |
| `--timeout <seconds>` | yes | Wall-clock budget for one test run under one interpreter. On expiry, the test process group is terminated and the mutant is reported as `timeout`. The runner passes its `--timeout` option, else `GAIA_MUTATION_TIMEOUT`, else the manifest's `default-timeout-seconds`. |

### Output Record

```json
{
  "mutant_id": "mutant-1",
  "status": "killed",
  "test_output": "ok 1 first test\nnot ok 2 test name 1",
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
| `status` | enum | yes | `killed` (a test genuinely failed), `survived` (tests passed), `timeout` (tests exceeded the deadline), `error` (the tests could not run, for example exit 126, exit 127 or death by signal, or the adapter failed). Only a real test failure may be reported as `killed`. |
| `test_output` | string | yes | Test result lines only, capped at 4 KB, or a fixed message when the adapter failed or withheld the output. See section 3. |
| `file` | string | no | Relative path of the mutated file. |
| `line` | integer | no | 1-based line number of the mutation. |
| `operator` | string | no | Human-readable description of the mutation operator. |
| `killed_by` | array of strings | no | Test names that detected the mutant. |
| `tests` | array of strings | no | Names of every test the command reported. The runner reads them from the baseline record to know which covering tests exist; it is not kept in the evidence. |
| `no_coverage` | boolean | no | True when no covering test references the mutated file. Set by the runner, not the adapter. |
| `interpreters` | array of strings | no | Version strings of interpreters used. |

### Exit Code

- `0` — the adapter completed execution cleanly, regardless of the mutant outcome (killed, survived, timeout). Exit 0 is the **only** valid clean-run exit.
- Non-zero — adapter execution failed. The runner records the mutant as `error`.

### Baseline

Before any mutant runs, the runner calls `run.sh` with a zero-byte patch for each distinct set of covering tests. Any status other than `survived` refuses the run: the evidence has `gate: errored`, `score: null`, `refused: baseline_red` (the tests failed) or `baseline_error` (they could not run, or ran out of time, which `baseline.status: timeout` marks), and a `baseline` object with the stored result lines (after a message naming the limit, on a timeout), because every mutant would otherwise look killed. Tool-native adapters are not called this way; their tools do their own green check.

## 3. What test_output Holds

`test_output` is stored with the story's other evidence under test-artifacts, so it holds test result lines and nothing else. A result line is `ok` or `not ok`, the test number and the test name, one per line, without a `# skip`, `# todo` or timing suffix. Anything else a test prints, including its environment, is not stored. A test command that prints no result lines gives an empty `test_output`.

An adapter scrubs the complete output before reading it. The bash adapter replaces the values of secret-named environment variables and `NAME=value` pairs with a secret-looking name, then applies the shared secret-pattern scrubber. Result lines, `killed_by` and `tests` are all read from that scrubbed text; `killed_by` and `tests` always cover the complete output. The status comes from the exit code. If the scrubber fails or is missing, `test_output` is a fixed message saying the output was withheld, and `killed_by` and `tests` are empty.

The stored lines are capped at the newest whole lines that fit 4 KB. A test name is stored as the test wrote it, so a secret in a name is removed only if scrubbing recognises it.

In an adapter or generator failure, `test_output` is a fixed message from the adapter or the runner: `patch failed to apply`, `generator failed`, `adapter exited <code>`. The failing tool's stderr goes to the runner's stderr for the operator and never into the record. The runner stores what a tool-native adapter returns as it stands, so that adapter owns the same guarantee.

## 4. tool-native Format

For tools whose mutants cannot be expressed as source patches (e.g., JVM bytecode mutation tools), the mutant file is a JSON batch descriptor (named by `batch_file` in `index.json`) and `run.sh` outputs a JSON array of records. Each array element becomes its own record in the evidence and its own entry in the totals. The runner accepts both `patch` and `tool-native` shapes based on the adapter manifest's `mutant-format` field.

## 5. Interpreter Shim

Adapters that support multiple interpreters (e.g., the bash adapter running under both bash 5 and bash 3.2) create a PATH shim directory inside the throwaway copy. Scripts started via `#!/usr/bin/env bash` resolve to the selected interpreter. Scripts with a hard-coded `#!/bin/bash` shebang always run under the system bash.
