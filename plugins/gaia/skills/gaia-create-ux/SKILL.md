---
name: gaia-create-ux
description: Create UX design specifications through collaborative discovery with the ux-designer subagent (Christy) — Cluster 5 planning skill. Use when the user wants to produce a validated UX design document from an existing PRD, covering personas, information architecture, wireframes, interaction patterns, accessibility, and Figma integration.
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
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

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-ux/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh ux-designer decision-log

## Mission

You are orchestrating the creation of a UX Design document. The UX design authoring is delegated to the **ux-designer** subagent (Christy), who conducts user research, designs information architecture, creates wireframes, and produces the final artifact. You load the PRD, validate inputs, coordinate the multi-step flow, and write the output to the canonical post-ADR-111 path `.gaia/artifacts/planning-artifacts/ux-design.md` using the carried `ux-design-assessment-template.md` for brownfield assessments.

**Path resolution (AF-2026-05-21-14).** All UX path references in this SKILL.md use the canonical post-ADR-111 location `.gaia/artifacts/planning-artifacts/ux-design.md`. Pre-ADR-111 projects continue to work via canonical-first two-tier resolution at the script layer (`scripts/finalize.sh` already implements the E96-S7 partial-4c smart-fallback). When writing the UX design via the Write tool, target the canonical path; the pre-ADR-111 fallback is read-side only.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/2-planning/create-ux-design` workflow (brief Cluster 5, story P5-S4 / E28-S43). The step ordering, prompts, and output path are preserved verbatim from the legacy `instructions.xml` — do not restructure, re-prompt, or reorder.

## Critical Rules

- A PRD MUST exist before starting. Resolve via the sharded-fallback rule (ADR-069 / FR-396..402): first try `.gaia/artifacts/planning-artifacts/prd.md` (flat layout); if missing, fall back to `.gaia/artifacts/planning-artifacts/prd/prd.md` (sharded layout). If NEITHER exists, fail fast with "PRD not found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md — run /gaia-create-prd first."
- Every design decision must trace to a user need from the PRD.
- UX design authoring is delegated to the `ux-designer` subagent (Christy) via native Claude Code subagent invocation — do NOT inline Christy's persona into this skill body. If the ux-designer subagent (E28-S21) is not available, fail with "ux-designer subagent not available — install E28-S21" error.
- If `.gaia/artifacts/planning-artifacts/ux-design.md` already exists, warn the user: "An existing UX design was found. Continuing will overwrite it. Confirm to proceed or abort." Do not silently overwrite.
- Template resolution (Test05 F-013): pick the template by mode.
  - **Greenfield** (designing from the PRD, no existing UI to assess): load `ux-design-template.md` from this skill directory — the structural template covering personas, information architecture, user flows (happy + error paths), wireframe descriptions, interaction patterns, accessibility, design-system reuse, and Figma integration.
  - **Brownfield** (assessing an existing codebase's UI): load `ux-design-assessment-template.md`.
  - For either mode, a non-empty `custom/templates/{same-filename}` overrides the framework default (ADR-020 / FR-101).

## Steps

### Step 1 — Load PRD

- Resolve the PRD path via the sharded-fallback rule (Critical Rules above). Read the resolved PRD (flat `.gaia/artifacts/planning-artifacts/prd.md` OR sharded `.gaia/artifacts/planning-artifacts/prd/prd.md`).
- If neither path resolves, fail fast: "PRD not found at .gaia/artifacts/planning-artifacts/prd.md or .gaia/artifacts/planning-artifacts/prd/prd.md — run /gaia-create-prd first."
- Extract: user personas, user journeys, and functional requirements.
- If `.gaia/artifacts/planning-artifacts/ux-design.md` already exists: warn "An existing UX design was found at .gaia/artifacts/planning-artifacts/ux-design.md. Continuing will overwrite it. Confirm with user before proceeding."

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 1 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 2 — User Personas

Delegate to the **ux-designer** subagent (Christy) via `agents/ux-designer` to refine persona definitions.

- Refine persona definitions from PRD.
- Add: scenarios, goals, tech proficiency, accessibility needs.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 2 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 3 — Information Architecture

Delegate to the **ux-designer** subagent (Christy) via `agents/ux-designer` to design information architecture.

- Design sitemap and navigation structure.
- Define content hierarchy and page relationships.
- Map each page or section to the FR IDs it serves — every page must trace to at least one FR. Flag any user-facing FR from the PRD that has no corresponding page in the sitemap.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 3 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 4 — Wireframes

Delegate to the **ux-designer** subagent (Christy) via `agents/ux-designer` to create wireframes.

- Create text-based wireframe descriptions for key screens.
- Define layout, component placement, interaction patterns.
- Annotate each wireframe with the FR IDs it addresses. Flag any FR with user-facing behavior that has no wireframe representation.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 4 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 5 — Interaction Patterns

Delegate to the **ux-designer** subagent (Christy) via `agents/ux-designer` to define interaction patterns.

- Define common UI patterns used across the application.
- Specify component library or design system choices.
- Document form behaviors, validation, error states.
- Map each interaction flow to the corresponding user journey from the PRD. Every PRD user journey must have a defined interaction pattern.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 5 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 6 — Accessibility

- Define WCAG compliance targets (A, AA, AAA).
- Plan keyboard navigation, screen reader support.
- Define color contrast and text sizing standards.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 6 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 7 — Figma MCP Detection and Mode Selection

- Probe for available Figma MCP server.
- If Figma MCP available: present mode selection — [Generate] Create Figma frames alongside ux-design.md | [Import] Import existing Figma designs (read-only) | [Skip] Text-only UX spec, no Figma integration.
- If not available: skip Figma integration — proceed with text-only UX design output. Log: "No Figma MCP server detected. Generating markdown-only ux-design.md." **(Test05 F-014)** Do NOT leave the ux-design.md "Figma Integration" section empty: write the no-Figma placeholder so downstream stories are not blocked on a missing visual source. The canonical placeholder is —

  > **No Figma source — text-only UX design.** This document's wireframe
  > descriptions (§5) and interaction patterns (§6) are the single source of
  > truth for visual intent. When a Figma MCP server becomes available, re-run
  > `/gaia-create-ux` in `[Generate]` or `[Import]` mode to attach frames.

  This matches §9 of `ux-design-template.md`; emit it verbatim into the Figma section on the no-MCP path.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 7 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 8 — Generate Mode (if selected)

Generate mode is the only mode permitted to issue Figma MCP **write** calls (per FR-140 read-heavy/write-light policy and ADR-024). All write operations performed during this step MUST be captured in the FR-140 audit log so the Step 8e compliance audit can verify them.

#### 8a — UI Kit & Design Tokens

- Create the UI Kit page in Figma, extract design tokens, and create styles and components.
- Tokens land in the published-styles section of the file; component variants are authored as Figma component sets so the variant matrix below can be enumerated programmatically.

#### 8b — Per-Screen Viewport Frames (6 canonical viewports)

Generate per-screen frames at the canonical 6-viewport set — every viewport in this list MUST be generated (no exemptions; partial-viewport failures are recorded in the FR-140 audit per AC-EC5):

- **280px** — narrow handset / split-view minimum.
- **375px** — standard handset (iPhone-class).
- **600px** — small tablet portrait / large handset landscape.
- **768px** — tablet portrait (iPad-class).
- **1024px** — tablet landscape / small laptop.
- **1280px** — desktop minimum.

Persist the canonical list in `ux-design.md` frontmatter as `viewports: [280, 375, 600, 768, 1024, 1280]`. Per ADR-060 this list is static — do NOT introduce templating or runtime resolution.

#### 8c — Component State Variants (6 canonical states)

For every component authored in the UI Kit, generate all 6 state variants — `default, hover, active, disabled, error, loading` — as distinct design artifacts under the component's Figma node:

- `default` — resting state.
- `hover` — pointer over the component (web/desktop).
- `active` — pressed / engaged state.
- `disabled` — non-interactive state.
- `error` — invalid / failed state with error styling.
- `loading` — pending / async-busy state.

Record every component's variant matrix in the generated `component-specs.yaml` under each component's `variants:` key. Components missing a variant MUST carry a documented exemption in the spec — the audit treats undocumented gaps as a failure (AC-EC7 disambiguation rule applies on naming collisions).

#### 8d — Prototype Flow Connections

After per-screen frames are created, establish prototype flow edges between screens in the Figma file. Each flow edge connects a source frame to a destination frame and is labeled with the triggering interaction.

Record the resulting graph in `ux-design.md` under a `## Prototype Flows` section and a structured `prototype_flows:` block, e.g.:

