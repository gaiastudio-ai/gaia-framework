---
name: gaia-brain-query
description: Query the brain knowledge layer's governance envelope for a story key — the related artifacts grouped by direction (UP the governance chain, DOWN to tests and reviews, LATERAL to design) in one read-only invocation. Use when "query the brain", "show the governance envelope", "what governs this story", "what verifies this story", or /gaia-brain-query. Read-only; degrades gracefully and never fails.
allowed-tools: [Bash, Read]
version: "1.0.0"
orchestration_class: light-procedural
---

# gaia-brain-query

A read-only traversal over the brain knowledge layer. From a seed story key it
walks the knowledge index's typed governance edges and returns the node's
**governance envelope** — every related artifact grouped by direction — in a
single invocation. It is the read counterpart to the reindex sweep (which is the
sole writer of the index): this query **writes nothing**.

## The three modes

- **`--envelope` (default):** from a seed key, return the related nodes grouped by
  direction.
- **`--health`:** delegate to the brain health view — the list of unlinked
  artifacts (traceability gaps).
- **`--search <terms>`:** a thin substring search over the indexed synopses,
  returning the matching keys. (Intentionally lightweight — it scans the stored
  synopsis text only; a richer ranked search is a later extension.)

```
/gaia-brain-query <story-key>                 # the governance envelope (default)
/gaia-brain-query <story-key> --envelope      # explicit
/gaia-brain-query --health                    # the unlinked-node view
/gaia-brain-query --search "<terms>"          # synopsis substring search
```

## The governance envelope

For a seed story, the envelope groups the related nodes into three directions:

- **UP** — the governance chain *above* the story: the requirements it
  implements, the decisions that govern it, and its **parent epic**. UP is a
  bounded transitive walk: it follows the story up to its epic, and the
  requirements and decisions that govern it, with a depth cap and a cycle guard
  so the walk always terminates. The walk follows **only** the parent epic — it
  never descends into sibling sub-stories.
- **DOWN** — the artifacts *below* the story: the tests that verify it and the
  reviews that gated it. DOWN is a single hop from the seed.
- **LATERAL** — the design artifacts that sit *alongside* the story. LATERAL is a
  single hop from the seed.

The output is deterministic — grouped by direction, then ordered by a stable
edge-type rank, then by target — so two runs over the same index produce
byte-identical output. The format is plain, grep-able structured text.

## Read-time freshness fall-through

When the query surfaces a node's synopsis, it recomputes the content hash of the
node's canonical file and compares it to the hash the index stamped at index
time. If the file has **changed** since the last reindex, or is **missing**, the
node is marked **stale** and the query surfaces the canonical **path** so you can
read the current bytes directly — the possibly-out-of-date stored synopsis is
never served as if it were current. The query surfaces the path, never the file
contents, so its output stays bounded regardless of file size. A stale node is a
prompt to rerun the reindex sweep; it is never an error.

## Graceful degradation

The query never fails on a partial graph:

- A node with **no edges in a direction** renders a non-error `(no … edges)` line
  for that direction.
- An **unknown key** is reported as an unresolved reference and still exits
  cleanly.
- A **missing index** prints an explanatory line pointing you to rebuild it, and
  still exits cleanly.

## Read-only boundary

The query reads the knowledge index and the artifact and state roots (the latter
only to recompute a canonical file's content hash for the freshness check). It
**never** reads or writes the agent-sidecar memory tree. The boundary holds in
both directions: the ground-truth refresh likewise never reads the knowledge
index. Retrieval is grep, tags, and the index only — there is no vector database,
embedding model, or external search dependency anywhere in this layer.

## Invariants

- **Read-only.** The query reads the index and canonical files and writes
  nothing.
- **Never fails on a partial graph.** Orphan nodes, unknown keys, and a missing
  index all exit cleanly with an explanatory view.
- **Deterministic.** The same index yields byte-identical envelope output across
  runs.
- **Freshness-aware.** A node whose canonical file drifted from the indexed hash
  is surfaced as stale with its path, never served as current.
