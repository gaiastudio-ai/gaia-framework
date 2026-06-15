---
name: gaia-knowledge-refresh
description: Re-fetch ingested sources in the Brain knowledge layer and replace only what changed. Hash-gated three-way reconcile -- skip on match, overwrite on diff, mark failed and preserve stale file on fetch error.
argument-hint: "[--fetched-content FILE]"
allowed-tools: [Bash, Read, WebFetch]
orchestration_class: light-procedural
version: "1.0.0"
---

# gaia-knowledge-refresh

`/gaia-knowledge-refresh` walks every ingested entry in the brain index,
re-fetches its source, and applies a hash-gated three-way reconcile so only
changed content touches the disk.

## What it does

For each `source_type: ingested` entry in `brain-index.yaml`:

1. **Re-fetch** -- retrieve the latest version of the source using the same
   fetch+strip machinery that the feed pipeline uses.
2. **Hash compare** -- compute the sha256 of the post-strip body and compare
   it against the stored `content_hash` in the brain-index trust block.
3. **Reconcile** -- apply exactly one of three outcomes:

| Outcome | Condition | Side effects |
|---|---|---|
| **Skip** | Hash matches | No file write. No brain-index mutation. |
| **Overwrite** | Hash differs | Ingested file atomically overwritten. Brain-index entry's `content_hash` and `fetched_at` updated. |
| **Mark failed** | Fetch fails | Ingested file's frontmatter `status` set to `failed`. Stale file content preserved. No destructive delete. |

This three-way reconcile is the core contract. The failure branch preserves the
last-good copy so operators can keep querying stale material while the source is
unavailable.

## Idempotency

A second consecutive run over unchanged sources produces zero file writes and
zero brain-index diffs. This is observable via file mtimes and manifest byte
comparisons. Idempotency comes from the hash-match skip path -- when content has
not changed, the refresh is a no-op.

## Shared library

The fetch, strip, hash, and metadata helpers live in a shared library
(`scripts/brain/lib/ingest-common.sh`) that both `/gaia-feed` and this refresh
lifecycle source. This prevents the two pipelines from drifting apart when
stripping logic, hash computation, or source-kind dispatch changes.

## Atomic write contract

Ingested file overwrites use the same atomic pattern as the feed pipeline:
write to a sibling temporary file and rename into place. A failed write never
corrupts the prior content. Brain-index updates are validated against the schema
before the rename; on failure the prior index is preserved unchanged.

## How to invoke

```
/gaia-knowledge-refresh
```

The orchestration layer fetches each ingested source's URL via `WebFetch`,
writes the content to a temporary file, and invokes the script with
`--fetched-content <path>`. For file-sourced entries the script re-reads the
original file directly.

## Steps (orchestration)

1. Read `brain-index.yaml` and enumerate all `source_type: ingested` entries.
2. For each entry with a `source_url`:
   a. Fetch the current content via `WebFetch` (for URL sources) or direct
      file read (for file sources). Write to a temporary file.
   b. Invoke the refresh script:
      ```bash
      bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain/gaia-knowledge-refresh.sh" \
        --fetched-content <tempfile>
      ```
3. Report the reconcile summary: skipped, updated, and failed counts.