```yaml
prototype_flows:
  - from: "Login"
    to: "Dashboard"
    trigger: "submit"
  - from: "Dashboard"
    to: "Settings"
    trigger: "tap settings icon"
```

Skip this sub-step only if the user defined a single screen — single-screen designs have no edges to generate.

#### 8e — Asset Export Catalogs (per platform, 1x/2x/3x)

Export raster assets for each platform target. The shared `figma-integration` skill provides the `export_asset` MCP wrapper; this sub-step wires the platform-specific output paths and density buckets:

- **iOS** — write to `{project-path}/design/ios/Assets.xcassets/<AssetName>.imageset/`. Each `.imageset` directory contains a `Contents.json` index and the three raster sizes: `<asset>.png` (1x), `<asset>@2x.png` (2x), and `<asset>@3x.png` (3x).
- **Android** — write to `{project-path}/design/android/res/drawable-mdpi/`, `drawable-hdpi/`, `drawable-xhdpi/`, `drawable-xxhdpi/`, and `drawable-xxxhdpi/`. The density mapping is `mdpi=1x`, `hdpi=1.5x`, `xhdpi=2x`, `xxhdpi=3x`, `xxxhdpi=4x`. The 1x/2x/3x asset trio MUST be present at the corresponding density buckets (`mdpi`/`xhdpi`/`xxhdpi`); `hdpi` and `xxxhdpi` are optional but recommended.

