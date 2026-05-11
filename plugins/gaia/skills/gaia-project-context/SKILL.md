---
name: gaia-project-context
description: "Generate an AI-optimised project context document by aggregating planning artifacts and source-tree metadata into a single project-context.md. Use when 'generate project context' or /gaia-project-context. GAIA-native replacement for the legacy generate-project-context XML engine workflow."
allowed-tools: [Read, Write, Bash, Grep, Glob]
model: inherit
version: "1.0.0"
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-project-context/scripts/setup.sh

## Mission

You are the GAIA project context aggregator. Your job is to produce a compact, AI-optimised `project-context.md` that distils everything an AI agent needs to work in this project: project name, tech stack, conventions, do/don't rules, and key file patterns. The output goes to `docs/planning-artifacts/project-context.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/anytime/generate-project-context/` XML engine workflow (brief Cluster 14 utility, story E28-S106). It implements ADR-041 (Native Execution Model) and ADR-042 (scripts-over-LLM) — deterministic operations (config resolution, checkpoint writes, lifecycle events) are delegated to the shared foundation scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/`.

## Critical Rules

- **Output must be optimised for AI agent consumption** — terse, structured, machine-scannable. No marketing prose, no narrative fluff.
- **Token budget (AC-EC7, NFR-048)** — keep the SKILL.md activation budget under ~15K tokens. The generated `project-context.md` artifact itself is also a budget-constrained output (target: ≤ 10K tokens) — if the project is large enough to exceed the aggregation budget, apply summarisation/truncation (see Step 2 and AC-EC5 below).
- **Foundation script integrity (AC-EC2)** — if `setup.sh` or `finalize.sh` is missing or not executable, `setup.sh` exits non-zero with a clear error identifying the missing/non-executable script. Fail-fast, no fallback.
- **Parallel invocation isolation (AC-EC6)** — this skill holds no shared mutable state. Both `/gaia-document-project` and `/gaia-project-context` can run in parallel on the same project — each invocation resolves config independently and writes its own checkpoint keyed by workflow name. No shared in-memory caches, no cross-invocation file locking.
- **Large monorepo handling (AC-EC5)** — if the Glob discovers > 10K files under `{project-path}`, apply summarisation: sample the first 500 files per pattern, emit an explicit machine-readable truncation warning as an HTML comment in the artifact using the uppercase token form `<!-- TRUNCATED: <reason>; <sampling-cap> -->` (e.g., `<!-- TRUNCATED: scan exceeded aggregation budget; sampled first 500 files per pattern -->`), and still complete successfully. The uppercase `TRUNCATED` token is mandatory so downstream consumers can detect truncation deterministically via `grep -E '<!-- TRUNCATED:' project-context.md` without case-folding. The marker is conditional — emit it ONLY when this large-monorepo summarisation path triggers; never emit unconditionally.
- **Zero engine-specific XML tags** — this file is pure prose + inline bash. All legacy engine tags (action, template-output, check, ask, invoke-workflow, step, workflow) have been replaced with native prose steps and inline script calls.

## Steps

### Step 1 — Scan Project

Read the canonical manifest and documentation files to extract high-signal metadata:

- **`package.json`** (or equivalent: `pubspec.yaml`, `pom.xml`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `Gemfile`) — extract project name, version, primary language, dependency set.
- **`README.md`** — extract the tagline / purpose paragraph only (first 500 chars).
- **Config files** — Glob root-level `*.{json,yaml,yml,toml}` in `{project-path}`. Extract keys that signal conventions (e.g., `eslint`, `prettier`, `tsconfig`, `.editorconfig`).

**Exclusion list** — ALWAYS exclude: `_gaia/`, `.claude/`, `_memory/`, `node_modules/`, `.git/`, `build/`, `dist/`, `coverage/`, `.DS_Store`, `*.lock`, `bin/`.

Cap each Glob pattern at 500 results — this protects against large-monorepo token blow-ups (AC-EC5).

### Step 2 — Distill Context

Aggregate the scan results from Step 1 with any existing planning artifacts under `docs/planning-artifacts/` (if present: `prd.md`, `architecture.md`, `epics-and-stories.md`). Read at most the top-level sections of each — do not pull full content.

