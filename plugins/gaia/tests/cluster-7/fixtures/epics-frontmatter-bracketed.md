# Epics — bracketed-array fixture (AF-2026-05-26-3 F-9)

This fixture exercises the bracketed YAML flow-sequence form
(`[A, B]`, `[A]`, `[]`) for `Depends on:` / `Blocks:` / `Traces to:` — the
form the production `epics-and-stories.md` uses almost exclusively. Before the
F-9 fix, `extract_array` embedded the literal brackets in the first/last
element (`["[E1-S1", "E1-S2]"]`) and turned empty `[]` into a phantom
dependency `["[]"]`.

## Epic E50 — bracketed fixture epic

### Story E50-S2: Multi-element bracketed deps

- **Epic:** E50 — Bracketed fixtures
- **Priority:** P1
- **Size:** M (5 pts)
- **Risk:** medium
- **priority_flag:** null
- **Depends on:** [E50-S1, E50-S3]
- **Blocks:** [E50-S4]
- **Source:** AF-2026-05-26-3
- **Feature ID:** AF-2026-05-26-3
- **Description:** Fixture story with multi-element bracketed arrays.
- **Scope:**
  - Some scope text.
- **Acceptance Criteria:**
  - AC1: example
- **Traces to:** [FR-001, FR-002]
- **Validates:** F-9
- **Status:** ready-for-dev

---

### Story E50-S5: Single-element bracketed dep + empty blocks

- **Epic:** E50 — Bracketed fixtures
- **Priority:** P2
- **Size:** S (2 pts)
- **Risk:** low
- **priority_flag:** null
- **Depends on:** [E50-S2]
- **Blocks:** []
- **Source:** AF-2026-05-26-3
- **Feature ID:** AF-2026-05-26-3
- **Description:** Fixture story with single-element + empty bracketed arrays.
- **Scope:**
  - Some scope text.
- **Acceptance Criteria:**
  - AC1: example
- **Traces to:** []
- **Validates:** F-9
- **Status:** ready-for-dev

---
