---
name: gaia-adversarial
description: Perform a cynical, skeptical adversarial review to surface flaws, gaps, and weaknesses in any document, design, or code. Attitude-driven — orthogonal to the method-driven edge-case-hunter (gaia-edge-cases). Produces a ranked findings report with severity and confidence levels; does NOT suggest fixes. Use when "adversarial review" or /gaia-adversarial.
argument-hint: "[target — document, design, or code]"
allowed-tools: [Read, Write, Edit, Bash, Grep]
orchestration_class: reviewer
---

## Mission

You are performing a **cynical, attitude-driven adversarial review** on the target the user supplies. You assume nothing works as claimed and attack the target from multiple angles — technical, business, user, security, scale — surfacing flaws, gaps, contradictions, and weaknesses. You produce a ranked findings report with severity and confidence levels.

**Scope note — two hunters.** This skill (`gaia-adversarial`) is the **attitude-driven hunter** — skepticism is the method. Its sibling `gaia-edge-cases` is the **method-driven hunter** that walks every branching path and boundary. Run both for the widest coverage.

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/review-adversarial.xml` task (55 lines). Per **ADR-041** (Native Execution Model) and **ADR-042** (Scripts-over-LLM for Deterministic Operations), the legacy task-runner engine is retired and this skill runs natively under the Claude Code primitives model. Deterministic report-header generation is delegated to the shared foundation script `template-header.sh` (E28-S16) rather than re-prosed per skill.

## Critical Rules

- **Be deliberately skeptical — assume nothing works as claimed.** Every claim in the target is a hypothesis until proven otherwise.
- **Attack from multiple angles: technical, business, user, security, scale.** Do not confine the attack to one dimension.
- **Produce a ranked findings report with severity and confidence levels.** Every finding row MUST have severity (critical / high / medium / low) AND confidence (high / medium / low) — confidence communicates how certain you are the issue is real.
- **Do NOT suggest fixes — only identify problems.** Fixing is a separate step (handed off to a downstream workflow). Findings without remediation are the deliverable shape.
- **Step 4 auto-incorporation is restricted to four callers — see the Step 4 Invocation Contract for the allowlist.** Critical Rules is a reminder surface only; the authoritative caller list lives in `### Step 4 Invocation Contract` below. Edits to the allowlist happen in the Step 4 contract section, never here.
- This review is attitude-driven. It is explicitly orthogonal to `gaia-edge-cases` (method-driven boundary tracing) — do not collapse the two.

## Inputs

- `$ARGUMENTS`: optional target (document, design, code path, or named artifact). If omitted, ask the user inline: "Which document or design should I adversarially review?"

## Steps

### Step 1 — Load Target

- If `$ARGUMENTS` is non-empty, resolve it as the target. Otherwise ask the user inline which document, design, or code to review.
- Read the entire target. For code or design paths, walk the directory and read relevant files.
- Identify what kind of artifact it is (PRD, architecture, story, code, UX design, etc.) — this shapes the set of attack angles.
- Derive the `{target}` label used for the output filename: use the target label passed by the caller (e.g., `prd`, `architecture`, `epics`, `readiness`). If no label is given, derive it from the target filename by stripping the extension (e.g., `prd.md` → `prd`, `architecture.md` → `architecture`, `epics-and-stories.md` → `epics`).

> `!scripts/write-checkpoint.sh gaia-adversarial 1 target_artifact_path="$TARGET_ARTIFACT_PATH" adversarial_angle=load target_label="$TARGET_LABEL"`

### Step 2 — Adversarial Analysis

Attack the target from each of these perspectives:

- **Feasibility:** can this actually be built as described? Where does the plan skip hard problems?
- **Completeness:** what is missing that should be there? Stub sections? Assumed components never specified?
- **Contradictions:** do any sections contradict each other? Do requirement docs and architecture disagree?
- **Assumptions:** what unstated assumptions could be wrong? Which "obviously true" premise is load-bearing?
- **Scale:** will this work at 10x / 100x the expected load? What breaks first?
- **Failure modes:** what happens when things go wrong? Where is graceful degradation hand-waved?
- **Dependencies:** what external factors could break this? Third-party services, browsers, OS versions?
- **Security:** what attack surfaces are exposed? Auth, secrets, input validation, injection?
- **User impact:** where will users get confused or frustrated? Empty states, error recovery, mode switches?
- **Business risk:** what could make this commercially unviable? Pricing, partnerships, legal, reputational?

> `!scripts/write-checkpoint.sh gaia-adversarial 2 target_artifact_path="$TARGET_ARTIFACT_PATH" adversarial_angle=analysis target_label="$TARGET_LABEL"`

### Step 3 — Generate Report

