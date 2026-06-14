---
name: gaia-feed
description: One-gesture external-document ingestion into the Brain knowledge layer. Fetches a URL, local file, or stdin paste, auto-infers slug and tags, writes provenance-stamped markdown under the knowledge store, and registers the entry in the brain index.
argument-hint: "<url-or-path | - for stdin> [--slug SLUG] [--tags TAG1,TAG2] [--ttl DAYS] [--kind url|file|llms_txt|stdin]"
allowed-tools: [Bash, Read, WebFetch]
orchestration_class: light-procedural
version: "1.0.0"
---

# gaia-feed

`/gaia-feed` ingests an external document into the Brain knowledge layer in a
single gesture. Hand it a URL, a local file path, or pipe content via stdin, and
it writes a provenance-stamped markdown file under `.gaia/knowledge/ingested/`
and registers an `ingested` entry in `brain-index.yaml`.

## What it does

A five-stage pipeline runs for every ingestion:

1. **Classify source** -- determine the source kind (`url`, `file`, `stdin`, or
   `llms_txt`).
2. **Fetch** -- read the content. For URLs, the orchestration layer fetches via
   `WebFetch` and passes the result to the script via `--fetched-content`. For
   local files and stdin, the script reads directly.
3. **Strip HTML** -- for URL sources, strip HTML tags and decode entities to
   produce clean markdown. File and stdin sources pass through unchanged.
4. **Write ingested file** -- write the content under
   `.gaia/knowledge/ingested/<slug>.md` with exactly 11 provenance frontmatter
   fields. The write is atomic: a sibling temporary file is written first and
   renamed into place only on success.
5. **Register brain-index entry** -- append (or replace) an `ingested` entry in
   `brain-index.yaml` with a populated trust block. The index is written to a
   temporary file, validated against the index schema, and renamed into place
   only on validation success. On failure, the prior index is preserved
   unchanged.

## Source-kind dispatch

| Source kind | Trigger | Fetch method |
|---|---|---|
| `file` | Path to an existing local file | Direct read |
| `stdin` | `-` as the source argument | Read from stdin |
| `url` | An `http://` or `https://` URL | `WebFetch` (orchestration layer) |
| `llms_txt` | A URL where the `llms-full.txt` probe succeeds | `WebFetch` for the `llms-full.txt` endpoint |

For URL sources, the orchestration runs `WebFetch` to retrieve the content,
writes it to a temporary file, and invokes the script with
`--fetched-content <path>`. The script itself never makes network calls.

### llms-full.txt probe

When the source is a URL, the pipeline first probes for a conventional
`llms-full.txt` endpoint at the base of the URL. If the probe returns a
non-empty response, the pipeline ingests that directly (setting
`ingest_source_kind: llms_txt` and a higher confidence tier) instead of fetching
and stripping the original page. This provides cleaner, LLM-optimized content
when the site publishes it.

## Provenance frontmatter schema

Every ingested file carries exactly 11 frontmatter fields (no extras, no
missing):

| Field | Type | Description |
|---|---|---|
| `title` | string | Document title, auto-inferred from the first heading or filename |
| `slug` | string | URL-safe identifier, auto-inferred or user-supplied via `--slug` |
| `ingest_source_kind` | enum | One of `url`, `file`, `llms_txt`, `stdin` |
| `source_url` | string or null | Origin path/URL; null for stdin |
| `fetched_at` | ISO 8601 | UTC timestamp of the fetch |
| `expires_at` | ISO 8601 | `fetched_at` + `ttl_days` |
| `content_hash` | string | sha256 of the post-strip markdown body |
| `ttl_days` | integer | Time-to-live in days (default 30) |
| `token_estimate` | integer | Rough token count via word count |
| `tags` | list | Auto-inferred tags (source kind, domain signals) |
| `status` | enum | One of `current`, `stale`, `failed` |

## Brain-index registration

The ingested entry in `brain-index.yaml` uses:

- `source_type: ingested` (the existing closed enum; not widened).
- Trust block fields: `confidence` (tiered by source kind), `content_hash`,
  `source_url`, `fetched_at`, `expires_at`.

### Confidence tiering

| Source kind | Confidence |
|---|---|
| `llms_txt` | 0.9 |
| `file` | 0.8 |
| `stdin` | 0.8 |
| `url` | 0.7 |

## Atomic write contract

Both the ingested file and the brain-index update follow the atomic-write
pattern: write to a sibling temporary file, validate (for the index), and rename
into place. A failed write or validation never corrupts the prior state.

## Security handoff

The safe-fetch guard (SSRF blocklist, size cap, timeout) and slug
write-boundary containment are implemented as pass-through seams in this first
version. A downstream story hardens them with real enforcement. The slug
containment guard already rejects path separators and traversal sequences.

## How to invoke

```
/gaia-feed <url-or-path>
/gaia-feed -                     # read from stdin
/gaia-feed --slug my-doc <path>  # explicit slug
/gaia-feed --ttl 60 <url>        # 60-day TTL
/gaia-feed --tags api,reference <path>
```

## Steps (orchestration)

1. Parse the source argument.
2. If the source is a URL, probe for `llms-full.txt` at the base URL via
   `WebFetch`. If the probe returns non-empty content, write it to a temp file
   and invoke the script with `--kind llms_txt --fetched-content <tempfile>`.
3. If the `llms-full.txt` probe did not hit (or the source is not a URL), fetch
   the original content via `WebFetch` (for URLs) and write to a temp file.
4. Invoke the script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain/gaia-feed.sh" \
     [--kind llms_txt] [--fetched-content <tempfile>] \
     [--slug SLUG] [--tags TAGS] [--ttl DAYS] <source>
   ```
   Pass `--kind llms_txt` only when the probe in step 2 succeeded. For all other
   source kinds the script auto-classifies from the source argument.
5. Report the ingested file path and brain-index registration status.
