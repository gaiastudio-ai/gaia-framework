---
name: gaia-test-a11y
description: Execute post-deploy accessibility smoke tests via axe-core, pa11y, or Lighthouse adapters under the tool adapter contract. Phase 3A toolkit + Phase 3B LLM judgment + verdict resolver. Shares the WCAG-aligned a11y rubric (rubrics/base/a11y.json) with the planning-phase /gaia-validate-design-a11y and pre-merge /gaia-review-a11y skills. Use when "run a11y tests" or /gaia-test-a11y.
argument-hint: "[story-key] [--adapter <name>] [--target-url <url>] [--wcag-level <A|AA|AAA>]"
allowed-tools: [Read, Grep, Glob, Bash]
type: action
verdict: true
phase: deployment
adapters: [axe-core-a11y, pa11y-a11y, lighthouse-a11y]
triggers:
  - run a11y tests
  - test a11y
  - accessibility test
  - post-deploy a11y
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | sed -n 's/^SURFACE-WARNING: //p' | head -n1)
  cat "$SENTINEL_PATH"
fi
```

**Surface contract.** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-test-a11y/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review and action skill. For `/gaia-test-a11y` it means: the configured a11y adapter (axe-core, pa11y, or Lighthouse, swappable via `test_execution.a11y.adapter` config or `--adapter` CLI flag) runs in Phase 3A and emits a structured `analysis-results.json` artifact. The LLM then performs an a11y severity-triage semantic judgment in Phase 3B — applying the shared WCAG rubric — but cannot override a deterministic adapter failure or Critical-tier WCAG violation. The verdict is computed by `verdict-resolver.sh`; the LLM never computes the verdict in natural language.

This skill is a deployment-phase action skill and a peer of `/gaia-test-e2e`, `/gaia-test-perf`, and `/gaia-test-dast` — same Phase 3A/3B/3C plumbing, a11y-specific rubric.

**Three-phase a11y family (shared rubric):** This skill is the post-deploy member of the three-phase a11y family. All three phases load the **same** rubric layer at `rubrics/base/a11y.json` so a contrast violation flagged at planning is the same severity tier as the same violation flagged at deployment:

- `/gaia-validate-design-a11y` — planning (agent: Christy)
- `/gaia-review-a11y` — pre-merge gate (conditional, agent: Christy)
- `/gaia-test-a11y` — post-deploy smoke (this skill, agent: Sable)

**Static vs dynamic distinction:** `/gaia-review-a11y` (pre-merge, static) reads code and finds WCAG violations in markup, ARIA usage, focus management, and CSS contrast tokens. `/gaia-test-a11y` (this skill, deployment-phase, dynamic) runs an a11y scanner against a live deployed page and reports rendered violations. They are complementary, not alternatives — both consume the same rubric so severity classification is consistent across phases.

**Fork context semantics:** Phase 3B LLM judgment runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). Phase 3A is deterministic shell. Phase 4 verdict resolution and Review Gate update happen in the parent context via `verdict.sh` + `finalize.sh`.

**Adapter swappability:** Resolved by `select-adapter.sh` with first-match-wins precedence: `--adapter <name>` CLI flag → `test_execution.a11y.adapter` from `.gaia/config/project-config.yaml` → default `axe-core-a11y`.

**Graceful degradation:** When `tool-availability-probe.sh` returns `expected_and_missing` (e.g., `axe` / `pa11y` / `lighthouse` not on PATH), Phase 3A emits a `checks[].status: errored` row with a diagnostic `error_reason` naming the missing tool and installation hint. `verdict-resolver.sh` maps this to BLOCKED — never to a false APPROVE.

## Critical Rules

- A story key argument MAY be provided. If absent, the deployment-phase invocation runs in story-less mode and skips the Review Gate update step.
- The `tool-availability-probe.sh` foundation script MUST be present at `plugins/gaia/scripts/tool-availability-probe.sh`.
- The `verdict-resolver.sh` foundation script MUST be present at `plugins/gaia/scripts/verdict-resolver.sh`.
- This skill is READ-ONLY in the fork (Phase 3B). Phase 4 `verdict.sh` runs in main context with Bash + the explicit narrow tool set required by `review-gate.sh`.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary: APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Adapter `run.sh` invocation MUST go through `tool-availability-probe.sh` first — the probe's three-state classification is the authoritative gate.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).
- The shared rubric at `rubrics/base/a11y.json` is the single source of truth for severity classification across all three a11y phases. WCAG level escalation (A → AA → AAA) is layered via `rubrics/regimes/wcag-2.1-aa.json` and `rubrics/regimes/wcag-2.1-aaa.json`.

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in analysis-results.json
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce LLM findings that match by `{category, severity}`. Textual message variation is allowed.

## Configuration Schema

Project-config block consumed by this skill (`.gaia/config/project-config.yaml`):

```yaml
test_execution:
  a11y:
    adapter: axe-core-a11y       # axe-core-a11y | pa11y-a11y | lighthouse-a11y (default: axe-core-a11y)
  deployment:
    a11y_test:
      target_url: https://staging.example.com
      wcag_level: AA              # A | AA | AAA (default: AA)
      timeout_seconds: 120
