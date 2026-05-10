# GAIA Subagent Frontmatter Schema

**Status:** Canonical reference for E28-S19..S23 native conversion cluster.
**Owner:** GAIA Native Conversion Program (Epic E28).
**Pinned from:** E28-S1 Claude Code marketplace schema pin.

This document enumerates every YAML frontmatter field permitted on a GAIA
subagent file under `plugins/gaia/agents/`. Every agent file converted under
E28-S19..S23 MUST conform to this schema. New fields MAY NOT be introduced
without an ADR amending ADR-041.

## References

- **ADR-041 — Native Execution:**
  `docs/planning-artifacts/architecture.md#ADR-041 Native Execution`.
  ADR-041 establishes that GAIA subagents run as native Claude Code subagents,
  not under the legacy `_gaia/core/engine/workflow.xml` engine. This schema is
  the concrete frontmatter contract that makes native execution possible.
- **Feature Brief — GAIA Native Conversion:**
  `docs/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md`
  (specifically the Cluster 3 subagent pattern section, P3-S1). The feature
  brief defines the `name` / `model` / `description` / `context` / `allowed-tools`
  shape and the `## Memory` loader pattern that this schema enforces.

Both documents are load-bearing: any conflict between this schema and those
sources MUST be resolved by amending ADR-041 (the architecture decision record),
which then cascades back into this file.

## Required fields

| Field | Type | Required | Allowed values | Description |
|-------|------|----------|----------------|-------------|
| `name` | string | Yes | Lowercase kebab-case identifier matching the filename (sans `.md`). `_`-prefixed names are reserved for abstract/template files (e.g., `_base-dev`). | Canonical agent id. Used by Claude Code to address the subagent and by GAIA tooling (memory-loader, review-gate) as the key. |
| `model` | string | Yes | One of: `claude-opus-4-6`, `claude-opus-4-7`, `claude-sonnet-4-5`, `claude-haiku-4-5`, or `inherit`. | Model the subagent runs on. `inherit` defers to the parent session model. Dev and review agents typically pin `claude-opus-4-6`; lightweight helpers pin `claude-haiku-4-5`. The Val (`validator`) subagent is the canonical exception — it pins `claude-opus-4-7` per ADR-074 C2 (framework-wide Val opus-pin contract), so any skill dispatching Val MUST inherit that pin and never silently degrade to a cheaper model. |
| `description` | string | Yes | Non-empty single-line human description, max 240 characters. | Shown in orchestrator routing menus and used by the Claude Code marketplace. MUST begin with the agent's role, not a verb. |
| `context` | string | Yes | `main` or `fork`. | `main` = the subagent runs in the calling session's context (dev agents, orchestration helpers). `fork` = the subagent runs in an isolated forked context window (review gate agents, evaluators that must not pollute the main context). `_base-dev` and all stack dev agents MUST use `main`. `fork` is reserved for review gate agents converted in a later cluster. |
| `allowed-tools` | list[string] | Yes | Subset of the Claude Code tool set: `Read`, `Write`, `Edit`, `Bash`, `Grep`, `Glob`, `WebFetch`, `WebSearch`, `Task`, `Agent`, `Skill`. Ordering is not significant. | Whitelist of tools the subagent may call. MUST be the minimum set required. Dev agents get the full code-editing set; review agents get `Read, Grep, Glob` plus whatever is needed to emit a report. `Agent` enables subagent invocation; `Skill` enables skill delegation. |

## Optional fields

| Field | Type | Required | Allowed values | Description |
|-------|------|----------|----------------|-------------|
| `abstract` | bool | No (default `false`) | `true` or `false` | Marks a template file that cannot be invoked directly (e.g., `_base-dev`). Abstract agents are skipped by `reload-plugins` discovery but MUST still pass this schema. |
| `aliases` | list[string] | No | List of lowercase kebab-case strings. | Alternate names the orchestrator accepts when routing. Used for persona names (e.g., `cleo` as an alias for `dev-typescript`). |
| `tags` | list[string] | No | Free-form lowercase tags. | Used by orchestrator search and marketplace categorization. |

## Forbidden fields

The following fields were used by the legacy `_gaia/` engine and MUST NOT appear
in any file under `plugins/gaia/agents/`:

- `template:` — legacy engine templating marker.
- `version:` on agent files — versioning is tracked by the plugin manifest, not per-agent.
- `used_by:` — legacy workflow engine routing hint.
- Any XML blocks (`<agent>`, `<memory-reads>`, `<shared-behavior>`, `<specification>`,
  `<rules>`, `<quality-gates>`, `<skill-registry>`) in the body. Native subagents
  use plain Markdown; XML is parsed by the legacy engine only.

## Body structure

Subagent bodies under native execution MUST follow this top-level section order:

1. `## Memory` — inline bash memory loader invocation (see below).
2. `## Mission` — one-paragraph mission statement.
3. `## Persona` — ported from legacy persona block.
4. `## Rules` — bulleted non-negotiables.
5. `## Skills` — JIT skill references (by skill id, resolved at runtime).
6. Any domain-specific sections (Scope, Authority, DoD, Constraints).

## Memory loader pattern

Every non-abstract subagent — and `_base-dev` as the shared template — MUST
include a `## Memory` section that invokes the memory loader as inline bash:

```markdown
## Memory

!${PLUGIN_DIR}/scripts/memory-loader.sh <agent-name> ground-truth
```

