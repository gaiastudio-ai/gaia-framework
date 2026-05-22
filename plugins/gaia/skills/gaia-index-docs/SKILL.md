---
name: gaia-index-docs
description: Generate or update an index.md file that references every document in a target folder. Use when "index these docs" or /gaia-index-docs. Scans .md/.xml/.yaml/.csv files in a target folder, reads titles, sorts logically, and emits a Markdown index with a linked table of contents. Native Claude Code conversion of the legacy index-docs task (E28-S111, Cluster 14).
argument-hint: "[target-folder]"
allowed-tools: [Read, Write, Grep]
orchestration_class: light-procedural
---

## Mission

You are generating a navigable Markdown index for a documentation folder. The target folder is passed as `$ARGUMENTS`. If `$ARGUMENTS` is empty, ask the user inline "Which folder should I index?" and use the response as the target folder (per ADR-066 inline-ask contract). Do NOT exit, do NOT print a usage message, do NOT default silently to the current working directory. The output is `{target-folder}/index.md` with a title, file-count summary, linked table of contents, and a last-updated timestamp.

This skill is the native Claude Code conversion of the legacy index-docs task at `_gaia/core/tasks/index-docs.xml` (brief Cluster 14, story E28-S111). The legacy 46-line XML body is preserved here as explicit prose per ADR-041 (Native Execution Model). No workflow engine, no engine-specific XML step tags.

## Critical Rules

- **Scan ALL files in the target folder — never skip any.** Every `.md`, `.xml`, `.yaml`, and `.csv` file under the target root must appear in the index.
- **Inline-ask on empty `$ARGUMENTS` — never fail-fast on missing target folder argument.** When `$ARGUMENTS` is empty, ask the user inline "Which folder should I index?" and use the response as the target folder (per ADR-066). Do NOT exit with a usage message; do NOT default silently to the current working directory. The inline-ask is an open-question indicator: in YOLO mode it MUST pause for user input (per ADR-067) — there is no safe default target folder for indexing.
- **Scan-depth convention is "top-level + one level deep" — deliberate, not a limitation.** This is a documented design choice inherited from the legacy `index-docs.xml` task. Users who need deeper hierarchies should invoke `/gaia-index-docs` on the relevant subdirectory rather than expecting recursive scanning.
- **Preserve existing manual entries in index.md if present.** If the target folder already contains an `index.md`, read it first and keep any manual sections (anything outside the auto-generated table of contents region).
- **Use relative paths in all links.** Links must resolve from the index file's own location — never absolute paths, never `{project-root}`-style tokens.
- **Fail fast when the target folder does not exist on disk.** Once a target folder has been resolved (from `$ARGUMENTS` or the inline-ask response), if the folder does not exist on disk, emit `index-docs: target folder '{folder}' not found` and exit non-zero. Do NOT create the folder. The existence check applies AFTER the inline-ask resolves a folder path — the inline-ask itself never fails-fast on empty input.
- **Handle the zero-markdown edge case gracefully (AC-EC6).** If the target folder exists but contains zero `.md`/`.xml`/`.yaml`/`.csv` files, emit an `index.md` with a clear `no markdown files found under {folder}` note. Never crash; never produce an empty file.

## Inputs

1. **Target folder** — from `$ARGUMENTS` when invoked via `/gaia-index-docs {folder}`. If `$ARGUMENTS` is empty, ask the user inline: "Which folder should I index?" and use the response as the target folder (per ADR-066 inline-ask contract). Do NOT print a usage message; do NOT silently default to the current working directory. In YOLO mode, this inline-ask is an open-question indicator and MUST HALT for user input (per ADR-067) — no safe default target folder exists.

**Scan-depth convention.** The skill scans the target folder **top-level plus one level deep** — deeper recursion is intentionally out of scope. This is a deliberate scope boundary inherited from the legacy `index-docs.xml` task, not a limitation to fix. To index a deeper hierarchy, run `/gaia-index-docs` on the specific subdirectory you want indexed.

## Pipeline Overview

The skill runs five steps in strict order, mirroring the legacy `index-docs.xml`:

1. **Identify Target** — resolve and verify the target folder exists
2. **Scan Files** — enumerate all indexable files, extract titles
3. **Check Existing Index** — preserve manual sections if index.md exists
4. **Generate Index** — emit the linked table of contents
5. **Report** — show the generated index and highlight untitled files