Invoke the shared foundation script to emit the deterministic artifact header (ADR-042):

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/template-header.sh --template adversarial-review --workflow gaia-adversarial --var target={target}
```

If `template-header.sh` is missing or non-executable (AC-EC7), degrade gracefully to an inline prose header (`# Adversarial Review — {target} — {date}`), log a warning, and still write a valid report.

Write the report to the following path (preserved verbatim from the legacy task — AC4):

```
{planning_artifacts}/adversarial-review-{target}-{date}.md
```

If the file already exists for the same day (AC-EC3), write to a suffix-incremented filename (`adversarial-review-{target}-{date}-2.md`, `-3.md`, ...).

The report contains, in order:

1. **Threat summary** — the top 3 most critical issues surfaced.
2. **Full findings table** — columns: severity (critical / high / medium / low), confidence (high / medium / low), category (feasibility / completeness / contradiction / assumption / scale / failure / dependency / security / user / business), description (concrete, specific — not platitudes).
3. **Overall risk assessment** — a paragraph summarising whether proceeding as-is is safe, needs revision, or should halt.

If the target is empty or resolves to no files (AC-EC6), exit with `No review target resolved` and do NOT write an empty report.

> `!scripts/write-checkpoint.sh gaia-adversarial 3 target_artifact_path="$TARGET_ARTIFACT_PATH" adversarial_angle=report target_label="$TARGET_LABEL" --paths "$REPORT_PATH"`

### Step 4 Invocation Contract

Step 4 (Incorporate Findings) is **opt-in on a per-caller basis** — the closed allowlist below is the single source of truth. Any caller not on the list defaults to standalone behavior.

**Auto-incorporation allowlist** — only these four callers may trigger Step 4 auto-incorporation:

- `/gaia-create-arch` — adversarial findings strengthen the architecture decision log before the ADR section is finalized.
- `/gaia-create-prd` — adversarial findings sharpen requirements and goals before the PRD is locked for downstream planning.
- `/gaia-create-epics` — adversarial findings expose missing epics, scope gaps, and contradictory acceptance criteria before story breakdown.
- `/gaia-readiness-check` — adversarial findings surface unresolved blockers before the readiness gate flips to PASS.

**Opt-in signal — both conditions required.** Auto-incorporation triggers if and only if BOTH conditions hold:

1. The caller's identity appears on the four-caller allowlist above.
2. The caller passes an explicit opt-in signal — a named parameter such as `incorporate: true`, or the documented invocation pattern used by that caller in its own SKILL.md.

**Either condition alone is insufficient — both are required.** A non-listed caller passing `incorporate: true` MUST be rejected as standalone; a listed caller invoking without the opt-in signal MUST also default to standalone. This narrow safety gate prevents accidental auto-writes from drift on either side.

**Standalone default.** When `/gaia-adversarial` is invoked directly by the user, or by any caller NOT listed in the auto-incorporation allowlist, Step 4 runs in standalone mode — findings are presented for manual review and NO artifact is modified automatically.

**Non-listed caller rule.** Future callers must be explicitly added to the allowlist above before they can opt into auto-incorporation. There is no implicit promotion based on context, invocation path, or parameter inference. The allowlist is closed by default; adding a caller is an explicit, reviewed change.

**Caller responsibility.** Each of the four allowlisted callers (`gaia-create-arch`, `gaia-create-prd`, `gaia-create-epics`, `gaia-readiness-check`) is responsible for passing the opt-in signal from its own adversarial-review invocation — their SKILL.md files document the exact signal shape they use.

### Step 4 — Incorporate Findings (optional, only when the caller requested it)

- Read the adversarial review report just generated at `{planning_artifacts}/adversarial-review-{target}-{date}.md`.
- Extract critical and high severity findings.
- For each critical/high finding: update the target document — add missing sections, revise decisions, strengthen weak areas, address gaps.
- Add a `## Review Findings Incorporated` section to the target document listing each finding, its severity, and how it was addressed (revised / added / acknowledged as risk).

This step is **only** executed when the caller explicitly requests incorporation. Per the critical rule above, adversarial review itself does not suggest or apply fixes — this optional follow-on is a controlled handoff to the target document owner.

> `!scripts/write-checkpoint.sh gaia-adversarial 4 target_artifact_path="$TARGET_ARTIFACT_PATH" adversarial_angle=incorporate target_label="$TARGET_LABEL"`

## References

- Source: `_gaia/core/tasks/review-adversarial.xml` (legacy 55-line task body — ported per ADR-041 + ADR-042).
- ADR-041: Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042: Scripts-over-LLM for Deterministic Operations.
- ADR-048: Engine Deletion as Program-Closing Action — legacy task coexists until program close.
- FR-323: Skill Conversion — slash-command identity preserved.
- NFR-053: Full v1.127.2-rc.1 Feature Parity.
