---
name: gaia-merge-docs
description: Merge multiple markdown files into a single document — the inverse of shard-doc. Use when "merge documents" or /gaia-merge-docs. Reassembles sharded files in correct order, preserves section numbering and cross-references, maintains consistent heading hierarchy, and emits a single merged Markdown artifact. Native Claude Code conversion of the legacy merge-docs task.
argument-hint: "[source-dir-or-file-list] [output-path]"
allowed-tools: [Read, Write]
orchestration_class: light-procedural
---

## Mission

You are merging multiple Markdown files into a single document. This is the inverse of `/gaia-shard-doc`. Inputs may be (a) a directory of sharded files produced by a previous `shard-doc` run, or (b) an explicit list of file paths. The output is a single Markdown artifact at the user-specified path with consistent heading hierarchy and resolved cross-references.

This skill is the native Claude Code conversion of the legacy merge-docs task at `_gaia/core/tasks/merge-docs.xml`. The legacy 34-line XML body is preserved here as explicit prose. No workflow engine, no engine-specific XML step tags.

## Critical Rules

- **Preserve section numbering and cross-references.** Any numbered section (`## 1. Introduction`, `## 2. Background`) retains its number after merge. Inline cross-references (`see §3.1`) continue to resolve to the correct section in the merged output.
- **Maintain consistent heading hierarchy.** After merge, all top-level headings are at the same level (typically `##` when shards were H2-rooted). Sub-sections nest one level deeper. Never emit a document with inconsistent heading depth.
- **Reassemble in correct order.** For directory inputs, use the filename prefix order (e.g., `01-intro.md`, `02-background.md`, `03-scope.md`). For explicit file lists, use the order provided by the user.
- **Fail fast on an empty input list (AC-EC5).** If no docs are provided (empty directory, empty list), emit `usage: /gaia-merge-docs <input-list>` and exit non-zero. Never produce an empty output artifact.
- **Resolve cross-references to anchors.** File-based links (`[see intro](./01-intro.md)`) are rewritten to section anchors (`[see intro](#intro)`) in the merged artifact — the links must stay valid inside the single merged document.

## Inputs

1. **Source** — from `$ARGUMENTS`. Either (a) a directory containing sharded files or (b) a comma-separated list of file paths.
2. **Output path** — user-specified. If omitted, default to `{source-dir}/merged.md` when input is a directory, or ask the user otherwise.

## Pipeline Overview

The skill runs four steps in strict order, mirroring the legacy `merge-docs.xml`:

1. **Identify Source Files** — resolve inputs, determine correct ordering
2. **Validate Structure** — check heading consistency, identify cross-references
3. **Merge** — reassemble in order, fix cross-refs, add TOC
4. **Output** — confirm target path (normal mode), then write the merged document

## Step 1 — Identify Source Files

- Read `$ARGUMENTS` or prompt the user for the directory or file list to merge.
- If the input is a directory: list all `.md` files and order them by filename prefix (e.g., `01-*`, `02-*`, `_preamble.md` first if present).
- If the input is an explicit list: use the order provided.
- Read every source file into memory (for this step's validation).
- **AC-EC5 — empty input list:** if zero source files are resolved, fail fast with `usage: /gaia-merge-docs <input-list>` and exit non-zero.

## Step 2 — Validate Structure

- Check that heading levels are consistent across files. For example, if shards were H2-rooted, every file should start with `## Heading`. Flag any file starting at a different level.
- Identify cross-references between sections: scan each file for `[text](./other-file.md)` and `see §N` style links.
- Resolve any numbering conflicts: if two files both claim `## 1. Title`, renumber the second occurrence to keep ordering consistent.

## Step 3 — Merge

- Reassemble the files in the order resolved in Step 1.
- Add a document header (title derived from the source directory name or user-provided) and a Table of Contents linking to each section anchor.
- Fix cross-references to use section anchors (`#section-slug`) instead of file links (`./other-file.md`). Every file-based link becomes an in-document anchor link.
- Preserve all content verbatim between headings — the merge is lossless.

## Step 4 — Output

- **Pre-write confirmation (normal mode).** Before calling `Write`, display the resolved output path and ask:
  ```
  Output path: {output-path}
  Proceed with merge to {output-path}? (y/n)
  ```
  Wait for the user's response.
  - If the user answers `y` (or `yes`): proceed to `Write`.
  - If the user answers `n` (or `no`): emit `Merge cancelled by user.` and halt without writing any file.
- **YOLO-mode bypass.** In YOLO mode, skip the confirmation prompt and auto-proceed to `Write`. This aligns with the YOLO Mode Contract — auto-confirm at template-output and auto-skip optional confirmations.
- Write the merged document to the user-specified output path.
- Report the merge summary: number of files merged, total line count, any headings that were renumbered, any cross-references that could not be resolved.

## Slug Algorithm for Anchor IDs

Step 3 rewrites file-based cross-references (`[see intro](./01-intro.md)`) to in-document anchor links (`[see intro](#intro)`). Anchor IDs are derived from heading text using the standard GitHub/Markdown convention:

1. Lowercase the heading text.
2. Replace every run of non-alphanumeric characters (whitespace, punctuation, symbols) with a single hyphen `-`.
3. Collapse consecutive hyphens into a single hyphen.
4. Trim leading and trailing hyphens.

Equivalent JavaScript:

```javascript
heading_text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
```

**Examples:**

| Heading | Anchor ID |
|---------|-----------|
| `## 1. Introduction` | `#1-introduction` |
| `## 3. API Design Patterns` | `#3-api-design-patterns` |
| `## API Design Patterns` | `#api-design-patterns` |
| `## C++ / Rust Interop` | `#c-rust-interop` |

This is the same algorithm used across GAIA for anchor generation; it matches GitHub's Markdown rendering of headings, ensuring merged documents render with working in-page links on GitHub, GitLab, and most static-site generators.

## Edge Cases

- **AC-EC5 — empty input list:** fail fast with `usage: /gaia-merge-docs <input-list>`; no empty output artifact.
- **Duplicate heading IDs:** append a `-2`, `-3` suffix to the anchor ID to maintain link uniqueness.
- **Missing files in a declared file list:** report each missing file as a warning; continue the merge with the files that do exist.

## References

- Legacy source: `_gaia/core/tasks/merge-docs.xml` (34 lines) — feature-parity reference.
- Inverse operation: `/gaia-shard-doc`. A merge→shard→merge round trip on the same content should yield byte-equivalent output.
- Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- Scripts-over-LLM for Deterministic Operations.
- Program-close deletion policy for legacy engine/workflows/tasks.
- Inline-Ask vs Fail-Fast Contract (pre-write confirmation extends the inline-ask convention to the output step).
- YOLO Mode Contract (auto-skip optional confirmations at template-output).
- Native Skill Format Compliance.
- Functional parity with the legacy task.
- Reference implementation: `plugins/gaia/skills/gaia-fix-story/SKILL.md`.
