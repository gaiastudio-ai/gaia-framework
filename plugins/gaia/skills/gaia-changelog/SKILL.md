---
name: gaia-changelog
description: Generate a changelog entry from git history and sprint-status files. Groups commits by Keep a Changelog category (Added, Changed, Fixed, Deprecated, Removed, Security) and cross-references story keys from .gaia/artifacts/implementation-artifacts/. Writes or appends to CHANGELOG.md. Use when "generate changelog" or /gaia-changelog.
argument-hint: "[version — optional, defaults to unreleased range since last tag]"
allowed-tools: [Read, Write, Edit, Bash, Grep]
orchestration_class: light-procedural
---

## Mission

You are producing a **Keep a Changelog**-formatted changelog entry for this repository. You gather commits since the last release tag, group them by conventional-commit type, cross-reference story keys back to `.gaia/artifacts/implementation-artifacts/`, and emit (or append to) `CHANGELOG.md` in the repository root.

This skill is the native Claude Code conversion of the legacy generate-changelog task. Per **ADR-041** (Native Execution Model) and **ADR-042** (Scripts-over-LLM for Deterministic Operations), the legacy task-runner engine is retired and deterministic git operations are delegated to inline bash (not re-prosed by the LLM).

## Critical Rules

- **Follow Keep a Changelog format.** See https://keepachangelog.com/ — the six categories are canonical: Added, Changed, Fixed, Deprecated, Removed, Security.
- **Group every commit into exactly one category.** Map conventional-commit prefixes: `feat:` → Added, `fix:` → Fixed, `refactor:` / `chore:` / `perf:` / `docs:` / `style:` → Changed, `BREAKING CHANGE:` footer or `!` marker → Removed (breaking) section. Commits with no recognizable prefix go to an "Uncategorized" group rather than being silently dropped.
- **Include version number and date.** The entry header is `## [{version}] — {YYYY-MM-DD}` where `{version}` is either the argument supplied, the next semver tag, or `Unreleased` when no version is known.
- **Cross-reference story keys.** If a commit subject contains a match for `E\d+-S\d+`, link the entry back to the corresponding story file under `.gaia/artifacts/implementation-artifacts/` so reviewers can open the full context.
- Do NOT invent version numbers or dates. If the argument is missing and no tag exists, use `Unreleased` as the version and today's ISO date as the date.
- Output path is `CHANGELOG.md` in the repository root. Append to an existing file rather than overwriting; new entries go above the previous top entry.

## Inputs

- `$ARGUMENTS`: optional version identifier. When supplied, it MUST be either:
  1. A valid SemVer 2.0.0 string of the form `MAJOR.MINOR.PATCH` with optional `-prerelease` and `+build` suffixes (e.g., `1.127.2`, `1.127.2-rc.1`, `2.0.0+build.42`), OR
  2. The literal string `Unreleased`.

  Anything else is rejected before any git work runs (see Step 1.5 — Validate Version Argument). When `$ARGUMENTS` is empty, the entry is labelled `Unreleased` (existing default — no rejection).

## Instructions

### Step 1 — Gather Sources

Use inline bash for the deterministic git operations (ADR-042):

```bash
!git log $(git describe --tags --abbrev=0 2>/dev/null || echo "")..HEAD --oneline --no-merges
```

If the previous-tag command returns empty (no tags yet), fall back to `git log --oneline --no-merges` for the entire history.

Then read any sprint-status files in `.gaia/artifacts/implementation-artifacts/` that name stories shipping in this release.

Identify the version number for this entry (argument, next tag, or `Unreleased`).

### Step 1.5 — Validate Version Argument

Before any further git work runs, validate `$ARGUMENTS` against the canonical accepted formats. Per **ADR-042** (Scripts-over-LLM for Deterministic Operations), this is a deterministic regex check — not LLM judgment. The user's intent (`semver` vs `Unreleased`) is binary; LLM interpretation would re-introduce non-determinism.

Accept `$ARGUMENTS` if and only if ONE of the following holds:

