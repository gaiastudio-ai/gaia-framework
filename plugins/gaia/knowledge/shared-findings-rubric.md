# Shared Findings Rubric

This document defines the severity levels, blocker definition, register schema,
and verdict rule shared by all review skills. Every review gate references this
rubric as its single source of truth for findings classification and verdict
computation.

---

## Severity Levels

| Level      | Description |
|------------|-------------|
| `critical` | A demonstrated failure of required behaviour, a confirmed security vulnerability, data-integrity corruption, or a violation of an agreed performance limit. Always blocking. |
| `high`     | A credible unresolved risk to required behaviour, security, data integrity, supported platforms, reliability, or an agreed performance limit. Always blocking unless explicitly resolved with rationale. |
| `medium`   | A defect or risk that does not meet the blocker definition. Non-blocking by default; routed to triage with an owner and a priority. |
| `low`      | A minor issue, style concern, or improvement suggestion. Non-blocking; routed to triage. |

### Template Tier Mapping

Review skills that use the template's three-tier scale normalise to canonical
severity as follows:

| Template tier | Canonical severity |
|---------------|--------------------|
| Critical      | `critical`         |
| Warning       | `medium`           |
| Suggestion    | `low`              |

Severity is case-insensitive on input and stored in lowercase.

---

## Blocker Definition

A **blocker** is a demonstrated failure, or a credible unresolved risk, to
required behaviour, security, data integrity, supported platforms, reliability,
or an agreed performance limit. Everything else is non-blocking and goes to
triage with an owner and a priority.

### Severity-to-Blocking Derivation

When a finding is recorded without an explicit blocking flag, the writer derives
the blocking status from severity:

- `critical` or `high` -> blocking (with an auto-generated rationale).
- `medium` or `low` -> non-blocking.

A non-blocking `bug` with `critical` or `high` severity is rejected — a
demonstrated high-severity or critical-severity bug always meets the blocker
definition and cannot be downgraded without an explicit resolution with
rationale.

### Material Risk Rule

A finding marked as a **material risk** (`material: true`) is always blocking,
regardless of its severity label. A material risk cannot be cleared by a low
severity label; the `material: true` flag persists through severity resolutions
and cannot be removed by `resolve-severity`.

### Test-Gap Materiality

A test gap is blocking only when material required behaviour or risk is left
unverified. A test gap for non-material behaviour (e.g. a cosmetic edge case
with no security or reliability impact) is non-blocking and goes to triage.

---

## Deterministic Blockers

Deterministic tool and execution failures — a failed blocking tool check, a
required test suite timeout, a required test suite non-zero exit, and a coverage
regression — block through the resolver's existing deterministic rules. These
deterministic blockers stay outside the register and are not recorded as
register entries. The register rule evaluates only after all deterministic rules
have passed.

---

## Findings Register

### Purpose

The findings register is a per-story YAML file that holds all findings from all
review gates in one place. Each finding carries exactly one resolution
obligation (owner + disposition). When the same underlying defect is detected by
more than one gate, it is held as a single register entry with one stable ID.

### Schema

```yaml
schema_version: 1
story: <story key>
gate_runs:
  - {run_id: <id>, gate: <gate-id>, at: <iso-8601>, outcome: completed | errored}
entries:
  - id: RF-<n>
    defect: <plain-language description>
    requirement_or_risk: <what it affects>
    evidence: <reproduction command, tool output or file:line>
    impact: <what breaks if unresolved>
    type: bug | security | tech-debt | test-debt | code-debt | doc-debt | design-debt | process-debt | framework-defect
    severity: critical | high | medium | low
    reproduction: <runnable command + expected output; optional>
    material: true | false
    blocking: true | false
    blocking_rationale: <required when blocking is true>
    dedup_key: <file>:<line-range>:<defect-class>
    originating_gates: [<gate-id>, ...]
    gate_ratings:
      - {gate: <gate-id>, severity: <level>, blocking: <bool>, material: <bool>}
    severity_resolution:
      resolved_severity: <level>
      resolved_blocking: true | false
      rationale: <non-empty>
    owner: <gate or assignee>
    priority: <required when disposition is triage>
    disposition: open | resolved | triage
    history: [{at: <iso-8601>, gate: <gate-id>, action: <string>, note: <string>}]
```

### ID Allocation

Entry IDs use the format `RF-<n>` where `<n>` is sequential per story,
allocated as the highest existing ID + 1. After a merge removes an entry, the
next ID is still max + 1 (never reuses a removed ID).

### Dedup Rule

The deterministic key `{file}:{line-range}:{defect-class}` proposes a merge on
`add`. When a new finding matches an existing entry's dedup key, the existing
entry gains the new gate in `originating_gates` and a new `gate_ratings` record.
No new ID is allocated. Cross-gate matches with differing descriptions use the
explicit `merge` subcommand, which is recorded in the entry history. Fully
automatic semantic dedup is not promised.

### Severity-Disagreement Resolution

When an entry's `gate_ratings` differ in severity or blocking and no
`severity_resolution` exists, the entry is an **unresolved disagreement**. The
`resolve-severity` subcommand records a resolution with a mandatory non-empty
rationale, writing the resolved severity and blocking values to both the
`severity_resolution` block and the entry's top level.

An unresolved disagreement is treated as blocking if any gate rated it blocking
(fail-closed).

---

## Verdict Rule

A review gate's verdict is **FAILED** (the resolver emits `REQUEST_CHANGES`) if
and only if at least one register entry is an **unresolved blocker** — that is,
the entry is blocking (per the blocking-determination order below) and its
disposition is not `resolved`. An unknown disposition counts as unresolved
(fail-closed).

An empty register (`entries: []`) yields **PASSED** (the resolver emits
`APPROVE`).

A malformed or structurally invalid register yields **BLOCKED** (exit 0,
consistent with the resolver's "verdict is data" convention), never `APPROVE`.

### Blocking-Determination Order (first match wins)

1. `material: true` -> blocking; no resolution can clear it.
2. `severity_resolution` present -> use `resolved_blocking`.
3. `gate_ratings` disagree on blocking, no resolution -> blocking if any rating
   is blocking.
4. Otherwise -> top-level `blocking` value.

### Same Register, Same Verdict

The same register evaluated through any of the six review gates produces the
same verdict. Gate identity does not influence the register rule.

---

## Writer and Fork Isolation

The register writer (`register-write.sh`) is the sole sanctioned writer for the
register file. Forked review skills (which run in read-only fork isolation) call
the writer from the parent context after the fork completes. Non-forked skills
call the writer directly.

---

## Non-Blocking Findings and Triage

Non-blocking findings are recorded with disposition `triage`, an owner, and a
priority. They appear as rows in the story's Findings section, where the triage
extractor picks them up. A finding that carries a reproduction is preserved
through triage (the extractor does not dismiss a row that carries a
reproduction).
