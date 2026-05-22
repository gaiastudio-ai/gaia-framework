---
name: gaia-shard-doc
description: Split a large Markdown document into smaller files based on level-2 (H2) sections. Use when "shard this document" or /gaia-shard-doc. Preserves every byte of content, generates a linking index.md, and asks for user confirmation before writing files. Default split level is H2 — user can override to H1 or H3. Native Claude Code conversion of the legacy shard-doc task (E28-S111, Cluster 14).
argument-hint: "[source-file] [--level=H1|H2|H3]"
allowed-tools: [Read, Write, Bash]
orchestration_class: light-procedural
---

## Mission

You are splitting one large Markdown document into multiple smaller shard files, one per section at the chosen heading level. The output is a directory named after the source file (without extension) containing the shards plus an `index.md` that links to each one. The default split level is `H2` (`##`); users may override to `H1` or `H3` via `$ARGUMENTS`.

This skill is the native Claude Code conversion of the legacy shard-doc task at `_gaia/core/tasks/shard-doc.xml` (brief Cluster 14, story E28-S111). The legacy 49-line XML body is preserved here as explicit prose per ADR-041. No workflow engine, no engine-specific XML step tags.

## Critical Rules

- **Default split level is H2 (`##`) — user can override to H1 or H3.** Pass `--level=H1` or `--level=H3` in `$ARGUMENTS`. Any other value fails with `shard-doc: invalid level '{value}' — expected H1, H2, or H3`.
- **Preserve ALL content — never drop text between sections.** Any content before the first split-level heading becomes `_preamble.md`. Every character of the source document must land in exactly one shard file.
- **Generate an index.md linking to all shards.** The index sits alongside the shard files inside the output directory and links to each shard with its heading text as the anchor.
- **Ask user for confirmation before writing files.** Show the preview plan (file list + line counts per shard) and wait for user confirmation. In YOLO or non-interactive mode, auto-proceed after previewing.
- **Handle the zero-headings edge case gracefully (AC-EC4).** If the source document contains zero headings at the split level (e.g., flat prose with no `##`), emit the message `no shard boundaries detected` and exit cleanly with zero shards written. Do NOT create empty shard files or an empty output directory.
- **Heading detection MUST be code-block-aware (E53-S236, ADR-070).** When scanning for split-level headings, maintain a fenced-code-block state machine: any line whose first three characters are a backtick fence (` ``` `) toggles "inside code block" state, and `## ` (or `# ` / `### ` per `--level`) lines encountered while inside that state MUST be ignored. The deterministic implementation lives at `scripts/parse-h2-boundaries.sh` (default H2 level); never re-implement the toggle inline. A naive line-based scanner that omits this state machine produces false boundaries on any document containing fenced markdown examples (originally surfaced as E53-S222 finding #4 against `architecture.md`, where 14 of 32 candidate boundaries fell inside fenced code blocks).

## Inputs

1. **Source file** — from `$ARGUMENTS`. If `$ARGUMENTS` is empty, ask the user inline: "Which file should I shard?" and use the response as the source file path. Otherwise, use `$ARGUMENTS` as the target. This follows the inline-ask contract per ADR-066.
2. **Split level** — optional, via `--level=H1|H2|H3`. Default: `H2`. The level flag is parsed independently of the source-file argument; if the user supplies `--level=H3` with no source file, still ask "Which file should I shard?" inline.

**YOLO-mode interaction.** Per ADR-067, inline-ask on empty `$ARGUMENTS` is an open-question indicator — YOLO mode HALTS here for user input. There is no safe default target file, so the user must provide one. This differs from the Step 3 (Preview Plan) confirmation prompt, which IS auto-proceeded in YOLO mode.

## Pipeline Overview

The skill runs five steps in strict order, mirroring the legacy `shard-doc.xml`:

1. **Load Source** — read and count
2. **Parse Sections** — identify split boundaries, derive filenames
3. **Preview Plan** — show the plan and confirm
4. **Write Shards** — create the output directory and emit each shard + index
5. **Report** — summarize shards created

## Step 1 — Load Source

- Resolve the source file path from `$ARGUMENTS`. If `$ARGUMENTS` is empty, ask the user inline: "Which file should I shard?" and use the response as the source file path (per ADR-066). In YOLO mode, this inline-ask still halts for input — there is no safe default file (per ADR-067).
- Read the entire source file; count total lines and sections at each heading level.

## Step 2 — Parse Sections

- Identify all sections at the split level (default `##`; overridable via `--level`). For the default H2 level, delegate boundary detection to `scripts/parse-h2-boundaries.sh <source_file>` — the helper emits one `<line_number>:<heading_text>` line per real H2 boundary and is code-block-aware per the Critical Rule above. For the H3 level, delegate the entire shard-emit pipeline (boundary detection + per-section file write + `index.md` + `_preamble.md`) to `scripts/h3-shard.sh --input <source_file> --output-dir <out_dir>` — the helper produces the H3 shards, an `index.md` table of contents, and an optional `_preamble.md` in one call. For H1 overrides, apply the same toggle-on-` ``` ` state machine inline (or extend the helper) — never use a naive `grep -E '^# '` scan.
- **Preamble:** any content before the first split-level heading becomes `_preamble.md`. If there is no content before the first heading, omit the preamble file.
- Generate a filename for each section from its heading text:
  1. Lowercase
  2. Replace spaces and punctuation with hyphens
  3. Remove special characters (anything not alphanumeric or hyphen)
  4. Collapse multiple consecutive hyphens into a single hyphen
  5. Trim leading / trailing hyphens
  6. Prefix with zero-padded section number: `01-section-name.md`, `02-next-section.md`
- **AC-EC4 — zero headings at the split level:** if the source contains no split-level headings, emit `no shard boundaries detected` and exit cleanly. Do NOT create an empty output directory.

## Step 3 — Preview Plan

- Show the user the planned file list with per-file line counts:
  ```
  _preamble.md              12 lines
  01-introduction.md        48 lines
  02-architecture.md        94 lines
  ...
  index.md                   N lines (auto-generated)
  ```
- Ask for confirmation. If the user adjusts the plan (renames, reorders, merges shards), update accordingly.
- In YOLO or non-interactive mode, proceed after displaying the preview.

## Step 4 — Write Shards

- Create the output directory — same path as the source file with the extension stripped (e.g., `.gaia/artifacts/planning-artifacts/prd.md` → `.gaia/artifacts/planning-artifacts/prd/`). Use `!` inline bash for `mkdir -p` per ADR-042.
- **Before writing each shard, invoke the sub-shard preservation guard** (E53-S250 / FR-453). For every shard slug about to be emitted, run:

  ```bash
  bash ${CLAUDE_PLUGIN_ROOT}/skills/gaia-shard-doc/scripts/check-sub-shard-conflict.sh \
      "<slug>" "<out_dir>" --summary-file "<summary_file>"
  ```

  The helper returns exit 0 (safe — proceed with the shard write) or exit 2 (preserve — skip this shard's body emit; the existing marker shard at `<out_dir>/<slug>.md` is preserved byte-identical). On exit 2 the helper has already emitted the preserve signal on three channels (stdout, stderr WARNING, summary file). The caller MUST NOT write to `<out_dir>/<slug>.md` for that slug — doing so would clobber the user-authored marker stub.

- Write each shard file: the section heading becomes the first line of the shard, and every line from that heading through the line before the next split-level heading goes into the shard. SKIP this write when the guard returned exit 2 for the slug.
- Write `index.md` with a table of contents linking every shard with its heading text, sorted by the numeric prefix. Preserved slugs ARE listed in the index (the marker stub at `<slug>.md` is still a navigable entry point).

## Step 5 — Report

- Report: number of shards created, total lines distributed (verify it equals the source line count — parity check), whether `_preamble.md` was emitted.
- **Preserved sub-shards aggregation (E53-S250 AC11):** if the Step-4 guard fired for any slug, read the summary file and emit a `Preserved sub-shards: <count>` line listing each preserved slug. When ≥1 section was preserved, the overall skill exit code is **2** (advisory, distinct from exit 0 clean run and non-zero hard error). Bats coverage in `tests/check-sub-shard-conflict.bats` asserts all three signal channels and the exit-code-2 contract.
- Suggest running `/gaia-index-docs` on the parent directory to update the folder-level index, if one exists.

## Sub-shard directories

The marker-shard + sibling-directory pattern (introduced by E53-S235, sprint-37) is a second-tier sharding model: a single H2 section that has grown unwieldy is split into a sibling directory of per-H3 child files. The parent shard `<NN>-<slug>.md` retains a stub heading `## <N>. <title> — Sub-Sharded` plus a pointer paragraph into the directory.

**`/gaia-shard-doc` recognises this pattern and refuses to destroy it.** When the Step-4 guard (`check-sub-shard-conflict.sh`) detects an existing sibling directory `<out_dir>/<slug>/` containing ≥1 content shard matching `<NN>-*.md`, it:

1. Skips emitting that section's body (preserves the existing marker stub byte-identical).
2. Emits the preserve signal on three channels — stdout, stderr `WARNING:`, and the Step-5 summary file aggregation.
3. Exits with code 2 (advisory) when ≥1 section was preserved.

**Detection gate (E53-S250 / AC12):** the guard counts CONTENT shards only — files matching the canonical pattern `<NN>-*.md` (two-digit numeric prefix). Meta files (`index.md`, `_preamble.md`, dotfiles) are ignored. A meta-only directory means the user manually deleted all content shards intending to re-shard — the guard is a no-op in that case and `/gaia-shard-doc` re-shards normally.

**No programmatic destruction path (E53-S250 / AC10):** there is NO `--force-destroy` flag. Refusal is absolute. If a sub-shard directory must be flattened back into a single shard, use the documented manual two-step workflow:

```bash
/gaia-merge-docs <sibling_dir> > <slug>.md && rm -rf <sibling_dir>
# Then re-run /gaia-shard-doc on the parent monolith.
```

This makes the destructive step explicit and user-authored, not buried in the shard-doc pipeline. See E53-S235 (sub-shard introduction) and TC-MSS-SUBSHARD-6..9 + TC-MSS-SUBSHARD-NEW (verification) for the contract details.

## Edge Cases

- **AC-EC4 — zero headings at the split level:** emit `no shard boundaries detected`; do not create any shard files; do not create the output directory.
- **Source file not found:** fail fast with a clear message.
- **Output directory already exists:** overwrite its contents after user confirmation. A byte-level diff on repeated runs of the same source must produce zero changes.
- **Heading slug collision:** if two sections produce the same slug, disambiguate with `-2`, `-3` suffixes.

## References

- Legacy source: `_gaia/core/tasks/shard-doc.xml` (49 lines) — parity reference for NFR-053.
- Inverse operation: `/gaia-merge-docs`.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations (inline `!` bash for `mkdir`).
- ADR-048 — Program-close deletion policy for legacy engine/workflows/tasks.
- ADR-070 — Auto-sharding policy; code-block-aware H2 detection contract enforced by `scripts/parse-h2-boundaries.sh` (E53-S236).
- E53-S245 — H3 shard pipeline lives at `scripts/h3-shard.sh`; flag CLI is `--input <file> --output-dir <dir>`. Emits per-section shards, `index.md`, and an optional `_preamble.md`. Idempotent across repeated runs (byte-identical output).
- FR-323 — Native Skill Format Compliance.
- NFR-053 — Functional parity with the legacy task.
- Reference implementation: `plugins/gaia/skills/gaia-fix-story/SKILL.md`.
- Byte-identity baseline: `_memory/checkpoints/E53-S222-shard-architecture.py::find_h2_boundaries` (the working code-block-aware parser AC3 of E53-S236 mandates parity with).
