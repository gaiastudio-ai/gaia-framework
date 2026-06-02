---
template: 'adr'
key: 'adr-068'
adr_id: 'ADR-068'
title: 'Canonical finalize-checklist.sh contract'
status: 'Proposed'
date: '2026-04-25'
author: 'Cleo (TypeScript Developer) — proxy author for the dev-story workflow'
traces_to: ['ADR-055', 'FR-358', 'FR-341', 'E45-S6', 'E45-S8', 'TD-60']
---

# ADR-068 — Canonical `finalize-checklist.sh` Contract

> **Decision artifact only.** This ADR pins the contract for the
> `finalize-checklist.sh` helper that every V2 skill's `finalize.sh` will
> shell out to. The implementation refactor is captured separately and
> **must not start until E45-S6 has landed** (per sprint-27 retro / TD-60
> guidance) — execution is scheduled for sprint-29+.

## Status

Proposed — 2026-04-25.

Decided in sprint-28 alongside the rest of the V2 Lifecycle Conventions
work (epic E45). Supersedes nothing — this is the first canonical contract
for the helper. Replaces the ad-hoc per-skill checklist parsing logic
that currently lives inline in 69 `finalize.sh` files.

## Context

### Today's shape

Every V2 skill ships a `scripts/finalize.sh` that runs at the end of the
SKILL.md flow. The body of `finalize.sh` is a mechanical copy of the
Cluster 7 reference implementation (originally authored under E28-S52)
and currently does two things:

1. Writes a checkpoint via the shared `checkpoint.sh` foundation script.
2. Emits a lifecycle event via `lifecycle-event.sh` for the tailing sync
   agent.

The 69 finalize.sh files live under
`gaia-public/plugins/gaia/skills/*/scripts/finalize.sh` and are
byte-identical except for `WORKFLOW_NAME` and `SCRIPT_NAME`. The
"canonical part" of finalize is well-factored.

### What's missing

What is **not** factored is the **inline checklist** that FR-341 / FR-358
introduced in late sprint-27. Many skills now embed a `## Validation`
section at the bottom of SKILL.md — a markdown checklist of "row items"
the skill author wants finalize to verify before the workflow can advance
to `review`. Today each skill that uses `## Validation` re-implements
the parser, the row classifier (script-verifiable vs. LLM-checkable),
and the exit-code semantics inline. The drift across skills is already
measurable — TD-60 (tech-debt-dashboard.md, 2026-04-24) catalogues
seven divergent implementations among the eleven skills that have
adopted the inline `## Validation` pattern.

The proximate driver — TD-60 catalogues the divergence — is the
load-bearing reason this ADR exists.

### Why decide now (and not refactor now)

E45-S6 just landed the **bats budget-watch invariant** (ADR-062). The
test suite is already at 2085 @tests with a 5-minute hard wall on
`bats-tests`. A finalize-checklist refactor that touches 69
`finalize.sh` files plus eleven `## Validation` sections plus a brand
new `scripts/lib/finalize-checklist.sh` script is conservatively a
60-test addition (one per skill × validation rows × edge cases). Per
ADR-062 §"What would trigger Option A": "A second `timeout-minutes`
escalation is proposed in any PR review" triggers parallelism. We do
not want this refactor to be the trigger.

So: **decide the contract now, ship the refactor in sprint-29 after
E45-S6's budget-watch warning has had a sprint of operational data.**

## Decision

The canonical helper is **`gaia-public/scripts/lib/finalize-checklist.sh`**
(shared, single source of truth — not a copy-per-skill). It is invoked
from each skill's `finalize.sh` via an explicit shell-out, not sourced.
Its contract is pinned below.

### Argument grammar

```
finalize-checklist.sh \
  --skill <skill-id> \
  --skill-md <path-to-SKILL.md> \
  [--strict] \
  [--format text|json] \
  [--row-id <id>]... \
  [--allow-missing-validation-section] \
  [--checkpoint-path <path>]
```

