---
name: gaia-create-stakeholder
description: Scaffold a new stakeholder file for Party Mode with YAML frontmatter (name, role, expertise, personality, optional perspective/tags) plus a Background section. Use when "create a stakeholder" or /gaia-create-stakeholder. Writes to custom/stakeholders/, enforces the 50-file cap and 100-line per-file limit, and rejects duplicate names case-insensitively. Native Claude Code conversion of the legacy create-stakeholder workflow (E28-S111, Cluster 14).
argument-hint: "[name]"
allowed-tools: [Read, Write, Bash]
orchestration_class: light-procedural
---

## Mission

You are scaffolding a new stakeholder file under `custom/stakeholders/`. The file is consumed by `/gaia-party` — Party Mode discovers stakeholders by scanning that directory pattern. Every stakeholder has a persona (name, role, expertise, personality) and optional viewpoint / tag metadata.

This skill is the native Claude Code conversion of the legacy create-stakeholder workflow at `_gaia/lifecycle/workflows/4-implementation/create-stakeholder/instructions.xml` (brief Cluster 14, story E28-S111). The legacy 79-line XML body is preserved here as explicit prose per ADR-041. No workflow engine, no engine-specific XML step tags.

## Critical Rules

- **Stakeholder files are written to `custom/stakeholders/` — never to `_gaia/`.** The framework tree is read-only for this skill. `custom/stakeholders/` is a user-authored directory that survives framework upgrades.
- **The 50-file cap and 100-line per-file limit are hard gates (FR-164).** Reject creation when the directory already has 50 files; trim the Background section to stay under 100 lines.
- **Duplicate name detection is case-insensitive against the `name:` frontmatter field (FR-157).** "Maria Santos" collides with "maria santos" and "MARIA SANTOS".
- **Never overwrite an existing stakeholder (AC-EC8).** If the name or filename slug collides with an existing file, refuse to overwrite. Offer a suffix (`-2`, `-3`) or ask the user to pick a different name. The existing sidecar stays untouched.
- **Preserve the sidecar path convention.** Stakeholder files go to `custom/stakeholders/{slug}.md`. No other path. `/gaia-party` discovers them by scanning this exact directory.

## Inputs

1. **Name** (required, display name, e.g., "Maria Santos")
2. **Role** (required, title / function, e.g., "Housekeeper Manager")
3. **Expertise** (required, domain skills, e.g., "Room turnover logistics")
4. **Personality** (required, traits, e.g., "Pragmatic, detail-oriented")
5. **Perspective** (optional, viewpoint / biases)
6. **Tags** (optional, comma-separated, e.g., "operations, hospitality")

The name may be passed via `$ARGUMENTS`; the other fields are collected interactively.

## Pipeline Overview

The skill runs six steps in strict order, mirroring the legacy `create-stakeholder/instructions.xml`:

1. **Ensure Directory Exists** — create `custom/stakeholders/` if missing
2. **Collect Required Inputs** — name, role, expertise, personality
3. **Collect Optional Inputs** — perspective, tags
4. **Validate Against Cap and Duplicates** — 50-file cap + case-insensitive duplicate check
5. **Generate Filename Slug** — kebab-case
6. **Generate and Write Stakeholder File** — YAML frontmatter + Background

## Step 1 — Ensure Directory Exists

- Check whether `custom/stakeholders/` exists.
- If missing, create it (and `custom/` as needed) via inline `!mkdir -p custom/stakeholders` (ADR-042).
- Confirm the directory is ready for writing.

## Step 2 — Collect Required Inputs

Prompt the user for all four required fields:

- **Name** (display name, e.g., "Maria Santos"):
- **Role** (title / function, e.g., "Housekeeper Manager"):
- **Expertise** (domain skills, e.g., "Room turnover logistics"):
- **Personality** (traits, e.g., "Pragmatic, detail-oriented"):

If any required field is empty: HALT with `All four fields (name, role, expertise, personality) are required. Please provide all values.`

## Step 3 — Collect Optional Inputs

Prompt the user (press Enter to skip):

- **Perspective** (viewpoint / biases, e.g., "Focuses on operational efficiency"):
- **Tags** (comma-separated, e.g., "operations, hospitality"):

## Step 4 — Validate Against Cap and Duplicates

- Count existing `.md` files in `custom/stakeholders/`.
- **50-file cap:** if the count is ≥ 50, HALT: `The 50-file cap has been reached in custom/stakeholders/ (FR-164). There are already {count} stakeholder files. Remove unused stakeholders before creating new ones.`
- Scan all existing stakeholder files — read the `name:` field from each file's YAML frontmatter.
- Compare each existing name against the new name using **case-insensitive** comparison.
- **AC-EC8 — duplicate detection:** if a case-insensitive match is found, HALT: `A stakeholder with the name "{existing_name}" already exists at custom/stakeholders/{existing_file}. Name collision detected (case-insensitive). Choose a different name (e.g., suffix -2) or remove the existing file.`

## Step 5 — Generate Filename Slug

Convert the stakeholder name to a kebab-case slug:

1. Convert to lowercase
2. Replace spaces with hyphens
3. Strip all characters that are not alphanumeric or hyphens
4. Collapse multiple consecutive hyphens into a single hyphen
5. Trim leading / trailing hyphens
6. Append `.md`

Examples:
- "Maria Santos" → `maria-santos.md`
- "Jean-Pierre O'Brien III" → `jean-pierre-obrien-iii.md`

Output path: `custom/stakeholders/{slug}.md`.

If a file already exists at the resolved output path (slug collision from a different display name): HALT with `File custom/stakeholders/{slug}.md already exists. This may indicate a slug collision from a different display name. Choose a different name or remove the existing file.`

## Step 6 — Generate and Write Stakeholder File

Write the stakeholder file with YAML frontmatter and a Markdown Background section:

```markdown
---
name: "{name}"
role: "{role}"
expertise: "{expertise}"
personality: "{personality}"
perspective: "{perspective}"    # Only include if provided in Step 3
tags: [{tags_as_yaml_array}]    # Only include if provided in Step 3
---

## Background

{A 2-3 sentence description synthesized from the provided fields, describing this stakeholder's viewpoint and discussion style.}
```

- Verify the generated file does not exceed **100 lines**. If it would, trim the Background section to fit within the limit.
- Write to `custom/stakeholders/{slug}.md` via the `Write` tool.
- Report: `Stakeholder '{name}' created at custom/stakeholders/{slug}.md. /gaia-party will pick it up on the next run.`

## Edge Cases

- **AC-EC8 — name collision with existing stakeholder:** refuse to overwrite; offer a suffix (`-2`, `-3`) or ask the user to pick a different name; the existing sidecar is untouched.
- **50-file cap reached:** HALT with the count and guidance to remove unused stakeholders first.
- **100-line limit:** trim the Background section as needed; never emit a file over 100 lines.

## References

- Legacy source: `_gaia/lifecycle/workflows/4-implementation/create-stakeholder/instructions.xml` (79 lines) — parity reference for NFR-053.
- Downstream consumer: `/gaia-party` (Party Mode) — discovers stakeholders by scanning `custom/stakeholders/*.md`.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations (inline `!` bash for `mkdir`).
- ADR-048 — Program-close deletion policy for legacy engine/workflows/tasks.
- FR-157 — Duplicate-name case-insensitive rejection.
- FR-164 — 50-file cap and 100-line per-file limit.
- FR-323 — Native Skill Format Compliance.
- NFR-053 — Functional parity with the legacy workflow.
- Reference implementation: `plugins/gaia/skills/gaia-fix-story/SKILL.md`.
