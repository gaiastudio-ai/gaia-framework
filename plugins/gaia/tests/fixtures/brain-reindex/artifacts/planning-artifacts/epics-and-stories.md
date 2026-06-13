# Epics and Stories (reindex fixture)

A tiny mirror of the epics-and-stories.md prose shape. The sweep pre-slices
this file once per run into per-key fragments fed to the harvester.

### Story E777-S2: Primary reindex node

- **Sprint:** sprint-99
- **Description:** The primary node whose allocation bullet mixes
  requirement-shaped and decision-shaped tokens.
- **Allocates:** FR-901 (master reindex policy), ADR-701 (reindex decision record)
- **Depends on:** [E777-S1]
- **Blocks:** [E777-S4, E777-S5]

---

### Story E777-S4: Legacy-nested reindex node

- **Allocates:** FR-903 (legacy-nested requirement)
- **Blocks:** []

---

### Story E777-S7: Flat-layout reindex node

- **Allocates:** ADR-702 (flat-layout decision record)
- **Blocks:** []
