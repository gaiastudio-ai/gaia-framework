---
template: 'story'
version: 1.4.0
key: "E777-S404"
title: "Orphan node — no links across any source"
status: in-progress
priority: "P3"
size: "S"
points: 1
risk: "low"
sprint_id: "sprint-99"
priority_flag: null
delivered: true
deferred_implementation: false
origin: add-feature
depends_on: []
blocks: []
traces_to: []
date: "2026-06-12"
author: "gaia-create-story"
---

# Story: Orphan node — no links across any source

No `epic:` field, empty `traces_to`, no epics-prose Allocates row, no matrix
Story mapping. All four C2 sources miss → the node ships `edges: []` and
`unlinked: true`, and is NEVER dropped.
