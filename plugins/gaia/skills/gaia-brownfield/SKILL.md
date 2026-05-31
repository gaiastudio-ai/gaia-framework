---
name: gaia-brownfield
description: Apply GAIA to an existing project — deep discovery, multi-scan gap analysis, NFR assessment, and template-driven artifact generation. Use when "onboard existing project" or /gaia-brownfield. Runs multi-scan logic (doc-code, hardcoded, integration-seam, runtime-behavior, security) plus NFR assessment via test-architect subagent.
argument-hint: "[project-path]"
context: main
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, Agent]
model: inherit
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

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-brownfield/scripts/setup.sh

## Memory

!${CLAUDE_PLUGIN_ROOT}/scripts/memory-loader.sh architect all

## Mission

You are applying the GAIA framework to an existing codebase. This skill runs **deep project discovery, parallel documentation subagents, multi-scan gap analysis, NFR assessment, gap consolidation, PRD/architecture generation, and optional ground-truth bootstrap**, then writes the canonical brownfield onboarding artifact set.

This skill is the native Claude Code conversion of the legacy `brownfield-onboarding` workflow (E28-S105, Cluster 14). The step ordering, prompts, subagent delegation, template-driven output generation, and post-complete quality gates are preserved from the legacy `instructions.xml` — parity confirmed per NFR-053.

**Main context semantics (ADR-041):** This skill runs under `context: main` with full tool access. It orchestrates a large discovery pipeline that reads the target project and produces a canonical artifact set under `.gaia/artifacts/planning-artifacts/` and `.gaia/artifacts/test-artifacts/`.

**Path resolution (AF-2026-05-21-17).** All Phase 2 brownfield artifact paths in this SKILL.md use the canonical post-ADR-111 locations under `.gaia/artifacts/planning-artifacts/` and `.gaia/artifacts/test-artifacts/`. The ~10 produced artifacts (brownfield-assessment.md, project-documentation.md, api-documentation.md, ux-design.md, event-catalog.md, dependency-map.md, dependency-audit-{date}.md, brownfield-subagent-summary.md, brownfield-scan-*.md, brownfield-onboarding.md) all target canonical destinations.

