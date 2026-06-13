---
name: gaia-brain-health
description: Show the brain knowledge layer's health view — every artifact the four-source linked predicate classifies as unlinked (no governance traceability). Use when "show brain health", "which artifacts are unlinked", "find traceability gaps", or /gaia-brain-health. Read-only; surfaces gaps as a quality signal and never fails.
allowed-tools: [Bash, Read]
version: "1.0.0"
orchestration_class: light-procedural
---

# gaia-brain-health

A read-only browse-on-demand view over the brain knowledge layer. It lists every
indexed artifact that carries **no governance link** — a traceability gap — so a
human can see at a glance where coverage is missing. A gap is a **quality signal,
never a failure**: this view always succeeds even when unlinked nodes are present.

## What it does

For every entry in the knowledge index, the health view re-derives whether the
artifact is linked, using the four-source linked predicate:

1. The artifact's own frontmatter declares what it traces to.
2. The artifact's own frontmatter declares its parent epic.
3. The epics-and-stories registry allocates work to the artifact's key.
4. The traceability matrix maps a requirement or test to the artifact's key.

If **none** of the four holds, the artifact is **unlinked** and is listed as a
gap. The view prints the unlinked nodes in a stable, sorted order with a count.

## Why it re-derives rather than reads a stored flag

The knowledge index does not persist an "unlinked" field on each entry — the
linked predicate is the single source of truth for what counts as linked. The
health view recomputes the verdict through that same predicate every time it
runs, so its answer can never drift from the predicate and needs no change to the
index format. The view is purely read-only: it reads the index and the existing
governance data, and writes nothing.

## How it runs

- **On demand:** invoke `/gaia-brain-health` at any time to browse the current
  traceability gaps — for example after a burst of artifact edits, before a
  sprint review, or whenever you want a quick coverage read.

The view consumes the index produced by the reindex sweep. If the index does not
exist yet, the view says so and points you to rebuild it first — it still exits
cleanly.

## Reading the output

- A node listed here carries no governance link of any kind. The remedy is to add
  traceability — a `traces_to`/`epic` entry in the artifact's frontmatter, an
  allocation row in the epics registry, or a matrix mapping — not to suppress the
  signal.
- An empty list means every indexed artifact is linked.

## Invariants

- **Never fails on a gap.** An unlinked node is surfaced, never raised as an
  error. The view exits cleanly whether or not gaps exist.
- **Read-only.** The view reads the index and governance data and writes nothing.
- **No drift.** The unlinked verdict is recomputed from the linked predicate on
  every run, so it always matches the predicate.
