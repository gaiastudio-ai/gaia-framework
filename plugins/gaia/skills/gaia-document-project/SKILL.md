---
name: gaia-document-project
description: "Document an existing project for AI context — scans source files, detects the tech stack, maps directory structure, and produces a comprehensive project-documentation.md artifact. Use when 'document this project' or /gaia-document-project. GAIA-native replacement for the legacy document-project XML engine workflow."
allowed-tools: [Read, Write, Bash, Grep, Glob]
model: inherit
version: "1.0.0"
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-document-project/scripts/setup.sh

## Mission

You are the GAIA project documentation agent. Your job is to scan an existing project's filesystem, detect its technology stack, map its directory structure, and produce a comprehensive `project-documentation.md` artifact under `docs/planning-artifacts/` optimised for onboarding humans and AI agents.

This skill is the native Claude Code conversion of the legacy `_gaia/lifecycle/workflows/anytime/document-project/` XML engine workflow (brief Cluster 14 utility, story E28-S106). It implements ADR-041 (Native Execution Model) and ADR-042 (scripts-over-LLM) — deterministic operations (config resolution, checkpoint writes, lifecycle events) are delegated to the shared foundation scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/`.

## Critical Rules

- **Scan the actual project files** — never guess, never infer, never rely on prior knowledge. Use Glob and Read to verify every claim against the filesystem before it goes into the artifact.
- **Token budget (AC-EC7, NFR-048)** — keep the SKILL.md activation budget under ~15K tokens (well under the 40K framework cap). Scan directories lazily; never pre-load large file trees into memory.
- **Foundation script integrity (AC-EC2)** — if `setup.sh` or `finalize.sh` is missing or not executable, `setup.sh` exits non-zero with a clear error identifying the missing/non-executable script. The skill body must not paper over a fail-fast setup error.
- **Parallel invocation isolation (AC-EC6)** — this skill holds no shared mutable state. Both `/gaia-document-project` and `/gaia-project-context` can run in parallel on the same project — each invocation resolves config independently via `resolve-config.sh` and writes its own checkpoint keyed by workflow name. No cross-invocation file locking is required.
- **Empty / no-sources project (AC-EC4)** — if the scan discovers no source files (empty/new project filesystem), still produce `project-documentation.md` with a "No source files detected" note under the Source Inventory section. Do not crash, do not halt.
- **Zero engine-specific XML tags** — this file is pure prose + inline bash. All legacy engine tags (action, template-output, check, ask, invoke-workflow, step, workflow) have been replaced with native prose steps and inline script calls.

## Steps

### Step 1 — Scan Project

Use Glob to discover the project's source files and directory structure. Use the exclusion list below to keep the scan bounded.

**Exclusion list** — ALWAYS exclude from scans: `_gaia/`, `.claude/`, `_memory/`, `node_modules/`, `.git/`, `build/`, `dist/`, `coverage/`, `.DS_Store`, `*.lock`, `bin/`.

Scans to perform (cap each Glob pattern at 500 results to protect the token budget):

1. **Source files** — Glob `**/*.{ts,tsx,js,jsx,py,java,kt,go,rs,dart,swift,rb,php,sh,md,yaml,yml,json,xml,toml}` under `{project-path}`. Extract file inventory and language distribution.
2. **Config files** — Glob root-level `*.{json,yaml,yml,toml,xml}` in `{project-path}`. Extract config keys, settings.
3. **Existing documentation** — Glob `README*`, `CHANGELOG*`, `CONTRIBUTING*`, `docs/**/*.md` under `{project-path}`.

If every scan returns zero files, this is an empty project — continue to Step 2 anyway and emit the "No source files detected" note at Step 4.

The 500-file Glob cap is parity-protected per **FR-395** — never relax or remove this cap without surfacing the parity regression in a follow-up story. Any language-distribution counts derived from the cap-bounded scan are reported as observed within the cap, not extrapolated.

### Step 2 — Technology Detection

Detect the tech stack by reading the canonical manifest files only (never infer from file extensions alone):

- `package.json` → Node.js / TypeScript / JavaScript; extract `dependencies`, `devDependencies`, `engines`, `scripts`.
- `pubspec.yaml` → Flutter / Dart; extract `dependencies`, `flutter` block, `environment.sdk`.
- `pom.xml` or `build.gradle` / `build.gradle.kts` → Java / Kotlin; extract `dependencies`, build tool.
- `requirements.txt`, `pyproject.toml`, `Pipfile`, `setup.py` → Python; extract dependencies, Python version.
- `Cargo.toml` → Rust; extract `dependencies`, `edition`.
- `go.mod` → Go; extract module path, Go version, dependencies.
- `Gemfile` → Ruby; extract dependencies.

Detect test frameworks (jest, vitest, bats, pytest, junit, gotest, flutter test, etc.) from dependency lists and config files. Detect build tools (vite, webpack, maven, gradle, make, cargo, go build, etc.) from the same sources.

### Step 3 — Structure Mapping

Produce a directory structure overview focused on the **top-level layout** (depth ≤ 2) plus any obviously significant subtrees (`src/`, `lib/`, `app/`, `plugins/`, `scripts/`, `tests/`, `docs/`).

#### Entry Points — Manifest-Field Lookup Contract (FR-379)

Read entry points from the actual manifest fields — NEVER from file-extension inference. Per **ADR-042** (Scripts-over-LLM for Deterministic Operations) manifest parsing is a structured key lookup, not an LLM judgment call: `package.json` is JSON, `pyproject.toml` is TOML, `pubspec.yaml` is YAML, `go.mod` is line-keyed text. Read the file, navigate to the key, render the value, cite the manifest path.

Per-ecosystem lookup table:

- **Node.js** — read `package.json`. Prefer `scripts.start`, fall back to `bin`, fall back to `main`. Cite `package.json:scripts.start` (or whichever field was found).
- **Go** — read `go.mod`. Extract the `module` path. Locate the `main` package by Globbing `**/main.go` (excluding the standard exclusion list above). Cite `go.mod:module` plus the discovered `main.go` path.
- **Python** — read `pyproject.toml`. Prefer `[project.scripts]`, fall back to `[tool.poetry.scripts]`. If absent, look for `__main__.py` or a `main()` function in a top-level module. Cite `pyproject.toml:[project.scripts]` (or the fallback path).
- **Rust** — read `Cargo.toml`. Read the `[[bin]]` table or fall back to `src/main.rs`. Cite `Cargo.toml:[[bin]]`.
- **Flutter / Dart** — read `pubspec.yaml` for the package name. Entry point is `lib/main.dart` by convention. Cite `pubspec.yaml:name` plus `lib/main.dart`.
- **Java / Kotlin** — read `pom.xml` (`<mainClass>` in shade/jar plugin) or `build.gradle` / `build.gradle.kts` (`application { mainClass = ... }`). Cite the manifest path plus the key.

**Manifest field missing** — when the manifest file is present but the relevant entry-point field is absent (for example, a `package.json` with no `scripts.start`, no `bin`, and no `main`), render the Entry Points line explicitly as:

> `Entry point: not declared (no scripts.start / main field in package.json)`

Do NOT silently fall back to file-extension inference in this case — the absence is the answer.

**File-extension inference is a last resort** — only when no manifest file exists at all (no `package.json`, no `go.mod`, no `pyproject.toml`, etc.). In that case, the inferred entry point is labelled as such (e.g., `Entry point (inferred from file name): src/index.ts`).

- Identify **key modules** from the top 2 directory levels.
- Note any **architecturally significant** directories (e.g., `hooks/`, `plugins/`, `skills/`, `agents/`).

### Step 4 — Generate Documentation

Compose the `project-documentation.md` artifact under `docs/planning-artifacts/` with the following sections (preserve this section ordering for downstream consumers):

1. **Overview** — project name (from the manifest), short purpose statement, detected primary language(s).
2. **Technology Stack** — language(s), runtime versions, frameworks, build tools, test frameworks. Cite the manifest file each claim came from.
3. **Directory Structure** — tree-style overview (depth ≤ 2) with one-line notes on each key directory.
4. **Conventions** — naming, file layout, testing conventions inferred from existing source + docs (cite evidence).
5. **Key Files** — manifest files, entry points, significant config files (e.g., `tsconfig.json`, `vite.config.*`, `Dockerfile`, CI config).
6. **Entry Points** — how to run / build / test the project, with exact commands extracted from manifest fields per the Step 3 lookup contract (`package.json:scripts.start`, `go.mod:module`, `pyproject.toml:[project.scripts]`, etc.). Cite the manifest path and key for every claim. When the manifest field is missing, render the explicit "not declared" line described in Step 3.
7. **Source Inventory** — counts by language / directory plus a **language-distribution** list (FR-379).
   - After the Step 1 source-file Glob runs, accumulate a per-extension count keyed to a friendly language name. Suggested mapping: `.ts` + `.tsx` → TypeScript; `.js` + `.jsx` → JavaScript; `.py` → Python; `.go` → Go; `.java` → Java; `.kt` → Kotlin; `.dart` → Dart; `.rs` → Rust; `.swift` → Swift; `.rb` → Ruby; `.php` → PHP; `.sh` → Shell; `.md` → Markdown; `.yaml` + `.yml` → YAML; `.json` → JSON; `.toml` → TOML; `.xml` → XML.
   - Render the counts under this section as a simple list, sorted descending by count, one line per language. Example:
     - `- TypeScript: 312`
     - `- Markdown: 87`
     - `- Shell: 24`
   - Languages with zero files are omitted from the list.
   - **Cap-aware sample note** — if any Glob in Step 1 hit the 500-file cap (FR-395), append a single trailing note under the list: `(Glob cap reached at 500 files; counts are a sample.)`. Counts are reported as observed within the cap, never extrapolated.
   - **Empty project** — if the scan found zero source files, render exactly: "No source files detected — this appears to be an empty or new project filesystem." and SKIP the language-distribution list entirely (do NOT emit an empty list).

### Step 5 — Generate Output

Write the composed artifact using the Write tool to `docs/planning-artifacts/project-documentation.md` (resolve the absolute path from `resolve-config.sh` output — specifically the `PLANNING_ARTIFACTS` env variable exported by `setup.sh`).

Do NOT overwrite silently if the file already exists — include a header comment: `<!-- generated-by: gaia-document-project; date: YYYY-MM-DD; mode: full-scan -->`.

Report the resolved artifact path to the user after the write completes.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-document-project/scripts/finalize.sh

## References

- **FR-379** — Manifest-field entry points and language-distribution counts in the Source Inventory section. Restores V1's `document-project` workflow contract: read `package.json:scripts.start`, `go.mod:module`, `pyproject.toml:[project.scripts]`, etc., directly from the manifest rather than inferring entry points from file names.
- **FR-395** — 500-file Glob cap parity protection. The cap declared in Step 1 is locked behavior — language-distribution counts are derived from the cap-bounded scan and labelled with a sample note when the cap fires.
- **ADR-041** — Native Execution Model. This skill is a Claude Code native skill; all behavior is defined in this SKILL.md prose.
- **ADR-042** — Scripts-over-LLM for Deterministic Operations. Manifest parsing is structured key lookup (JSON / TOML / YAML / line-keyed text), not an LLM judgment call. The "manifest field missing" path is a deterministic present/absent check, not an inference.