Extract the following high-signal fields:

- **Project name** (from manifest).
- **Tech stack** (language + runtime + framework + test framework).
- **Naming conventions** (from existing source file patterns — e.g., `kebab-case`, `PascalCase`, `snake_case`).
- **File layout conventions** (top-level directory roles: `src/`, `lib/`, `app/`, `plugins/`, `tests/`, etc.).
- **Coding standards** (linter/formatter in use, if any).

If the project exceeds the aggregation budget (> 10K files scanned in Step 1), apply summarisation here: keep only the top-frequency directories, sample files, and write a machine-readable truncation marker into the output as an HTML comment (`<!-- TRUNCATED: <reason>; <sampling-cap> -->`, uppercase token — see Critical Rules above). Do not halt on large monorepos.

**Log inference trail.** Whenever a naming or layout convention is inferred from observed evidence (file extensions, directory frequencies, language counts), append one line per inferred convention to a stable inference trail. Each entry MUST name the convention, the file count observed, the language, and the directory scope, using the exact wording shape `inferred <convention> from <count> <language> files in <dir>` (e.g., `inferred snake_case from 47 Python files in src/`). The trail records every inference made so reviewers can audit how naming and layout conventions were derived. Persist these entries — Step 4 renders them in the generated artifact under a stable, grep-friendly anchor.

### Step 3 — Generate AI Rules

Produce an AI-agent-optimised rules block:

- **Do rules** — e.g., "Use TypeScript strict mode", "Prefer functional React components", "Write tests alongside source files".
- **Don't rules** — e.g., "Do not commit to main directly", "Do not import from deep relative paths (> 2 levels)".
- **File pattern rules** — e.g., "Tests live in `tests/` mirroring `src/` structure", "Config files go at the repo root".
- **Convention rules** — naming, imports, formatting, commit message format.

These rules should be derived from evidence in the scan — cite the source where the rule was inferred from (e.g., `package.json:eslint-config`, `.editorconfig`, existing file structure).

**Log inference trail (continued).** Each rule that is inferred (rather than read verbatim from a config file) MUST also produce an inference-trail entry per the wording shape established in Step 2 (`inferred <convention> from <count> <language> files in <dir>`). This keeps the inference and inferred trail entries colocated with the convention they justify so audits can grep a single anchor.

### Step 4 — Generate Output

Write the composed artifact to `docs/planning-artifacts/project-context.md` using the Write tool. Resolve the absolute path from the `PLANNING_ARTIFACTS` environment variable exported by `setup.sh`.

Output structure (preserve section ordering for downstream consumers):

1. **Project Overview** — name, purpose, primary language, version.
2. **Tech Stack** — one-line summary per layer (language, framework, test, build).
3. **File Structure** — top-level directory map with one-line notes each.
4. **Conventions** — naming, layout, formatting rules cited from evidence.
5. **Inference Trail** — bulleted list of inference-trail entries collected in Step 2 / Step 3 (one line per inferred convention, in the `inferred <convention> from <count> <language> files in <dir>` wording shape). This is the stable, grep-friendly anchor downstream tooling and audits use.
6. **Do / Don't Rules** — bulleted list of AI-agent rules (from Step 3).
7. **Key File Patterns** — glob patterns an AI agent should use to find source, tests, configs.
8. **Entry Points** — build, test, run commands (from manifest scripts).

Include a header comment: `<!-- generated-by: gaia-project-context; date: YYYY-MM-DD; mode: full|truncated -->`. Set `mode: truncated` if large-monorepo summarisation kicked in at Step 2.

**Conditional truncation marker.** When `mode: truncated` is set (and ONLY then), additionally emit the machine-readable HTML comment `<!-- TRUNCATED: <reason>; <sampling-cap> -->` near the top of the artifact, using the uppercase token form so `grep -E '<!-- TRUNCATED:'` matches deterministically. When `mode: full`, do NOT emit a TRUNCATED marker — the marker is conditional, not unconditional, and `mode: full` artifacts must remain marker-free so the absence is itself a signal.

Report the resolved artifact path to the user after the write completes.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-project-context/scripts/finalize.sh
