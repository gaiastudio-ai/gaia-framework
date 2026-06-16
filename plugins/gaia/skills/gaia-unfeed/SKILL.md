---
name: gaia-unfeed
description: Remove an ingested document from the Brain knowledge layer. Deletes the ingested file and de-registers its brain-index entry atomically.
argument-hint: "<slug>"
allowed-tools: [Bash, Read]
orchestration_class: light-procedural
version: "1.0.0"
---

# gaia-unfeed

`/gaia-unfeed` removes an ingested document from the Brain knowledge layer in a
single gesture. Hand it the slug of a previously-ingested document, and it
deletes the file under `.gaia/knowledge/ingested/` and de-registers the matching
`ingested` entry from `brain-index.yaml`.

This is the sanctioned inverse of `/gaia-feed`: where feed writes and registers,
unfeed deletes and de-registers. It is the only supported way to remove an
ingested source. Do not hand-edit the knowledge files directly.

## What it does

A three-stage pipeline runs for every removal:

1. **Validate and locate** -- confirm the slug is well-formed (no path traversal,
   no escapes), look it up in `brain-index.yaml`, and verify it is a
   `source_type: ingested` entry. Only ingested entries are eligible;
   project-artifact and lesson entries are never touched.
2. **De-register the index entry** -- remove the matching entry from
   `brain-index.yaml`. The updated index is written to a sibling temporary file,
   validated against the index schema, and renamed into place only on validation
   success. On failure, the prior index is preserved byte-unchanged.
3. **Delete the ingested file** -- remove
   `.gaia/knowledge/ingested/<slug>.md` from disk, but only after a realpath
   containment check confirms the file is inside the ingested directory.
4. **Re-render the human index** (best-effort) -- update `brain-index.md` (the
   human-readable Map of Content) so the removed entry no longer appears.

## When to use it

- You ingested a document you no longer need in the knowledge layer (wrong
  source, outdated version, duplicate).
- You want to stop using a previously ingested reference and remove it from
  brain queries.
- You want to clean up a stale or failed ingestion that will never be refreshed.

**Do not use** `/gaia-unfeed` to update an existing source. To replace a document
with a newer version, re-run `/gaia-feed` with the same `--slug` -- the existing
entry is overwritten without needing to unfeed first.

## How to invoke

```
/gaia-unfeed my-api-docs
```

Pass the slug of the ingested document to remove. This is the same slug shown in
the ingested file's frontmatter and in the brain-index entry key.

## Steps (orchestration)

1. Parse the slug argument.
2. Invoke the script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain/gaia-unfeed.sh" "<slug>"
   ```
3. Report the removal status.

## Safety guarantees

- **Idempotent.** If the slug is not present in the brain index, the command
  exits cleanly as a no-op with a "nothing to remove" message. Running it twice
  has the same effect as running it once.
- **Ingested entries only.** The command only ever removes entries with
  `source_type: ingested`. Project-artifact entries (stories, architecture
  decisions, epics, etc.) and lesson entries are never modified or deleted.
- **Slug containment (two-layer).** The slug is first checked at the character
  level for path separators and traversal sequences. Then the resolved file path
  is verified via realpath to be a child of `.gaia/knowledge/ingested/` before
  any unlink. A symlink escape is caught by the realpath layer.
- **Atomic index update.** The brain-index is written to a temporary file,
  validated against the schema, and renamed into place. A failed validation
  preserves the prior index byte-unchanged and the ingested file is NOT deleted.

## Troubleshooting

### The slug is not found

The command exits cleanly as a no-op. Verify the slug matches what is in the
brain index (check `brain-index.yaml` or the file under
`.gaia/knowledge/ingested/`).

### Brain-index validation failed

The updated index did not pass schema validation after removing the entry. The
prior index is preserved unchanged and the ingested file is NOT deleted. Check
the error message for details.

### How do I update a source instead of removing it?

Use `/gaia-feed` with the same `--slug`. The existing entry is overwritten
cleanly without needing to unfeed first.

## Related commands

| Command | Relationship |
|---|---|
| `/gaia-feed` | Ingests a document into the knowledge layer. The inverse of `/gaia-unfeed`. |
| `/gaia-knowledge-refresh` | Re-fetches all ingested sources. Does not remove entries. |
| `/gaia-brain-reindex` | Rebuilds the project-artifact index. Preserves ingested entries. |
| `/gaia-brain-query` | Query the brain to verify a document has been removed. |
