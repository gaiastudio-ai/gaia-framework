# Epics and Stories (harvest fixture)

A tiny mirror of the `epics-and-stories.md` prose shape. Each story row is a
`### Story <KEY>:` heading followed by metadata bullets, including the
`- **Allocates:**` bullet the `implements`/`governed-by` harvester parses.

### Story E777-S2: Primary harvest node

- **Sprint:** null
- **Priority flag:** null
- **Description:** A story whose allocation bullet mixes requirement-shaped and
  decision-shaped tokens, and carries parenthetical glosses on each token.
- **Acceptance Criteria:**
  - AC1: something happens.
- **Allocates:** FR-901 (master harvest policy), NFR-310 (render budget contract), ADR-701 (harvest decision record)
- **Depends on:** []
- **Blocks:** [E777-S4, E777-S5]
- **Traces to:** AF-2026-06-12-9

---

### Story E777-S20: Near-miss node (whole-token guard)

This heading's key is a superstring of the primary node key. A substring match
would wrongly fold this story's allocation into the primary node — the harvester
must match whole tokens only.

- **Allocates:** FR-999 (near-miss requirement, must NOT leak into the primary node)
- **Blocks:** [E777-S21]

---

### Story E777-S7: Node with no allocation bullet

A story row that carries no `- **Allocates:**` bullet at all. The harvester must
emit zero `implements`/`governed-by` edges from this source for this node and must
not error.

- **Sprint:** null
- **Depends on:** []
- **Blocks:** []

---

### Story E777-S30: Unrelated node referencing the primary key in prose

- **Description:** This row mentions E777-S2 in free prose, but its own
  allocation bullet is its own. Prose mentions outside the node's own heading
  block must not contribute allocation tokens to the primary node.
- **Allocates:** FR-555 (belongs to this node, not the primary)
