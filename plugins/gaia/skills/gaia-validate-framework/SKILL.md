---
name: gaia-validate-framework
description: Scan the GAIA framework tree for consistency, broken references, and missing components. Use when "validate framework" or /gaia-validate-framework. Walks the plugin tree, compares against ${CLAUDE_PLUGIN_ROOT}/knowledge/manifest.yaml, checks workflow integrity, agent integrity, command integrity, manifest integrity, config resolution (via resolve-config.sh), skill index integrity, and knowledge index integrity, then emits a severity-grouped findings report. Native Claude Code conversion of the legacy validate-framework task (E28-S111, Cluster 14).
argument-hint: "[--report-path]"
allowed-tools: [Read, Bash, Grep]
orchestration_class: reviewer
---

## Mission

You are running a framework self-validation scan. The skill walks the plugin tree, compares the on-disk file inventory against `${CLAUDE_PLUGIN_ROOT}/knowledge/manifest.yaml` (shipped inside the plugin under ADR-041's `knowledge/` convention; the legacy v1 location `_gaia/_config/manifest.yaml` is retired and no longer used), and verifies that every workflow, agent, command, skill, and knowledge reference resolves. The output is a severity-grouped findings report written to `.gaia/artifacts/implementation-artifacts/framework-validation-{date}.md` (or a user-provided path).

This skill is the native Claude Code conversion of the legacy validate-framework task at `_gaia/core/tasks/validate-framework.xml` (brief Cluster 14, story E28-S111). The legacy 66-line XML body is preserved here as explicit prose per ADR-041. No workflow engine, no engine-specific XML step tags.

## Critical Rules

- **Report ALL issues found — do not stop at first error.** Every step collects findings into an aggregated list. The skill emits the full report even when critical findings are present.
- **Check every path reference in every file.** Every `{installed_path}/...`, `{project-root}/...`, and `{project-path}/...` reference must resolve to an actual file. Dangling references are CRITICAL findings.
- **Verify config resolution works end-to-end.** Invoke `scripts/resolve-config.sh` and confirm it emits a parseable result — this is the authoritative resolver under ADR-044's two-file split (`config/project-config.yaml` shared + `config/global.yaml` machine-local). Under the native model there is no `.resolved/` pre-compilation step — config is resolved at skill-invocation time. Flag resolver failure or unparseable output as CRITICAL.
- **Report format preserves the legacy output shape.** Severity column, section column, finding column, suggested-fix column. Downstream tooling (CI checks, triage workflows) consume this shape — do NOT invent a new one.
- **Fail fast when manifest.yaml is missing (AC-EC3).** If `${CLAUDE_PLUGIN_ROOT}/knowledge/manifest.yaml` is absent, emit a CRITICAL finding `manifest.yaml missing — cannot validate framework` and exit non-zero. No partial report. This is the strict-mode variant of the graceful-missing-file contract documented in `plugins/gaia/scripts/lib/missing-file-fallback.sh` (E28-S162): validate-framework treats the manifest as a hard prerequisite (strict = exit non-zero with an error), whereas other callers (next-step.sh, gaia-help) treat similar retired-path files as graceful no-ops. Strictness is a per-caller policy, not a helper default.
- **Use inline `!` bash for deterministic ops (ADR-042).** Manifest reads, directory listings, and `shasum` go through inline `!` bash. Do NOT re-implement manifest parsing in LLM prose.

## Val Dispatch Contract

> Any Val invocation triggered by this skill (directly or as a follow-up validation pass on findings) is dispatched with `model: claude-opus-4-7` and `effort: high` per ADR-074 contract C2 (Val opus pin). Validation rigor is the framework-wide contract; the harness MUST NOT downgrade Val to a cheaper default model. **Non-opus mismatch guard (AC3):** if a test fixture or downstream override forces a non-opus model into the dispatch context, this skill MUST emit the canonical WARNING `Val dispatch on non-opus model — forcing opus per ADR-074 contract C2` and force `model: claude-opus-4-7` before invoking Val. Silent degradation is forbidden.
>
> [Val opus-pin contract — see plugins/gaia/agents/validator.md §Val Operations]

## Inputs

1. **Report path** — optional, via `$ARGUMENTS`. Defaults to `.gaia/artifacts/implementation-artifacts/framework-validation-{date}.md`.

## Pipeline Overview

The skill runs ten steps in strict order, mirroring the legacy `validate-framework.xml` plus the E53-S243 monolith-shard-sync addition (Tier 1):

1. **File Inventory** — scan the plugin tree, count by type, compare against manifest.yaml
2. **Workflow Integrity** — verify every `workflow.yaml` has its companion files
3. **Agent Integrity** — verify every agent `.md` has well-formed XML and real menu links
4. **Command Integrity** — verify every `.claude/commands/gaia-*.md` references real framework files
5. **Manifest Integrity** — verify surviving `agent-manifest.csv` rows match on-disk agent files and vice versa (legacy workflow/task/skill manifests retired by ADR-048)
6. **Config Resolution** — verify `scripts/resolve-config.sh` emits parseable output under the native resolution path (ADR-044 two-file split; module `config.yaml` and `.resolved/` retired by ADR-044/ADR-048)
7. **Skill Index Integrity** — verify every entry in `_skill-index.yaml` has a real file and valid line ranges
8. **Knowledge Index Integrity** — verify every entry in knowledge `_index.csv` has a real fragment under 200 lines
9. **Monolith-Shard Sync** (Tier 1, E53-S243) — invoke `plugins/gaia/scripts/check-monolith-shard-sync.sh` and fold each emitted `WARNING` line into the findings list at WARNING severity. Documented exceptions (Change Log monolith-as-source-of-truth, `_preamble.md` partial mirror) are honored by the script and produce no false positives.
9b. **Orphan-tmp Sweep Allowlist** (E64-S6) — static check rejecting any startup orphan-tmp `find ... -delete` whose target paths fall outside the allowlist (`${PLANNING_ARTIFACTS}/epics`, `${IMPLEMENTATION_ARTIFACTS}`, `${MEMORY_PATH}`). Out-of-bounds sweeps are CRITICAL findings.
9c. **Orchestration-Class Coverage** (E84-S2, ADR-093) — invoke `plugins/gaia/scripts/check-orchestration-class.sh`. The script verifies every SKILL.md under `plugins/gaia/skills/*/SKILL.md` declares an `orchestration_class:` frontmatter field set to one of `{reviewer, light-procedural, heavy-procedural, conversational}`. Any missing field, unknown value, or duplicate declaration is a CRITICAL finding. Source of truth for the enum: `plugins/gaia/skills/README.md` §"Orchestration Class".
9d. **Fork-Strip Invariant** (E84-S3, ADR-093) — invoke `plugins/gaia/scripts/check-fork-stripped.sh`. The script verifies that no non-reviewer plugin SKILL.md (orchestration_class ∈ `{light-procedural, heavy-procedural, conversational}`) declares `context: fork` in its frontmatter. Reviewers MAY retain `context: fork` per NFR-060 (clean-room invariant). Violations are CRITICAL findings. Agent persona files under `plugins/gaia/agents/*.md` are intentionally out of scope for this check (ADR-093 amends ADR-041 only for the skill-invocation layer); their fork retention is guarded by bats regression tests instead.
9e. **Orchestration-Warning Invocation Presence** (E84-S6, ADR-093 / FR-446) — invoke `plugins/gaia/scripts/check-orchestration-warning-wired.sh`. The script verifies that every SKILL.md with `orchestration_class ∈ {heavy-procedural, conversational}` invokes BOTH `detect-orchestration-mode.sh` AND `orchestration-warning.sh` in its procedural body. Missing invocations are CRITICAL findings. Out-of-scope classes (`light-procedural`, `reviewer`) are silently ignored — `reviewer` in particular is a clean-room one-shot fork per NFR-060, where Mode A is the design and the warning is not applicable. This check closes the E84-S4 integration gap where the helper scripts were shipped but never wired into any SKILL.md.
9f. **Stale-flag Registry Audit** (E86-S6, ADR-102 / FR-475 / SR-59) — invoke `plugins/gaia/scripts/check-stale-flag-registry.sh`. The script scans `_memory/` (top-level only, per ADR-102 marker contract clause 3) for files matching `.*-stale` and verifies every marker is registered in the ADR-102 registry table inside `.gaia/artifacts/planning-artifacts/architecture/12-12-adr-detail-records.md`. Unregistered markers are CRITICAL findings — they represent a governance audit gap per SR-59. The script's stdout is folded into the validate-framework findings list at CRITICAL severity; non-zero exit propagates as a CRITICAL finding.
10. **Report** — emit PASS/FAIL overall + itemized findings grouped by severity

## Step 1 — File Inventory

- **AC-EC3 — manifest.yaml missing:** check `${CLAUDE_PLUGIN_ROOT}/knowledge/manifest.yaml`. If absent, emit CRITICAL `manifest.yaml missing — cannot validate framework` and exit non-zero. No partial report.
- Scan the plugin directory tree via inline `!find "${CLAUDE_PLUGIN_ROOT}" -type f \( -name '*.md' -o -name '*.xml' -o -name '*.yaml' -o -name '*.csv' \)`. Count files by type.
- Compare counts against expected counts from `manifest.yaml` (version field and declared module counts).
- Flag any drift as INFO (counts off by small margin) or WARNING (counts off by a large margin).

## Step 2 — Workflow Integrity

- For each `workflow.yaml` under `_gaia/{core,lifecycle,dev,creative,testing}/workflows/`:
  - Verify the `instructions` file declared in the yaml exists on disk.
  - Verify the `validation` (checklist) file exists when declared.
  - Verify the `config_source` file exists.
  - Verify the `template` field, when declared, points to an existing template (respecting the `custom/templates/` override order).
- Scan each `workflow.yaml` and its `instructions` for unresolved `{variable}` references that were NOT expected (expected tokens: `{project-root}`, `{project-path}`, `{installed_path}`, `{date}`, `{memory_path}`, `{checkpoint_path}`, and any explicit workflow variables).
- Flag unresolved references as CRITICAL.

## Step 3 — Agent Integrity

- For each `.md` file under `_gaia/{core,lifecycle,dev,creative,testing}/agents/`:
  - Verify the `<agent>` XML block is well-formed (balanced tags, no orphan attributes).
  - Verify each menu item's `file=` attribute points to a real file.
  - Verify activation steps are numbered correctly (1..N with no gaps).
- Flag malformed XML as CRITICAL; missing menu targets as WARNING.

## Step 4 — Command Integrity

- For each `.claude/commands/gaia-*.md` (or equivalent slash-command definition file):
  - Verify it references a real framework workflow, agent, or skill file.
  - Cross-reference `gaia-help.csv` — every help entry should have a matching command definition.
- Flag missing references as CRITICAL; help-CSV drift as WARNING.

## Step 5 — Manifest Integrity

- Verify `agent-manifest.csv` has a row for every agent `.md` file found on disk, and vice versa.
- Flag any drift (manifest row without a file, or file without a manifest row) as WARNING.
- Note: `workflow-manifest.csv`, `task-manifest.csv`, and `skill-manifest.csv` were retired under ADR-048 (program-closing engine deletion). The native model discovers skills/subagents via Claude Code's auto-discovery, so these manifests are no longer authoritative and MUST NOT be checked here.

## Step 6 — Config Resolution

- Invoke `scripts/resolve-config.sh` (per ADR-044) and verify it emits parseable output. The resolver handles the ADR-044 two-file split (shared `config/project-config.yaml` + machine-local `config/global.yaml`) transparently — this skill does NOT probe the on-disk files directly. Confirm the key `project-root` / `project-path` / `memory-path` fields resolve cleanly from the resolver output.
- Flag resolver failure or unparseable output as CRITICAL.
- Note: module `config.yaml` files, the `.resolved/` pre-compilation chain, and the legacy v1 location `_gaia/_config/global.yaml` were retired under ADR-044 + ADR-048. The native model resolves config at skill-invocation time via `scripts/resolve-config.sh` — there is no pre-compiled output to verify and no v1 path to probe.

## Step 7 — Skill Index Integrity

- For each entry in `_gaia/dev/skills/_skill-index.yaml`:
  - Verify the referenced `.md` file exists.
  - Verify the declared `lines: [start, end]` range is valid (end > start; both within file bounds).
  - Verify the section content at the declared range starts with a matching `<!-- SECTION: xxx -->` marker.
- Flag missing files as CRITICAL; invalid line ranges as WARNING.

## Step 8 — Knowledge Index Integrity

- For each entry in knowledge `_index.csv` files (e.g., `_gaia/testing/knowledge/*/index.csv`):
  - Verify the fragment `.md` file exists on disk.
  - Verify each fragment is under 200 lines (per `<200-line` context-budget rule in the framework spec).
- Flag missing fragments as CRITICAL; oversize fragments as WARNING.

## Step 9 — Monolith-Shard Sync (E53-S243)

- Invoke `plugins/gaia/scripts/check-monolith-shard-sync.sh --root "${PROJECT_ROOT}"` (where `PROJECT_ROOT` is resolved via `scripts/resolve-config.sh`).
- The script always exits 0 (advisory) and prints zero or more lines on stdout. Lines beginning with `WARNING:` are folded into the findings list at WARNING severity, preserving the section name and diverging file paths in the `Finding` column. Lines beginning with `INFO:` are folded at INFO severity (e.g., monolith exists but shard directory missing).
- The script enforces the ADR-070 "Monolith-vs-Shard Sync Contract" subsection. Documented exceptions (Change Log direction is monolith-as-source-of-truth; `_preamble.md` is a partial frontmatter-only mirror) are honored by the script and MUST NOT be re-implemented in this skill — keep the script as the single source of truth.
- Suggested fix for each `WARNING:` finding: run `/gaia-shard-doc <monolith>` (when the monolith was edited) or `/gaia-merge-docs <shard-dir>` (when shards were edited) before commit, per the sync contract.

## Step 9b — Orphan-tmp Sweep Allowlist (E64-S6)

- Static check: scan every `*.sh` under `plugins/gaia/scripts/` and `plugins/gaia/skills/**/scripts/` for orphan-tmp sweep call sites — lines containing both `*.tmp.??????` and `-delete`. Each match is a startup-sweep `find` invocation introduced for E64-S6 (or a future caller adopting the same pattern).
- Inline `!` bash reference idiom:

```bash
grep -rEn "\*\.tmp\.\?\?\?\?\?\?.*-delete|find[^|;]*-name[[:space:]]*['\"]?\\*\\.tmp\\.\\?\\?\\?\\?\\?\\?['\"]?[^|;]*-delete" \
  plugins/gaia/scripts plugins/gaia/skills 2>/dev/null
```

- For each hit, extract the `find` argument paths and verify EVERY path expands to one of the allowlisted roots:
  - `${PLANNING_ARTIFACTS}/epics`
  - `${IMPLEMENTATION_ARTIFACTS}`
  - `${MEMORY_PATH}`
- Reject (CRITICAL) any sweep whose first `find` argument resolves to a path outside the allowlist — explicitly forbidden targets include `/tmp`, `$HOME`, `${PROJECT_PATH}` (root), `~`, `${HOME}`, `/var/tmp`. Hard fail the framework validation report with severity CRITICAL and a finding row that names the offending file and line number.
- Suggested fix for each CRITICAL finding: re-scope the sweep to one of the three allowlisted roots, or remove the sweep entirely. The allowlist exists to bound blast radius — an orphan-tmp sweep MUST NOT walk arbitrary filesystem paths.
- This static check enforces AC4 of E64-S6 ("a static check in `/gaia-validate-framework` rejects any sweep call that targets a path outside the allowlist") and is the single source of truth for the sweep allowlist policy. Future scripts adopting the sweep MUST land their call site under one of the three roots.

## Step 9e — Orchestration-Warning Invocation Presence (E84-S6)

- Invoke `plugins/gaia/scripts/check-orchestration-warning-wired.sh`. The script verifies that every SKILL.md under `plugins/gaia/skills/*/SKILL.md` whose frontmatter declares `orchestration_class ∈ {heavy-procedural, conversational}` invokes BOTH `detect-orchestration-mode.sh` AND `orchestration-warning.sh` in its procedural body.
- Each missing invocation is a CRITICAL finding of the shape `<file>: orchestration_class=<cls> missing invocation: <script>.sh`. Fold each CRITICAL line into the findings list at CRITICAL severity, preserving the file path and missing-script name in the `Finding` column.
- Out-of-scope classes (`light-procedural`, `reviewer`) are silently skipped by the script. Reviewers in particular are clean-room one-shot forks per NFR-060 where Mode A is the design and the warning is not applicable; light-procedural skills are cheap (≤2 subagent dispatches, no continuity benefit) and the warning would be alarmist noise.
- Suggested fix for each CRITICAL finding: insert the canonical invocation pattern immediately after the SKILL.md frontmatter and before the first procedural section:

  ```bash
  SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class <orchestration_class> --mode "$SESSION_MODE"
  ```

  The `<orchestration_class>` literal must equal the SKILL.md's own `orchestration_class:` frontmatter value verbatim.
- This static check closes the E84-S4 integration gap where `orchestration-warning.sh` and `detect-orchestration-mode.sh` were shipped but no SKILL.md invoked either script — making the warning unreachable in production despite AC8 of E84-S4 being marked passing.

## Step 10 — Report

Generate the framework validation report at the configured output path.

Format:

```markdown
# GAIA Framework Validation Report — {YYYY-MM-DD}

**Overall Status:** PASS | FAIL

**Summary:**
- Critical findings: {N}
- Warning findings: {M}
- Info findings: {K}

## Findings

| Severity | Section | Finding | Suggested Fix |
|----------|---------|---------|---------------|
| CRITICAL | Workflow Integrity | workflow.yaml at ... references missing instructions file ... | Restore the instructions file or remove the workflow.yaml entry |
| WARNING  | Manifest Integrity | agent-manifest.csv has a row for ... but no file exists on disk | Remove the stale manifest row or restore the file |
| INFO     | File Inventory     | file count drift — expected 42 md files, found 43 | Run /gaia-build-configs and re-validate |
| ...      | ...                | ...                                             | ...           |
```

Grouping: CRITICAL first, then WARNING, then INFO. Within each severity, sort by section then alphabetical by finding text.

**Overall Status**: PASS when there are zero CRITICAL findings; FAIL otherwise. WARNING and INFO do not break the gate.

## Edge Cases

- **AC-EC3 — manifest.yaml missing:** exit with a single CRITICAL finding `manifest.yaml missing — cannot validate framework`. No partial report. Non-zero exit.
- **Empty `_gaia/` tree:** report each expected directory as WARNING; Overall Status FAIL.
- **Legacy `.resolved/` remnants present:** INFO — `.resolved/` was retired under ADR-044/ADR-048; surviving directories are stale artifacts from pre-native installs. Suggest running `plugins/gaia/scripts/gaia-cleanup-legacy-engine.sh`.

## References

- Legacy source: `_gaia/core/tasks/validate-framework.xml` (66 lines) — parity reference for NFR-053.
- `${CLAUDE_PLUGIN_ROOT}/knowledge/manifest.yaml` — authoritative file inventory source (read-only input for this skill; ships inside the plugin under ADR-041's `knowledge/` convention, legacy v1 location `_gaia/_config/manifest.yaml` retired).
- `scripts/resolve-config.sh` output — authoritative config source (read-only input for this skill; resolves the ADR-044 two-file split on demand, legacy v1 location `_gaia/_config/global.yaml` retired).
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations (inline `!` bash for manifest reads, `find`, `shasum`).
- ADR-048 — Program-close deletion policy for legacy engine/workflows/tasks.
- FR-323 — Native Skill Format Compliance.
- NFR-053 — Functional parity with the legacy task.
- Reference implementation: `plugins/gaia/skills/gaia-fix-story/SKILL.md`.
- `plugins/gaia/scripts/lib/missing-file-fallback.sh` (E28-S162): shared bash helper; this skill adopts the strict variant of its contract for manifest.yaml (AC-EC3).