When the source asset is only available at 1x (AC-EC8), upscale from the largest available source and stamp `upscaled_from: {source_res}` into the asset metadata; emit a `warning` in the FR-140 audit instead of failing the export.

#### 8f — Record Figma Metadata & MCP Call Log

- Record Figma node IDs for every generated frame, component, and asset.
- Append every MCP call performed during Step 8 to the in-memory call log keyed `mcp_calls`. The Step 8g compliance audit consumes this log directly.
- Persist the Figma metadata block (file key, page IDs, screen→node mapping) into `ux-design.md`.

#### 8g — FR-140 Compliance Audit

At the end of Step 8 — after every write operation has been issued — emit the FR-140 compliance audit. The audit is the canonical enforcement point for the read-heavy/write-light policy per FR-140 and architecture.md §10.17.

Audit logic (reuses the read/write classification table hosted in `figma-integration/SKILL.md` §FR-140 Read/Write Classification Table — do NOT duplicate the table here):

1. Walk the `mcp_calls` log accumulated during Steps 8a–8f.
2. Categorize every call as `read` or `write` against the shared classification table.
3. Set `mode: "Generate"`.
4. Compute `fr_140_compliance` outcome — **pass | fail | incomplete**:
   - `pass` — at least one write call occurred AND every write call's `fr_140_scope` is `always_allowed` or `generate_only` AND mode is `Generate`.
   - `fail` — any write call occurred outside Generate mode OR any call's classification disallows it under the current mode. Populate `violations[]` with `{call, reason}` entries and abort downstream consumers (AC-EC4 defensive check).
   - `incomplete` — the run was interrupted (MCP unreachable, partial-viewport failure, etc.). Record the partial state and surface remediation guidance (AC-EC2, AC-EC5).

Emit the audit report in two places:

- **Human-readable** — append a `## FR-140 Audit` block to `ux-design.md` with the full call log and outcome.
- **Machine-parseable** — write `{project-path}/.figma-cache/audit.json` (gitignored) for bats consumption and downstream tools.

Audit data shape (canonical):

```yaml
fr_140_audit:
  mode: "Generate"
  fr_140_compliance: "pass"  # pass | fail | incomplete
  mcp_calls:
    - call: "get_file"
      type: "read"
    - call: "create_frame"
      type: "write"
  violations: []  # populated when fr_140_compliance == "fail"
```

The audit logic is symmetric with E46-S2's Import-mode zero-write assertion — the shared classification table and the audit data shape are reused there unchanged.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 8 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 9 — Import Mode (if selected)

Import mode is **read-only** by FR-140 contract — `expected_writes: 0`, `allowed_write_calls: []`. Every Figma MCP call MUST be a read; any write call is intercepted by the pre-dispatch guard (Step 9f) and the run halts with an FR-140 compliance violation. The end-of-step audit (Step 9f) is the canonical proof that no write occurred. Implementation reuses the FR-140 audit infrastructure delivered by E46-S1 (the audit logger, classifier, and report formatter) — Import mode extends it with the zero-write enforcement configuration only. Cross-reference: PRD §FR-350, architecture.md §10.17, and the canonical FR-140 read/write classification table hosted in `figma-integration/SKILL.md`.

#### 9a — File Key Validation

