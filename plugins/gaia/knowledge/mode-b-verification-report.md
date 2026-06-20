# Persistent-Teammate Dispatch — Verification Report

_Generated: 2026-06-20T16:46:58Z_

## Summary

This report verifies the persistent-teammate (team-dispatch) stack against
every skill in the plugin. It records the static readiness preconditions —
whether each skill declares a team-dispatch readiness section, whether the
shared dispatch bridge it names is reachable on disk, and whether the skill
pins itself to the foreground dispatch path via a per-skill override.

Live team dispatch is not exercisable in this environment: the runtime
primitives for persistent teammates are gated, so every skill resolves to
the foreground **fallback** path at runtime. The Dispatch column therefore
reads `fallback` for every row — this is an honest record of what was
measured, not a claim that any skill was exercised live. The roster-cost
number below is likewise the fallback-path bookkeeping cost.

- Skills scanned: **166**
- Team-ready skills (readiness section present): **42**
- Named bridges reachable: **42**
- Skills with a per-skill foreground override: **0**

## Roster Cost (fallback-path spawn latency)

Measured over 30 iterations of a single spawn-then-shutdown cycle on the
foreground fallback path. The P95 below is the fallback bookkeeping cost
(registry write, handle generation, provenance append, fallback-token
emission) — the floor cost the dispatcher always pays. Live teammate
startup would add substrate latency on top of this number.

- `p95_ms=46`
- `threshold_ms=250`
- `verdict=pass`

## Per-Skill Status

| Skill | Readiness | Bridge | Mode override | Dispatch |
|-------|-----------|--------|---------------|----------|
| `gaia-a11y-testing` | readiness section present | reachable | none | fallback |
| `gaia-add-feature` | readiness section present | reachable | none | fallback |
| `gaia-advanced-elicitation` | readiness section present | reachable | none | fallback |
| `gaia-atdd` | readiness section present | reachable | none | fallback |
| `gaia-brainstorm` | readiness section present | reachable | none | fallback |
| `gaia-brainstorming` | readiness section present | reachable | none | fallback |
| `gaia-brownfield` | readiness section present | reachable | none | fallback |
| `gaia-create-arch` | readiness section present | reachable | none | fallback |
| `gaia-create-epics` | readiness section present | reachable | none | fallback |
| `gaia-create-prd` | readiness section present | reachable | none | fallback |
| `gaia-create-story` | readiness section present | reachable | none | fallback |
| `gaia-create-ux` | readiness section present | reachable | none | fallback |
| `gaia-creative-sprint` | readiness section present | reachable | none | fallback |
| `gaia-deploy` | readiness section present | reachable | none | fallback |
| `gaia-design-thinking` | readiness section present | reachable | none | fallback |
| `gaia-dev-story` | readiness section present | reachable | none | fallback |
| `gaia-domain-research` | readiness section present | reachable | none | fallback |
| `gaia-edit-arch` | readiness section present | reachable | none | fallback |
| `gaia-edit-prd` | readiness section present | reachable | none | fallback |
| `gaia-edit-test-plan` | readiness section present | reachable | none | fallback |
| `gaia-edit-ux` | readiness section present | reachable | none | fallback |
| `gaia-infra-design` | readiness section present | reachable | none | fallback |
| `gaia-init` | readiness section present | reachable | none | fallback |
| `gaia-innovation` | readiness section present | reachable | none | fallback |
| `gaia-market-research` | readiness section present | reachable | none | fallback |
| `gaia-mobile-testing` | readiness section present | reachable | none | fallback |
| `gaia-nfr` | readiness section present | reachable | none | fallback |
| `gaia-party` | readiness section present | reachable | none | fallback |
| `gaia-perf-testing` | readiness section present | reachable | none | fallback |
| `gaia-problem-solving` | readiness section present | reachable | none | fallback |
| `gaia-product-brief` | readiness section present | reachable | none | fallback |
| `gaia-quick-dev` | readiness section present | reachable | none | fallback |
| `gaia-quick-spec` | readiness section present | reachable | none | fallback |
| `gaia-readiness-check` | readiness section present | reachable | none | fallback |
| `gaia-retro` | readiness section present | reachable | none | fallback |
| `gaia-run-all-reviews` | readiness section present | reachable | none | fallback |
| `gaia-sprint-plan` | readiness section present | reachable | none | fallback |
| `gaia-sprint-review` | readiness section present | reachable | none | fallback |
| `gaia-storytelling` | readiness section present | reachable | none | fallback |
| `gaia-tech-research` | readiness section present | reachable | none | fallback |
| `gaia-test-a11y` | readiness section present | reachable | none | fallback |
| `gaia-test-perf` | readiness section present | reachable | none | fallback |

## Backward-Compatibility Note

The per-skill foreground override is opt-in and one-directional: a skill
that declares `mode: A` in its frontmatter is pinned to the foreground
dispatch path even when the framework runs with persistent teammates
enabled globally. A foreground-only framework can never be upgraded by a
skill — the knob only opts a skill OUT of team dispatch, never into it.
This preserves existing foreground behaviour unchanged for any skill that
is not team-ready.
