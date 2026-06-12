---
template: 'story'
version: 1.4.0
key: "E777-S2"
title: "Primary harvest node — empty traces variant"
epic: "E777"
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
traces_to: []
date: "2026-06-12"
author: "gaia-create-story"
---

# Story: Primary harvest node — empty traces variant

`traces_to` is an empty inline list and there are no `blocks:`/`depends_on:`
links — but `epic:` is still present, so the C2 predicate treats this node as
LINKED on the epic-present source alone.