- `${PLUGIN_DIR}` is resolved by Claude Code at subagent spawn time to the
  plugin's installed directory.
- The first argument is the agent name (matching the `name:` field).
- The second argument is the memory scope. Per ADR-046 (Hybrid Memory
  Loading) and FR-331, every subagent MUST call with `ground-truth` — this is
  Path 1 of the hybrid model (invocation-time ground-truth injection). The
  `decision-log` tier is reserved for Path 2 (skill-execution-time inline
  calls, not agent-load-time). The `all` tier is retained by `memory-loader.sh`
  for ad-hoc debugging but MUST NOT be used in agent files.
- `memory-loader.sh` is delivered by E28-S13 and lives at
  `plugins/gaia/scripts/memory-loader.sh`. Its CLI shape is considered stable
  once E28-S13 ships; this schema pins only the invocation pattern.
- Tier 2 and Tier 3 agents (no `ground-truth.md` sidecar) still use the
  `ground-truth` token for uniformity — the script returns empty stdout with
  exit 0 when the file is missing (E28-S13 AC4), so the line is safe to inject
  into every agent regardless of tier.

### Section placement (ADR-046 / FR-331)

The `## Memory` section MUST sit AFTER the agent's persona/identity block
(the last of `## Identity`, `## Persona`, `## Expertise`, or the
persona-paragraph body when no explicit heading is used) and BEFORE the first
behavioural section (`## Rules`, `## Activation`, `## Scope`, or equivalent
— whichever appears first). This post-persona / pre-behavioural ordering
matches how Claude Code subagent prompts are assembled in the forked context
(ADR-041) and keeps the persona declarative at the top of the file for
humans reading it.

The placement rule is enforced by the ATDD suite at
`tests/atdd/e28-s147-subagent-memory-injection.bats`; the mechanical rewrite
helper lives at `scripts/dev/rewrite-agent-memory-injection.sh`. New agents
added beyond the current 28 MUST inherit this shape — run the rewrite helper
or copy `_base-dev.md`'s `## Memory` block as the template.

## Validation

Files under `plugins/gaia/agents/**/*.md` are linted by
`.github/scripts/lint-agent-frontmatter.sh` (the agent-frontmatter linter added
alongside this schema under E28-S19). The linter enforces:

- Presence of all required fields.
- Non-empty string values for string fields.
- `context` is one of `main` or `fork`.
- `allowed-tools` is a non-empty list.

See E28-S7 for the parallel SKILL.md frontmatter linter; the agent linter
mirrors its structure and error format.

## Runtime audit (E28-S226 — 2026-05-10)

Empirical comparison against the published Claude Code plugin loader schema
(reference: `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/*/agents/*.md`,
e.g., `code-modernization/agents/architecture-critic.md`,
`feature-dev/agents/code-explorer.md`) yields the following PASS / IGNORED-AT-LOAD
table for each GAIA agent frontmatter field:

| Field | Status | Evidence | Reconciliation |
|-------|--------|----------|----------------|
| `name` | PASS | Identical key shape across GAIA and reference plugins. | None — keep as-is. |
| `description` | PASS | Identical. | None. |
| `model` | PASS | Reference plugins (e.g., `code-explorer`) use `model: sonnet` / `model: opus`. GAIA pins specific model ids — accepted by the loader. | None. |
| `context` | IGNORED-AT-LOAD | No `context:` key appears in any reference plugin's agent frontmatter. The Claude Code subagent runtime determines the execution context from the dispatch site (`Task` tool with `subagent_type`); the subagent file itself does not declare it. | Field is GAIA-internal documentation only. Retain in source until an explicit cleanup story removes it; the `gaia:<persona>` dispatch convention (this story) makes the loader-side `context` decision the source of truth. |
| `allowed-tools` | IGNORED-AT-LOAD | Reference plugins use `tools: Read, Grep, ...` (comma-separated string). GAIA writes `allowed-tools: [Read, Grep]` (YAML list). Loader silently drops the unknown key, leaving the subagent with default tool permissions. | DEFERRED — rename `allowed-tools: [...]` to `tools: a, b, c` across all 28 agent files. Tracked as a Finding on E28-S226 for follow-up because the rename requires per-agent functional smoke verification (AC7 scope), which is outside the prose-rewrite scope of this story. The deferral leaves agents running with default permissions today; that is the existing behavior, not a regression introduced by this story. |
| `abstract` | PASS | YAML bool; the loader simply ignores unknown bools without error. GAIA uses it to skip `_base-dev` from the dispatch registry. | None. |
| `aliases` | PASS / GAIA-internal | YAML list; ignored by the Claude Code loader. GAIA tooling consumes it for orchestrator routing. | None — keep as GAIA-internal, document the duality here. |
| `tags` | PASS / GAIA-internal | YAML list; ignored by the Claude Code loader. GAIA tooling consumes it for marketplace / search categorization. | None — keep as GAIA-internal. |
| `color` (NOT used by GAIA) | PASS | Reference plugins use `color: yellow` for orchestrator routing menus. | Optional; GAIA may adopt it later for orchestrator visuals. |

### Migration plan (deferred)

The `allowed-tools` → `tools` rename is the only material reconciliation. Because
the rename touches every agent file and requires per-agent functional smoke
verification to confirm the loader honors the new keys without surprising the
subagent persona, it is recorded as a follow-up story on the E28 backlog rather
than landed under E28-S226. The deferred-rename Finding is recorded on the
E28-S226 story file.
