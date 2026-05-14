---
name: gaia-validation-patterns
description: Reusable validation patterns used by Val — factual claim extraction, filesystem verification, cross-referencing against ground truth and related artifacts, severity classification (CRITICAL/WARNING/INFO), and findings formatting. Native Claude Code port of the legacy validation-patterns lifecycle skill.
version: '1.0'
applicable_agents: [validator]
sections: [claim-extraction, filesystem-verification, cross-reference, severity-classification, findings-formatting]
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

<!-- Converted under ADR-041 (Native Execution Model). Source: _gaia/lifecycle/skills/validation-patterns.md. -->

## Mission

Supply the reusable building blocks that every Val validation run composes: extract factual claims from an artifact, verify each claim against the filesystem, cross-reference against `ground-truth.md` and sibling artifacts, classify severity, and format the findings report.

Every section marker below is part of the public JIT contract consumed by `gaia-val-validate`, `gaia-val-validate-plan`, and the `two-pass-logic` section of `gaia-document-rulesets` (Pass 2). Renaming sections breaks those callers.

## Critical Rules

- **Only verifiable claims are findings.** Opinions, goals, and aspirations are ignored — see `claim-extraction` for the closed list of what counts.
- **Out-of-boundary paths are INFO, not WARNING.** External references outside `{project-root}` are skipped with severity INFO per the boundary rule.
- **Ground-truth absence is not a failure.** Missing ground-truth entries produce a WARNING (suggesting `/gaia-refresh-ground-truth`) — but filesystem verification still runs independently.
- **Severity is controlled by the decision tree in `severity-classification`.** Do not invent intermediate severities or downgrade findings for cosmetic reasons.
- **Binary files are verified for existence only.** Never attempt to parse content of recognized binary extensions.

<!-- SECTION: claim-extraction -->
## Claim Extraction

### What Constitutes a Factual Claim

A factual claim is any statement in an artifact that can be verified against the filesystem or other artifacts:

- **File references** — paths to files or directories (e.g., `_gaia/core/engine/workflow.xml`)
- **Version numbers** — framework, dependency, or API versions (e.g., `v1.29.0`)
- **Configuration values** — settings declared in YAML, JSON, or env files
- **Component names** — agent IDs, workflow names, skill names referenced by identifier
- **Counts** — numeric quantities (e.g., "25 agents", "62 workflows", "8 shared skills")
- **Endpoint paths** — API routes, URL patterns
- **Dependency names** — package names, module references
- **Architectural decisions** — ADR references citing specific patterns or statuses

### What Is NOT a Factual Claim

- Opinions or subjective assessments ("the system is well-designed")
- Goals or aspirational statements ("the system should be scalable")
- Future intentions ("we will add support for X")
- Descriptions of behavior without verifiable specifics
- Relative comparisons without concrete values ("faster than before")

### Extraction Method

1. Parse markdown headings, tables, code blocks, inline references, and YAML frontmatter
2. Identify tokens matching claim type patterns (file paths contain `/`, versions match semver, counts are digits followed by nouns)
3. Record source location: artifact file path + section heading or line range
4. Skip content inside `<!-- comments -->` and fenced code blocks marked as `pseudo` or `example`

### Output Format

For each extracted claim, produce:

| Field | Description |
|-------|-------------|
| `claim_text` | The literal text of the claim |
| `source` | Artifact file path + section or line reference |
| `type` | One of: `file-reference`, `version`, `config-value`, `component-name`, `count`, `path`, `dependency`, `adr-reference` |
| `verifiable` | `true` if claim can be checked against filesystem or artifacts; `false` if requires external validation |
<!-- END SECTION -->

<!-- SECTION: filesystem-verification -->
## Filesystem Verification

### Verification Strategy by Claim Type

| Claim Type | Verification Method |
|------------|-------------------|
| `file-reference` | `existsSync(path)` — check file or directory exists |
| `version` | Read target file, extract version field, compare |
| `config-value` | Parse config file (YAML/JSON), compare field value |
| `component-name` | Check manifests (`workflow-manifest.csv`, `skill-manifest.csv`, agent dirs) |
| `count` | Run filesystem query (glob/find), compare actual count to claimed count |
| `path` | Resolve path variables (`{project-root}`, `{project-path}`), then `existsSync` |
| `dependency` | Check `package.json`, `pubspec.yaml`, `pom.xml`, or equivalent |

