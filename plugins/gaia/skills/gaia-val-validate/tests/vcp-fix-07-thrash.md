# VCP-FIX-07 — Thrash observability

> Covers AC1, AC2, AC3, AC4, AC5 of E44-S8 (Val auto-review observability +
> logging) and AC4 / AC-EC4 of E44-S2 (auto-fix loop pattern). LLM-checkable.
>
> **Trace:** FR-344, ADR-058, ADR-059, VCP-FIX-07.

## Setup

Construct an artifact such that the upstream skill's fix attempt produces a
byte-identical artifact (no-op fix), and Val returns the same findings on
the next iteration. The skill is wired with the canonical Auto-Fix Loop
Pattern (see `gaia-framework/plugins/gaia/skills/gaia-val-validate/SKILL.md`
§ "Auto-Fix Loop Pattern"). The checkpoint write path lives at
`.gaia/memory/checkpoints/{skill-name}/{timestamp}-step-{N}.json` per ADR-059.

## Steps

1. Iteration 1: Val returns CRITICAL → "fix" applied (byte-identical result) → record appended to `custom.val_loop_iterations`.
2. Iteration 2: Val returns identical CRITICAL → byte-identical "fix" → record appended to `custom.val_loop_iterations`.
3. Iteration 3: same → record appended to `custom.val_loop_iterations`.
4. Iteration-3 prompt presented per E44-S2 AC2.

## Assertions

### Per-record shape (AC3 of E44-S8)

For every record in `custom.val_loop_iterations`, assert each canonical field is present and well-typed:

- `iteration_number` (int)
- `timestamp` (ISO-8601 UTC string)
- `findings` (array of `{severity, description, location}`)
- `fix_diff_summary` (string; empty or "no-op" marker is permitted for thrash iterations)
- `revalidation_outcome` (one of `clean | info_only | findings_present | val_invocation_failed`)

### Per-iteration distinguishability (AC1 of E44-S8)

- The array has length exactly 3 (no merging, overwriting, or loss).
- Each record has its own copy of `findings` and `fix_diff_summary` (the latter is empty or marked as a no-op for thrash iterations).
- Records are distinguishable by `iteration_number = 1, 2, 3`.

### Programmatic parsing (AC2 of E44-S8)

- The log is read from the checkpoint `custom:` namespace (ADR-059) under the reserved key `val_loop_iterations` — a parser uses a standard JSON reader, not regex scraping.

### Persistence across resume (AC4 of E44-S8)

- Interrupting the loop after iteration 2 and invoking `/gaia-resume` restores the prior records — `custom.val_loop_iterations` length and content are preserved across the session boundary.

### Thrash + cap behavior (AC5 of E44-S8 / AC-EC4 of E44-S2)

- A `"thrash"` warning is logged into iterations 2 and 3 (since iteration 1 has no prior to compare against).
- The thrash detection does NOT short-circuit the 3-cap; the loop runs all 3 iterations and only then presents the prompt.