Accept either a Figma URL (`https://www.figma.com/file/{key}/...`) or a bare file key string. Delegate to the `validateFigmaFileKey(input)` helper exposed by `figma-integration` — this is the same helper used by `/gaia-edit-ux` and the `/gaia-code-review` fidelity gate so the parsing rule stays consistent across the framework. Halt **before any Figma API call** if the input is empty, malformed, too short (under 22 characters), or contains non-alphanumeric characters; return error `"Invalid Figma file key: '{input}'. Expected a Figma URL (https://www.figma.com/file/{key}/...) or the 22+ character key directly."` (AC5, AC-EC1). On parse success the normalised key is passed forward to Step 9b.

#### 9b — Depth-1 Metadata Check

Issue exactly one `figma_get_file` call with `depth=1`. The intent is to fetch only the file-level metadata (no frame tree, no node payload) — this is the cheapest possible read that still proves the file exists and the API token has access. Record `name`, `lastModified`, and `version` into the audit log and surface them in the `ux-design.md` Figma metadata section (Step 9g). If the call returns 404, halt with `"Figma file not found: {key}. Verify the file key and access permissions."` and emit zero tokens / zero partial outputs (AC-EC2). If the call returns 401/403, halt with guidance referencing the Figma MCP server config and the required scopes `files:read` + `file_content:read` (AC-EC3). 429 responses inherit the shared backoff schedule from `figma-integration` (AC-EC7).

#### 9c — Frame Discovery and Viewport Classification

List frames on the canvas (filtered to `FRAME` nodes at depth-2). For each frame, call the `classifyViewport(width_px)` helper from `figma-integration` to map the frame width to one of the canonical viewport categories: 280px, 375px, 600px, 768px, 1024px, 1280px, or `custom` if the width is outside the canonical set (AC7, AC-EC8). Use **exact-match** (not nearest-neighbour) so a 400px frame is flagged `custom` rather than silently bucketed as 375px — this matches V1 behaviour and keeps classification deterministic. Record the result in the `ux-design.md` viewport distribution table (`| Viewport | Frame count | Frame names |`, sorted in canonical order with `custom` last). Frames with `custom` width receive a caution flag `"Frame '{name}' uses width {width}px which is outside the canonical viewport set. Review whether this frame is intentional or a stale artifact."`

#### 9d — W3C DTCG Token Extraction

Call the `figma-integration` read API to extract Figma styles + variables, then transform each into a W3C DTCG token entry with the canonical key set: `$value`, `$type`, and optional `$description`. Map Figma style types per the DTCG draft — color → `color`, typography → `typography`, effect → `shadow`, float/number variable → `dimension` or `number`. Tokens whose source Figma type is outside the DTCG registered set (e.g., `BOOLEAN`) are mapped to the closest DTCG type (`boolean` or `other`) with the `$description` annotation preserving the source Figma type (AC-EC6). Emit the document to `.gaia/artifacts/planning-artifacts/design-system/design-tokens.json` using the DTCG **nested-group convention** (e.g., `{"colors": {"primary": {"$value": "#0066CC", "$type": "color"}}}`) — flat dot-notation token names are discouraged by the DTCG draft. Include a top-level `$schema` reference to the DTCG draft schema URL so downstream tooling can validate. Apply delta-sync semantics per FR-168: do NOT overwrite tokens that already exist and are unchanged; only add new tokens and update changed token values (Subtask 5.3).

#### 9e — Component Specs Generation

Walk imported Figma components filtered to `COMPONENT` and `COMPONENT_SET` nodes. Emit one entry per component under a top-level `components:` map in `.gaia/artifacts/planning-artifacts/design-system/component-specs.yaml`. Each entry carries `name`, `figma_node_id`, `variants` (from component-set child names), `states` (inferred from variant property names — `default`, `hover`, `active`, `disabled`, `error`, `loading`), `props` (extracted from component description + variant properties), and `platform_tokens: {}` as an empty placeholder (populated later by platform resolvers per FR-172). Add `schema_version: "1.0"` at the root per the test-plan.md:891 contract. If a component is missing a name or node id, skip its emission and log the skipped component in the FR-140 audit section. When the imported file has zero components (AC-EC5), still emit `component-specs.yaml` with `schema_version: "1.0"` and an empty `components: {}` map; `ux-design.md` notes "No components found".

#### 9f — FR-140 Compliance Audit (Read-Only)

