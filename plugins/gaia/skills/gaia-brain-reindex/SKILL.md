---
name: gaia-brain-reindex
description: Rebuild the brain knowledge layer's index from source — a full, correct-by-construction sweep of the project's artifact and state trees. Use when "reindex the brain", "rebuild the knowledge index", or /gaia-brain-reindex. Runs automatically as a best-effort pass at sprint-close and is available on demand at any time.
allowed-tools: [Bash, Read]
version: "1.0.0"
orchestration_class: light-procedural
---

# gaia-brain-reindex

The reindex sweep is the **sole writer** of the brain knowledge layer's index.
It walks the project's source trees, derives a typed-edge graph of how the
artifacts relate, stamps every entry with a content-integrity hash, and writes
the index atomically. Because every run regenerates the whole index from the
files on disk, hand-tampering never persists and synopses never silently drift.

## What it does

For each artifact it discovers, the sweep:

1. Computes the file's content hash.
2. If the index already carries that exact hash for the artifact, carries the
   prior synopsis and edges forward unchanged — no re-work for unchanged files.
3. Otherwise generates a fresh one-paragraph synopsis and harvests the
   artifact's typed governance edges from the project's existing planning data.
4. Records the entry — key, relative path, tags, synopsis, edges, and a trust
   block carrying the content hash.

It then writes the whole index in one atomic step: the new index is staged in a
sibling temporary file next to the live index, validated against the index
schema, and only then renamed into place. A concurrent reader never sees a
partial index, and if validation fails the previous index is left exactly as it
was.

## Source scope (read-only boundary)

The sweep reads from exactly two trees and writes to exactly one:

- **Reads:** the artifacts tree (planning, implementation, test, creative, and
  research artifacts) and the state tree (sprint status, the epics-and-stories
  registry, and other runtime state).
- **Writes:** only the knowledge store. The index is the single file it writes.

The sweep is a **read-only consumer** of everything it indexes — it never
modifies an artifact or a state file, and it never copies an artifact's bytes
into the knowledge store; entries point at each file in place.

The sweep does **not** read or write the agent-sidecar working-memory tree, the
configuration tree, or the user-extension tree. The agent sidecars in particular
are private, per-agent working memory owned by their agents and maintained by a
separate ground-truth refresh flow; the brain index is a distinct, project-wide
governance index. The two are independent subsystems and neither substitutes for
the other. This boundary is enforced by construction: the sweep enumerates only
the artifacts and state trees, so a sidecar file can never enter the index.

## Three-layout tolerance

The framework has used three story-file layouts over its history — a flat layout,
a per-epic-nested layout, and a per-story-directory layout. The sweep discovers
stories across all three and tolerates a project that mixes them. When the same
story key appears in more than one layout, the highest-precedence layout wins and
a single entry is emitted for that key.

## How it runs

- **On demand:** invoke `/gaia-brain-reindex` at any time to refresh the index —
  for example after a burst of mid-sprint artifact edits.
- **At sprint-close:** the close ceremony runs a reindex as a **best-effort,
  non-blocking** pass. The sprint's primary outcome must never be blocked by a
  knowledge-index rebuild, so a reindex failure emits a warning and the close
  continues.

## Synopsis generation

The synopsis is a deterministic extract of each artifact — its first heading plus
its first line of prose, falling back to the filename. This keeps a large sweep
well within its time budget; a richer, model-generated synopsis is a documented
later extension.

## Invariants

- **Sole writer.** Only this sweep writes the index. No other flow may write it.
- **Atomic write.** The index is replaced in one rename; no partial index is ever
  visible.
- **Correct by construction.** Every run rebuilds the whole index from source —
  the index always matches the files on disk after a run.
- **Content-integrity hashes.** Every entry carries the hash of its source file
  at synopsis time, so a downstream consumer can detect a stale synopsis.