| Flag | Required | Default | Semantics |
|------|----------|---------|-----------|
| `--skill <id>` | Yes | — | Skill identifier (e.g., `gaia-validate-story`). Used in lifecycle event payloads and checkpoint keys. |
| `--skill-md <path>` | Yes | — | Absolute path to the SKILL.md being finalized. The script reads this file to extract the `## Validation` section. |
| `--strict` | No | off | When set, **any** row that fails to verify (or that lacks a verifier) is fatal. When off, only script-verifiable rows that fail are fatal; LLM-checkable rows that lack an answer are reported but do not block. See **Exit codes** for semantics. |
| `--format text\|json` | No | `text` | Output format. `text` is for interactive use; `json` is consumed by `quality_gates.post_complete` evaluators. |
| `--row-id <id>` | No (repeatable) | all | Restrict verification to the given row IDs. When omitted, all rows are verified. |
| `--allow-missing-validation-section` | No | off | When set, finalize succeeds (exit 0) if SKILL.md has no `## Validation` section at all. When off, missing-section is exit 4. |
| `--checkpoint-path <path>` | No | derived from `--skill` | Override checkpoint write target. Wired in for the rare per-invocation checkpoint case (default uses the canonical `_memory/checkpoints/{skill}-checkpoint.json` path). |

Long-form flags only — no positional arguments. This matches the
foundation-script convention established by `sprint-state.sh` and
`review-gate.sh` (per ADR-055 §10.29). No short flags — eliminates the
"`-s` means strict here, skill there" footgun.

### Exit codes

| Code | Name | Semantics |
|------|------|-----------|
| 0 | OK | All rows passed, or SKILL.md had no `## Validation` section and `--allow-missing-validation-section` was set. |
| 1 | INTERNAL_ERROR | Helper itself crashed (missing dependencies, malformed args, I/O failure). Distinguished from row-level failures so CI can route differently. |
| 2 | ROW_FAILURE | One or more script-verifiable rows failed. In `--strict` mode, also includes LLM-checkable rows that have no answer. |
| 3 | UNKNOWN_VERIFIER | A row declared a verifier that the helper does not know how to dispatch. Always fatal — silent unknowns would defeat the contract. |
| 4 | MISSING_VALIDATION_SECTION | SKILL.md has no `## Validation` section and `--allow-missing-validation-section` was not set. |
| 5 | LOCKED_OUT | Another finalize-checklist.sh process holds the per-skill flock. Caller may retry with backoff. |

This taxonomy mirrors the explicit exit-code contract pattern from
ADR-055 (sprint-state.sh exit-code taxonomy) — not a coincidence;
finalize-checklist.sh is the second member of the "every PR-gate script
needs structured exit codes" cohort.

### JSON output schema

When `--format json` is set, the helper writes a single JSON document
to stdout matching the schema below. The schema is versioned via the
`schema_version` field — the canonical version pinned by this ADR is
`1`.

```json
{
  "schema_version": 1,
  "skill": "gaia-validate-story",
  "skill_md_sha256": "sha256:abc123...",
  "strict": false,
  "rows": [
    {
      "id": "vlr-01",
      "label": "All ACs marked validated",
      "kind": "script_verifiable",
      "verifier": "scripts/verify-acs.sh --story $STORY_KEY",
      "status": "pass",
      "elapsed_ms": 142,
      "evidence": "3/3 ACs validated"
    },
    {
      "id": "vlr-02",
      "label": "No open questions remain",
      "kind": "llm_checkable",
      "verifier": null,
      "status": "skipped_in_non_strict",
      "elapsed_ms": 0,
      "evidence": null
    }
  ],
  "summary": {
    "total": 7,
    "passed": 5,
    "failed": 0,
    "skipped": 2,
    "unknown": 0
  },
  "exit_code": 0
}
```

### `--strict` mode

`--strict` flips three behaviors:

1. **LLM-checkable rows without answers become fatal.** Outside strict
   mode they are reported with status `skipped_in_non_strict` and do
   not block. Inside strict mode they exit `2 ROW_FAILURE`.
