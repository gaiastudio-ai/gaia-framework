# Epics and Stories (detail-block dependency fixture)
#
# Some stories have pipe-table roster rows; others are expressed ONLY via
# bold-label detail blocks under ### Story headings.  The lint must extract
# Depends on from ALL three forms.

## Epic E900

| Story | Title | Size | Points | Risk | Depends on | Blocks |
|-------|-------|------|--------|------|------------|--------|
| E900-S1 | Foundation | L | 8 | medium | none | E900-S2 |

### Story E900-S10: Bold-label hard dep only

- **Size:** M
- **Points:** 5
- **Risk:** medium
- **Depends on:** [E900-S1]
- **Blocks:** []
- **Description:** This story has NO pipe-table row. Its dependency is expressed
  only in the bold-label detail block.

### Story E900-S11: Bold-label with soft dep tail

- **Size:** S
- **Points:** 3
- **Risk:** low
- **Depends on:** E900-S1; soft on E902-S2
- **Blocks:** []
- **Description:** Hard dep on E900-S1, soft dep on E902-S2.

### Story E900-S12: Bold-label with parenthetical annotation

- **Size:** S
- **Points:** 3
- **Risk:** low
- **Depends on:** E900-S1 (Step 4 hook)
- **Blocks:** []
- **Description:** Hard dep on E900-S1 with parenthetical annotation.

### Story E900-S13: Bold-label none (no deps)

- **Size:** S
- **Points:** 2
- **Risk:** low
- **Depends on:** none
- **Blocks:** []
- **Description:** Depends on nothing.

### Story E900-S14: Bold-label comma-separated deps

- **Size:** M
- **Points:** 5
- **Risk:** medium
- **Depends on:** [E900-S1, E901-S9]
- **Blocks:** []
- **Description:** Hard deps on two stories from different epics.

### Story E900-S15: Bold-label empty list

- **Size:** S
- **Points:** 2
- **Risk:** low
- **Depends on:** []
- **Blocks:** []
- **Description:** Depends on nothing (empty list).