### Path Variable Resolution

Before verifying, resolve GAIA path variables:
- `{project-root}` → absolute path to repo root (where `_gaia/` lives)
- `{project-path}` → application source directory (resolved via `!scripts/resolve-config.sh project_path`; see ADR-044 §10.26.3)
- `{installed_path}` → workflow directory path

### Symlink Handling

- Follow symlinks and verify the **target** exists
- If the symlink target is missing, report as `unverified` with evidence noting broken symlink
- Record both the symlink path and resolved target in evidence

### Binary File Handling

- For binary files (images, compiled assets, fonts, archives): verify **existence only**
- Do NOT attempt content parsing — report as `verified` if file exists, `unverified` if missing
- Recognized binary extensions: `.png`, `.jpg`, `.jpeg`, `.gif`, `.ico`, `.webp`, `.svg`, `.pdf`, `.woff`, `.woff2`, `.ttf`, `.zip`, `.tar`, `.gz`

### Out-of-Boundary Handling

- Files referenced outside `{project-root}` are **skipped** with severity `INFO`
- Val only verifies within the project boundary — external paths are not its responsibility
- Log: "Out-of-boundary reference skipped: {path} is outside {project-root}"

### Output Format Per Claim

| Field | Description |
|-------|-------------|
| `status` | `verified` / `unverified` / `not-applicable` |
| `evidence` | What was checked and what was found (or not found) |
| `path_checked` | Resolved absolute path that was verified |
<!-- END SECTION -->

<!-- SECTION: cross-reference -->
## Cross-Reference Verification

### Ground Truth Cross-Reference

Compare extracted claims against entries in `ground-truth.md`:
- File path inventories — verify claimed paths match ground truth file lists
- Component counts — verify claimed counts match ground truth tallies
- Version numbers — verify claimed versions match ground truth records
- Structural patterns — verify claimed directory structures match ground truth maps

If a claim matches a ground truth entry: mark as `verified` with ground truth as evidence.
If a claim contradicts a ground truth entry: mark as `unverified` with both values noted.

### Inter-Artifact Cross-Reference

Verify consistency between related artifacts:
- Architecture references PRD requirements → check requirement IDs exist in PRD
- Stories reference epics → check epic key exists in epics-and-stories.md
- Test plans reference stories → check story keys exist in implementation-artifacts
- Stories reference ADRs → check ADR exists in architecture.md
- Traceability matrix entries → check both source and target exist

### Missing Ground Truth Entries

When a claim cannot be found in `ground-truth.md`:
- Do NOT classify as `unverified` — ground truth may be incomplete
- Flag as `WARNING` with message: "No ground truth entry for: {claim}. Ground truth may need refresh."
- Suggest running `/gaia-refresh-ground-truth` if multiple missing entries are detected (threshold: 3+)
- Still attempt filesystem verification independently of ground truth
<!-- END SECTION -->

<!-- SECTION: severity-classification -->
## Severity Classification

### CRITICAL

A factual error that would cause a workflow to fail or produce wrong output:
- File path that does not exist and is used as input by a workflow step
- Nonexistent agent, workflow, or skill name referenced in a config or instruction
- Incorrect count that affects downstream logic (e.g., "8 skills" when actually 9, causing a loop to miss one)
- Wrong version number in a dependency declaration that would cause install failure
- Configuration value that would cause runtime errors

### WARNING

An inconsistency that will not break execution but indicates drift:
- Version mismatch by patch version only (e.g., `1.29.0` vs `1.29.1`)
- Stale reference to a renamed or moved file that still exists at old path
- Incomplete section that is referenced but contains placeholder content
- Missing ground truth entry for a verifiable claim
- Count off by one where the difference does not affect logic

### INFO

A minor observation that might be intentional:
- Naming convention deviation (e.g., underscore vs hyphen in a file name)
- Unused reference that is declared but never consumed
- Formatting inconsistency (e.g., inconsistent heading levels)
- Out-of-boundary reference that was skipped during verification
- Aspirational or future-tense statement in a factual section

### Decision Tree

