# Epics & Stories (resolve-epic-slug fixture)

This is a hermetic fixture for resolve-epic-slug.bats — a curated, in-repo
epics file + epic dirs so the resolver tests are deterministic and do NOT read
the operator's live .gaia/ tree (absent in a published-source CI checkout).

## E79 — Canonical Per-Epic Story-File Layout (`/gaia-create-story` Path Convergence)

Fixture epic used to assert the resolver derives
`epic-E79-canonical-per-epic-story-file-layout`.

## E1 — Framework Core Validation

A second epic so byte-identical enumeration has more than one entry.