1. **Empty** — no argument supplied. Continue with the default (`Unreleased` label). No rejection.
2. **Literal `Unreleased`** — case-sensitive equality with the string `Unreleased`. Accept.
3. **Valid SemVer 2.0.0** — matches the canonical SemVer regex:
   ```
   ^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$
   ```
   This requires `MAJOR.MINOR.PATCH` (each a non-negative integer with no leading zeros) and allows optional `-prerelease` and `+build` suffixes per [SemVer 2.0.0](https://semver.org/). Pure shell or grep is sufficient — do NOT add a parser dependency.

On any other input (e.g., `v1.x`, `1.0`, `latest`, `1.127`, `release-2`), HALT immediately with a single-line guidance message naming the two accepted formats and an example of each:

```
Expected semver (e.g., 1.127.2) or the literal "Unreleased". Got: "{value}".
```

Do NOT write `CHANGELOG.md` on rejection — the artifact stays untouched. The validation MUST run BEFORE the `git log` command in Step 1; rejecting an invalid version after running git wastes work and produces confusing partial output.

### Step 2 — Categorize Changes

Walk the commit list and bucket each commit into one of the Keep a Changelog categories:

- **Added** — `feat:` commits, new capabilities.
- **Changed** — `refactor:`, `perf:`, `style:`, `docs:`, `chore:` commits that alter existing capabilities without breaking them.
- **Fixed** — `fix:` commits.
- **Deprecated** — explicit deprecation notices in commit bodies.
- **Removed** — `BREAKING CHANGE:` footer, `!` marker after the type, or explicit removal notices.
- **Security** — commits that mention a CVE, a security fix, or start with `security:`.

Extract a meaningful one-line description from each commit subject (strip the conventional-commit prefix). For story-linked commits, append `— [{story_key}](.gaia/artifacts/implementation-artifacts/{story_key}-*.md)` so reviewers can open the story file. The story-key cross-reference (`E\d+-S\d+`) is a V2 win and MUST be preserved — do NOT silently drop story-linked commits (FR-394).

Commits with no recognizable conventional-commit prefix are placed in an **Uncategorized** group rather than being silently dropped. The "Uncategorized" group is the V2-added uncategorised-commit capture and MUST be preserved as a distinct section so unparseable commits remain visible (FR-394).

#### Excluded-Commit Logging

When iterating the commit list, some commits are excluded from categorisation entirely. The base `git log ... --no-merges` invocation already filters merges out; this step makes that exclusion **observable** rather than silent (FR-394 audit trail).

For each commit excluded from categorisation, log a structured line to the conversation transcript (NOT to `CHANGELOG.md` — the artifact stays clean):

```
Excluded {sha:7} — reason: {merge|revert|unparseable|other}
```

Reason taxonomy:
- `merge` — merge commit (filtered by `--no-merges`).
- `revert` — `revert:` prefixed commit (excluded from category emission to avoid double-counting the original).
- `unparseable` — subject line that cannot be parsed (e.g., empty, non-UTF-8). Note: this is distinct from "no conventional-commit prefix" — those commits go to the **Uncategorized** group, NOT the excluded log.
- `other` — any other deliberate exclusion.

At end of Step 2, emit a single-line summary so the count is observable at a glance:

```
Excluded N commits (Mm, Rr, Uu, Oo)
```

where `N` is the total, `M` is the merge count, `R` is the revert count, `U` is the unparseable count, and `O` is the other count. The audit trail belongs in the run log so reviewers can reconstruct what was filtered without inspecting `CHANGELOG.md`.

### Step 3 — Format

Render the entry as:

```
## [{version}] — {YYYY-MM-DD}

### Added
- {commit subject} — {story reference if any}

### Changed
- …

### Fixed
- …

### Deprecated
- … (omit section if empty)

### Removed
- … (omit section if empty)

### Security
- … (omit section if empty)
```

Sections with zero entries MUST be omitted (do not emit empty "### Added" blocks).

### Step 4 — Output

Write or append to `CHANGELOG.md` in the repository root. If the file exists, insert the new entry immediately below the top-level heading (`# Changelog`) and above the previous top entry. If the file does not exist, create it with the standard preamble:

```
# Changelog

All notable changes to this project are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

{new entry here}
```

If the commit range is empty (no commits since last tag), append a single-line note `_No changes since {previous tag}._` under the version header rather than writing an empty entry (AC-EC3: empty git range).

## References

- Source: legacy `generate-changelog` task body — ported per ADR-041 + ADR-042.
- Keep a Changelog: https://keepachangelog.com/
- Semantic Versioning: https://semver.org/
- ADR-041: Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042: Scripts-over-LLM for Deterministic Operations — version validation is a deterministic regex check expressed in prose, NOT LLM judgment.
- ADR-048: Engine Deletion as Program-Closing Action — legacy task coexists with this skill until program close.
- FR-323: Skill Conversion — slash-command identity preserved.
- FR-378: Changelog version validation — `$ARGUMENTS` MUST be valid SemVer or the literal `Unreleased` (Step 1.5).
- FR-394: Excluded-commit logging plus V2 wins (story-key cross-references and uncategorised-commit capture preserved unchanged).
- NFR-053: Full v1.127.2-rc.1 Feature Parity.