```
Is the claim verifiable?
├─ NO → skip (not a factual claim)
└─ YES → Does the referenced resource exist?
   ├─ NO → Is it used as workflow input or config?
   │  ├─ YES → CRITICAL
   │  └─ NO → WARNING
   └─ YES → Does the value match exactly?
      ├─ YES → verified (no finding)
      ├─ PARTIAL (minor diff) → WARNING
      └─ NO (major diff) → Is the diff logic-affecting?
         ├─ YES → CRITICAL
         └─ NO → WARNING
Not in ground truth? → WARNING
Out of boundary? → INFO
Style/convention only? → INFO
```
<!-- END SECTION -->

<!-- SECTION: findings-formatting -->
## Findings Formatting

### Per-Finding Format

Each finding must include:

```
**[{SEVERITY}]** {one-line summary}
- **Source:** {artifact file} § {section or line range}
- **Claim:** "{exact text of the claim}"
- **Evidence:** {what was checked} → {what was found}
- **Resolution:** {suggested fix}
```

Severity tag format: `[CRITICAL]`, `[WARNING]`, or `[INFO]` — always uppercase, always bracketed.

### Report Structure

```markdown
## Validation Findings

**Summary:** {total} findings — {n} critical, {n} warning, {n} info
**Artifact:** {artifact file path}
**Validated:** {date}

### Critical Findings
{findings with [CRITICAL] tag, ordered by source location}

### Warnings
{findings with [WARNING] tag, ordered by source location}

### Info
{findings with [INFO] tag, ordered by source location}
```

If a severity group has zero findings, include the heading with "None." underneath.

### Consistency Rules

- Same format for both `val-validate-artifact` and `val-validate-plan` workflows
- Always include the summary line, even when zero findings
- Group by severity: CRITICAL first, then WARNING, then INFO
- Within each group, order by source location (file path, then line/section)
- Evidence must state both what was expected and what was actually found
- Resolution must be actionable — never "fix this" without specifics
<!-- END SECTION -->

<!-- SECTION: completion-notes-deferral-scan -->
## Pattern: completion-notes-deferral-scan (E88-S4, FR-DPD-4)

Refs: ADR-107 (closed-list taxonomies SSOT), AI-2026-05-13-6.

**Trigger.** Val validates a story whose `status` frontmatter is `done` or `review`.

**Scan.** Source the deferral-phrase matcher via the canonical helper — do NOT inline the taxonomy:

```bash
bash $PLUGIN/scripts/lib/completion-notes-deferral-scan.sh --story-file "$STORY_FILE"
```

The helper internally sources `lib/deferral-phrase-match.sh` (E88-S1) and walks the story's `### Completion Notes List` subsection. Each matched phrase is paired against the `## Findings` table.

**Pair-check.** A Completion-Notes deferral phrase is considered "paired" when EITHER:
1. A `## Findings` table row contains the phrase as a substring in any column (typically the `Finding` column), OR
2. The Completion-Notes line that surfaced the phrase carries an explicit `Finding ID: <X>` token (case-sensitive prefix).

The helper emits one record per matched phrase: `phrase=<phrase>\tpaired=<true|false>\tfinding_id=<id-or-empty>`.

**Emit.** For each helper record where `paired=false`, emit an ADR-037 finding with:
- `severity: CRITICAL`
- `scope: completion-notes-deferral-scan`
- `detail`: name the unmatched phrase, quote the Completion-Notes line that surfaced it, and suggest either adding a Finding row OR annotating with an inline `Finding ID:` reference.

**Rationale.** Deferral by itself is acceptable — landing stubs with explicit follow-up is a known pattern. The defect class is **unmatched** deferral language: Completion Notes mentioning deferral without a corresponding Finding row, which leaves the deferral invisible to `/gaia-triage-findings` and downstream retros.
<!-- END SECTION -->

## Changelog

- **2026-05-14 — E88-S4 — Val `completion-notes-deferral-scan` pattern (FR-DPD-4, ADR-107, AI-2026-05-13-6).** Added the `completion-notes-deferral-scan` pattern documenting the trigger (story status `done` or `review`), the scan (source `lib/completion-notes-deferral-scan.sh` which wraps `lib/deferral-phrase-match.sh` per E88-S1), the pair-check heuristic (Findings-table substring match OR explicit `Finding ID:` token), and the emit contract (CRITICAL ADR-037 finding on unmatched phrases). Closes the drift class from AI-2026-05-13-6 (Completion Notes mentioning deferral phrases without corresponding Finding rows).
