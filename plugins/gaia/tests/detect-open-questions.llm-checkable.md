# detect-open-questions.sh — LLM-Checkable Fixtures (E44-S7 / VCP-OQD-01..08)

> Source story: `.gaia/artifacts/implementation-artifacts/E44-S7-open-question-detection-helper-and-wire-into-18-skills.md`
> Helper under test: `plugins/gaia/scripts/detect-open-questions.sh`
> Convention: VCP LLM-checkable test (matches existing `*.llm-checkable.md` siblings)

These fixtures lock in the AC1..AC4 contract (single TBD, mixed markers,
clean artifact, empty vs. non-empty Open Questions section) plus the
word-boundary and checked-checkbox guard cases (VCP-OQD-06 / VCP-OQD-07)
and the 18-skill wire-in audit (VCP-OQD-08). Bats coverage of the same
contract lives at `tests/detect-open-questions.bats` for CI.

---

## VCP-OQD-01 — Single TBD (AC1)

**Input artifact:**

```markdown
# Spec

Throughput: 100 rps
Performance target: TBD
Latency p95: 200 ms
```

**Expected:** exactly 1 finding, group `TBD`, line 4, context contains
`Performance target: TBD`. Exit code 0.

---

## VCP-OQD-02 — Mixed markers (AC2)

**Input artifact:**

```markdown
# Mixed

Goal: TBD
- TODO research vendor X
- TODO survey users
- [ ] Define metric A
- [ ] Define metric B
- [ ] Define metric C
```

**Expected:** exactly 6 findings. Group `TBD`: 1 (line 3). Group `TODO`:
2 (lines 4–5). Group `Unchecked checkboxes`: 3 (lines 6–8). No duplicate
of any (line, marker) pair. Exit code 0.

---

## VCP-OQD-03 — Clean artifact (AC3)

**Input artifact:**

```markdown
# Clean Spec

Throughput target: 100 rps.
Latency p95: 200 ms.
- [x] Defined metric A
- [X] Defined metric B
```

**Expected:** zero findings. stdout is empty. Exit code 0. The skill
proceeds to Val without emitting a guidance block.

---

## VCP-OQD-04 — Empty Open Questions section (AC4, negative)

**Input artifact:**

```markdown
# Spec

## Overview

Some content.

## Open Questions

## Decisions

Done.
```

**Expected:** the empty `## Open Questions` heading is NOT flagged
(empty body = resolved). Zero findings. Exit code 0.

---

## VCP-OQD-05 — Non-empty Open Questions section (AC4, positive)

**Input artifact:**

```markdown
# Spec

## Open Questions

Should we use vendor X or build in-house?

## Decisions

Done.
```

**Expected:** the `## Open Questions` heading IS flagged. Group
`Open Questions sections` has 1 finding at line 3. Exit code 0.

---

## VCP-OQD-06 — Word-boundary false-positive guard (Subtask 2.3)

**Input artifact:**

```markdown
# Tone

A STUBBORN bug.
The ATODOLIST naming is bad.
Apply our METHODOLOGY consistently.
```

**Expected:** zero findings. Substring TBD/TODO inside `STUBBORN`,
`ATODOLIST`, `METHODOLOGY` MUST NOT register. Exit code 0.

---

## VCP-OQD-07 — Checked checkboxes are not flagged

**Input artifact:**

```markdown
# Tasks

- [x] First
- [X] Second
```

**Expected:** zero findings. Only `- [ ]` (literal space inside
brackets) is flagged. Exit code 0.

---

## VCP-OQD-08 — 18-skill wire-in audit (AC5)

**Input:** the 18 SKILL.md files in the Skill Inventory of E44-S7.

**Expected:** every SKILL.md contains the canonical annotation line
`> After artifact write: run open-question detection snippet` after
the artifact-write step body and before the `/gaia-val-validate`
invocation, ordered per architecture §10.31.1 (write -> detect -> Val).
The annotation line MAY appear adjacent to the existing
`> After artifact write: invoke /gaia-val-validate` annotation; the
ordering is normative.

The 18 target skills:

- `/gaia-brainstorming`
- `/gaia-brainstorm`
- `/gaia-market-research`
- `/gaia-domain-research`
- `/gaia-tech-research`
- `/gaia-product-brief`
- `/gaia-advanced-elicitation`
- `/gaia-create-prd`
- `/gaia-create-arch`
- `/gaia-create-ux`
- `/gaia-create-epics`
- `/gaia-infra-design`
- `/gaia-test-design`
- `/gaia-threat-model`
- `/gaia-a11y-testing`
- `/gaia-mobile-testing`
- `/gaia-perf-testing`
- `/gaia-create-story`

Audit command (CI-friendly):

```bash
for f in plugins/gaia/skills/gaia-brainstorming/SKILL.md \
         plugins/gaia/skills/gaia-brainstorm/SKILL.md \
         plugins/gaia/skills/gaia-market-research/SKILL.md \
         plugins/gaia/skills/gaia-domain-research/SKILL.md \
         plugins/gaia/skills/gaia-tech-research/SKILL.md \
         plugins/gaia/skills/gaia-product-brief/SKILL.md \
         plugins/gaia/skills/gaia-advanced-elicitation/SKILL.md \
         plugins/gaia/skills/gaia-create-prd/SKILL.md \
         plugins/gaia/skills/gaia-create-arch/SKILL.md \
         plugins/gaia/skills/gaia-create-ux/SKILL.md \
         plugins/gaia/skills/gaia-create-epics/SKILL.md \
         plugins/gaia/skills/gaia-infra-design/SKILL.md \
         plugins/gaia/skills/gaia-test-design/SKILL.md \
         plugins/gaia/skills/gaia-threat-model/SKILL.md \
         plugins/gaia/skills/gaia-a11y-testing/SKILL.md \
         plugins/gaia/skills/gaia-mobile-testing/SKILL.md \
         plugins/gaia/skills/gaia-perf-testing/SKILL.md \
         plugins/gaia/skills/gaia-create-story/SKILL.md; do
  grep -q "run open-question detection snippet" "$f" \
    || { echo "MISSING wire-in: $f"; exit 1; }
done
echo "All 18 SKILL.md files wired."
```