2. **Unknown verifiers are reported earlier.** Outside strict mode the
   helper still exits `3 UNKNOWN_VERIFIER` (always fatal), but in strict
   mode the helper aborts on the first unknown rather than running all
   knowable rows first. This shortens the CI feedback loop during
   author bring-up.
3. **Missing `evidence` field on `pass` rows is fatal.** Outside strict
   mode a passing row may omit evidence. Inside strict mode every pass
   row must populate `evidence`. This catches verifiers that always
   exit 0 ("turn off the tests" anti-pattern).

The default is off because retrofitting eleven existing skills with
strict-clean validation sections is a sprint-29+ exercise. Strict mode
becomes the CI default once the migration is complete.

### Integration with `quality_gates.post_complete`

Per the V2 SKILL.md engine contract (ADR-019, §10.7 — quality-gate
evaluation), every skill runs `quality_gates.post_complete` checks
before transitioning the story to `review`. This ADR pins how
`finalize-checklist.sh` plugs into that gate:

1. The skill's SKILL.md frontmatter declares a `post_complete` check of
   the form:

   ```yaml
   quality_gates:
     post_complete:
       - check: "finalize_checklist_passed"
         on_fail: "HALT: Validation rows failed. Run finalize-checklist.sh --skill <id> --skill-md <path> --format text for details."
   ```

2. The engine resolves `finalize_checklist_passed` by shelling out to
   `scripts/lib/finalize-checklist.sh --skill <id> --skill-md <path>
   --format json` and checking that `exit_code` is `0` in the JSON
   response. This indirection lets the engine cache the JSON for later
   review-gate consumption without re-running verifiers.

3. `validate-gate.sh` (the foundation script that evaluates
   `quality_gates`) gains a `finalize_checklist_passed` predicate
   handler in sprint-29's refactor story. Until then the predicate is
   resolved by the inline shell-out shown above.

4. The exit-code mapping into the gate: `0` → gate passes, `2`/`3`/`4`
   → gate fails with the `on_fail` message, `1`/`5` → gate fails with a
   "validation infrastructure error — re-run" message that does not
   blame the row authors.

### Idempotency

The helper is idempotent over its input: two back-to-back invocations
with the same `--skill`, `--skill-md`, and SKILL.md content produce
identical JSON modulo `elapsed_ms`. The `skill_md_sha256` field exists
so callers (notably review-gate.sh) can detect mid-flight SKILL.md
edits between finalize and review-gate evaluation.

### Where it lives

Canonical path: `gaia-public/scripts/lib/finalize-checklist.sh`. **Not**
under each skill — that defeats the "single source of truth" goal. Each
skill's `finalize.sh` shells out via:

```bash
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
FINALIZE_CHECKLIST="$PLUGIN_SCRIPTS_DIR/lib/finalize-checklist.sh"
"$FINALIZE_CHECKLIST" --skill "$SKILL_ID" --skill-md "$SKILL_MD_PATH"
```

This mirrors the `checkpoint.sh` and `lifecycle-event.sh` resolution
pattern already used in every `finalize.sh`.

### Relationship to FR-341 / FR-358 inline `## Validation` sections

FR-358 fixes the canonical row schema for SKILL.md `## Validation`
sections. This ADR consumes FR-358 — the helper parses
FR-358-conformant rows and dispatches their verifiers. The helper does
**not** redefine the row schema. If FR-358 changes (e.g., adds a new
`kind:` value), this ADR's schema versions to `2` and the helper gains
a new dispatcher branch. Schema version bump is a coupled change.

FR-341 introduced the `## Validation` section concept. This ADR makes
the parser canonical so FR-341's eleven adopters and the next ~30
SKILL.md files that adopt the pattern share one parser instead of
re-implementing.

## Consequences

### Positive

- **Eliminates seven divergent parsers** (TD-60, sprint-28). Every skill
  uses the same row classifier, the same exit codes, the same JSON
  schema.
- **`quality_gates.post_complete` becomes mechanically cheap to wire.**
  Skill authors copy a one-line YAML block and one-line shell call.
