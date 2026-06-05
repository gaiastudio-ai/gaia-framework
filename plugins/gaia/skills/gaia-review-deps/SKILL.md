---
name: gaia-review-deps
description: Audit project dependencies for known CVEs, outdated versions, and license conflicts. Scans package.json, requirements.txt, pom.xml, pubspec.yaml, go.mod, Gemfile, Cargo.toml and produces a risk-ranked findings report with CVE IDs, outdated packages, and license concerns. Use when "audit dependencies" or /gaia-review-deps.
argument-hint: "[target — project root or specific manifest file]"
allowed-tools: [Read, Write, Edit, Bash, Grep]
orchestration_class: reviewer
---

## Mission

You are performing a **dependency audit** on the target project — scanning manifest files for known CVEs, deprecated or abandoned packages, and license conflicts. You produce a risk-ranked markdown report prioritised by exploitability and impact, with CVE IDs, outdated package list, license conflict summary, and remediation recommendations.

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/review-dependency-audit.xml` task (38 lines). The legacy task-runner engine is retired and this skill runs natively under the Claude Code primitives model. Deterministic report-header generation is delegated to the shared foundation script `template-header.sh` rather than re-prosed per skill.

## Critical Rules

- **Check for known CVEs in dependencies.** Every dependency is cross-referenced against published CVE advisories; each finding cites the CVE ID and CVSS severity.
- **Identify outdated or unmaintained packages.** Packages that are several major versions behind latest, or have had no release / activity for a long window, are flagged.
- **Flag license conflicts.** License types are identified for every dependency; copyleft / viral licenses (GPL, AGPL) and incompatible combinations are flagged.

## Inputs

- `$ARGUMENTS`: optional target (project root, a specific manifest path, or a directory). If omitted, assume the current working directory as the project root.

## Steps

### Step 1 — Identify Dependency Files

Look for any of the following manifests under the target:

- `package.json` (npm / Node.js)
- `requirements.txt`, `pyproject.toml`, `Pipfile` (Python)
- `pom.xml`, `build.gradle`, `build.gradle.kts` (Java / Kotlin)
- `pubspec.yaml` (Dart / Flutter)
- `go.mod` (Go)
- `Gemfile` (Ruby)
- `Cargo.toml` (Rust)
- `composer.json` (PHP)

Read all found dependency files. If none are found (AC-EC6), exit with `No review target resolved` and do NOT write an empty report.

### Step 2 — Vulnerability Check

- For each dependency and version, identify known CVEs and security advisories. Where a CLI auditor is available locally (`npm audit`, `pip-audit`, `mvn dependency-check`, `bundle audit`, `cargo audit`), invoke it and capture findings.
- Check for deprecated or abandoned packages (e.g., `request` on npm, Python 2-only packages, packages marked deprecated in their registry).
- For each finding, record the CVE ID (e.g., `CVE-2023-12345`), CVSS severity, affected version range, fixed version, and a short description.

### Step 3 — Version Analysis

- Flag dependencies that are significantly outdated (one or more major versions behind the latest release).
- Identify dependencies with no recent releases or maintenance signal — a stale repository, an archived package, or a maintainer-abandoned advisory.
- Produce an outdated list ordered by dependency tier — **prioritise runtime dependencies first, then dev dependencies, then transitive dependencies**. Within each tier, sort by severity (critical → high → medium → low) and then by package name. The tiered ordering surfaces the highest-blast-radius upgrades at the top so triage proceeds from runtime downward without manual re-sorting.
- Detect the tier of every dependency from its manifest. Use these canonical inputs:
  - **runtime** — top-level `dependencies` in `package.json`; `[project.dependencies]` in `pyproject.toml`; `<dependency>` entries without `<scope>test</scope>` in `pom.xml`.
  - **dev** — `devDependencies` in `package.json`; `[project.optional-dependencies.dev]` (or equivalent dev extras) in `pyproject.toml`; test-scoped Maven dependencies (`<scope>test</scope>`) in `pom.xml`.
  - **transitive** — anything resolved by the package manager but not declared at the top level of the manifest.
  For other manifests (`Cargo.toml`, `go.mod`, `pubspec.yaml`, `Gemfile`, `composer.json`, etc.) defer to the package manager's native categorisation of runtime versus development dependencies.
- If a tier has no outdated entries, **omit** the corresponding sub-section from the report — do not print empty `Runtime`, `Dev`, or `Transitive` headers. Empty-tier collapse prevents the misleading-placement risk where transitive results appear under a stale `Runtime` heading when no runtime upgrades are pending.

### Step 4 — License Check

- Identify the license for every dependency.
- Flag potential conflicts: GPL / AGPL in a proprietary product, incompatible combinations (e.g., GPLv2-only alongside Apache-2.0 code with certain usage patterns), missing licenses, ambiguous licenses.
- Note the transitive dependency license tree where it matters — a permissive direct dep can pull a copyleft transitive.

### Step 5 — Report

Invoke the shared foundation script to emit the deterministic artifact header:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/template-header.sh --template dependency-audit --workflow gaia-review-deps
```

If `template-header.sh` is missing or non-executable (AC-EC7), degrade gracefully to an inline prose header (`# Dependency Audit — {date}`), log a warning, and still write a valid report.

Write the report to the following path (preserved verbatim from the legacy task — AC4):

```
{test_artifacts}/dependency-audit-{date}.md
```

If the file already exists for the same day (AC-EC3), write to a suffix-incremented filename (`dependency-audit-{date}-2.md`, ...).

The report includes:

- **Risk-ranked vulnerability findings** with CVE IDs, affected versions, fixed versions, CVSS severity (critical / high / medium / low), and remediation guidance.
- **Outdated package list** sorted by severity and criticality. The list is rendered tier-by-tier per Step 3 (runtime → dev → transitive); empty tiers are omitted.
- **License conflict summary** — flagged conflicts, rationale, and suggested action.
- **Remediation recommendations** — concrete upgrade paths, replacements for abandoned packages.

## References

- Source: `_gaia/core/tasks/review-dependency-audit.xml` (legacy 38-line task body).
