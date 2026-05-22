---
name: gaia-quick-spec
description: Create a quick implementation spec for small changes. Use when "create a quick spec" or /gaia-quick-spec. Runs a lightweight five-step flow (Scope → Quick Analysis → Escape Hatch Check → Generate Quick Spec → Generate Output) and writes the spec to .gaia/artifacts/implementation-artifacts/quick-spec-{spec_name}.md. Native Claude Code conversion of the legacy quick-spec workflow (E28-S116, Cluster 16).
argument-hint: "[spec-name]"
allowed-tools: [Read, Write, Edit, Bash]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

<!--
  Source: _gaia/lifecycle/workflows/quick-flow/quick-spec/ (workflow.yaml + instructions.xml)
  ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks
  ADR-048 — Program-close deletion policy for legacy engine/workflows/tasks
  FR-323 — Native Skill Format Compliance
  NFR-048 — 40–55% activation-budget reduction vs legacy workflow engine
  NFR-053 — Functional parity with the legacy workflow

  Cluster 16 — Quick Flow (first delivery). Pairs with E28-S117 (quick-dev).
  Unblocks E28-S118 (end-to-end Quick Flow test gate).
-->

## Mission

You are creating a lightweight implementation spec for a small change or feature — the quick-flow entry point. This skill intentionally skips the full lifecycle (PRD → architecture → epics/stories → story); use it when scope is well under a day and touches a handful of files. The output is a single markdown file at `.gaia/artifacts/implementation-artifacts/quick-spec-{spec_name}.md` with five fixed sections (summary, files to change, implementation steps, acceptance criteria, risks) that a developer can hand straight to `/gaia-quick-dev`.

This skill is the native Claude Code conversion of the legacy quick-spec workflow at `_gaia/lifecycle/workflows/quick-flow/quick-spec/` (`workflow.yaml` + `instructions.xml`; no checklist, no template, no stack binding beyond `dev-*`). The step order, both Scope prompts, the escape-hatch threshold, and the output path are preserved verbatim per ADR-041 and NFR-053.

## Critical Rules

- **If scope exceeds the quick threshold (more than 5 files OR more than 1 day), offer escalation to the full lifecycle before producing the spec.** This is the legacy guardrail — do not remove it, do not soften it, do not make it interactive-only. Suggest `/gaia-create-prd` on escalation.
- **Ask both Scope prompts verbatim.** The exact prompts are "What small change or feature do you want to spec?" and "Which files are likely affected?" — do not paraphrase.
- **The output path is fixed:** `.gaia/artifacts/implementation-artifacts/quick-spec-{spec_name}.md`. Do not invent a different folder or filename convention.
- **If `{spec_name}` is not supplied on invocation, prompt for it at Step 5** before writing the file. This matches the legacy `{spec_name}` placeholder resolution.
- **The five output sections are fixed and ordered:** (1) Summary, (2) Files to change, (3) Implementation steps, (4) Acceptance criteria, (5) Risks. Do not add sections, do not drop sections, do not reorder them.
- **Do not dispatch to a stack-specific developer agent here.** The legacy workflow has `agent: dev-*` with no auto-detect — the quick-spec step itself is stack-agnostic. The stack is selected downstream by `/gaia-quick-dev` (story E28-S117).
- **Do not read agent memory sidecars.** The legacy workflow does not load memory at any step; `dev-*` agents are Tier 3 (decision-log only) and this skill preserves that behavior.

## Inputs

1. **Spec name** — optional, via `$ARGUMENTS`. Used as the `{spec_name}` placeholder in the output filename. If missing, prompt at Step 5.

## Pipeline Overview

The skill runs five steps in strict order, mirroring the legacy `quick-spec/instructions.xml`:

1. **Scope** — ask the two canonical questions
2. **Quick Analysis** — identify affected files and dependencies, estimate scope
3. **Escape Hatch Check** — if scope exceeds the quick threshold, offer escalation to the full lifecycle
4. **Generate Quick Spec** — assemble the lightweight implementation plan
5. **Generate Output** — write the spec to `.gaia/artifacts/implementation-artifacts/quick-spec-{spec_name}.md`

### Step 1 — Scope

Ask the user these two questions verbatim, one at a time, and capture the answers:

1. "What small change or feature do you want to spec?"
2. "Which files are likely affected?"

Do not paraphrase. Do not skip either prompt. Record the responses; they feed Step 2.

### Step 2 — Quick Analysis

Using the user's Scope answers:

