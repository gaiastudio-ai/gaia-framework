---
template: 'story'
version: 1.4.0
key: "E777-S2"
title: "Primary harvest node"
epic: "E777"
status: in-progress
priority: "P2"
size: "L"
points: 8
risk: "medium"
sprint_id: "sprint-99"
priority_flag: null
delivered: true
deferred_implementation: false
origin: add-feature
origin_ref: AF-2026-06-12-9
depends_on: ["E777-S1"]
blocks: ["E777-S4", "E777-S5"]
traces_to: ["FR-901", "FR-902", "ADR-701", "ADR-702"]
date: "2026-06-12"
author: "gaia-create-story"
---

# Story: Primary harvest node

This frontmatter populates `traces-to` (every `traces_to` token), `decomposes`
(the `epic:` value plus each `blocks:`/`depends_on:` key), and `governed-by`
(the ADR-shaped subset of `traces_to`). It deliberately carries NO `implements:`
field — the forbidden trap. `implements` edges come from prose + matrix only.