```

The `wcag_level` field controls rubric escalation:

- `A` — load `rubrics/base/a11y.json` only (Level A criteria).
- `AA` (default) — load base + `rubrics/regimes/wcag-2.1-aa.json` regime layer.
- `AAA` — load base + `rubrics/regimes/wcag-2.1-aa.json` + `rubrics/regimes/wcag-2.1-aaa.json`.

CLI override: `--wcag-level <A|AA|AAA>` beats the project-config value at the per-invocation level. The level is forwarded to the adapter (axe-core / pa11y) which translates it into the tool-native tag set (`wcag2a` / `wcag2aa` / `wcag2aaa` for axe; `WCAG2A` / `WCAG2AA` / `WCAG2AAA` for pa11y; full a11y category for Lighthouse with rubric-side filtering).

## Phases

### Phase 1 — Resolve adapter (config)

- Resolve `compliance.ui_present` via `resolve-config.sh`. If the value is not `true`, exit early with `SKIPPED — compliance.ui_present is not true` (the orchestrator at `/gaia-review-all` performs this check via `--skip-a11y`; this guard is defense-in-depth). Mirrors `/gaia-review-a11y` L29 for three-phase a11y family gating consistency.

Invoke `scripts/select-adapter.sh [--adapter <name>] [--config <project-config-yaml>]`. The script emits the absolute adapter directory path on stdout. Abort the run with an actionable diagnostic if the resolved adapter directory is missing.

### Phase 2 — Availability probe + Phase 3A toolkit (evidence collection)

Invoke `scripts/phase3a-collect.sh --adapter-dir <path> --output-dir <dir> [--target-url <url>] [--wcag-level <A|AA|AAA>] [--config <path>] [--story-key <key>]`. The script:

1. Calls `tool-availability-probe.sh --adapter-dir <path> --file-list <synthetic>` to classify availability.
2. If `available`, invokes the adapter's `run.sh` to execute the a11y scan, capturing stdout/stderr to `evidence/`.
3. Writes a top-level `analysis-results.json` with `checks[0]` reflecting the adapter outcome.

Probe state to `checks[].status` mapping:

| Probe state             | check.status | Verdict resolver maps to |
|-------------------------|--------------|--------------------------|
| `available` (run.sh exit 0) | `passed`   | APPROVE eligible         |
| `available` but run.sh exit ≠ 0 | `errored` | BLOCKED              |
| `expected_and_missing`  | `errored` (with diagnostic) | BLOCKED      |
| `ran_and_errored`       | `errored` (with diagnostic) | BLOCKED      |
| `not_applicable`        | `skipped`    | non-blocking             |

### Phase 3B — LLM judgment (forked context)

Persona resolved via `agent-overlay.sh --skill gaia-test-a11y` → `sable` (Test Architect). The fork loads `knowledge/a11y-rubric.md` plus the layered rubric output from `rubric-loader.sh --skill a11y` (base + WCAG regime layers per `wcag_level`) and produces `llm-findings.json` covering:

- **WCAG severity triage** — interpretation of axe / pa11y / Lighthouse violations against the shared rubric. Critical for any Level-A keyboard or contrast failure (matches `/gaia-review-a11y` static classifier).
- **False-positive screening** — explicit "no actionable findings" when the adapter reports only Informational items (e.g., Lighthouse "manual checks" advisories).
- **Coverage gaps** — flagged when the scan omits known-interactive routes (declared in project-config) or when the adapter cannot exercise authenticated views.
- **Rubric consistency** — the rubric the LLM applies in this skill is byte-identical to the one applied by `/gaia-review-a11y`. Severity classifications MUST agree across the two skills for the same rule ID — a regression here is a CRITICAL finding.

The fork is read-only; the parent context writes `llm-findings.json` to the output directory.

### Phase 4 — Verdict resolution + Review Gate update

Invoke `scripts/verdict.sh --analysis-results <path> --llm-findings <path> [--story-key <key>] [--gate "Accessibility Review"]`. The script:

1. Calls `verdict-resolver.sh --skill gaia-test-a11y` to compute the verdict (precedence: errored > tool-failed-blocking > LLM-Critical > APPROVE).
2. When `--story-key` and `--gate` are provided, invokes `review-gate.sh update` to update the matching Review Gate row to PASSED (APPROVE) or FAILED (REQUEST_CHANGES, BLOCKED). Deployment-phase invocations without an associated story skip this step.
3. Echoes the verdict on stdout for downstream chaining.

### Phase 5 — Report generation

After verdict resolution, the lifecycle hook `scripts/finalize.sh` writes a checkpoint, emits a `workflow_complete` lifecycle event, and (when an output directory was configured) renders a human-readable Markdown report alongside `analysis-results.json` summarizing findings by severity, grouped by WCAG criterion ID.

## Severity Rubric

> See `knowledge/a11y-rubric.md` for the full per-tier rubric and the shared-rubric contract with `/gaia-review-a11y`. Categories: a11y.semantic-html, a11y.aria-usage, a11y.keyboard-navigation, a11y.color-contrast, a11y.screen-reader-support. Severity tiers: Critical, High, Medium, Suggestion.

## Adapters

This skill ships with three a11y adapters under `plugins/gaia/scripts/adapters/`:

- **`axe-core-a11y/`** — invokes `axe <url> --tags <wcag-tags> --save - --stdout`. Default. Tags resolve from `--wcag-level` (A → `wcag2a`; AA → `wcag2a,wcag2aa`; AAA → `wcag2a,wcag2aa,wcag2aaa`).
- **`pa11y-a11y/`** — invokes `pa11y --reporter json --standard <std> <url>`. Standard resolves from `--wcag-level` (A → `WCAG2A`; AA → `WCAG2AA`; AAA → `WCAG2AAA`). pa11y exit 2 (audit completed with findings) is normalized to a successful run.
- **`lighthouse-a11y/`** — invokes `lighthouse <url> --output=json --quiet --only-categories=accessibility`. The full a11y category is captured; the rubric loader filters by `--wcag-level` at judgment time.

All three adapters honour the canonical tool adapter contract (`adapter.json`, `run.sh`, `test/contract.bats`) PLUS the deployment-phase additive flags `--target-url <url>` and `--wcag-level <A|AA|AAA>`.

## Output Contract

The skill emits two JSON files in the configured output directory:

- `analysis-results.json` — Phase 3A artifact, canonical schema (`plugins/gaia/schemas/analysis-results.schema.json`).
- `llm-findings.json` — Phase 3B artifact, schema-compatible with the verdict resolver's `--llm-findings` input.

The verdict (APPROVE | REQUEST_CHANGES | BLOCKED) is emitted on stdout by `verdict.sh`.

## Design Notes

- Review skill evidence/judgment split.
- Three-tier review pipeline (seven-phase structure).
- Tool adapter framework (`adapter.json` schema, `run.sh` contract, four-state probe).
- Layered rubric loading (base + regime composition).
- Deployment-phase action skill pattern.
- Deployment-phase a11y execution.
- Env-var-only credentials.
- Three-phase a11y reorganization (planning + pre-merge sibling phases share this rubric).
- Peer deployment-phase action skills.