At end-of-step — after all read operations have returned — run the FR-140 compliance audit. Reuse the audit infrastructure delivered by E46-S1 (do NOT re-implement); Import mode configures it with `expected_writes: 0` and `allowed_write_calls: []`.

Audit logic:

1. Walk the `mcp_calls` log accumulated during Steps 9a–9e.
2. Categorize every call as `read` or `write` against the shared classification table in `figma-integration/SKILL.md` §FR-140 Read/Write Classification Table.
3. Set `mode: "Import"`.
4. Compute `fr_140_compliance` outcome — **pass | fail | incomplete**:
   - `pass` — every call is `read`; zero `write` calls observed.
   - `fail` — any `write` call appears in the log (even classified as `write / blocked`); enumerate every violating write call with its method name and index in the `violations[]` array (AC-EC4).
   - `incomplete` — the run was interrupted (MCP unreachable, 429 exhaustion, file not found mid-run); record the partial state and surface remediation guidance.

**Pre-dispatch write guard.** Any `figma_create_*` or `figma_update_*` MCP method invoked during Import mode is intercepted by the dispatcher pre-dispatch — the call is short-circuited before reaching the MCP server, recorded in the audit log as `write / blocked`, and the workflow halts with `"FR-140 violation: Import mode is read-only; write call {method} is not permitted. Switch to Generate mode to create or modify Figma frames."` This guard makes AC-EC4 a hard halt rather than a post-hoc detection.

Emit the audit report in two places:

- **Human-readable** — append a `## FR-140 Compliance Audit` block to `ux-design.md` with a PASS/FAIL banner and the call log table `| Call # | MCP method | Direction | Outcome |` (Subtask 2.3).
- **Machine-parseable** — write `{project-path}/.figma-cache/audit.json` (gitignored) for bats consumption and downstream tools.

Audit data shape (canonical — same shape as Generate mode, only `mode` and the expected counts differ):

```yaml
fr_140_audit:
  mode: "Import"
  expected_writes: 0
  allowed_write_calls: []
  fr_140_compliance: "pass"  # pass | fail | incomplete
  mcp_calls:
    - call: "figma_get_file"
      type: "read"
    - call: "get_components"
      type: "read"
    - call: "get_styles"
      type: "read"
  violations: []  # populated when fr_140_compliance == "fail" — each entry is {call, method, reason}
```

The Import-mode audit assertion is symmetric with E46-S1's Generate-mode audit: shared classification table, shared data shape, shared report formatter — only the expected outcome differs (Generate expects ≥1 write; Import expects exactly 0).

#### 9g — Write Figma Source Section into `ux-design.md`

Append an H2 section "Figma Source (Import)" to `ux-design.md` with the file key, file name, `lastModified`, version, frame count, viewport distribution table (Step 9c), and the runtime paths to the emitted `design-tokens.json` + `component-specs.yaml`. The FR-140 Compliance Audit block (Step 9f) sits directly under this section so reviewers can verify the read-only outcome alongside the source metadata.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 9 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

### Step 10 — Generate Output

Write the UX design document to `.gaia/artifacts/planning-artifacts/ux-design.md` with: personas, information architecture, wireframe descriptions, interaction patterns, component specifications, accessibility plan, FR-to-Screen Mapping table. Include Figma metadata sections if Generate or Import mode was active.

The `ux-design-assessment-template.md` carried in this skill directory is available for brownfield UX assessments — reference it at `${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-ux/ux-design-assessment-template.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh .gaia/artifacts/planning-artifacts/ux-design.md`

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 10 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH" --paths .gaia/artifacts/planning-artifacts/ux-design.md`

### Step 11 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `.gaia/artifacts/planning-artifacts/ux-design.md` -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = .gaia/artifacts/planning-artifacts/ux-design.md`, `artifact_type = ux-design`.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `.gaia/artifacts/planning-artifacts/ux-design.md` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2). Validation runs against the Step 10 primary save (the artifact-as-drafted), independent of whether the optional accessibility review (Step 12) is later executed.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 11 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH" stage=val-auto-review --paths .gaia/artifacts/planning-artifacts/ux-design.md`

### Step 12 — Optional: Accessibility Review