- Identify affected files and any direct dependencies (imports, config references, shared utilities, test files that would need updating).
- Estimate scope along two dimensions: **files changed** (count) and **complexity** (rough day estimate — under a day, around a day, more than a day).
- Note any obvious follow-on work that is clearly out of scope for the quick spec (e.g., architecture changes, new ADRs, cross-cutting refactors).

Keep this lightweight. A paragraph of analysis plus a short list of files is enough.

### Step 3 — Escape Hatch Check

Apply the scope-threshold heuristic from the legacy workflow:

- If the estimate shows **more than 5 files** affected, OR **more than 1 day** of effort, the change is too big for a quick spec.
- Offer escalation to the full lifecycle. Suggested message:

  > This looks bigger than a quick spec. It touches {N} files and is estimated at ~{days}d. Would you like to escalate to the full lifecycle? Run `/gaia-create-prd` to start with a PRD, then `/gaia-create-arch` and `/gaia-create-epics-stories`.

- If the user confirms escalation: suggest `/gaia-create-prd` and stop — do not write a quick-spec file.
- If the user declines: continue with the quick spec (explicitly acknowledge the risk in Step 5's "Risks" section).
- If scope is within the threshold (≤ 5 files AND ≤ 1 day): continue silently — no escalation prompt.

### Step 4 — Generate Quick Spec

Assemble the lightweight implementation plan. This is a draft held in memory — the file write happens in Step 5. The draft must include the five canonical sections (and only these five, in this order):

1. **Summary** — one or two sentences: what is changing and why.
2. **Files to change** — bulleted list of files to create, modify, or delete, with a one-line description per file.
3. **Implementation steps** — numbered steps describing the work in execution order. Keep each step small enough that a developer can tick it off in one sitting.
4. **Acceptance criteria** — bulleted or Given/When/Then list. One criterion per user-observable behavior. The criteria must be verifiable without additional context.
5. **Risks** — bulleted list of known risks, assumptions, or open questions. If Step 3 offered an escalation and the user declined, log that decision here.

Do not invent new sections. Do not inflate the spec with narrative prose — it is a quick spec on purpose.

### Step 5 — Generate Output

Resolve the output path: `.gaia/artifacts/implementation-artifacts/quick-spec-{spec_name}.md`.

- If `{spec_name}` was supplied as `$ARGUMENTS` in Step 1, use it directly.
- If `{spec_name}` was not supplied, prompt: "What short name should this quick spec use in its filename? (e.g., `add-dark-mode-toggle`)" — use lowercase, hyphens, no spaces. Use the response as `{spec_name}`.

Write the file with this structure:

```markdown
# Quick Spec: {title derived from Step 1 answer}

## Summary

{summary from Step 4}

## Files to change

- {file path} — {one-line description}
- ...

## Implementation steps

1. {step 1}
2. {step 2}
3. ...

## Acceptance criteria

- {AC1}
- {AC2}
- ...

## Risks

- {risk / assumption / declined-escalation note}
- ...
```

Confirm the file was written and report the path back to the user. Suggest the next step:

> Quick spec written to `.gaia/artifacts/implementation-artifacts/quick-spec-{spec_name}.md`. Run `/gaia-quick-dev {spec_name}` to implement it.

## Edge Cases

- **Escape hatch declined — continue as quick spec:** continue silently after logging the decline in the "Risks" section of the output. Do not block the write.
- **`{spec_name}` contains spaces or uppercase:** normalize to lowercase-with-hyphens before resolving the output path.
- **Output file already exists:** warn the user and ask whether to overwrite, rename, or abort. Do NOT silently overwrite — the legacy flow had no overwrite protection because it relied on the workflow engine's template-output checkpoint; the native flow must be explicit.
- **MCP / Figma / design tokens:** out of scope for quick-spec. If the user asks about design tokens, route them to `/gaia-create-ux`.
- **Agent memory:** do not load any sidecar. Do not write any sidecar on completion. This is intentional per the legacy behavior.

## References

- Legacy source: `_gaia/lifecycle/workflows/quick-flow/quick-spec/workflow.yaml` + `instructions.xml` — parity reference for NFR-053.
- Canonical SKILL.md shape: `plugins/gaia/skills/gaia-create-story/SKILL.md` (Cluster 7).
- Sibling story: `E28-S117` — converts `/gaia-quick-dev` to consume the spec produced here.
- Downstream gate: `E28-S118` — Cluster 16 end-to-end quick-spec → quick-dev test.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-048 — Program-close deletion policy for legacy engine/workflows/tasks.
- FR-323 — Native Skill Format Compliance.
- NFR-048 — 40–55% activation-budget reduction vs legacy workflow engine.
- NFR-053 — Functional parity with the legacy workflow.
