---
name: gaia-doctor
description: Preflight readiness scan — checks deterministic-tools availability per detected stack, reports the achievable scan tier (Tier 0 LLM-only / Tier 1 pure-pip / Tier 2 heavy/native or containerized), and emits an actionable install plan. Use when "check tool readiness", "what tools do I need", "doctor", or /gaia-doctor.
argument-hint: "[--install] [--json] [--stack <name>]"
allowed-tools: [Read, Grep, Glob, Bash]
orchestration_class: light-procedural
---

## Orchestration Mode

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

This skill runs under Claude Code main-turn inline orchestration per ADR-093. Steps below are performed by the LLM orchestrator dispatching deterministic helper scripts under `plugins/gaia/skills/gaia-doctor/scripts/` — there is no forked Skill-tool execution. The CRUD-menu / interactive prompts in this SKILL.md are LLM-driven interaction patterns under main-turn orchestration; the deterministic helpers are the actual probe + install primitives.

Skill class: `light-procedural`. The skill is read-only by default — only `--install` mutates host state (installs deterministic-tool binaries), and only after per-tool confirmation.

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-doctor/scripts/setup.sh

## Mission

`/gaia-doctor` scans the project for declared stacks (from `.gaia/config/project-config.yaml`), and for each stack consults the bundled readiness registry (`knowledge/tool-readiness.json`) to report which deterministic tools are installed versus missing. Output is a per-stack readiness table plus a scan-tier verdict (Tier 0 LLM-only / Tier 1 pure-pip / Tier 2 heavy/native or containerized) plus a copy-pasteable install plan.

The skill is read-only by default. The optional `--install` flag dispatches per-tool install commands interactively (prompts before invoking each). Designed to address Test10 §7 Component 1 (Preflight doctor) + Component 3 (Honest tiering) and Test01 §E1 (highest-leverage capability gap).

## Critical Rules

- **Read-only by default.** `--install` is opt-in and prompts per-tool before invoking the install command.
- If `.gaia/config/project-config.yaml` is absent, fall back to `detect-signals.sh` in signal-only mode (print which detector signals fire) — do NOT HALT.
- The readiness registry is a bundled data file (`knowledge/tool-readiness.json`) — single source of truth. Do NOT re-implement tool-detection inline in prose.
- Output format is stable (Test10 §7 acceptance criteria). Two present-states per tool: `✓ present` | `✗ missing`. Two non-tool states: `– not-applicable` (no matching stack) | `⚠ environment warning` (e.g., bash 3.2).
- Scan-tier verdict computed from registry + present state. Tier 0 is always achievable; Tier 1 requires every tool tagged `tier: 1`; Tier 2 requires every tool tagged `tier: 2`.
- Never write to project files. Never modify `.gaia/config/project-config.yaml`. The skill probes the host environment, not the project tree.

## Arguments

- `--install` — interactive install dispatcher; prompts before each missing tool, runs `install.macos` or `install.linux` from the registry per host OS.
- `--json` — emit machine-readable JSON (for CI integration / `consolidated-gaps.md` frontmatter stamping per Component 3).
- `--stack <name>` — limit probe to a single named stack rather than auto-detect from `project-config.yaml`.

## Steps

### Step 1 — Detect stacks

- If `.gaia/config/project-config.yaml` exists and `--stack` is not supplied: read the `stacks[].language` list via `yq`.
- If `--stack <name>` is supplied: use that single value, bypass config read.
- If neither: run `${CLAUDE_PLUGIN_ROOT}/scripts/detect-signals.sh --project-root <root> --format json` and extract `.stacks[]` in signal-only mode (no merge, no write).

### Step 2 — Load readiness registry

Read `${CLAUDE_PLUGIN_ROOT}/skills/gaia-doctor/knowledge/tool-readiness.json`. Filter entries whose `applies_to_stacks[]` intersects the detected stack set, treating the literal `"any"` as a universal match.

### Step 3 — Probe each applicable tool

For each filtered registry entry: dispatch `check-tools.sh` which runs the entry's `probe_cmd` (typically `command -v <bin>`) followed by `version_cmd` when present. Record `present | missing | warning` plus the resolved version. Internal scan does not mutate state.

### Step 4 — Render the readiness table

Emit the Test10 §7 example format (one block per stack), e.g.:

```
GAIA deterministic tools — readiness for stack: python
  ✓ jq, yq, python3            (core, present)
  ✗ grype          CVE scan of dependencies      →  brew install grype
  ✗ cdxgen         SBOM generation               →  npm i -g @cyclonedx/cdxgen
  ✗ vulture        Python dead-code              →  pip install vulture
  – spotbugs       JVM dead-code                 (not needed: no JVM stack)
  ⚠ bash 3.2 detected — orchestrator needs 4.0+  →  brew install bash

Result: 1/3 applicable tools available. Achievable scan tier: TIER 0 (LLM-only)
```

Final summary line: `Result: <N>/<M> applicable tools available. CVE + SBOM + dead-code will fall back to LLM heuristics. Run gaia-doctor --install to fix, or proceed.`

Final verdict line: `Achievable scan tier: TIER <0|1|2> (<reason>)`.

### Step 5 — Install (opt-in only)

If `--install` was supplied, for each MISSING applicable tool:

- Prompt `Install <tool> via <command>? [Y/n]`.
- On `Y`: detect host OS (`uname -s`) → run `install.macos` or `install.linux` from the registry. Skip on `n`.
- On completion, re-run the probe pass to confirm.

If `--install` was NOT supplied: emit the install plan as copy-pasteable shell (one `# tool` comment + the command line per missing tool, grouped by package manager).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-doctor/scripts/finalize.sh

## Notes

- The readiness registry under `knowledge/tool-readiness.json` is the single source of truth — when a new adapter ships, append its tool entry there rather than editing this SKILL.md.
- Tier definitions: **Tier 0** LLM-only (always achievable); **Tier 1** pure-pip / npm / static-binary tools (cheap to install on any host); **Tier 2** heavy native or containerized toolchains (grype/syft/spotbugs/mobsf — typically Homebrew or Docker).
- This skill is the inverse companion to `/gaia-brownfield` Phase-3 — surface the tooling story before the scan, so silent degradation (Test10 F-09/F-10/F-06) becomes visible.
- Exits 0 even when tools are missing — this is a read-only diagnostic, not a gate.
