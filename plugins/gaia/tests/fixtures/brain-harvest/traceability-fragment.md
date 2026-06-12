# Traceability Matrix (harvest fixture)

## 1. Functional Requirements → Story Mapping

The `implements` harvester reads column 3 (the Story(s) comma-list) of each
FR row and emits an `implements` edge from every story whose key appears there.
Whole-token matching: `E777-S2` must NOT match the near-miss key `E777-S20`.

| FR ID | Description | Story(s) | Unit | Integration | Coverage |
|-------|-------------|----------|------|-------------|----------|
| FR-901 | Primary requirement mapped to the primary node | E777-S2 | — | — | Planned |
| FR-902 | A requirement mapped to several stories incl. the primary | E777-S1, E777-S2, E777-S3 | — | — | Planned |
| FR-903 | A requirement mapped ONLY to the near-miss key | E777-S20 | — | — | Planned |
| FR-904 | A requirement mapped to an unrelated node | E777-S9 | — | — | Planned |

## Per-Story Verification Rows (Story → Test, per-STORY shape)

The `verified-by` harvester reads rows whose FIRST cell is exactly the node key
and harvests the test tokens from that row. This is the per-STORY shape.

| Story | Pts | Description | Tests | Reqs | ADR |
|-------|-----|-------------|-------|------|-----|
| E777-S2 | 2 | Primary node verification row | TC-HARV-1, TC-HARV-2 | FR-901 | ADR-701 |
| E777-S20 | 1 | Near-miss verification row (must not leak into primary) | TC-HARV-99 | FR-999 | — |
| E777-S9 | 3 | Unrelated node verification row | TC-HARV-50 | FR-904 | — |

## Per-Epic Roll-up Rows (Epic → Stories, roll-up shape — OUT OF SCOPE)

Roll-up rows are NOT keyed on the node key in column 1; they carry story-RANGES
and test-prefix ranges. The per-STORY harvester ignores these. A story documented
only here degrades to no `verified-by` edges (acceptable under the never-drop rule).

| Epic | Stories | Pts | Risk | Key Tests |
|------|---------|-----|------|-----------|
| E778 | E778-S1..S5 | 12 | medium | TC-ROLL-1..4 |