- **CI gains a stable JSON contract.** PR-gate runners parse one
  schema; review-gate.sh can consume the same JSON without re-running
  verifiers (the `skill_md_sha256` field guards staleness).
- **Strict mode is opt-in for now, default later.** Migration path is
  graceful — eleven existing adopters can stay non-strict during the
  refactor sprint and flip strict in a follow-up sweep.
- **Refactor is sequenced behind E45-S6.** No CI cliff risk.

### Negative

- **One more shared script in `scripts/lib/`** to maintain. Mitigation:
  scripts/lib/ is the canonical location for shared bash helpers; this
  is exactly its purpose.
- **Coupled schema version with FR-358.** A future row-schema change
  is a two-file PR (FR-358 + this ADR + the helper). Mitigation: this
  is correct coupling — the helper *is* the FR-358 reference parser.
- **Migration cost across 11 existing adopters in sprint-29+.**
  Mitigation: the helper is backward-compatible by default
  (`--strict` is off). Migration is mechanical (delete inline parser,
  add one-line shell-out).

### Neutral

- **No production code ships in this story.** The only artifacts are
  this ADR, the bats document-presence test, and the architecture.md
  registry row. The implementation story is drafted in the backlog
  for sprint-29 (per Definition of Done).

## Alternatives

### Option A — Per-skill parser (status quo)

Continue letting each skill implement its own `## Validation` parser
inline. **Rejected:** TD-60 already catalogues seven divergent
implementations; the divergence will compound as the next ~30 skills
adopt the pattern.

### Option B — Source the helper instead of shelling out

Each `finalize.sh` would `source "$FINALIZE_CHECKLIST"` and call its
exposed functions directly. **Rejected:** sourcing leaks the helper's
internal state (variables, flock handles) into the calling shell, and
the cluster-9 e2e bats suite has known flakes around sourced foundation
scripts (E43-S5 retro). Shell-out costs ~20ms; that's well below the
2s budget for a finalize step.

### Option C — Embed the helper in `validate-gate.sh`

Make `validate-gate.sh` (the existing `quality_gates` evaluator) the
parser, with no separate helper. **Rejected:** `validate-gate.sh` is a
predicate evaluator that dispatches to N predicate handlers. Embedding
a 200-line markdown parser plus row dispatcher inside it violates that
single-responsibility shape and forces every CI run that evaluates a
non-validation gate to load the parser too. Keeping them separate lets
each evolve independently and lets `validate-gate.sh` cache the JSON
result instead of re-parsing.

### Option D — Per-skill copy of `finalize-checklist.sh`

Mirror the existing `finalize.sh` pattern: 69 byte-identical copies of
the helper, one per skill. **Rejected:** the original `finalize.sh`
copy-paste was deliberate (E28-S52 reference architecture, byte-identical
bodies for static analysis). The checklist helper is not a candidate for
that pattern because it carries actual logic that must evolve as
FR-358's row schema evolves; per-skill copies would re-introduce the
seven-way divergence we're trying to delete.

## Cross-reference

- **ADR-055** — sprint-state.sh exit-code taxonomy. This ADR's
  exit-code section uses the same shape.
- **FR-341** — `## Validation` section concept. This ADR is its
  canonical parser pin.
- **FR-358** — canonical row schema. This ADR consumes it; schema
  version bumps are coupled.
- **ADR-062** — bats budget-watch (E45-S6). This ADR explicitly
  defers refactor execution until ADR-062 has run for one sprint to
  give us early-warning signal before the CI cliff.
- **TD-60** — tech-debt-dashboard.md (2026-04-24). The driver for
  this ADR.
- **E45-S8** — this story. Decision artifact only.

## Out of scope (deferred to sprint-29+)

- The actual implementation of `gaia-public/scripts/lib/finalize-checklist.sh`.
- Migration of the eleven existing inline-parser skills.
- The `validate-gate.sh` `finalize_checklist_passed` predicate handler.
- The CI wiring that surfaces JSON failures into PR comments.
- Strict-mode default flip (sprint-30+ candidate).

A follow-up implementation story is drafted in the backlog per the
story's Definition of Done.