## Step 1 — Identify Target

- Resolve the target folder from `$ARGUMENTS`. If `$ARGUMENTS` is empty, ask the user inline: "Which folder should I index?" and use the response as the target folder path (per ADR-066). Do NOT exit, do NOT print a usage message — the inline-ask is the contract. In YOLO mode, this is an open-question indicator: pause and wait for explicit user input rather than auto-proceeding (ADR-067) — there is no safe default target folder.
- If `$ARGUMENTS` is provided, use it directly as the target folder with no prompt (preserve the explicit-argument happy path).
- Verify the resolved folder exists on disk via a `Read` or `!ls` probe.
- If the folder does not exist: fail fast with `index-docs: target folder '{folder}' not found`. This existence check runs AFTER the target has been resolved (whether from `$ARGUMENTS` or the inline-ask response) — the inline-ask itself never triggers this fail-fast.

## Step 2 — Scan Files

- List all `.md`, `.xml`, `.yaml`, `.csv` files in the target folder. **Scan depth: top-level plus one level deep.** Deeper recursion is intentionally out of scope — see the Inputs section for the rationale and the subdirectory-invocation guidance. To index files nested more than one level under the target, invoke `/gaia-index-docs` on the relevant subdirectory.
- For each file, read the first 5 lines to extract a title or purpose:
  - For Markdown: the first `# Heading` line, falling back to the first non-blank line.
  - For XML: a `name=` attribute on the root element, falling back to the filename.
  - For YAML: a top-level `title:` or `name:` field, falling back to the filename.
  - For CSV: the first header row, falling back to the filename.
- If a file has no discernible title: record `(no title)` and flag it for the report in Step 5.
- Sort files by logical order: `README.md` (or `README`) first if present, then alphabetical by filename.

## Step 3 — Check Existing Index

- If `{target-folder}/index.md` already exists: read it in full.
- Identify any **manual sections** (anything outside the auto-generated region between `<!-- index-docs: START -->` and `<!-- index-docs: END -->` markers). Preserve those sections verbatim.
- If no `index.md` exists: proceed to generate one from scratch.

## Step 4 — Generate Index

Write `{target-folder}/index.md` with the following layout:

```markdown
# {Folder Title}

> {N} documents indexed. Last updated: {YYYY-MM-DD}

{preserved manual sections, if any}

<!-- index-docs: START -->

## Table of Contents

- [README](./README.md) — {extracted title or "Folder overview"}
- [{title}](./{filename}) — {extracted title}
- ...

<!-- index-docs: END -->
```

- Derive `{Folder Title}` from the folder name (snake-case or kebab-case → Title Case; e.g., `planning-artifacts` → "Planning Artifacts").
- Use relative paths in every link (e.g., `./prd.md`, never `/.gaia/artifacts/planning-artifacts/prd.md`).
- Include the last-updated timestamp in `YYYY-MM-DD` format.
- Emit the full table of contents between the START/END markers so future re-runs regenerate only that region.

## Step 5 — Report

- Show the user the path to the generated index (`{target-folder}/index.md`) and summarize what changed.
- Report: files indexed (count), any files with missing titles (flagged in Step 2), whether existing manual sections were preserved.

## Edge Cases

- **AC-EC6 — zero markdown files:** folder exists but has no indexable files. Emit `index.md` with the note "no markdown files found under {folder}" in the Table of Contents region. Do NOT crash; do NOT omit the file.
- **Folder does not exist:** fail fast with a clear message; do not create the folder.
- **Existing index.md has manual sections:** preserve every line outside the START/END markers verbatim; merge the new auto-generated region inside the markers.

## References

- Legacy source: `_gaia/core/tasks/index-docs.xml` (46 lines) — parity reference for NFR-053.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations.
- ADR-048 — Program-close deletion policy for legacy engine/workflows/tasks (legacy XML preserved until Cluster 18/19).
- FR-323 — Native Skill Format Compliance.
- NFR-053 — Functional parity with the legacy task.
- Reference implementation: `plugins/gaia/skills/gaia-fix-story/SKILL.md` (canonical Cluster 7/14 shape).
