---
template: 'story'
version: 1.4.0
key: "E777-S2"
title: "Primary harvest node — traces-only variant"
status: in-progress
priority: "P2"
size: "M"
points: 3
risk: "low"
sprint_id: "sprint-99"
priority_flag: null
delivered: true
deferred_implementation: false
origin: add-feature
depends_on: []
blocks: []
traces_to: ["FR-901", "ADR-701"]
date: "2026-06-12"
author: "gaia-create-story"
---

# Story: Primary harvest node — traces-only variant

`traces_to` is a non-empty inline list, but there is NO `epic:` field and no
`blocks:`/`depends_on:` links. The frontmatter `traces_to:` source is the ONLY
possible linking signal, so the C2 predicate must treat this node as LINKED on
the `traces_to` source alone.