**Scripts-over-LLM (ADR-042 / FR-325):** Deterministic operations (config resolution, checkpoint writes, gate validation, lifecycle events) are delegated to the shared foundation scripts under `plugins/gaia/scripts/` via inline `!scripts/*.sh` calls. The canonical foundation set includes: `resolve-config.sh`, `checkpoint.sh` (with `write` / `read` / `validate` subcommands — the consolidated checkpoint surface per architecture §10.26.3), `validate-gate.sh` (deployed equivalent for spec's `file-gate.sh`), `template-header.sh`, `memory-loader.sh`, `lifecycle-event.sh`. See the Reconciliation Note under Critical Rules for the one remaining spec-vs-deployed name mapping.

## Critical Rules

- **Document existing state before proposing changes.** Stories written downstream must cover gaps only, not re-implement existing features.
- **Gap-only PRD:** When generating the brownfield PRD, fill every section with gap-focused content. Do NOT re-document working features as new requirements.
- **Mermaid diagrams only:** Every diagram in generated artifacts must use Mermaid syntax — no ASCII art, no prose descriptions of diagrams.
- **Swagger/OpenAPI for APIs:** All API documentation must use Swagger/OpenAPI format. If an OpenAPI spec exists, validate it against actual routes; if not, generate one from code.
- **Limit flow diagrams to 3–5 key flows** to avoid output bloat.
- **Subagent completion MUST NOT auto-advance.** After parallel subagents return, pause for user review before proceeding to the next phase. Halt-on-failure is scoped per subagent — individual scanner failures do not block the overall workflow (see the Failure Semantics section), but the post-complete gates halt when their required files are absent.
- **Sprint-status.yaml is NEVER written by this skill** (Sprint-Status Write Safety rule). This skill writes only planning and test artifacts.
- **Parallel invocation isolation (AC-EC7):** Each invocation uses an isolated checkpoint path and independent `_resolved` config derived from `resolve-config.sh`. Two concurrent runs on different project roots never share mutable state or contaminate each other's artifacts.
- **Token budget (NFR-048 / AC-EC1):** Keep the SKILL.md body under the activation budget. Scanners stream/chunk results and emit a "scan truncated — review manually" advisory rather than exceed the budget (AC-EC6).
- **Fail-fast on missing foundation scripts (AC-EC2):** `setup.sh` aborts with an actionable error identifying the missing / non-executable script path. No partial scan output is written if the setup step fails.

### Reconciliation Note — Architecture Spec vs Deployed Scripts

Architecture §10.26.3 specifies the foundation-script surface. The live `plugins/gaia/scripts/` set exposes `checkpoint.sh` (with `write` / `read` / `validate` subcommands — same canonical name used by architecture §10.26.3 since E28-S172) alongside `validate-gate.sh`, which is the deployed equivalent for the spec's `file-gate.sh`. This skill calls the deployed names for parity with the live script set. If the `file-gate.sh` spec name is added later under a separate story (E28-S9..E28-S16), the inline calls in `setup.sh` / `finalize.sh` can be updated without touching the skill body. The checkpoint surface no longer requires reconciliation — `checkpoint.sh` is the canonical name in both the spec and the product.

## Inputs

This skill accepts the following inputs (from `$ARGUMENTS` when invoked via slash command, or from interactive prompt otherwise):

1. **Project path** — absolute or relative path to the target codebase. Defaults to the current working directory.
2. **Execution mode** — `normal` (pause for user review at checkpoints) or `yolo` (auto-advance). YOLO mode always uses the safe default of `merge` when resolving `test-environment.yaml` conflicts.

## Pipeline Overview

The skill runs nine phases in strict order:

1. **Deep Project Discovery** — capability detection and project classification
2. **Parallel Documentation Subagents** — API, UX, events, dependencies
3. **Deep Analysis Multi-Scan Subagents** — five scan branches + doc-code + config-contradiction + dead-code
4. **Test Execution During Discovery** — non-blocking test runner probe
5. **Auto-Generate test-environment.yaml** — from detected test infrastructure (conditional)
6. **NFR Assessment & Performance Test Plan** — test-architect subagent (Sable)
7. **Gap Consolidation & Deduplication** — merge, rank, budget-check
8. **PRD + Adversarial Review + Code-Verified Review** — gap-focused PRD generation
9. **Architecture + Ground-Truth Bootstrap** — optional Val seed + Tier 1 agent extraction

Each phase is independent in its write targets but must run sequentially because later phases consume earlier outputs.

## Phase 1 — Deep Project Discovery

1. Scan the project root for the primary tech stack, frameworks, runtime versions, and conventions.
2. Set capability flags by scanning source files:
   - `{has_apis}` — route/controller definitions, OpenAPI/Swagger specs present
   - `{has_events}` — Kafka / RabbitMQ / SNS-SQS / Redis pub-sub / NATS patterns
   - `{has_external_deps}` — outbound HTTP clients, SDKs, service URLs, database connections
   - `{has_frontend}` — call the shared `detectProjectType` module; set `true` when result.type is `frontend`, `fullstack`, or `mobile`
3. Classify infrastructure markers across six categories (Terraform, Docker, Helm, Kubernetes, Pulumi, CloudFormation) to set `{has_infra}`.
4. Detect framework imports (Express, Spring Boot, Django, FastAPI, Angular, React, Next.js, NestJS, Flask, Gin, Fiber) to set `{has_app_code}`.
5. Apply the classification decision tree to set `{project_type}`:
   - `has_infra` + `has_app_code` → `platform`
   - `has_infra` + no `has_app_code` → `infrastructure`
   - no `has_infra` → `application` (default)

<!-- E71-S2: detection-driven config extension begin -->
5a. **Detection-driven config draft (E71-S2 / FR-RSV2-35, FR-RSV2-36, AF-2026-05-04-1).** After the boolean capability flags are set, run `detect-signals.sh` to produce a structured signal inventory and (optionally) merge it into the project's `.gaia/config/project-config.yaml`:

   - Run `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-signals.sh --project-root <project> --merge-into <project>/.gaia/config/project-config.yaml --output <project>/.gaia/config/project-config.draft.yaml --schema ${CLAUDE_PLUGIN_ROOT}/config/project-config.schema.yaml --format json`. **AF-2026-05-30-4 / Test11 F-01 + V-01**: the draft output path MUST live under `.gaia/config/` (canonical post-ADR-111), not at repo-root `config/`. Prior to this fix the prose said `<project>/config/project-config.draft.yaml` (outside `.gaia/`, contradicting both the .gaia/-only write contract AND the step 5b multi-stack draft path on line 122 which already used the canonical home). Worse, on any clean checkout `config/` doesn't exist and the script died with `FileNotFoundError`, exit 1 — Phase 1 step 5a was unreachable.
   - The script emits a JSON document with five keys — `stacks`, `platforms`, `ci_platform`, `tool_providers`, `warnings` — plus a top-level `verdict` (PASS | WARNING | CRITICAL) per ADR-063.
   - Detected sections are merged into the existing `project-config.yaml` using **RFC 7396 JSON Merge Patch** semantics: existing user-edited values are preserved unchanged; only null or absent fields are filled. The merged draft is written to `project-config.draft.yaml` for user review before promotion to `project-config.yaml`.
   - When the `--schema` flag is provided, the script invokes `resolve-config.sh --shared <draft> --schema <schema>` to validate the merged draft. A schema rejection collapses the verdict to `CRITICAL` and exits non-zero.
   - **Verdict surfacing (ADR-063 — mandatory):** the parent skill MUST surface the verdict to the user verbatim — no silent swallowing. PASS = all sections populated, no conflicts. WARNING = conflicts detected (e.g., multiple test runners) or partial signals (e.g., empty project). CRITICAL = post-merge schema validation failure; HALT until resolved.
   - **Empty-project advisory:** when no signals are detected, the script emits a `warnings` entry directing the user to configure manually via `/gaia-config-stack`, `/gaia-config-platform`, `/gaia-config-ci`, `/gaia-config-tools`. Surface this advisory to the user.
   - **Mobile signals out of scope (E74-S11):** Package.swift, Android Gradle, Flutter mobile, react-native, Xcode/Android Studio detection do NOT fire here — those land downstream.
   - **Plugin-project classification (E77-S16 / FR-420).** `detect-signals.sh` ALSO invokes `plugin-detection.sh` and emits a top-level `project_kind` field. Three or more co-occurring signals from `{SKILL.md, adapter.json, plugin manifest, commands/, settings.json hooks, .claude/}` set `project_kind: claude-code-plugin`. Single-signal detection is rejected to avoid false positives on stray SKILL.md or manifest files in non-plugin repos. Surface `project_kind` to the user so the downstream `/gaia-trace` plugin chain (FR-421) can attach to it.
<!-- E71-S2: detection-driven config extension end -->

5b. **Multi-stack `stacks[].path` proposal / audit (E70-S11 / FR-548 / NFR-88 / ADR-126).** When the deterministic-tools master flag (`brownfield.deterministic_tools`) and per-tool override (`brownfield.detect_signals_enabled`, default true) are on, run `detect-signals.sh` in the OPT-IN stacks-path mode to give multi-stack monorepos advisory partitioning help. This is distinct from the E71-S2 root-only detection above (that path is unchanged):

   ```bash
   ds_start=$(date +%s)
   # auto = audit when stacks[].path is already declared, else propose.
   DECLARED="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path 2>/dev/null \
     | xargs -I{} yq eval '[.stacks[].path | select(. != null)] | join(",")' {} 2>/dev/null || true)"
   ds_mode="proposal"; [ -n "$DECLARED" ] && ds_mode="audit"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-signals.sh" --project-root "${GAIA_PROJECT_PATH:-.}" \
     --stacks-path-mode "$ds_mode" --declared-paths "$DECLARED" \
     --draft-out "${GAIA_CONFIG_DIR:-.gaia/config}/project-config.draft.yaml" \
     --audit-out "${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit/partitioning-audit.json" \
     --format json || true
   ds_seconds=$(( $(date +%s) - ds_start ))
   ```

   - **Proposal mode** (no `stacks[].path` declared): scans ecosystem manifests and writes a `stacks[].path` mapping to `project-config.draft.yaml` (advisory — the user accepts by renaming to `project-config.yaml` OR merging the entries via `/gaia-config-stack`; declared truth always wins). A single root-level stack emits "nothing to propose" and writes no draft. Nested manifests (a manifest inside another stack's path) scope to the parent — `ignore_nested_manifests: true` default per FR-546 / E85-S14; they do NOT spawn a phantom child stack.
   - **Audit mode** (`stacks[].path` IS declared): compares declared vs auto-detected and logs disagreement to `.gaia/memory/brownfield-audit/partitioning-audit.json` (`{auto_detected_partitioning, declared_partitioning, disagreement_count}`); it does NOT regenerate the draft (auto-detection vs explicit precedence, TC-MSP-3). Never overrides the declared config.
   - Telemetry (E104-S1 `brownfield-telemetry.sh`; detect_signals owns its fields, single-author): populate `phase_runtime_seconds.detect_signals` / `deterministic_tool_seconds.detect_signals` / `llm_token_count:0` / `detect_signals_mode: proposal|audit|skipped` (skipped when the flags are off). Advisory, never gating — runs in ≤2s on a 10-manifest fixture (NFR-88).

6. Generate the brownfield assessment artifact. AF-2026-05-31-1 / Test12 F-05 — the canonical template lives at `${CLAUDE_PLUGIN_ROOT}/templates/brownfield-assessment-template.md` and ships with the plugin. Read it as the starting shape (mode/schema_version/generated_by frontmatter + the seven section headers: Project Overview, Repository Layout, Existing Documentation Surface, Stack Signals, Known Gaps, Scan-readiness checklist, Continuation pointer). Fill the placeholder fields with concrete project data: component inventory, technical debt, migration constraints, coexistence strategy, and adoption path. Include `{project_type}` in the output. Write to `.gaia/artifacts/planning-artifacts/brownfield-assessment.md`.
7. Write the enhanced project documentation — all standard sections plus detected capability flags, `{project_type}`, testing infrastructure summary, and CI/CD pipeline summary. Write to `.gaia/artifacts/planning-artifacts/project-documentation.md`.

Checkpoint after Phase 1 via the canonical `checkpoint.sh write` subcommand. AF-2026-05-31-1 / Test12 F-08 — the prior prose was a bare invocation with no flag set documented; reasonable guesses like `--phase` / `--status` both error with `unknown flag to write`. The actual accepted flags are `--workflow <name>`, `--step <name>`, `--var <key=value>` (repeatable), and `--file <path>` (repeatable). Brownfield's Phase 1 checkpoint:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh write \
  --workflow brownfield \
  --step phase-1-discovery \
  --var status=complete \
  --file ".gaia/artifacts/planning-artifacts/brownfield-assessment.md"
```

Per phase, the `--step` value advances: `phase-1-discovery`, `phase-2-documentation`, `phase-3-scans`, `phase-4-tests`, `phase-5-env`, `phase-6-nfr`, `phase-7-consolidation`, `phase-8-prd`, `phase-9-architecture`. The non-gating contract of brownfield checkpoints means an unknown-flag error from a stale invocation is informational, not blocking — but the canonical form above is what the helper recognizes.

## Phase 2 — Parallel Documentation Subagents

Spawn the following subagents in parallel (single message, multiple `Agent` tool calls). Only spawn subagents for detected capabilities:

- **If `{has_apis}`** — API Documenter subagent. Scan for routes, controllers, and specs. Validate existing OpenAPI specs against routes or generate a new OpenAPI 3.x spec from code. Document all endpoints with method, path, handler, auth, parameters, request/response schemas, error formats. Include a Mermaid API flow diagram. List undocumented endpoints as gaps. Output to `.gaia/artifacts/planning-artifacts/api-documentation.md`.
- **If `{has_frontend}`** — UX Assessor subagent. Scan UI frameworks, components, design patterns, styling. Document UI patterns, navigation structure (Mermaid sitemap), interaction patterns, accessibility (WCAG, ARIA, keyboard nav). Propose improvements for gaps only. Output to `.gaia/artifacts/planning-artifacts/ux-design.md`.
- **If `{has_events}`** — Event Cataloger subagent. Scan messaging infrastructure, produced/consumed events with schemas, external events, delivery guarantees (retry, DLQ, idempotency). Include Mermaid event flow diagrams (2–3 key flows). Output to `.gaia/artifacts/planning-artifacts/event-catalog.md`.
- **Always** — Dependency Mapper subagent. Document external service dependencies, infrastructure dependencies, key library dependencies (ORM, auth lib — check version currency and CVE risk). Build a Mermaid dependency graph. Document contracts, SLAs, fallback strategies. Identify dependency risks. Output to `.gaia/artifacts/planning-artifacts/dependency-map.md`. After writing, run the shared `review-dependency-audit` task to generate a dependency audit report at `.gaia/artifacts/test-artifacts/dependency-audit-{date}.md`.

**Post-subagent validation:** verify each expected output file exists. If any subagent failed to write its output file, the orchestrator (this skill) MUST write a stub file on the subagent's behalf using the paths declared in the legacy `output.artifacts` contract. Dependency-audit goes to `.gaia/artifacts/test-artifacts/`; all other Phase 2 artifacts go to `.gaia/artifacts/planning-artifacts/`. Do NOT use hardcoded paths.

After all subagents return, write a subagent summary at `.gaia/artifacts/planning-artifacts/brownfield-subagent-summary.md` (which subagents ran, artifacts produced, file paths, any errors). Pause for user review in `normal` mode before continuing.

## Phase 3 — Deep Analysis Multi-Scan Subagents (Infra-Aware)

### Phase 3 pre-flight — deterministic-tools pre-warm (E70-S7 / FR-539 / ADR-121)

Before the Phase 3 scan timer starts, run the deterministic-tools pre-flight. This primes the Grype vulnerability DB and cdxgen package-registry caches so a cold runner does not pay the 15–30s cold-fetch against the NFR-84 120s WARNING budget.

```bash
# Resolve the master flag + per-tool override (ADR-121 / ADR-078) and export
# them for the adapter scripts. resolve-config.sh is the single config source.
DET_TOOLS="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.deterministic_tools 2>/dev/null)"
PREWARM_ON="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.prewarm_enabled 2>/dev/null)"
# resolve-config emits empty when the key is unset.
# AF-2026-05-30-3: defaults flipped from `false` to `true` so a stock
# /gaia-brownfield run actually engages the deterministic-tools battery.
# Prior to this flip the layer was inert on every clean install (the
# Test10 §7 finding) — operators had to discover + flip the master flag
# by hand, which nobody did. Operators who want the layer OFF can
# declare `brownfield.deterministic_tools: false` (or
# `brownfield.prewarm_enabled: false`) explicitly in project-config.yaml;
# absence now resolves to ON. External-integration flags
# (defectdojo_enabled) remain opt-in because they require an API token
# the operator must configure (avoids silent third-party exfil).
export GAIA_BROWNFIELD_DETERMINISTIC_TOOLS="${DET_TOOLS:-true}"
export GAIA_BROWNFIELD_PREWARM_ENABLED="${PREWARM_ON:-true}"

# Run pre-warm (it self-skips with an INFO line when either flag is off).
prewarm_start=$(date +%s)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/pre-warm.sh" || true
prewarm_seconds=$(( $(date +%s) - prewarm_start ))

# Telemetry population (E104-S1 brownfield-telemetry.sh — the shared, single-author-per-field
# writer). The pre-warm pre-flight OWNS the *.pre_warm fields (no fan-out).
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/brownfield-telemetry.sh"
if [ -f "$REPORT" ]; then
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.pre_warm --value "$prewarm_seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.pre_warm --value "$prewarm_seconds" || true
fi

# Phase 3 scan timer anchor (E70-S7 AC2 / AC-X2). pre-warm MUST complete BEFORE
# this start_ts so its runtime is attributed to pre_warm, not the scan budget.
start_ts=$(date +%s)
```

`prewarm_seconds` feeds the `phase_runtime_seconds.pre_warm` / `deterministic_tool_seconds.pre_warm` telemetry fields, populated via `brownfield-telemetry.sh` (the shared writer landed by E104-S1). When the flags are off, `pre-warm.sh` emits an INFO skip line and contributes 0.

### Phase 3 per-stack file-list intersection (E70-S10 / FR-546 / ADR-126)

When the master flag is on, the deterministic-tools orchestrator computes, for each `stacks[]` entry, the file-list passed to that stack's per-tool adapters as `(path_root ∩ paths[]) − excludes[]` (path_root = `stack.path || '.'`; excludes ALWAYS win on collision). The intersection is applied BEFORE adapter dispatch so per-stack adapters see only files within their declared stack scope — the ADR-078 `run.sh --input <file-list>` contract is byte-stable (adapters receive a flat file-list, never `path`/`paths`/`excludes` metadata). Single-stack repos (`stacks[].path: null`) collapse to `'.' ∩ paths − excludes`, byte-identical to pre-deploy (zero-regression invariant — the dominant deployment shape).

```bash
orch_start=$(date +%s)
# Per-stack file-lists are written to $ORCH_OUT_DIR/<stack>.files (sorted, repo-root-relative);
# the orchestrator logs `per_stack_file_counts: <stack>=<count> ...` for telemetry.
orch_log="$(GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
  ORCH_CONFIG="${GAIA_CONFIG_DIR:-.gaia/config}/project-config.yaml" \
  ORCH_ROOT="${GAIA_PROJECT_PATH:-.}" \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/orchestrator.sh" 2>&1 || true)"
printf '%s\n' "$orch_log"
orch_seconds=$(( $(date +%s) - orch_start ))

# Telemetry (E104-S1 brownfield-telemetry.sh — orchestrator owns *.orchestrator_intersection
# + per_stack_file_counts; single-author, no fan-out). Parse the per-stack counts from the log.
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/brownfield-telemetry.sh"
if [ -f "$REPORT" ]; then
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.orchestrator_intersection --value "$orch_seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.orchestrator_intersection --value "$orch_seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
  # per_stack_file_counts: one nested key per stack from the `<stack>=<count>` pairs in $orch_log.
  for pair in $(printf '%s' "$orch_log" | sed -n 's/.*per_stack_file_counts: //p'); do
    s="${pair%%=*}"; c="${pair##*=}"
    [ -n "$s" ] && bash "$TELEM" --report "$REPORT" --field "per_stack_file_counts.$s" --value "$c" || true
  done
fi
```

Adapter dispatch then consumes each `<stack>.files` list via the existing `run.sh --input` contract — no adapter change. (Detection of nested ecosystem manifests is E70-S11's responsibility; this orchestrator only respects the `path_root` boundary and does not double-count files under a nested manifest.)

### Phase 3 SBOM completeness check (E104-S3 / FR-543)

After the cdxgen SBOM is produced, run the completeness check: compare the declared dependency count (from lock files) against the SBOM component count, and WARN when `abs(divergence_pct)` exceeds 10% — or 15% when any of five per-ecosystem carve-outs auto-detects (Yarn Berry PnP, conda, Go vendor, Gradle no-lockfile, Gradle shadow/shade) — so real-dependency CVEs don't silently fail to surface from an incomplete SBOM. NEVER aborts (NFR-84). When the SBOM is absent (the cdxgen SBOM-persist producer is not yet wired — tracked Finding), the check INFO-skips.

**SBOM-format note (AF-2026-05-30-4 / Test11 F-27).** cdxgen emits CycloneDX 1.7 (current spec); grype 0.112.0 rejects 1.7 input ("sbom format not recognized") because Anchore's parser tracks the CycloneDX spec a few revisions behind. When feeding an SBOM to grype (e.g. `grype sbom:<file>` for a re-scan without re-walking the project tree), prefer **syft** as the SBOM producer (`syft scan dir:. -o cyclonedx-json=<file>`) — the Anchore tools are version-matched and the handoff is reliable. cdxgen output remains the canonical source for the completeness check above (which doesn't pass through grype) and for any downstream consumer that accepts current CycloneDX. The brownfield Phase 3 pipeline therefore runs BOTH SBOMs: syft for the grype-feeding path, cdxgen for the broader-language-coverage path.

```bash
SBOM_ON="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.sbom_completeness_enabled 2>/dev/null)"
export GAIA_BROWNFIELD_SBOM_COMPLETENESS_ENABLED="${SBOM_ON:-true}"
sbomck_start=$(date +%s)
SBOM_PROJECT_ROOT="${GAIA_PROJECT_PATH:-.}" \
  SBOM_FILE="${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit/sbom.json" \
  SBOM_REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md" \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/sbom-completeness-check.sh" || true
sbomck_seconds=$(( $(date +%s) - sbomck_start ))
# The check writes sbom_completeness_warning / divergence_pct / applied_threshold /
# detected_carve_outs / llm_token_count via brownfield-telemetry.sh; the orchestrator adds
# the runtime fields (single-author).
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/brownfield-telemetry.sh"
if [ -f "$REPORT" ]; then
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.sbom_completeness --value "$sbomck_seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.sbom_completeness --value "$sbomck_seconds" || true
fi
```

Spawn seven scan subagents in parallel. These run alongside Phase 2 documentation to detect gaps that structural analysis misses. Each scanner receives `{tech_stack}`, `{project-path}`, and `{project_type}` as context. When `{project_type}` is `infrastructure` or `platform`, infra-specific detection patterns are applied alongside application patterns; for `application`, only application patterns run.

### Doc-Code Scan

Read the doc-vs-code scan prompt template from the bundled knowledge. Scan the project for mismatches between documentation and code — stale claims, missing endpoints in docs, config values that differ from the documented defaults. Output gap entries to `.gaia/artifacts/planning-artifacts/brownfield-scan-doc-code.md` using the standardized gap-entry schema. Contradictory signals between docs and code produce gap rows tagged with evidence_file and evidence_line.

### Hardcoded Values Scan

Scan for hard-coded logic, magic numbers, embedded literals that should be configuration. For `infrastructure` / `platform` projects, also detect hard-coded IPs, magic ports, embedded secrets / AMI IDs, and hard-coded resource limits in IaC files. Output to `.gaia/artifacts/planning-artifacts/brownfield-scan-hardcoded.md`.

### Integration Seam Scan

Scan for integration seams between modules, services, and external systems — contracts, shared state, coupling patterns. For `infrastructure` / `platform`, also map service mesh topology, ingress / egress routes, and cross-namespace dependencies. Output to `.gaia/artifacts/planning-artifacts/brownfield-scan-integration-seam.md`.

### Runtime Behavior Scan

Catalog runtime behavior: `@Scheduled`, Quartz, startup hooks, background threads, health checks. For `infrastructure` / `platform`, also catalog CronJobs, DaemonSets, init containers, sidecar patterns, health probes. Output to `.gaia/artifacts/planning-artifacts/brownfield-scan-runtime-behavior.md`.

### Security Scan

Audit security posture: mutating endpoints, IDOR candidates, authorization gaps, missing CSRF. For `infrastructure` / `platform`, also detect exposed ports in k8s manifests, permissive ingress rules, overly broad RBAC bindings, missing NetworkPolicy. Output to `.gaia/artifacts/planning-artifacts/brownfield-scan-security.md`.

### Config Contradiction Scan (infra-aware)

Detect contradictions between configuration files (e.g., different service limits in `values.yaml` vs `deployment.yaml`). For `infrastructure` / `platform`, apply patterns for `terraform.tfvars`, `values.yaml`, and kustomize overlays. Output to `.gaia/artifacts/planning-artifacts/brownfield-scan-config-contradiction.md`.

### Dead Code & Dead State Scan

Identify unused modules, orphaned routes, dead migrations, unused feature flags. Output to `.gaia/artifacts/planning-artifacts/brownfield-scan-dead-code.md`.

#### Per-stack deterministic dead-code adapters (E70-S8 / FR-545 / NFR-87 / ADR-078)

When `brownfield.deterministic_tools: true`, the LLM dead-code heuristic is
**replaced** by three sound per-stack adapters under
`scripts/adapters/dead-code/`. Each is independently gated by its per-tool
override (`brownfield.deadcode_go_enabled` / `deadcode_python_enabled` /
`deadcode_jvm_enabled`, default true) and degrades gracefully (WARN + exit 0)
when its toolchain is absent — Phase 3 never aborts (NFR-84).

```bash
AUDIT="${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit"
ADAPT="$GAIA_PLUGIN_ROOT/scripts/adapters/dead-code"
# Each adapter writes BOTH a flat JSON (AUDIT/dead-code/<tool>.json — report
# rendering) AND a SARIF run (AUDIT/sarif/<tool>.sarif — feeds the Phase 7
# E104-S1 dedup precision ladder via .properties.symbol).
GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true DEADCODE_PROJECT_ROOT="$PROJECT_PATH" \
  DEADCODE_OUT_DIR="$AUDIT" bash "$ADAPT/go-deadcode/adapter.sh"
GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true PY_PROJECT_ROOT="$PROJECT_PATH" \
  PY_OUT_DIR="$AUDIT" bash "$ADAPT/python-vulture/adapter.sh"
GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true JVM_PROJECT_ROOT="$PROJECT_PATH" \
  JVM_OUT_DIR="$AUDIT" bash "$ADAPT/jvm-spotbugs/adapter.sh"
```

**Per-stack precision is the contract, not a bug (NFR-87).** Go reports a
whole-program reachability binary verdict (`<pkg>.<Function>`), Python a
confidence percentage (`<line>:<symbol>@<conf>`), JVM a priority×rank ordinal
(`<FQCN>.<method>(<sig>)`). The framework MUST NOT synthesize a unified
cross-stack confidence score — `file_path` is the universal JOIN key, and each
stack-native `qualifier` is preserved verbatim. The unified "Test Quality"
report section is rendered in Phase 7 (see the Phase 7 render sub-step) as THREE
labeled per-stack sub-sections — never one flat list. Telemetry
(`phase_runtime_seconds.deadcode_{go,python,jvm}` etc.) is written by each
adapter through the single-author `brownfield-telemetry.sh`.

#### CVE + SBOM adapters (AF-2026-05-31-1 / Test12 F-07 — wire-up closure)

When `brownfield.deterministic_tools: true`, Phase 3 ALSO runs the
deterministic CVE-scan and SBOM-producer adapters that the dead-code block
above doesn't cover. Prior to AF-2026-05-31-1 the brownfield SKILL.md
referenced `phase_runtime_seconds.grype` + an `E70-S9 Grype adapter` in the
Phase-3 telemetry but never actually invoked them — the grype adapter at
`scripts/adapters/grype/adapter.sh` and a syft SBOM-producer path both
existed only as docker-dispatched leaves with no caller. On a stock run the
CVE scan and SBOM-persist were never produced, defeating the "deterministic
tools default-on" contract that AF-2026-05-30-3 established.

```bash
AUDIT="${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit"
mkdir -p "$AUDIT/sarif"

# syft SBOM (CycloneDX 1.4-compatible — the grype-feeding path documented in
# the AF-2026-05-30-4 / Test11 F-27 note above). The completeness check below
# already references this path; producing it makes the check non-INFO-skip.
SBOM_FILE="$AUDIT/sbom-syft.json"
if command -v syft >/dev/null 2>&1; then
  syft scan dir:"$PROJECT_PATH" -o cyclonedx-json="$SBOM_FILE" 2>/dev/null \
    || printf 'INFO: syft returned non-zero — SBOM unavailable (graceful degrade)\n' >&2
else
  printf 'INFO: syft not on PATH — SBOM step skipped (run gaia-doctor --install to add)\n' >&2
fi

# grype CVE scan — prefer SBOM input when syft produced one (faster + no
# re-walk), fall back to directory scan otherwise. Both forms write SARIF
# into $AUDIT/sarif/ so the Phase 7 E104-S1 dedup ladder picks up the
# findings via .properties.symbol.
if command -v grype >/dev/null 2>&1; then
  if [ -s "$SBOM_FILE" ]; then
    GRYPE_INPUT="sbom:$SBOM_FILE"
  else
    GRYPE_INPUT="dir:$PROJECT_PATH"
  fi
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    ADAPTER_OUT_DIR="$AUDIT" \
    GRYPE_INPUT="$GRYPE_INPUT" \
    bash "$GAIA_PLUGIN_ROOT/scripts/adapters/grype/adapter.sh" \
    || printf 'INFO: grype adapter exited non-zero — CVE scan absent (graceful degrade)\n' >&2
else
  printf 'INFO: grype not on PATH — CVE scan skipped (run gaia-doctor --install to add)\n' >&2
fi
```

Both invocations follow the same graceful-degrade contract as the dead-code
adapters: when a toolchain is absent the step emits ONE INFO line pointing
at the remediation command (`gaia-doctor --install`) and continues. The
Phase 3 verdict is unchanged by their absence — they enrich the gap report
when present, they don't block when missing. The runner cascade
(`brownfield.tools.runner = docker`, AF-2026-05-30-3) still applies: when
the docker runner is selected, the same invocations transparently dispatch
through `scripts/lib/docker-runner.sh` via the per-adapter helper and the
host doesn't need grype/syft on PATH. This closes the Test12 F-07 wire-up
gap — the adapters are now actually called by the orchestrator that the
telemetry already credited.

**Partial-failure semantics (AC-EC8):** If a scanner crashes mid-run, the other scanners continue. The failed scan writes a gap row tagged `scan failed: {reason}`. The overall skill exits non-zero with a partial-result summary listing which scanners succeeded, which failed, and what recoverable evidence is available. The remaining scanners continue — one failure does not block the cohort.

**Language-aware INFO degrade log (AF-2026-05-30-4 D-02).** When a stack signal is present but the matching deterministic dead-code adapter cannot run because its toolchain is absent, emit ONE INFO line per missing toolchain at Phase 3 scan time — do NOT wait for the Phase 7 banner to be the only fidelity disclosure. The emission rule, applied per detected stack:

- Python signal present (e.g. `pyproject.toml`, `setup.py`, `requirements.txt`, or `.py` files under a configured stack path) AND `vulture` not on PATH:
  `[INFO] python project detected — install vulture for tool-grade dead-code (gaia-doctor --install)`
- Go signal present (`go.mod` or `.go` files) AND the `deadcode` tool (golang.org/x/tools/cmd/deadcode) not on PATH:
  `[INFO] go project detected — install golang.org/x/tools/cmd/deadcode for tool-grade dead-code (gaia-doctor --install)`
- JVM signal present (`pom.xml`, `build.gradle`, `build.gradle.kts`, or `.java`/`.kt` files) AND `spotbugs` not on PATH:
  `[INFO] jvm project detected — install spotbugs for tool-grade dead-code (gaia-doctor --install)`

Stack detection re-uses the signal set already computed by `detect-signals.sh` in Phase 1 — do NOT re-scan. The INFO lines are non-blocking and DO NOT change the Phase 3 verdict; they exist to make the toolchain-absence visible at the scan step rather than only at the Phase 7 banner.

### Per-Subagent Scan Diagnostic Table (E48-S4)

After all seven Phase 3 scan subagents return (doc-code, hardcoded, integration-seam, runtime-behavior, security, config-contradiction, dead-code), collect exit status and timing metadata for each subagent and surface a structured diagnostic table to the user before the Phase 3 user-review pause point. The table is lightweight metadata (subagent name + status + duration + reason); it is not gated by the NFR-048 / NFR-024 token budget that applies to scanner output.

**Table format:**

| Scan Subagent | Status | Duration | Reason |
|---------------|--------|----------|--------|
| doc-code | success | 12s | — |
| hardcoded | success | 9s | — |
| integration-seam | timeout | 300s | exceeded 5-minute scanner budget |
| runtime-behavior | success | 14s | — |
| security | resource-capped | 60s | scan output truncated per NFR-024 — review manually |
| config-contradiction | errored | 4s | parser crash on unrecognized YAML anchor |
| dead-code | success | 11s | — |

**Canonical scan statuses (four values):**

- `success` — the scan completed and wrote its expected output file under `.gaia/artifacts/planning-artifacts/`.
- `timeout` — the scan exceeded its time / token budget. The reason string MUST capture the budget threshold and the scanner identity (e.g., `exceeded 5-minute scanner budget`).
- `resource-capped` — the scan output was truncated per NFR-024 / AC-EC6. The reason string MUST surface the truncation advisory (`scan truncated — review manually`) so the user knows the gap list is partial.
- `errored` — the scan crashed mid-run per AC-EC8 partial-failure semantics. The reason string MUST contain the underlying error (parser crash, file read failure, subagent unreachable) — do not silently omit failed scans from the diagnostic log.

The table is rendered to the conversation after Phase 3 scans complete, before the Phase 3 user-review pause point. Timed-out and errored scans MUST appear with their canonical status and reason string — they are never silently omitted from the log even though their gap rows are also tagged `scan failed: {reason}` per AC-EC8.

### Phase 3 deterministic-tools telemetry (E70-S7 / NFR-85)

The brownfield report frontmatter records deterministic-tools telemetry so the
gap-consolidation report (Phase 7) can attribute runtime and token cost:

| Frontmatter field | Source | Notes |
|-------------------|--------|-------|
| `phase_runtime_seconds.pre_warm` | `prewarm_seconds` (pre-flight) | Wall-clock of the pre-warm pre-flight; tracked WARNING-only against the NFR-84 120s budget — no hard timeout abort (AC-X2). |
| `deterministic_tool_seconds.pre_warm` | `prewarm_seconds` | Deterministic-tool runtime contribution (same value; separated so LLM vs deterministic cost is distinguishable). |
| `llm_token_count` | `0` for pre-warm | Pre-warm is fully deterministic — zero LLM tokens (NFR-85). |
| `gap_count_before_dedup` | gap-consolidation | Populated by Phase 7 / E104-S1 dedup; pre-warm contributes 0. |
| `gap_count_after_dedup` | gap-consolidation | Populated by Phase 7 / E104-S2 reconciliation; pre-warm contributes 0. |
| `phase_runtime_seconds.sarif_merge` / `deterministic_tool_seconds.sarif_merge` | SARIF merge pre-step (E104-S4) | Wall-clock of the SARIF Multitool merge; SARIF-merge-owned. |
| `phase_runtime_seconds.dedup` / `deterministic_tool_seconds.dedup` | dedup sub-step (E104-S1) | Wall-clock of the cross-tool dedup; dedup-owned. |
| `phase_runtime_seconds.grype` / `deterministic_tool_seconds.grype` | Grype adapter (E70-S9) | Wall-clock of the Grype CVE scan; Grype-owned. |
| `grype_db_checksum` | Grype adapter (E70-S9) | SHA-256 of the resolved grype-db.sqlite at scan time (trust-boundary; ADR-122). Grype-owned. |
| `grype_db_built_age` | Grype adapter (E70-S9) | Seconds since the Grype DB build timestamp. Grype-owned. |
| `phase_runtime_seconds.orchestrator_intersection` / `deterministic_tool_seconds.orchestrator_intersection` | orchestrator (E70-S10) | Wall-clock of the per-stack file-list intersection; orchestrator-owned. |
| `per_stack_file_counts.<stack>` | orchestrator (E70-S10) | Post-intersection file count per declared stack (explicit 0 for empty stacks). Orchestrator-owned. |
| `phase_runtime_seconds.detect_signals` / `deterministic_tool_seconds.detect_signals` | detect-signals (E70-S11) | Wall-clock of the Phase 1 stacks[].path proposal/audit; detect-signals-owned. |
| `detect_signals_mode` | detect-signals (E70-S11) | `proposal` \| `audit` \| `skipped` — the stacks-path mode taken. detect-signals-owned. |
| `phase_runtime_seconds.sbom_completeness` / `deterministic_tool_seconds.sbom_completeness` | sbom-completeness (E104-S3) | Wall-clock of the SBOM completeness check; sbom-completeness-owned. |
| `sbom_completeness_warning` / `divergence_pct` / `applied_threshold` / `detected_carve_outs` | sbom-completeness (E104-S3) | Lock-vs-SBOM divergence WARNING + the percentage, applied 10/15% threshold, and matched carve-outs. sbom-completeness-owned. |
| `phase_runtime_seconds.deadcode_go` / `deterministic_tool_seconds.deadcode_go` | go-deadcode adapter (E70-S8) | Wall-clock of the Go deadcode scan; go-deadcode-owned. |
| `phase_runtime_seconds.deadcode_python` / `deterministic_tool_seconds.deadcode_python` | python-vulture adapter (E70-S8) | Wall-clock of the Python vulture scan; python-vulture-owned. |
| `phase_runtime_seconds.deadcode_jvm` / `deterministic_tool_seconds.deadcode_jvm` | jvm-spotbugs adapter (E70-S8) | Wall-clock of the JVM SpotBugs scan; jvm-spotbugs-owned. |
| `phase_runtime_seconds.phase_4b` / `deterministic_tool_seconds.phase_4b` | reconciliation (E104-S2) | Wall-clock of the Phase 4b reconciliation JSON-join; reconciliation-owned. |
| `findings_demoted_by_reconciliation` | reconciliation (E104-S2) | Count of file-only findings demoted to INFO (reachable from entry points); reconciliation-owned. `gap_count_*` stay dedup-owned (read-through). |
| `phase_runtime_seconds.phase_4b_cross_stack` / `deterministic_tool_seconds.phase_4b_cross_stack` | cross-stack analysis (E104-S5) | Wall-clock of the Phase 4b cross-stack edge inspection; cross-stack-owned. |
| `cross_stack_warnings` | cross-stack analysis (E104-S5) | Array of `{source_stack, source_file, target_stack, target_file}` detail rows (possibly empty); cross-stack-owned. |
| `cross_stack_bypass_applied` | cross-stack analysis (E104-S5) | Bool — whether `--bypass cross-stack-refs` suppressed WARNINGs this run; cross-stack-owned. |

> **Single-author writer (AF-2026-05-09-12 sibling-defect guidance).** Each field
> is written by exactly ONE owning phase via `brownfield-telemetry.sh` — no fan-out.
> Ownership: the pre-warm pre-flight owns `*.pre_warm`; the SARIF merge owns
> `*.sarif_merge`; the dedup sub-step owns `*.dedup` + `gap_count_*` +
> `llm_token_count`; the Grype adapter owns `*.grype` + `grype_db_checksum` +
> `grype_db_built_age`; the orchestrator owns `*.orchestrator_intersection` +
> `per_stack_file_counts.*`; detect-signals owns `*.detect_signals` +
> `detect_signals_mode`; sbom-completeness owns `*.sbom_completeness` +
> `sbom_completeness_warning` + `divergence_pct` + `applied_threshold` +
> `detected_carve_outs`; the per-stack dead-code adapters own
> `*.deadcode_{go,python,jvm}`; the cross-stack analysis owns
> `*.phase_4b_cross_stack` + `cross_stack_warnings` + `cross_stack_bypass_applied`.
> The `gap_count_*` values are populated for real by
> the dedup (E104-S1) / reconciliation (E104-S2) phases.

## Phase 4 — Test Execution During Discovery

After Phases 2 / 3 scans complete, execute the existing test suite at the project path to capture test failures as gap entries. **This step is non-blocking** — test execution failures must not halt the overall brownfield onboarding workflow.

Spawn a Test Execution Scanner subagent:

- Auto-detect test runners (package.json with `test` script, pytest, Maven, Gradle, Go, Flutter) in priority order.
- Execute each detected runner with a 5-minute timeout.
- Parse test output for metrics (total, passing, failing, skipped).
- Convert failing tests to gap entries with severity mapped by test type (unit → medium, integration → high, e2e → critical).
- Detect infrastructure errors (ECONNREFUSED, missing env vars) and log as warning gaps rather than test-failure gaps.
- For monorepo / polyglot projects, execute all detected runners sequentially and aggregate results.
- Truncate output per NFR-024 token budget if needed.
- If no test suite is detected, log an info-level gap entry `GAP-TEST-INFO-001`.

Output to `.gaia/artifacts/planning-artifacts/brownfield-scan-test-execution.md`. If the subagent fails to write its output file, log a warning and continue.

## Phase 4b — Reconciliation (E104-S2 / FR-540 / ADR-124)

Inserted between Phase 4 (test execution) and Phase 5 (test-environment.yaml). When `brownfield.deterministic_tools: true` AND `brownfield.phase_4b_enabled: true`, Phase 4b reconciles Phase 3 file-only findings against the dependency graph and **demotes** (never removes) findings whose file is reachable from an application entry point — the barrel-file / dynamic-import false-positive guard that keeps FP rates tolerable for the deterministic-tools rollout.

It is a **pure JSON-join** — NO tool re-invocation — consuming already-computed outputs: the E104-S1 deduped finding stream + per-stack call-graphs (`callgraph-{js,go,python}.json`).

```bash
AUDIT="${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit"
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/reconcile.sh"
# Reads AUDIT/deduped-findings.json + AUDIT/callgraph-*.json; writes
# AUDIT/reconciled-findings.json. Degrades (WARN + passthrough) when the call-graph
# is absent (producer is Phase 4 supplementary tooling — not yet wired).
```

**Demote, don't remove (audit integrity).** A reachable finding keeps every identity field (`file_path`, `qualifier`, `source_tool`, `ruleId`, `start_line` — UNCHANGED) and gains `severity: info`, `reconciled: true`, `original_severity`, `entry_points: [...]`, `reconciliation_reason`. Files not reachable retain their original severity. Single-level reachability suffices (the call-graphs already encode transitivity), so the join is O(n log n) build + O(n) lookup — < 5s on a 1M-line monorepo (AC5). Telemetry: `findings_demoted_by_reconciliation`, `phase_runtime_seconds.phase_4b` (single-author; `gap_count_*` stay dedup-owned). See `scripts/adapters/brownfield/reconcile.README.md`.

The **Phase 4 → Phase 4b → Phase 5** ordering is preserved on every brownfield run. The cross-stack scope sub-step below composes WITHIN this Phase 4b body.

### Phase 4b cross-stack scope + WARNING emission (E104-S5 / FR-547 / NFR-89 / ADR-063 / ADR-120 / ADR-126)

A sub-step within Phase 4b. When `brownfield.deterministic_tools: true` AND `brownfield.phase_4b_cross_stack_enabled: true`, the reconciliation body above is extended with a cross-stack scope check that catches **unintended coupling** in multi-stack monorepos. It respects `stacks[].path` partitioning (per-stack reconciliation runs in isolation) and inspects the dependency-graph for edges that cross a stack boundary.

```bash
AUDIT="${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/reconcile-cross-stack.sh" \
  --bypass "$BYPASS_SKILL" --reason "$BYPASS_REASON"   # bypass args forwarded only when present
# Reads stacks[].path + cross_refs[] from project-config; reads the dep-graph from
# AUDIT/depgraph.json (producer wired by E104-S2 — degrades to INFO-skip if absent).
```

An edge from stack A to stack B where B is NOT in A's `cross_refs[]` allowlist emits the canonical ADR-063 WARNING (exact — operators/CI may grep it):

```
unsanctioned-cross-stack-reference: <source_stack>:<file> -> <target_stack>:<file>
```

**`cross_refs[]` is a per-source-stack outbound allowlist** (`A.cross_refs: [B]` ⇒ A may reference B). Shared subdirs require explicit declaration on EACH consuming stack — there is no "shared resource" concept (ADR-126 §Corner Cases). **Asymmetric allowlists are valid**: if `api` declares `[shared]` but `web` does not, only `web→shared` warns.

**Worked shared-subdir example.** `/shared` imported by both `/services/api` and `/services/web`:
- Both declare `cross_refs: [shared]` → no WARNING (both edges sanctioned).
- Drop `shared` from `web` only → one WARNING for `web→shared`; `api→shared` stays silent.

**Bypass (ADR-120).** `--bypass cross-stack-refs --reason "<text>"` suppresses the WARNINGs for the run and appends to `.gaia/memory/brownfield-audit/bypass-log.json`. The flag is parsed by the shared `scripts/lib/parse-bypass-flag.sh` (E85-S14 — required-reason, length 10–500); the SR-86 reason char-class (`^[A-Za-z0-9 ._-]+$`, shell metachars rejected) is enforced in the adapter. See E85-S14 for the canonical bypass-vocabulary doc (not duplicated here).

**Performance (NFR-89).** A `{file→stack}` reverse-index (longest-path-prefix match over `stacks[].path`) makes each edge an O(1) lookup — no per-edge graph walk; per-stack-pair detection is well under 100ms. **Single-stack** (`path: null`) collapses to one catch-all stack → zero cross-stack edges → byte-identical to the E104-S2 baseline (zero-regression). See `scripts/adapters/brownfield/reconcile-cross-stack.README.md`.

## Phase 5 — Auto-Generate test-environment.yaml from Detected Infrastructure

This phase delegates manifest generation to the shared library helper at `${CLAUDE_PLUGIN_ROOT}/scripts/lib/test-environment-manifest.sh` (E17-S33). The helper is the SINGLE canonical generator for `.gaia/config/test-environment.yaml` — both `/gaia-brownfield` Phase 5 (this section) and `/gaia-bridge-enable` Step 4 (E17-S34) invoke it.

1. Invoke the shared helper with `--target <project-path> --write` to detect stack signals and emit the manifest:

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/lib/test-environment-manifest.sh \
     --target "${PROJECT_PATH}" \
     --write
   ```

   The helper uses `detect-signals.sh` under the hood (same detection-signals.yaml registry brownfield consumes elsewhere). It writes to `.gaia/config/test-environment.yaml` with copy-if-absent semantics — if the file already exists, the helper preserves it byte-identical and exits 0.

2. **Conflict resolution** is handled by the helper:
   - File does not exist → helper writes the stack-specific manifest. Log `Created test-environment.yaml from detected infrastructure.`
   - File exists → helper preserves it byte-identical. Log `test-environment.yaml already exists — preserved byte-identical (copy-if-absent).`
   - Detection finds no stack → helper writes a generic single-tier-1 placeholder (FR-497) so Layer 0 readiness has something valid to read. Log `No stack detected — generic placeholder written; user should customize.`

3. **If the helper exits non-zero**, log the stderr message as a WARN-level entry and proceed. The conditional `test_environment_yaml_required_when_infra_detected` gate (per legacy E19-S12..S15 semantics) is NOT triggered when the helper succeeds OR when no stack is detected.

4. **Normal-mode review pause (E48-S4):** in normal mode, present a summary of the generated `.gaia/config/test-environment.yaml` (file path + detected stack name + runner names) and pause for user review before continuing to Phase 6. In yolo mode, skip the pause entirely and auto-continue. When the helper reported "preserved byte-identical" (existing file), the review pause is also skipped — the user is presumed to have already engaged with their existing manifest.

5. Record the helper exit code, detected stack, and chosen file disposition in the brownfield onboarding report for traceability.

## Phase 6 — NFR Assessment & Performance Test Plan

Invoke the `test-architect` subagent (Sable) via the `Agent` tool:

- Analyze the codebase for non-functional requirements across code quality (linting, complexity, duplication), security posture (dependency vulnerabilities, secrets handling, auth quality), performance (bundle size for frontend, query patterns, caching, resource management), accessibility (ARIA, semantic HTML, keyboard nav for frontend), test coverage (framework, count, coverage %, untested areas, quality), and CI/CD (pipeline, deploy strategy, environments, IaC).
- Create an NFR Baseline Summary Table with measured values (not placeholders).
- Output the NFR assessment to `.gaia/artifacts/planning-artifacts/nfr-assessment/nfr-assessment-{date}.md` (E105-S3 / ADR-127 Pillar 3 — dated-snapshot subdir under planning-artifacts; AF-29-2 / AF-30-1 moved this out of flat `test-artifacts/`). Legacy ungrouped `test-artifacts/nfr-assessment.md` remains read-only fallback for projects pre-migration (Test10 F-37).
- Generate a performance test plan: load k6 patterns; if frontend, also load Lighthouse-CI patterns. Define performance budgets (P50/P95/P99), load test scenarios (gradual, spike, soak), backend profiling targets (slow queries, N+1, connection pools), CI performance gates. If frontend, define Core Web Vitals targets (LCP < 2.5s, INP < 200ms, CLS < 0.1).
- Output the performance test plan to `.gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-{date}.md` (E105-S3 / ADR-127 Pillar 3 — dated-snapshot subdir under planning-artifacts; legacy ungrouped `test-artifacts/performance-test-plan-{date}.md` remains read-only fallback for projects pre-migration; Test10 F-37).

**AC-EC5 fallback — test-architect unavailable:** If the `test-architect` subagent is not installed or unreachable at runtime, log a non-blocking warning and write a stub `nfr-assessment.md` with a clear banner:

```
> WARNING: test-architect subagent (Sable) unavailable at runtime.
> This is a stub file emitted by gaia-brownfield to satisfy the
> post-complete nfr_assessment_exists gate. Re-run /gaia-nfr after
> installing the test-architect agent to populate real content.
```

The post-complete gate then reports the gap rather than crashing. Also write a stub `performance-test-plan-{date}.md` with the same banner and re-run instruction.

**AC-EC9 — both outputs required:** The legacy gate requires BOTH `nfr-assessment.md` AND `performance-test-plan-{date}.md`. If the subagent completes but emits only one of the two, the orchestrator MUST write the second (at minimum as a stub) so both exist before the post-complete gate fires. Missing either one halts the skill at the gate with the same error text as the legacy workflow: `HALT: NFR assessment not found at {test_artifacts}/nfr-assessment.md.` or `HALT: Performance test plan not found at {test_artifacts}/. Run /gaia-perf-testing.` Both files are required for pass.

**Gate check after Phase 6:** Invoke the shared validate-gate pathway inline — see the Post-Complete Gates section at the end of this skill for the three gates enforced via `!${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh`.

## Phase 7 — Gap Consolidation & Deduplication

### Phase 7 PRE-step 0 — Scan-fidelity banner (AF-2026-05-30-2 / Test10 §7 C3)

Before SARIF merge runs, invoke `/gaia-doctor` (via its check-tools.sh) to determine the achievable scan tier and stamp it into `consolidated-gaps.md`:

```bash
DOCTOR_JSON=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/gaia-doctor/scripts/check-tools.sh --json 2>/dev/null || echo '{}')
TIER=$(printf '%s' "$DOCTOR_JSON" | jq -r '.tier // "tier-0"')
TIER_REASON=$(printf '%s' "$DOCTOR_JSON" | jq -r '.tier_reason // "LLM-only (deterministic tools missing — heuristic fidelity)"')
MISSING_TOOLS=$(printf '%s' "$DOCTOR_JSON" | jq -r '[.tools[] | select(.state=="missing") | .id] | join(", ")')

REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
# Prepend banner + frontmatter scan_fidelity field. If consolidated-gaps.md
# already has frontmatter, splice scan_fidelity into it; else create one.
if [ -f "$REPORT" ] && head -1 "$REPORT" | grep -q '^---$'; then
  # Has frontmatter — splice scan_fidelity in.
  awk -v tier="$TIER" -v reason="$TIER_REASON" '
    NR==1 { print; print "scan_fidelity: " tier; print "scan_fidelity_reason: " reason; next }
    /^---$/ && nseen<1 { nseen++; print; next }
    { print }
  ' "$REPORT" > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
else
  # No frontmatter — create one.
  {
    echo "---"
    echo "scan_fidelity: $TIER"
    echo "scan_fidelity_reason: $TIER_REASON"
    echo "---"
    echo ""
    [ -f "$REPORT" ] && cat "$REPORT"
  } > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
fi

# Banner block — visible in the rendered Markdown.
{
  echo ""
  echo "> **Scan fidelity: ${TIER^^} (${TIER_REASON}).**"
  if [ -n "$MISSING_TOOLS" ]; then
    echo "> Deterministic CVE/SBOM/dead-code did not run (${MISSING_TOOLS} absent)."
    echo "> This gap list is heuristic, not tool-verified. Re-run after \`gaia-doctor --install\` for tool-grade results."
  fi
  echo ""
} >> "$REPORT"
```

**Why this exists (Test10 §7 C3 guiding principle):** "Never degrade silently." Before this banner, an LLM-only scan looked byte-identical to a clean full-tier scan — operators read PASS verdicts on gap reports where no actual tool had run. The banner makes the degradation transparent: every consolidated-gaps.md now declares its achievable tier in frontmatter (`scan_fidelity: tier-0|tier-1|tier-2`) and renders a human-readable degradation notice in the report body when applicable. The frontmatter field is also machine-readable so downstream consumers (review skills, dashboards) can refuse to grade a Tier 0 scan as equivalent to a Tier 2 scan.

### Phase 7 PRE-step — SARIF Multitool merge (E104-S4 / FR-544 / ADR-125)

Before the 6-step gap-consolidation recipe runs, merge all scanner SARIF outputs into one merged SARIF. This gives the recipe (and downstream dedup E104-S1) a single uniform interchange format instead of bespoke per-tool JSON.

```bash
# Flag resolution (ADR-078 master flag + per-tool override).
# AF-2026-05-30-3: defaults flipped from `false` to `true` so a stock
# /gaia-brownfield run merges SARIF by default. See the matching note on
# the Phase 3 prelude flip earlier in this SKILL.
DET_TOOLS="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.deterministic_tools 2>/dev/null)"
SARIF_ON="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.sarif_merge_enabled 2>/dev/null)"
export GAIA_BROWNFIELD_DETERMINISTIC_TOOLS="${DET_TOOLS:-true}"
export GAIA_BROWNFIELD_SARIF_MERGE_ENABLED="${SARIF_ON:-true}"

sarif_merge_start=$(date +%s)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/sarif-merge.sh" || true
sarif_merge_seconds=$(( $(date +%s) - sarif_merge_start ))

# Telemetry population (E104-S1 brownfield-telemetry.sh — shared, single-author-per-field).
# The SARIF merge step OWNS the *.sarif_merge fields (no fan-out).
SARIF_REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
SARIF_TELEM="${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/brownfield-telemetry.sh"
if [ -f "$SARIF_REPORT" ]; then
  bash "$SARIF_TELEM" --report "$SARIF_REPORT" --field phase_runtime_seconds.sarif_merge --value "$sarif_merge_seconds" || true
  bash "$SARIF_TELEM" --report "$SARIF_REPORT" --field deterministic_tool_seconds.sarif_merge --value "$sarif_merge_seconds" || true
fi

# DefectDojo export is opt-in (default off → zero network). Fire-and-forget.
DD_ON="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.defectdojo_enabled 2>/dev/null)"
export GAIA_BROWNFIELD_DEFECTDOJO_ENABLED="${DD_ON:-false}"
if [ "${GAIA_BROWNFIELD_DEFECTDOJO_ENABLED}" = "true" ]; then
  export GAIA_BROWNFIELD_DEFECTDOJO_API_URL="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.defectdojo_api_url 2>/dev/null)"
  # api_token config holds the NAME of an env var (NFR-RSV2-7); resolve the name, then deref it.
  DD_TOKEN_VAR="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.defectdojo_api_token 2>/dev/null)"
  export GAIA_BROWNFIELD_DEFECTDOJO_API_TOKEN="${!DD_TOKEN_VAR:-}"
  export GAIA_BROWNFIELD_DEFECTDOJO_ENGAGEMENT_ID="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.defectdojo_engagement_id 2>/dev/null)"
fi
bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/defectdojo-export.sh" \
  "${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/brownfield-sarif-merged.json" || true
```

**SARIF-as-interchange rationale (AC6).** SARIF 2.1.0 is the consensus interchange format — named independently by Zara (security), Soren (DevOps), Hugo (Java), and Derek (PM) in the 2026-05-23 brownfield deterministic-tools meeting. Microsoft's `Sarif.Multitool` is the canonical merger: it preserves per-tool attribution by concatenating one `run` per scanner (each carrying its `tool.driver.name`). Migrating bespoke per-tool JSON to merged SARIF removes per-tool parser maintenance and enables uniform downstream consumption (dedup, reconciliation, ranking). See `scripts/adapters/brownfield/sarif-merge.README.md`.

**Migration shim (1-sprint deprecation).** When no `*.sarif` inputs exist (or the flag is off), `sarif-merge.sh` emits a WARN/INFO line and the 6-step recipe below falls back to its prior per-tool JSON consumption at Step 1. The legacy per-tool JSON path is slated for removal in the next sprint.

`sarif_merge_seconds` feeds the `phase_runtime_seconds.sarif_merge` telemetry field (see the Phase 3 telemetry subsection; the populating writer is `brownfield-telemetry.sh`, landed by E104-S1).

### Phase 7 dedup sub-step (E104-S1 / FR-541 / ADR-123)

Immediately after the SARIF merge PRE-step and BEFORE Phase 4b reconciliation (E104-S2), run the cross-tool dedup over the merged SARIF. Dedup is the FIRST sub-step of the 6-step recipe (reordered to **load → dedup → validate → rank → budget → write**) — dedup-first shrinks the working set the downstream validate/rank/budget steps process. Dedup uses two key shapes (CVE-class keyed `(CVE-ID, file, severity)` with Grype-canonical tie-break; non-CVE-class grouped `(file, symbol)` with the precision ladder) per `docs/dedup-contract.md`.

```bash
DEDUP_ON="$(${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh --field brownfield.dedup_enabled 2>/dev/null)"
export GAIA_BROWNFIELD_DEDUP_ENABLED="${DEDUP_ON:-true}"   # default-on per E104-S1 Task 5
dedup_start=$(date +%s)
# Capture dedup.sh stdout so the gap_count_* values can be parsed from its INFO log line:
#   "dedup: <N> raw finding(s) -> <M> deduped (gap_count_before_dedup=<N> gap_count_after_dedup=<M>) ..."
dedup_log="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/dedup.sh" 2>&1 || true)"
printf '%s\n' "$dedup_log"
dedup_seconds=$(( $(date +%s) - dedup_start ))
gap_before="$(printf '%s' "$dedup_log" | sed -n 's/.*gap_count_before_dedup=\([0-9][0-9]*\).*/\1/p' | head -n1)"
gap_after="$(printf '%s' "$dedup_log" | sed -n 's/.*gap_count_after_dedup=\([0-9][0-9]*\).*/\1/p' | head -n1)"

# Telemetry population (E104-S1 brownfield-telemetry.sh — the shared, single-author-per-field
# writer). The dedup phase OWNS gap_count_*, *.dedup runtime, and llm_token_count (deterministic).
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
TELEM="${CLAUDE_PLUGIN_ROOT}/scripts/adapters/brownfield/brownfield-telemetry.sh"
if [ -f "$REPORT" ]; then
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.dedup --value "$dedup_seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.dedup --value "$dedup_seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
  [ -n "$gap_before" ] && bash "$TELEM" --report "$REPORT" --field gap_count_before_dedup --value "$gap_before" || true
  [ -n "$gap_after" ]  && bash "$TELEM" --report "$REPORT" --field gap_count_after_dedup  --value "$gap_after"  || true
fi
```

When the dedup flag is off (or the master flag is off), `dedup.sh` passes the raw stream through unchanged (`gap_count_before_dedup == gap_count_after_dedup`) and logs an INFO skip. The deduped stream is written to `.gaia/memory/brownfield-audit/deduped-findings.json` for the E104-S2 Phase 4b reconciliation consumer.

> **Single-author-per-field telemetry (AF-2026-05-09-12).** `brownfield-telemetry.sh` is the shared writer mechanism, but each field has exactly ONE owning phase: the pre-warm pre-flight owns `*.pre_warm`, the SARIF merge owns `*.sarif_merge`, and this dedup sub-step owns `*.dedup` + `gap_count_*` + `llm_token_count`. No field is written by more than one phase (no fan-out).

### Phase 7 dead-code "Test Quality" render sub-step (E70-S8 / FR-545 / NFR-87)

After the dedup sub-step, render the unified **Test Quality** section into
`consolidated-gaps.md` from the three per-stack dead-code adapter outputs
collected in Phase 3. This is a NET-NEW section (created, not edited) and is
intentionally rendered as ONE `## Test Quality` H2 with THREE per-stack H3
sub-sections (Go / Python / JVM) — each showing its stack-native qualifier
verbatim. The renderer is idempotent (re-running replaces, never duplicates).

```bash
AUDIT="${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit"
REPORT="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/adapters/dead-code/render-test-quality.sh" \
  --out-dir "$AUDIT" --report "$REPORT" || true
```

**Anti-pattern guard (NFR-87 / AC4).** The section MUST NOT collapse the three
stacks into one flat list with a synthesized cross-stack confidence column — Go's
binary reachability verdict, Python's confidence %, and JVM's priority×rank ordinal
are NOT commensurable. Per-stack precision is the contract this story preserves
(meeting-2026-05-23, Sable turn 12). The per-stack SARIF runs (Phase 3) ALSO feed
the dedup precision ladder above via `.properties.symbol`, so the dead-code findings
participate in cross-tool dedup without forfeiting their native qualifier.

Spawn a Gap Consolidation subagent:

**Step 1 — Load all scan outputs.** When the SARIF merge pre-step produced `.gaia/artifacts/planning-artifacts/brownfield-sarif-merged.json`, load gap entries from that MERGED SARIF as the primary scanner-finding source (one `run` per contributing scanner, attributed by `tool.driver.name`). When the merge was skipped/fell back (no SARIF inputs or flag off), load gap entries from the legacy per-tool sources below instead. In BOTH paths, also load the non-scanner gap sources. If a file is empty or missing, log a warning noting which scanner produced no results and continue.

- Deep analysis scans (7 files from Phase 3): config-contradiction, dead-code, hardcoded, security, runtime-behavior, doc-code, integration-seam.
- Test execution scan (1 file from Phase 4): brownfield-scan-test-execution.md.
- Phase 2 documentation outputs (4 files): api-documentation.md (API gaps), event-catalog.md (messaging gaps), ux-design.md (frontend/UX gaps), dependency-map.md (dependency gaps).
- Phase 6 NFR: nfr-assessment.md (NFR gap findings).

**Step 2 — Validate entries against schema.** Required fields: `id`, `category`, `severity`, `title`, `description` (or `evidence`), `evidence_file`, `evidence_line`, `recommendation`. Entries missing required fields are logged as warnings (noting source file and missing field) and skipped from consolidation.

**Step 3 — Deduplicate (LLM entry-level).** Cross-tool scanner-finding dedup already ran as the deterministic dedup sub-step BEFORE this recipe (E104-S1 `dedup.sh`, the FIRST sub-step of the reordered load → dedup → validate → rank → budget → write recipe). This Step 3 is a SECONDARY, coarser entry-level dedup over the consolidated gap entries (including the non-scanner sources). Group gap entries by `evidence_file` + `evidence_line` exact match. For each group:
- Retain the entry with the highest severity (critical > high > medium > low).
- Merge recommendations from all duplicate entries into the retained entry.
- Add a `merged_from` field listing all original gap IDs.
- If duplicates have different categories, retain the primary category from the highest-severity entry and note the alternate category in the description.

**Step 4 — Rank.** Sort by severity DESC, then confidence DESC, then category alphabetical. Assign sequential numbering.

**Step 5 — Budget check.** Estimate token count (~100 tokens per gap entry). If the total exceeds the 40K token budget, truncate low-severity and info entries with a count summary `N additional low/info gaps omitted for budget`. Stay within budget (AC-EC6).

**Step 6 — Generate consolidated output.** Write `.gaia/artifacts/planning-artifacts/consolidated-gaps.md` with summary statistics at the top:
- Total raw gaps (pre-dedup count)
- Duplicates removed
- Final unique count
- Breakdown by category
- Breakdown by severity
- Per-scanner source counts

## Phase 8 — PRD + Adversarial Review + Code-Verified Review

### 8a — Create PRD for Gaps

Select the PRD template based on `{project_type}`:

| project_type     | Template File              | Requirement ID Scheme                        |
|------------------|----------------------------|----------------------------------------------|
| application      | prd-template.md            | FR-###, NFR-###                              |
| infrastructure   | infra-prd-template.md      | IR-###, OR-###, SR-###                       |
| platform         | platform-prd-template.md   | FR-###, NFR-### and IR-###, OR-###, SR-###   |

Verify the template file exists. If missing, halt with `Template {selected_template} not found. Ensure E12-S2 (infra) or E12-S3 (platform) templates are installed.` If `{project_type}` is unrecognized, default to `application`.

Read upstream artifacts to inform gap analysis:
- `project-documentation.md` → project context (tech stack, patterns, conventions, capability flags, CI/CD).
- `consolidated-gaps.md` → primary input (deduplicated, ranked, code-verified gap list). If a `## Verification Corrections for PRD` section exists (from Phase 8c), apply its corrections.
- `nfr-assessment.md` → NFR "Current Baseline" and "Target" columns with real values.
- `api-documentation.md` (if exists) → API gaps.
- `event-catalog.md` (if exists) → messaging gaps.
- `dependency-map.md` → dependency risks.
- `dependency-audit-{date}.md` → critical / high findings.
- `ux-design.md` (if exists) → UX gaps.

Generate the PRD in brownfield mode — every section filled with gap-focused content only. Overview = existing project summary + what gaps this PRD addresses. Goals = gap closure goals only. Non-Goals = existing features that will NOT be re-implemented. User Stories = gap stories only. Functional Requirements = gap requirements organized by priority. NFRs = NFR gaps with baseline and target from the NFR assessment.

If `prd.md` already exists, warn the user: `A PRD already exists. Continuing will overwrite it with brownfield gap content. Choose: (a) overwrite, (b) save as prd-brownfield-gaps.md instead.` If the user chooses (b), adjust the output path.

YAML frontmatter MUST include `mode: brownfield`, `baseline_version: {version from package.json or inferred}`, `focus: gap-filling`. Add `Mode: Brownfield — gaps only` to the header. Include a Priority Matrix section mapping each gap to priority / effort / impact.

Write to `.gaia/artifacts/planning-artifacts/prd.md`.

### 8b — Adversarial Review & PRD Refinement

Dispatch the **`adversarial-reviewer`** subagent (Sage) via the Agent tool to critique the PRD. Target `.gaia/artifacts/planning-artifacts/prd.md`; **before dispatching, run `mkdir -p .gaia/artifacts/planning-artifacts/adversarial/`** so the nested directory exists on first run (ADR-119). Report output path `.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-{YYYY-MM-DD}.md` (use today's UTC date; AF-2026-05-30-1 / Test03 §7.3 — adversarial joins the dated-snapshot pattern). Sage's persona at `plugins/gaia/agents/adversarial-reviewer.md` defines the review structure, severity vocabulary (CRITICAL/WARNING/INFO per ADR-037), and brownfield-relevant lenses (documented-vs-actual drift, hidden coupling, known-knowns vs known-unknowns). When the subagent returns, verify `adversarial-review-prd-{date}.md` exists in `.gaia/artifacts/planning-artifacts/adversarial/` (legacy ungrouped `.gaia/artifacts/planning-artifacts/adversarial-review-prd-{date}.md` is accepted as a read-only fallback on pre-AF-30-1 projects). Per ADR-063 (Mandatory Verdict Surfacing), display the returned ADR-037 envelope to the user. Extract critical and high severity findings. For each critical/high finding, add a new requirement or refine an existing requirement in the PRD. Add a `## Review Findings Incorporated` section to the PRD listing each finding, its severity, and how it was addressed.

**YOLO mode contract (AF-2026-05-29-2 / Test09 F-11; extended by
AF-2026-05-31-1 / Test12 F-11).** Under YOLO, brownfield CRITICAL findings
that describe **the scanned codebase itself** are auto-downgraded to
WARNING-equivalent for the purposes of the halt-check across THREE phases:

- **Phase 3** scan subagents (doc-code drift, hardcoded values, integration
  seams, runtime behavior, security, config contradictions, dead code) —
  every CRITICAL these subagents return is, by definition, a real defect
  in the target codebase. Halting on them defeats brownfield's
  gap-discovery mission. Subagent errors of the form "scanner crashed" /
  "tool not available" are still halts; finding-content CRITICALs about
  the scanned code are downgraded.
- **Phase 6** test-architect (Sable) NFR assessment — Sable routinely
  returns CRITICAL findings like "CI pre-merge gate is a no-op stub; tests
  never run" or "no test coverage measurement". These are baseline-state
  facts about the project, not scanner failures. Same downgrade rule as
  Phase 3.
- **Phase 8b** adversarial review (Sage) on the synthesized PRD —
  content-quality CRITICALs like untestable acceptance criteria, ambiguous
  scope, or missing edge cases. Phase 8c's code-verified review provides
  the anti-fabrication backstop.

**The downgrade does NOT apply to:** Phase 4 test-execution CRITICALs
(which signal test-infrastructure problems, not target-code gaps), Phase 8c
code-verified CRITICALs (which signal verified contradictions between PRD
claims and code — these MUST halt to avoid shipping factually-wrong PRDs),
or any subagent error CRITICAL of the "tool crashed / pipeline broken"
shape. Those still halt under YOLO per ADR-063/067. The original CRITICAL
findings are still recorded verbatim in the artifact each phase produces
(scan reports for Phase 3, NFR assessment for Phase 6,
`adversarial-review-prd-{date}.md` for Phase 8b) and roll into the Phase 7
consolidated gap list — nothing is lost; only the halt-on-CRITICAL
semantic is downgraded for these three phases under YOLO so the brownfield
onboarding loop can actually complete on any real-world project (which by
definition has critical gaps — that's why brownfield is being run on it).

### 8c — Code-Verified Review

Spawn a Code-Verified Review subagent to verify every factual claim in the consolidated gap entries against the actual codebase.

**Step 1 — Load and parse `consolidated-gaps.md`.** Parse all YAML gap entries. If empty or zero parseable entries, exit gracefully with `0 gaps to verify`. For malformed entries missing required fields, log a warning, skip, and include in the summary as skipped.

**Step 2 — Extract verifiable claims.** For each valid entry: file existence (`evidence_file`), line range (`evidence_line` within file's total line count), pattern / string presence from `description` and `recommendation`, config key existence (for `configuration` category gaps). Entries with no verifiable claims → classify as `unverifiable`.

**Step 3 — Verify each claim against the codebase** using `Grep`, `Glob`, `Read` (not shell commands). For each claim:
- File existence: glob/read the path. Missing file → classify gap as `contradicted` with reason `Referenced file not found: {evidence_file}`. Preserve original gap with downgraded confidence.
- Binary files (extensions `.png`, `.jpg`, `.gif`, `.woff`, `.ttf`, `.ico`, `.pdf`, `.zip`, `.tar`, `.gz`, `.exe`, `.dll`, `.so`, `.dylib`) → classify as `unverifiable` with reason `Binary file — cannot verify textual claims`.
- Line range: total line count vs `evidence_line`. Out of range → `contradicted` with reason `Line {evidence_line} exceeds file length ({actual_lines} lines)`.
- Pattern search: use grep with escaped regex special characters. Pattern found → confirmed. Pattern not found → contributes to `contradicted`.
- Config key: parse YAML/JSON and check for key existence at stated paths.

**Step 4 — Apply tristate classification.** `verified` (all claims confirmed), `unverifiable` (cannot be confirmed from code alone — runtime behavior, subjective assessments, binary files), `contradicted` (evidence directly contradicts one or more claims). For contradicted gaps, downgrade confidence, attach a `reason` string, and generate a new entry `GAP-VERIFIED-{seq}` with `verified_by: code-verified` and the actual state found.

**Step 5 — Update `consolidated-gaps.md`.** Add `verification_status` and `verified_by: code-verified` to each entry. Preserve all existing fields — do not remove or overwrite original data. Append new entries from contradicted claims at the end.

**Step 6 — Verification summary.** Include total processed, verified, unverifiable, contradicted, new entries from contradictions, and skipped (malformed) counts.

**Step 7 — Feedback to Step 8a.** Write contradicted claims and reasons to a section `## Verification Corrections for PRD` at the top of `consolidated-gaps.md`. When the PRD is regenerated, this section corrects factual errors.

## Phase 9 — Architecture + Ground-Truth Bootstrap

### 9a — Architecture

The architecture is generated by invoking the shared `create-architecture` pipeline via a subagent in YOLO mode. The `create-architecture` pipeline auto-detects brownfield mode from the PRD `Mode: Brownfield` header set in Phase 8a.

If `architecture.md` already exists, warn the user: `An architecture document already exists. Continuing will overwrite it with the brownfield version. Choose: (a) overwrite, (b) save as architecture-brownfield.md instead.` If the user chooses (b), instruct the subagent to output to `architecture-brownfield.md`.

After architecture is generated, verify it has YAML frontmatter with `mode: brownfield`, `baseline_version: {version}`, and `update_scope: [list of components being modified]`. If missing, append them.

### 9b — Bootstrap Val Ground Truth (optional)

Check if Val is installed: `plugins/gaia/agents/validator.md` exists AND `.validator-sidecar/` directory is present. If not installed, skip this phase silently — brownfield onboarding continues without ground-truth bootstrap.

Ask: `Step 7: Bootstrap Val ground truth from brownfield assessment? [y/n]`

If yes: invoke `/gaia-refresh-ground-truth` (if the skill exists) to scan the filesystem and populate framework inventory facts. Load the `brownfield-extraction` section of `ground-truth-management` JIT. Read available brownfield artifacts and extract project-specific facts:
- `brownfield-assessment.md` → tech stack, dependencies, file counts, project structure
- `project-documentation.md` → architecture patterns, conventions, config values
- `nfr-assessment.md` (if present) → performance targets, security requirements

Write extracted facts to `.gaia/memory/validator-sidecar/ground-truth.md`. If the file already exists with content, merge — add new facts, update changed facts, flag removed facts. Never destructive overwrite.

### 9c — Tier 1 Agent Ground Truth (optional)

Ask: `Bootstrap Tier 1 agent ground truth (Theo, Derek, Nate)? [y/n]`

If yes:

- **Theo (Architect)** — Read `architecture.md` (fall back to `brownfield-assessment.md`). Extract tech stack (→ variable-inventory), ADRs (→ structural-pattern), component inventory (→ file-inventory), dependency map (→ cross-reference). Token budget: 150K; trim at 60% threshold (90K). Write to `.gaia/memory/architect-sidecar/ground-truth.md`.
- **Derek (Product Manager)** — Read `prd.md` (fall back to `prd-brownfield-gaps.md`). Extract functional requirements, user stories, acceptance criteria summaries. Also read `epics-and-stories.md` for epic overviews and story-to-epic mappings. Also read `nfr-assessment.md` for quality baselines. Token budget: 100K; trim at 60% threshold (60K). Write to `.gaia/memory/pm-sidecar/ground-truth.md`.
- **Nate (Scrum Master)** — Read `sprint-status.yaml` (if exists) for sprint state. Read `.gaia/memory/sm-sidecar/velocity-data.md` (if exists) for velocity and capacity. If neither exists, log `insufficient sprint data, velocity unavailable` and write ground-truth.md omitting velocity. Token budget: 100K; trim at 60% threshold (60K). Write to `.gaia/memory/sm-sidecar/ground-truth.md`.

After all Tier 1 extractions complete, output a summary: `Seeded {N} entries for Theo, {M} entries for Derek, {K} entries for Nate`. If sprint data was absent, append `(sprint data absent — velocity entries omitted)`. Include token budget status (GREEN/YELLOW/RED) per agent.

## Output — Primary Artifact

Write the final brownfield onboarding report to `.gaia/artifacts/planning-artifacts/brownfield-onboarding.md`. This is the primary output artifact (preserved verbatim from the legacy workflow's `output.primary` contract for NFR-053 parity). It summarizes:

- Project discovery findings (`{project_type}`, capability flags, tech stack)
- Links to all generated secondary artifacts
- Consolidated gap summary (counts by severity / category)
- NFR baseline summary
- Test-environment generation outcome (created / merged / skipped / not-applicable)
- Next-step recommendations (remaining Phase 3 chain)

## Output — Secondary Artifacts

The full artifact set emitted by this skill (preserved from the legacy `output.artifacts` contract):

- `.gaia/artifacts/planning-artifacts/project-documentation.md` (Phase 1)
- `.gaia/artifacts/planning-artifacts/api-documentation.md` (Phase 2, if `{has_apis}`)
- `.gaia/artifacts/planning-artifacts/ux-design.md` (Phase 2, if `{has_frontend}`)
- `.gaia/artifacts/planning-artifacts/event-catalog.md` (Phase 2, if `{has_events}`)
- `.gaia/artifacts/planning-artifacts/dependency-map.md` (Phase 2)
- `.gaia/artifacts/test-artifacts/dependency-audit-{date}.md` (Phase 2)
- `.gaia/artifacts/planning-artifacts/brownfield-subagent-summary.md` (Phase 2)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-doc-code.md` (Phase 3)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-hardcoded.md` (Phase 3)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-integration-seam.md` (Phase 3)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-runtime-behavior.md` (Phase 3)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-security.md` (Phase 3)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-config-contradiction.md` (Phase 3)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-dead-code.md` (Phase 3)
- `.gaia/artifacts/planning-artifacts/brownfield-scan-test-execution.md` (Phase 4)
- `.gaia/config/test-environment.yaml` (Phase 5, conditional)
- `.gaia/artifacts/planning-artifacts/nfr-assessment/nfr-assessment-{date}.md` (Phase 6 — gated; Test10 F-37 — dated-snapshot subdir under planning-artifacts per E105-S3 / ADR-127 Pillar 3; legacy flat `test-artifacts/nfr-assessment.md` remains read-only fallback)
- `.gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-{date}.md` (Phase 6 — gated; Test10 F-37 — dated-snapshot subdir under planning-artifacts per E105-S3 / ADR-127 Pillar 3; legacy flat `test-artifacts/performance-test-plan-{date}.md` remains read-only fallback)
- `.gaia/artifacts/planning-artifacts/consolidated-gaps.md` (Phase 7)
- `.gaia/artifacts/planning-artifacts/prd.md` (Phase 8a)
- `.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-{date}.md` (Phase 8b — AF-2026-05-30-1 / Test03 §7.3 grouping)
- `.gaia/artifacts/planning-artifacts/architecture.md` (Phase 9a)
- `.gaia/artifacts/planning-artifacts/epics-and-stories.md` (downstream, via next-step chain — see below)
- `.gaia/artifacts/planning-artifacts/brownfield-onboarding.md` (primary)

### Known constraint — artifact dispersion across four roots (AF-2026-05-30-4 F-20 / F-21)

The artifact set above is intentionally dispersed across **four** roots
rather than consolidated under a single `planning-artifacts/` tree. The
dispersion is FORCED by the framework's existing gate / writer contracts
in 1.181.0 — relocating any of these files would break the readiness and
review gates until the underlying resolvers are refactored.

The four roots and their pin points:

1. `.gaia/artifacts/planning-artifacts/` — the bulk of brownfield outputs
   (PRD, architecture, ux-design, epics-and-stories, the seven scan
   reports, NFR-assessment + perf-test-plan dated snapshots,
   adversarial reviews, etc.). The "natural" home.
2. `.gaia/artifacts/test-artifacts/` — `test-plan.md`,
   `traceability-matrix.md`, `ci-setup.md`, and
   `dependency-audit-{date}.md`. Pinned here by the
   `validate-gate.sh` resolvers `test_plan_exists` /
   `traceability_exists` / `ci_setup_exists` which look at
   `${TEST_ARTIFACTS}/…`. Moving these into `planning-artifacts/`
   without changing the resolvers first breaks the readiness gates.
3. `.gaia/config/` — `test-environment.yaml(.example)`, pinned by
   ADR-110.
4. `.gaia/state/` — `sprint-status.yaml` (the live runtime state),
   pinned by `sprint-state.sh`'s writer contract.

Per-story `reviews/` (Test-artifacts mirror absence, F-21):
The test-lens review reports (`qa-tests`, `test-automate-review`,
`test-review`) and the per-tier `execution-evidence.json` are written
ONLY under `implementation-artifacts/epic-*/{key}-*/reviews/`, co-located
with the code / security / performance reviews. The framework does NOT
emit a symmetric `test-artifacts/epic-*/{key}-*/` mirror, and execution
evidence is a single `execution-evidence.json` rather than a per-tier
`execution-evidence/{qa-tests,test-automation,test-review}.json` set.
AF-2026-05-30-1's per-story resolver already supports the mirror
direction in code; consumers (the three test reviewers + the bridge)
have not yet been retrofitted to write or read the mirror. Until that
retrofit lands, expect every test-lens artifact at the
`implementation-artifacts/…/reviews/` path only.

A consolidation refactor (moving test-plan/traceability/ci-setup into
`planning-artifacts/`, mirroring the test-lens artifacts under
`test-artifacts/`) is a multi-skill change tracked separately — out of
scope for the brownfield skill itself.

The `{date}` placeholder is substituted with the current date in `YYYY-MM-DD` form at write time, preserving the legacy substitution pattern.

## Post-Complete Gates

Three gates enforced via `!${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh` after all phases complete. **AF-2026-05-29-2 / Test09 F-16:** the prior names (`nfr_assessment_exists`, `performance_test_plan_exists`, `test_environment_yaml_required_when_infra_detected`) were NOT registered in `validate-gate.sh`'s `SUPPORTED_GATES` constant — invoking them produced `unknown gate type` and silently no-op'd. The gates are now expressed via the supported `file_exists --file <path>` form so they actually execute:

1. **NFR-assessment exists** — first resolve via the dated-subdir form (`.gaia/artifacts/planning-artifacts/nfr-assessment/nfr-assessment-*.md`) then fall back to the legacy flat `.gaia/artifacts/test-artifacts/nfr-assessment.md`. Assert: `!${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh file_exists --file "$(ls -1t .gaia/artifacts/planning-artifacts/nfr-assessment/nfr-assessment-*.md 2>/dev/null | head -1 || echo .gaia/artifacts/test-artifacts/nfr-assessment.md)"`. On fail: `HALT: NFR assessment not found at .gaia/artifacts/planning-artifacts/nfr-assessment/.` (Test10 F-37 — moved out of flat test-artifacts/.)
2. **Performance test plan exists** — first resolve via the dated-subdir form (`.gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-*.md`) then fall back to the legacy flat `.gaia/artifacts/test-artifacts/performance-test-plan-*.md`. Assert: `!${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh file_exists --file "$(ls -1t .gaia/artifacts/planning-artifacts/performance-test-plan/performance-test-plan-*.md 2>/dev/null | head -1 || ls -1t .gaia/artifacts/test-artifacts/performance-test-plan-*.md 2>/dev/null | head -1)"`. On fail (no match or empty file): `HALT: Performance test plan not found at .gaia/artifacts/planning-artifacts/performance-test-plan/. Run /gaia-perf-testing.` (Test10 F-37 — moved out of flat test-artifacts/.)
3. **test-environment.yaml when infra detected** (conditional) — if any of the four test-infrastructure detectors (E19-S12 / S13 / S14 / S15) fired during Phase 5, then `.gaia/config/test-environment.yaml` MUST exist: `!${CLAUDE_PLUGIN_ROOT}/scripts/validate-gate.sh file_exists --file .gaia/config/test-environment.yaml` (legacy `config/test-environment.yaml` is also accepted as read-compat per ADR-111). On fail: `HALT: Brownfield detected test infrastructure but test-environment.yaml was not generated. Re-run step 2.8 or run /gaia-brownfield again.` When zero test infrastructure was detected (AC-EC3), the orchestrator SKIPS this gate entirely.

`validate-gate.sh` serves the role of the spec-level `file-gate.sh` in the deployed script set (see Reconciliation Note).

## Subagent Dispatch Contract

Every subagent dispatched by this skill — Phase 2 documenters, Phase 3 scan subagents, Phase 4 test-execution scanner, Phase 6 test-architect (Sable), Phase 7 gap consolidation, Phase 8b adversarial review, Phase 8c code-verified review, Phase 9a architecture pipeline — returns a structured payload conforming to the **ADR-037** schema: `{status, summary, artifacts, findings, next}`. Per **ADR-063** (Mandatory Verdict Surfacing), this skill MUST surface every subagent's verdict (`PASS` / `WARNING` / `CRITICAL`) to the user — no silent gates. Specifically:

- `status: PASS` — log the subagent name, the artifacts it produced, and continue to the next phase.
- `status: WARNING` — display the `findings` block to the user before continuing. The user remains in control: in normal mode they may approve or revise; in YOLO mode the workflow auto-continues after displaying the warning (per ADR-067).
- `status: CRITICAL` — HALT. The skill MUST NOT advance to the next phase until the user resolves the critical finding. This rule applies in both normal and YOLO mode (CRITICAL still halts under YOLO — see YOLO Behavior below) **with the documented per-phase carve-outs**: under YOLO, finding-content CRITICALs (CRITICALs that describe the SCANNED CODEBASE) are auto-downgraded to WARNING-equivalent at **Phase 3** (scan subagents), **Phase 6** (NFR assessment), and **Phase 8b** (PRD adversarial review) per the YOLO mode contract above. Subagent error CRITICALs (scanner crashed, tool unavailable, pipeline broken) still halt unconditionally. The carve-out is justified by brownfield's gap-discovery purpose: every Phase 3/6 CRITICAL is, by construction, a real defect in the project being onboarded — halting on each one defeats the autonomous-run promise of YOLO mode (`gaia-brownfield yolo`). See AF-2026-05-31-1 / Test12 F-11 for the precedent + AF-2026-05-29-2 / Test09 F-11 for the Phase 8b precursor.

The Phase 3 per-subagent scan diagnostic table (above) is the surfacing channel for the seven scan subagents — its `Status` and `Reason` columns are the user-visible projection of each scan subagent's structured return. A subagent that crashes mid-run is treated as `CRITICAL` for the orchestrator (skill exits non-zero with a partial-result summary per AC-EC8), but the cohort's surviving scanners still appear in the diagnostic table with their own statuses. This is the canonical pattern for the six-command remediation cohort identified in **ADR-063** (add-feature, security-review, brownfield, test-gap-analysis, fill-test-gaps, problem-solving).

## YOLO Behavior

Per **ADR-067** (YOLO Mode Contract — Consistent Non-Interactive Behavior):

- Auto-continue at every template-output / review prompt EXCEPT where an explicit gate halts (CRITICAL findings, post-complete file-existence gates, conflict resolution when `test-environment.yaml` already exists with a non-`yolo` execution mode).
- The Phase 5 normal-mode review pause (E48-S4) is skipped under YOLO — the skill auto-continues to Phase 6 after writing the test-environment.yaml.
- Conflict resolution under YOLO uses the safe default `merge` for `test-environment.yaml` (Phase 5 step 5) — detected values fill only null fields and every non-null user-supplied field is preserved.
- Subagent verdicts are still displayed: `PASS` and `WARNING` auto-continue in YOLO, but `CRITICAL` still halts. CRITICAL-halt is a hard rule under YOLO — the workflow refuses to proceed past a critical finding without explicit user input.
- Open-question indicators (unchecked checkboxes, TBD markers, "Decisions Needed" sections in any artifact this skill produces) are NEVER auto-skipped under YOLO. Memory writes are NEVER auto-approved.

## Failure Semantics

- **Scanner crash mid-run (AC-EC8):** Remaining scanners continue. The failed scan writes a gap row tagged `scan failed: {reason}`. Skill exits non-zero with a partial-result summary.
- **Test-architect subagent unavailable (AC-EC5):** Log a non-blocking warning. Write stub `nfr-assessment.md` and stub `performance-test-plan-{date}.md` with `agent unavailable` banners. Post-complete gate reports the gap rather than crashing.
- **NFR output missing (AC-EC9):** Both `nfr-assessment.md` and `performance-test-plan-{date}.md` are required by the post-complete gates. Missing either one halts with the legacy error text — both required for pass.
- **Foundation script missing (AC-EC2):** `setup.sh` aborts fail-fast with an actionable error identifying the missing / non-executable script path. No partial scan output is written.
- **Large codebase (AC-EC6):** Scanners stream / chunk results, emit incremental gap rows, and produce a `scan truncated — review manually` advisory rather than exceeding the NFR-048 activation token budget.

## Frontmatter Linter Compliance

This SKILL.md passes the E28-S7 / E28-S74 frontmatter linter (`.github/scripts/lint-skill-frontmatter.sh`) with zero errors. Required fields are present: `name` matches the directory slug `gaia-brownfield`; `description` is a trigger-signature with a concrete action phrase; `allowed-tools` is validated against the canonical tool set (`Agent` is required because Phase 2, 3, 4, 6, 7, 8, and 9 delegate to subagents via the `Agent` tool); `model: inherit` is set per E28-S74 schema.

If a future edit removes the `description` field or any other required field, the frontmatter linter reports the missing field and the CI gate fails — no silent skill registration is permitted (AC-EC4 equivalent for the legacy conditional test-environment gate is covered by the conditional gate wiring above).

## Parity Notes vs. Legacy Workflow

The native skill preserves the legacy 7-step structure as 9 native phases (Steps 2.5, 2.75, 2.8, 3, 3.5, 4, 5, 5.5, 6, 7 of the legacy `instructions.xml` map to Phases 1–9 here). Data flow between phases is identical to the legacy workflow — each phase's output feeds the next via the documented input contracts. The skill does not re-implement the workflow engine; it uses native Claude Code primitives (Skills + Subagents + inline scripts) per ADR-041.

Legacy file paths are intentionally not re-referenced in this body per the E28-S105 parity check (the reference pointer lives only in the References section below). This matches the E28-S102 / E28-S103 precedent.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-brownfield/scripts/finalize.sh

## References

- ADR-021 — Deep brownfield code analysis with seven parallel scan subagents and gap consolidation (the cohort surfaced by the Phase 3 per-subagent scan diagnostic table).
- ADR-037 — Structured subagent return schema (`status`, `summary`, `artifacts`, `findings`, `next`) consumed by the Subagent Dispatch Contract section.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks (replaces the legacy workflow engine).
- ADR-042 — Scripts-over-LLM for Deterministic Operations (foundation script set invoked inline via `!scripts/*.sh`).
- ADR-045 — Review Gate via Sequential `context: fork` Subagents (fork-context dispatch pattern reused by the cohort surfaced in Phase 3).
- ADR-063 — Subagent Dispatch Contract — Mandatory Verdict Surfacing (the framework-wide rule the Subagent Dispatch Contract section codifies for this skill).
- ADR-067 — YOLO Mode Contract — Consistent Non-Interactive Behavior (the rules the YOLO Behavior section codifies for this skill).
- FR-323 — Native Skill Format Compliance (frontmatter schema per E28-S74).
- FR-325 — Foundation scripts wired inline.
- NFR-048 — Conversion token-reduction target / activation-budget ceiling.
- NFR-053 — Functional parity with the legacy workflow.
- E28-S74 — Canonical SKILL.md frontmatter schema.
- E28-S88 — `gaia-nfr` SKILL.md (pattern for the test-architect subagent integration mirrored here in Phase 6).
- E28-S9..E28-S16 — Foundation scripts implementation stories (deployed equivalents referenced in the Reconciliation Note).
- E19-S12 / S13 / S14 / S15 — Test infrastructure detectors aggregated in Phase 5.
- Reference implementations (parity pattern and Cluster 14 sibling skills):
  - `plugins/gaia/skills/gaia-nfr/SKILL.md` — test-architect subagent pattern (Phase 6 mirrors this).
  - `plugins/gaia/skills/gaia-creative-sprint/SKILL.md` — sequential multi-subagent orchestration pattern.
- Legacy parity source (for reference only; not invoked from this skill; legacy path intentionally omitted from the body to satisfy the "zero legacy references" parity check — see E28-S105 test scenario 5).
