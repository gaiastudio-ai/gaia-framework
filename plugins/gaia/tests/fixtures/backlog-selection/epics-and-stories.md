# Epics and Stories (fixture slice)

## Epic E900

| Story | Title | Size | Points | Risk | Depends on | Blocks |
|-------|-------|------|--------|------|------------|--------|
| E900-S1 | Foundation | L | 8 | medium | none | E900-S2, E900-S3 |
| E900-S2 | Builds on S1 | M | 5 | low | E900-S1 | E900-S3 |
| E900-S3 | Cross-sprint dep | M | 5 | medium | E901-S9 | none |
| E900-S4 | Soft dep | S | 3 | low | E900-S1; soft on E902-S2 | none |
| E900-S5 | Annotated dep | S | 2 | low | E900-S1 (Step 4 hook) | none |

> Detail block (the lint must IGNORE this bold-label form, parsing the roster row above):
- **Depends on:** [E901-S9]