- Ask if the user wants to review the UX design for WCAG 2.1 accessibility compliance.
- If yes: spawn a subagent to run the accessibility review.
- If skip: accessibility review can be run anytime later with `/gaia-review-a11y`.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-create-ux 12 project_name="$PROJECT_NAME" ux_slug="$UX_SLUG" prd_path="$PRD_PATH"`

## Validation

<!--
  E42-S7 — V1→V2 26-item checklist port (FR-341, FR-359, VCP-CHK-13, VCP-CHK-14).
  Classification (26 items total):
    - Script-verifiable: 18 (SV-01..SV-18) — enforced by finalize.sh.
    - LLM-checkable:      8 (LLM-01..LLM-08) — evaluated by the host LLM
      against the UX design artifact at finalize time.
  Exit code 0 when all 18 script-verifiable items PASS; non-zero otherwise.

  The V1 source checklist at _gaia/lifecycle/workflows/2-planning/create-ux-design/
  checklist.md carried 14 bulleted items. The story 26-item count is
  authoritative: the 14 V1 bullets are expanded here to 26 by
  (a) adding envelope items SV-01..SV-03 (artifact presence, non-empty,
  frontmatter), (b) splitting "All required sections present" into per-
  section presence checks (SV-04..SV-10 — Personas, Information Architecture,
  Wireframes, Interaction Patterns, Accessibility, Components, FR-to-Screen
  Mapping), (c) adding per-section body-sanity checks (SV-11..SV-15), each
  using the V1 item string verbatim as the item description so violation
  output reproduces the V1 anchor exactly, (d) adding structural checks
  for the FR-to-Screen Mapping table (SV-16..SV-17), (e) adding an FR-###
  traceability regex (SV-18), and (f) pulling 8 LLM-checkable items
  (LLM-01..LLM-08) from the V1 semantic bullets (persona coherence, IA
  plausibility, wireframe sufficiency, keyboard/screen-reader coverage,
  user-journey coverage, component-description specificity).

  The VCP-CHK-14 anchor is SV-13 — "Key screens described". This is the
  V1 phrase verbatim and MUST appear in violation output when the
  Wireframes section is empty.

  Invoked by `finalize.sh` at post-complete (per §10.31.1). Validation
  runs BEFORE the checkpoint and lifecycle-event writes (observability
  is never suppressed by checklist outcome — story AC5).

  See .gaia/artifacts/implementation-artifacts/E42-S7-port-gaia-create-ux-26-item-checklist-to-v2.md.
-->

- [script-verifiable] SV-01 — Output file exists at .gaia/artifacts/planning-artifacts/ux-design.md
- [script-verifiable] SV-02 — Output artifact is non-empty
- [script-verifiable] SV-03 — Artifact has frontmatter or top-level title
- [script-verifiable] SV-04 — Personas section present
- [script-verifiable] SV-05 — Information Architecture section present (sitemap)
- [script-verifiable] SV-06 — Wireframes section present
- [script-verifiable] SV-07 — Interaction Patterns section present
- [script-verifiable] SV-08 — Accessibility section present
- [script-verifiable] SV-09 — Components section present
- [script-verifiable] SV-10 — FR-to-Screen Mapping section present
- [script-verifiable] SV-11 — Personas refined with scenarios
- [script-verifiable] SV-12 — Sitemap defined
- [script-verifiable] SV-13 — Key screens described
- [script-verifiable] SV-14 — Common UI patterns documented
- [script-verifiable] SV-15 — WCAG compliance target stated
- [script-verifiable] SV-16 — FR-to-Screen Mapping table present with markdown table structure
- [script-verifiable] SV-17 — FR-to-Screen Mapping table has at least one data row
- [script-verifiable] SV-18 — At least one FR-### identifier referenced (traceability)
- [LLM-checkable] LLM-01 — Personas coherent with scenarios, goals, and tech proficiency
- [LLM-checkable] LLM-02 — Every PRD FR maps to at least one page or screen in the sitemap
- [LLM-checkable] LLM-03 — Navigation structure clear (sitemap groupings are plausible)
- [LLM-checkable] LLM-04 — Layout and component placement defined for every key wireframe
- [LLM-checkable] LLM-05 — Form behaviors specified and error states defined across interaction patterns
- [LLM-checkable] LLM-06 — Keyboard navigation planned and screen reader support addressed
- [LLM-checkable] LLM-07 — Each PRD user journey has a corresponding interaction flow
- [LLM-checkable] LLM-08 — Component descriptions specific enough for implementation (not vague)

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-create-ux/scripts/finalize.sh

## Next Steps

- `/gaia-review-a11y` — Review UX design for WCAG 2.1 accessibility compliance.
- `/gaia-create-arch` — If accessibility review will be done later, proceed to architecture design.
