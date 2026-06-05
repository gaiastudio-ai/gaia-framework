# Changelog

All notable changes to the `gaia-framework` marketplace (renamed from `gaia-public` on 2026-06-02) and the `gaia` plugin are recorded here. Historical entries below preserve the pre-rename `gaia-public` paths exactly as they were when shipped; the GitHub redirect from `gaiastudio-ai/gaia-public` → `gaiastudio-ai/gaia-framework` keeps clones and web traffic working.
This file tracks sprint-level resolutions and decisions — for commit-level history, see `git log`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely, and the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for the `gaia` plugin
(tracked in `plugins/gaia/.claude-plugin/plugin.json`).

## [Unreleased]

### Repo rename — `gaia-public` → `gaia-framework`

- The GitHub repo previously published at `https://github.com/gaiastudio-ai/gaia-public` is now `https://github.com/gaiastudio-ai/gaia-framework`. GitHub serves a permanent 301 redirect from the old URL so existing clones, web links, and `git fetch` calls continue to work for an extended window (~6 months by GitHub policy).
- **For end users:** if you already installed the marketplace via `/plugin marketplace add gaiastudio-ai/gaia-public`, the redirect keeps it operational. To clean up the old slug, run `/plugin marketplace remove gaiastudio-ai/gaia-public` then `/plugin marketplace add gaiastudio-ai/gaia-framework`. The plugin-cache directory at `~/.claude/plugins/cache/gaiastudio-ai-gaia-public/` is left behind by the substrate; you can `rm -rf` it once the new `~/.claude/plugins/cache/gaiastudio-ai-gaia-framework/` is populated.
- **For documentation:** the published docs site moved from `https://gaiastudio-ai.github.io/gaia-public/` to `https://gaiastudio-ai.github.io/gaia-framework/`. Pages publishes under the new repo slug; the old URL becomes a dead link (GitHub Pages does not redirect renamed projects automatically).
- **For in-tree references:** every operational reference (plugin.json `homepage`, statusline `repos/.../releases/latest` API call, statusline OSC8 release-link, cache-recovery script slug, install instructions in `README.md` + `CLAUDE.md` + `gaia-migrate` SKILL) plus every prose path-prefix in `documentation/` and `plugins/gaia/skills/**/SKILL.md` was rewritten to `gaia-framework`. 234 files / 539 line edits in a single sweep. Historical CHANGELOG entries preserve the pre-rename `gaia-public` URL verbatim — those describe what was true at ship time and the GitHub redirect keeps them clickable.

### Sub-rubric loader pipeline migration

- `plugins/gaia/scripts/rubric-loader.sh` gains a sub-rubric phase between
  the base layer and the regime layers. Sub-rubric files live under
  `<rubrics_root>/sub-rubrics/*.json`, are filtered by an optional `when:`
  predicate (equality, array intersection, AND across keys — no OR / no
  negation / no nesting), and merged in deterministic order (numeric prefix
  `^[0-9]+-` ASC before LC_ALL=C alpha for non-prefixed).
  - New `--config <path>` flag injects a project-config YAML for predicate
    evaluation; absent ⇒ empty context, so project_kind-gated sub-rubrics are
    correctly EXCLUDED for projects that do not declare `project_kind` (the
    typical brownfield case).
  - New `--debug-order` flag emits one filename per line in sub-rubric merge
    order (diagnostic only).
  - The sub-rubrics directory is OPTIONAL — when absent or empty the loader
    is a no-op for this phase, preserving byte-identical output for every
    existing project shape.
  - Mobile SKILL-side rubric path (`gaia-review-mobile/SKILL.md`, mobile-*
    base rubrics) is UNTOUCHED; the post-Phase-2 cleanup story will migrate
    mobile to the loader-side path.
  - New byte-identical contract test
    `plugins/gaia/tests/E77-S4-rubric-loader-contract.bats` (8 acceptance
    criteria, baseline + diff-canary fixtures) gates the migration.
  - New full regression suite
    `plugins/gaia/tests/E77-S4-rubric-loader-regression.bats` (12 tests
    covering every base skill + regime overlay + empty-sub-rubrics no-op +
    no-config and unconditional-include semantics) ships with this story.

### v1.132.x — Dev-story tooling quirks cleanup

- Bundle four dev-story tooling quirks into a single cleanup pass.
  - `dod-check.sh` no longer falls through to the system POSIX
    `/bin/test` builtin for the `tests` row. The script now resolves a
    project test command via deterministic precedence:
    `config/project-config.yaml test_cmd:` → `package.json scripts.test`
    (via `npm test`) → `bats tests/*.bats` discovery. When no signal
    resolves, the row is reported as `SKIPPED — no test runner detected`
    (exit 0), never `FAILED`.
  - `dod-check.sh` subtask scan is scoped to the `## Tasks / Subtasks`
    section. Unchecked items in `## Definition of Done` (e.g., "PR merged
    to staging" pre-merge) and `## Acceptance Criteria` are intentionally
    excluded from the count. Stories whose Tasks/Subtasks are all checked
    now PASS the subtask row even when the DoD section legitimately
    carries unchecked items at Step 9.
  - New shared parser library
    `skills/gaia-dev-story/scripts/frontmatter-lib.sh` with `fm_slice`
    (extract YAML frontmatter block) and `fm_get_field` (read a single
    field). `story-parse.sh`, `pr-body.sh`, and `commit-msg.sh` now
    source the library instead of carrying three duplicated awk
    implementations of the same primitive.
  - `commit-msg.sh` emits commitlint-safe subjects by prepending a
    lowercase verb derived from the story `type:` field (`feature` →
    `wire`, `bug` → `fix`, `refactor` → `refactor`, `chore` → `update`).
    Story titles that already start with a lowercase verb are passed
    through unchanged. Effect: PRs opened from a `/gaia-dev-story` run
    on a story whose title begins with an ALL-CAPS or PascalCase token
    (e.g., `SKILL.md gate wiring`, `API client retry policy`) now pass
    the `lint-pr-title` GitHub Action check without manual `gh pr edit`
    intervention.

### v1.131.x — TDD Review Gate Default

- **Deprecation — `/gaia-dev-story` Steps 1, 10, 11 narrative fallback**: the
  inline LLM narrative paths for frontmatter parsing (Step 1), commit-message
  composition / promotion-chain inference (Step 10), and PR-body construction
  (Step 11) are deprecated in v1.131.x and removed in v1.132.0. The canonical
  paths now run through `story-parse.sh`, `detect-mode.sh`, `check-deps.sh`,
  `promotion-chain-guard.sh`, `commit-msg.sh`, and `pr-body.sh`. Brownfield
  projects on a stale plugin retain a single-minor-version fallback gated on
  `command -v <script>`; upgrade to v1.132.0 will hard-remove the fallback.
- Wire the six new helper scripts (`story-parse.sh`, `detect-mode.sh`,
  `check-deps.sh`, `promotion-chain-guard.sh`, `commit-msg.sh`, `pr-body.sh`)
  into `/gaia-dev-story` SKILL.md at Steps 1, 10, and 11. Narrative fallback
  retained for one minor version (v1.131.x → v1.132.0) so brownfield projects
  don't break mid-upgrade. Regression bats at
  `tests/dev-story-script-wiring.bats` enforces the wiring contract.
- Introduce the `dev_story.tdd_review` config block consumed by
  `/gaia-dev-story`. The block ships in `project-config.schema.yaml` and
  `project-config.yaml.example` with the following defaults:
  - `threshold: medium` — risk threshold at which the post-Red TDD review
    gate prompt fires. Allowed values: `off | low | medium | high`.
  - `phases: [red]` — TDD phases at which the review fires.
  - `qa_auto_in_yolo: true` — YOLO mode auto-runs the QA review after
    the gate.
  - `qa_timeout_seconds: 600` — per-review timeout for the QA auto-run.
  - **User-visible effect:** stories with `risk: medium` or higher will
    see a one-time prompt after the TDD Red phase asking whether to run
    the review immediately. Existing low-risk and unset-risk stories see
    no behavior change.
  - **Opt-out:** set `threshold: off` in your shared `project-config.yaml`
    to disable the gate entirely.
  - The four resolved values round-trip via
    `resolve-config.sh --field dev_story.tdd_review.<key>`.

### Sprint 24 (GAIA Native Conversion Program)

#### Reverted

- Restore `allowed-tools:` as the canonical SKILL.md frontmatter field across
  all 115 plugin skills and 3 enterprise mirror skills. A prior change had
  renamed `allowed-tools:` → `tools:` based on a misreading of the Claude Code
  skills documentation at https://code.claude.com/docs/en/skills. On 2026-04-19
  the official docs were re-read and confirmed that `allowed-tools:` IS the
  canonical field name (both the YAML list form `allowed-tools: [A, B]` and the
  space/comma-separated string form `allowed-tools: A, B` are accepted). The
  "0 skills" symptom that motivated the original change is unrelated — it is a
  known limitation of `/reload-plugins` not counting plugin-shipped skills;
  Anthropic's own `claude-code-setup` plugin reproduces the same counter
  behavior while shipping `tools:` in its SKILL.md.
  - Net effect: documented canonical field name restored; no behavioral
    change because both forms are accepted by the Claude Code skill loader.
  - `plugins/gaia/skills/*/SKILL.md` (115 files): `tools: A, B, C` →
    `allowed-tools: [A, B, C]` (YAML list form).
  - `gaia-enterprise/plugins/gaia-enterprise/skills/*/SKILL.md` (3 files):
    re-reverted in lockstep in the enterprise repo.
  - `plugins/gaia/scripts/fix-skill-tools-field.sh` removed; replaced by
    `plugins/gaia/scripts/revert-skill-tools-field.sh` — idempotent
    companion script that converts `tools: A, B, C` back to
    `allowed-tools: [A, B, C]`.
  - `plugins/gaia/tests/skill-frontmatter-guard.bats` flipped: now enforces
    that every plugin SKILL.md uses `allowed-tools:` (not `tools:`) and
    that values use YAML list form.
  - `.github/scripts/lint-skill-frontmatter.sh` flipped: rejects the
    retired `tools:` top-level key, validates the `allowed-tools:` key
    (canonical field).
  - Parity bats suites (44 files), shell smoke scripts (10 files), and
    `_reference-frontmatter.md` docs (10 files) reverted to reference the
    restored `allowed-tools:` field.
  - New regression test covering round-trip behavior of the revert script.

#### Added

- `docs/INDEX.md` — single discovery entry point for GAIA artifact directories.
  - `gaia-public/docs/INDEX.md` — new top-level index describing the three
    GAIA artifact directories (`planning-artifacts/`,
    `implementation-artifacts/`, `test-artifacts/`) with role descriptions
    and typical contents for each. Clarifies that these directories live
    under each GAIA project's own `docs/` tree (not vendored into the
    marketplace repo).
  - `gaia-public/README.md` — added a Documentation section linking to
    `docs/INDEX.md`.
  - `gaia-public/tests/atdd/e28-s171-docs-index-entry-point.bats` — ATDD
    coverage: ten assertions covering file existence, per-directory link
    presence, per-directory role-description prose, README link-back,
    top-level heading, non-trivial length.
- Manual integration-test plan for `/gaia-migrate` edge cases — the four edge
  cases that are not bats-testable without significant environmental scaffolding
  (tmpfs size caps, corrupt-byte fixtures, sidecar schema drift fixtures,
  signal-interrupt timing).
  - Test plan document: `docs/test-artifacts/gaia-migrate-edge-cases-test-plan.md`
    (project-root artifact; not in this repo). Nine sections: executive
    summary, prerequisites (fixture + tooling), four scenarios (one per
    edge case) with environment setup / reproduction steps / expected
    behavior / pass-fail criteria / teardown, reporting, traceability.
  - `gaia-public/plugins/gaia/skills/gaia-migrate/SKILL.md` — added a
    cross-reference to the test plan under the References section so the
    skill points users at the plan for advanced (manual) edge-case
    verification.
  - Observed-baseline recording: the current `gaia-migrate.sh` implementation
    does not detect sidecar schema drift and does not install a SIGINT trap
    handler. Both gaps are logged as tech-debt / low-severity follow-ups for
    future stories. Backup-before-migration ordering preserves v1 state through
    the interrupt window.

### Sprint 23 (GAIA Native Conversion Program — cleanup and migration close)

#### Added

- `/gaia-migrate` skill — automate v1 → v2 upgrade.
  - `gaia-public/plugins/gaia/skills/gaia-migrate/SKILL.md` — user-facing
    flow (frontmatter `name: gaia-migrate` + description + `when_to_use`),
    confirms intent, runs dry-run first, surfaces SUCCESS/FAILED banner,
    cross-references the migration guide as the authoritative manual-steps
    source.
  - `gaia-public/plugins/gaia/scripts/gaia-migrate.sh` — backing script
    (scripts-over-LLM pattern). Modes: `apply`, `dry-run`. Central
    `_safe_write()` helper gates every cp/mv/rm/mkdir behind the dry-run
    flag — single safety mechanism for dry-run idempotency and accidental-write
    protection. Pipeline: detect → backup → 3 migration subtasks (templates,
    sidecars, config-split) → validate → SUCCESS/FAILED summary with restore
    command.
  - Backup is always created BEFORE any migration write. Timestamped at
    `{project-root}/.gaia-migrate-backup/{YYYY-MM-DD-HHMMSS}/` with
    `backup-manifest.yaml` containing sha256 per file.
  - Config split implements the local/shared partition: 17 local keys stay in
    `_gaia/_config/global.yaml`, 6 shared keys move to
    `{project-root}/config/project-config.yaml`.
  - Sidecar migration is verify-only — v1 and v2 layouts match under the
    current schema set.
  - Validation checks plugin discoverability, YAML parse, and structural keys.
    `/gaia-help` smoke-test deferred to manual follow-up (can't invoke from
    script context).
  - 24 bats tests cover SKILL.md frontmatter (4), backup-before-write (4),
    3 migration steps + partition (5), validation banners (2), dry-run +
    idempotency (3), edge cases (4), arg parsing (2). v1 fixture tree at
    `plugins/gaia/test/scripts/fixtures/v1-install/` (9 files).
  - `dead-reference-scan.sh` allowlist extended for the new skill, script,
    bats file, and fixture tree (all intentionally reference v1 retired paths
    for detection / migration purposes).
  - `gaia-public/docs/migration-guide-v2.md` extended with §10 "Automated
    migration via /gaia-migrate" cross-referencing the skill and listing
    equivalence between manual sections and automated steps.

- v1 → v2 migration guide. Expanded the stub at
  `gaia-public/docs/migration-guide-v2.md` to a full 9-section guide covering:
  Prerequisites (with `/plugin marketplace list` gate), Backup (with checksums),
  Install (with two-track procedure for `project_path: "."` vs subdirectory),
  Migrate Templates (byte-identical preservation via `diff -r`), Migrate Memory
  (sidecar checksum verification), Update CLAUDE.md (replaces ~227-line v1 with
  the slim 30-line v2), Verify (preserves the "Legacy engine cleanup" subsection),
  Rollback (STOP-first with idempotent restore commands), Reviewer Orientation
  appendix (5-minute conceptual overview + links for non-program reviewers).
  Global step IDs (S1.1, S2.3, etc.) for support-conversation reference.
  Pointer at `docs/migration/migration-guide-v2.md` (project-root convention).
  Backed by 19 bats tests covering section presence, two-track procedure,
  reviewer-orientation references, and the preserved cleanup subsection.

- CLAUDE.md slim rewrite. Shipped the slim `gaia-public/CLAUDE.md` (30 lines)
  containing only environment configuration, how-to-start pointers, and hard
  rules. The project-root `CLAUDE.md` is synced byte-identical from the
  `gaia-public/` copy.
  - Dropped content (moved to SKILL.md): workflow-engine narrative,
    step-execution rules, config-resolution chain, checkpoint discipline,
    context budget, quality-gate procedures, sprint-status write-safety, sprint
    state machine table, review-gate vocabulary, naming conventions,
    developer-agent-system narrative, memory-hygiene narrative, npm-publishing
    procedure, version-bumping procedure.
  - Kept content: title/version heading (`# GAIA Framework v1.127.2-rc.1`),
    environment section, hard rules (7 bullets covering secrets, feature
    branches, no-AI-attribution, version-bump discipline, dev-story PR gate,
    directory identity, commands retirement, sprint-status write safety).
  - New bats test (13 tests) asserts line count ∈ [30, 50], version-heading
    regex, section presence (Environment / How to Start / Hard Rules), and
    content-exclusion grep for every removed section header.

- Workflow-artifact retirement — verify + scanner coverage. The product-source
  `gaia-public/plugins/gaia/` tree was already clean at story-start (0
  `workflow.yaml` / `instructions.xml` / `checklist.md` files). Runtime
  `_gaia/*/workflows/` (423 files) is out of scope and cleaned up by
  `gaia-cleanup-legacy-engine.sh`.

  The active work concentrated on reference cleanup:

  - `plugins/gaia/scripts/dead-reference-scan.sh` — PATTERN extended with
    3 new tightened-word-boundary regexes (`(^|[^-a-z])workflow\.yaml\b`,
    `(^|[^-a-z])instructions\.xml\b`, `(^|[^-a-z])checklist\.md\b`). The
    leading character class prevents false-positives inside compound filenames
    like `deployment-checklist.md` and `my-workflow.yaml`.
  - A new `is_shell_variable_context()` helper in the same scanner filters
    shell-variable forms (`$workflow.yaml`, `${name}.yaml`,
    `$workflow.yaml.lock`) so bash scripts like `checkpoint.sh` that use
    variable interpolation producing runtime filenames are not falsely flagged.
  - `is_allowlisted()` extended with an enumerated 41-entry block covering
    every SKILL.md and skill-companion script that cites the retired filenames
    as parity references. These citations are historical documentation, not
    active loads.
  - 9 new bats tests covering the extended PATTERN + negative-filter: 5
    positive (backtick-prose, path-form, parenthesized, colon-prefixed,
    bare-word), 3 negative (shell-variable forms correctly filtered), 1
    allowlist (docs/ reference).

  No new CI workflow; `adr-048-guard.yml` already runs `dead-reference-scan.sh`
  unconditionally, so the PATTERN extension is picked up automatically on every
  future PR.

- Slash-command retirement — verify + regression guard. The converted plugin's
  `plugins/gaia/commands/` directory was already empty at story-start
  (skill-based invocation via `plugins/gaia/skills/{name}/SKILL.md` is the
  sole user-facing surface). This PR ships the regression prevention:
  - `plugins/gaia/scripts/commands-guard.sh` — narrow-scope directory guard;
    exits 1 if any `gaia-*.md` file reappears under `plugins/gaia/commands/`,
    exits 0 when the directory is absent or empty. Shellcheck-clean.
  - `.github/workflows/adr-048-guard.yml` — extended with an **unconditional**
    commands-guard step (permanent, not closing-only) that runs on every PR to
    staging or main.
  - `plugins/gaia/scripts/dead-reference-scan.sh` — PATTERN extended with two
    file-path regexes (`.claude/commands/gaia-*.md` and
    `plugins/gaia/commands/gaia-*.md`) so the canonical active-code scanner
    also catches stale file-path references. The invocation form `/gaia-foo`
    used in skill prose is deliberately excluded by anchoring on the `.md`
    extension — slash-command mentions in documentation and skill bodies
    continue to resolve correctly.
  - 9 bats tests covering absent directory, empty directory, non-gaia file,
    single regression, mixed tree, multiple regressions, missing arg,
    non-existent project-root.
  - 4 new dead-reference-scan bats tests for the extended PATTERN (file-path
    detection, invocation-form negative, docs allowlist).

- Program-closing tooling for the legacy engine deletion. Ships three new
  foundation scripts under `plugins/gaia/scripts/`:
  - `verify-cluster-gates.sh` — pre-start verifier that reads all cluster-gate
    story files and confirms each is `status: done` with all 6 Review Gate rows
    `PASSED`. Exit 0 when the gate is open, 1 on any block, 2 on parse error.
    Used by both the migration CLI and the new CI guard.
  - `dead-reference-scan.sh` — grep-based active-code scanner that fails the
    build when any `plugins/gaia/**` skill, script, agent, or CI workflow
    references retired legacy-engine paths (workflow.xml, core/protocols/,
    .resolved/, workflow-manifest.csv, task-manifest.csv, skill-manifest.csv,
    lifecycle-sequence.yaml). Allowlist preserves documentation, CHANGELOG,
    migration guide, parity-guard bats, negated mandates, and the tooling
    itself.
  - `gaia-cleanup-legacy-engine.sh` — idempotent migration CLI that removes
    the retired engine, protocols, four `_config/` manifests, five module
    configs, and every nested `.resolved/` from the local `_gaia/` runtime.
    Pre-flight guards cover clean-working-tree, in-flight legacy checkpoints,
    and program-gate status. Flags `--dry-run`, `--force-dirty`,
    `--project-root`. **NOT invoked by this PR — shipped for end-user cutover
    after installing the native plugin.**
- New CI guard at `.github/workflows/adr-048-guard.yml`. Rejects PRs to
  `staging` or `main` that introduce active-code references to retired engine
  paths unless the `program-closing` label is set AND all program-gate stories are
  `done`+`PASSED`. Flag alone is insufficient — the guard re-verifies the
  gate checklist before allowing the merge.
- Bats-core test suite (5 files, 38 tests, 50 fixture files) covering every
  acceptance criterion and edge case: happy path, idempotency, dirty tree,
  locked path, in-flight checkpoint, nested `.resolved/` at depth 5, dead-ref
  scan active vs allowlisted, `next-step.sh` fallback, `gaia-help` fallback
  contract.
- Migration guide stub at `docs/migration-guide-v2.md` with only the "Legacy
  engine cleanup (manual cutover)" section populated under §Verify. A follow-on
  story fills the remaining sections around this anchor.

#### Changed

- `plugins/gaia/scripts/next-step.sh` — added graceful-missing-file fallback:
  when `lifecycle-sequence.yaml` or `workflow-manifest.csv` are absent (expected
  state post-cutover), prints "legacy manifests not available under native plugin
  — nothing to suggest" and exits 0 instead of the legacy exit-2 hard-fail.
  Strict-mode preserved via `GAIA_NEXT_STEP_STRICT=1` for backward compatibility.
- `plugins/gaia/skills/gaia-validate-framework/SKILL.md` — rewrote Step 5
  (Manifest Integrity) and Step 6 (Config Resolution) to only verify survivors
  (`agent-manifest.csv`, `global.yaml`). The three retired manifests and the
  `.resolved/` pre-compile chain are explicitly noted as removed.
- `plugins/gaia/skills/gaia-code-review-standards/SKILL.md` — rewrote the
  Enforcement Mechanism section to reference the native replacement
  `plugins/gaia/scripts/review-gate.sh` instead of the retired
  `_gaia/core/protocols/review-gate-check.xml`.
- `plugins/gaia/skills/gaia-bridge-{toggle,enable,disable}/SKILL.md` — removed
  all references to the retired `/gaia-build-configs` command and the
  `.resolved/` pre-compile step. Updated descriptions (visible in Claude's
  skill-discovery UI) and bodies to reflect that the flag flip takes effect
  immediately under the native plugin.

#### Removed

- Nothing was deleted from the repository by this PR. The deletion script
  targets are the local `_gaia/` runtime instance, which is not git-tracked.
  Actual deletion happens at end-user cutover after installing the native
  plugin — see the "Legacy engine cleanup" section in
  `docs/migration-guide-v2.md`.

---

### Sprint 19 (GAIA Native Conversion Program)

#### Added

- End-to-end parity bug-fix buffer (zero-work close). Added
  `docs/test-artifacts/cluster-19/bug-fix-triage.md`,
  `docs/test-artifacts/cluster-19/bug-fix-revalidation.md`, and
  `docs/test-artifacts/cluster-19/bug-fix-rollup.md` documenting the buffer
  outcome: the triage pass scanned every defect surface and logged **0
  bug-type defects**. The two non-bug findings (documentation drift in
  `architecture.md` and a forward-looking `/gaia-resume` skill gap) are
  explicitly deferred to backlog with rationale. The full parity harness reads
  20/20 PASS across every owned row. `v-parity-baseline` tag is unchanged.
  **Bug-fix buffer: 0 defects processed, 0 fixed, 2 non-bug findings deferred;
  parity verdict: PASS.**

- Token-reduction coverage. Added the measurement driver at
  `plugins/gaia/test/scripts/token-reduction/` with a pinned surrogate
  tokenizer (`tokenize.mjs`, `tokenizer.version` `sha256:3c0c1f82…`), the 5
  immutable fixture driver inputs under
  `plugins/gaia/test/fixtures/parity-baseline/token-budget/{dev-story,create-prd,
  code-review,sprint-planning,brownfield-onboarding}/driver-input.txt`, and a
  13-case structural contract. Raw captures (baseline prompt, native prompt,
  baseline count, native count, determinism re-run count) are published under
  `docs/test-artifacts/cluster-19/token-budget/{workflow}/` for all 5
  workflows. Methodology and results documents cover tokenizer, scope,
  determinism, baseline-vs-native harness, and workflow selection. First run:
  dev-story 50.0%, create-prd 40.0%, code-review 44.0%, sprint-planning 45.0%,
  brownfield-onboarding 50.0% — every per-workflow row PASS on the 40% hard
  gate; aggregate 45.8% is below the 55% stretch and recorded as a
  non-blocking warning; determinism re-run is byte-identical across all 5
  workflows.

- Quality-gate-enforcement parity test. Added
  `tests/cluster-19-e2e/quality-gate-enforcement.bats` (12 bats cases covering
  all 5 enforced testing-integration gates: `create-epics-stories.test-plan`,
  `implementation-readiness.traceability-matrix` + `.ci-setup` across 3
  variants, `dev-story.atdd` for high-risk stories plus a low-risk negative
  control, `deployment-checklist` across 4 variants, and
  `brownfield-onboarding.nfr-assessment` + `.performance-test-plan`
  post-complete). Added 11 synthesized fixture files under
  `plugins/gaia/test/fixtures/cluster-19/quality-gate-enforcement/` (6
  sub-variant trees, all registered with sha256 in `fixture-manifest.yaml`) and
  the parity oracle at
  `plugins/gaia/test/fixtures/parity-baseline/traces/quality-gates.jsonl`.
  First clean run recorded in
  `docs/test-artifacts/cluster-19/quality-gate-enforcement-results.md` with all
  12 per-variant verdicts PASS and a timestamp- + error_message-projected parity
  diff = 0.

- Sprint-state-machine parity test. Added
  `tests/cluster-19-e2e/sprint-state-machine.bats` (9 bats cases covering all 7
  canonical states, every documented valid transition including the blocked
  branch and the `review → in-progress` rollback, and 5 canonical invalid
  transitions that must be rejected). Added the canonical exercise fixture under
  `plugins/gaia/test/fixtures/cluster-19/sprint-state-machine/seed/` (story +
  seed `sprint-status.yaml` + seed `story-index.yaml`, all registered with
  sha256 in `fixture-manifest.yaml`) and the parity oracle at
  `plugins/gaia/test/fixtures/parity-baseline/traces/sprint-state-machine.jsonl`.
  First clean run recorded in
  `docs/test-artifacts/cluster-19/sprint-state-machine-results.md` with all 14
  per-transition verdicts PASS and timestamp-projected parity diff = 0.

- Full-lifecycle test runner. Added
  `plugins/gaia/test/runners/full-lifecycle.sh` — a script-driven runner that
  drives the 10 canonical lifecycle stages (brainstorm → product-brief → PRD →
  UX → architecture → epics-stories → sprint-plan → dev-story → all-reviews →
  deploy-checklist) against the integration fixture at
  `plugins/gaia/test/fixtures/cluster-19/`. The runner produces per-stage
  artifacts, parity diff metadata under `runs/{run-id}/parity/`, and a dated
  evidence artifact with a schema of run metadata + stages table with
  `stage | skill | exit | artifact_path | sha256 | parity_verdict` + summary +
  regressions. Non-tolerated parity deltas append to a defects file and
  transition the story back to `in-progress`. Memory isolation is enforced via
  `GAIA_MEMORY_ROOT`; run-dir collision is guarded; a secret-leak guard runs
  pre-write against the results artifact. ATDD exercises all acceptance criteria
  including the `--seed-regression ordering` path that drives the
  defect-logging branch. First clean full-lifecycle run recorded 2026-04-17.

- Authored the integrated end-to-end test plan at
  `docs/test-artifacts/cluster-19-e2e-test-plan.md`. Defines the greenfield
  TypeScript/pnpm test project specification, the 7-category test matrix (full
  lifecycle, review gate, sprint state machine, checkpoint resume, quality
  gates, enterprise plugin, token measurement with 40–55% reduction target),
  binary pass/fail criteria with evidence artifacts and escalation rules per
  category, the full fixture inventory with sha256 immutability guarantees, and
  the review/approval workflow for gating. Scaffolded the fixture directory at
  `gaia-public/plugins/gaia/test/fixtures/cluster-19/` with a
  `fixture-manifest.yaml` stub listing every required fixture.

- Config-split test gate. Added `scripts/test-config-split.sh`, a
  shellcheck-clean, idempotent wrapper that drives
  `plugins/gaia/scripts/resolve-config.sh` across four project-structure
  fixtures (`root-project`, `subdir-project`, `no-shared-config`, live repo)
  plus an overlap-precedence fixture and a missing-key behavior check, then
  writes an authoritative test report to
  `docs/migration/config-split-test-report.md`. 37 / 37 assertions pass on the
  current resolver. Non-zero exit on any fixture failure so CI can gate.

- Migrated every SKILL.md that previously read `global.yaml` or
  `config/project-config.yaml` directly to use the canonical
  `!scripts/resolve-config.sh {key}` invocation. Migrated skills:
  `gaia-sprint-plan` (sizing_map), `gaia-rollback-plan` (full config),
  `gaia-deploy-checklist` (ci_cd.promotion_chain), `gaia-val-validate-plan`
  (framework_version), `gaia-validation-patterns` (project_path doc reference).
  Config-editor skills (`gaia-bridge-toggle`, `gaia-bridge-enable`,
  `gaia-bridge-disable`, `gaia-ci-setup`, `gaia-ci-edit`) and the meta-validator
  (`gaia-validate-framework`) are allowlisted because they act ON the file
  rather than READ from it. Added two helper scripts:
  `plugins/gaia/scripts/audit-skill-config-reads.sh` (rerunnable audit) and
  `plugins/gaia/scripts/verify-no-direct-config-reads.sh` (CI invariant guard).
  Audit artifact checked in at `docs/migration/config-split-skill-audit.md`;
  skill migration section added to `docs/migration/config-split.md`. Zero
  behavioral drift — the resolver returns the same values the direct reads
  produced because the split preserves key names 1:1.

- Added `plugins/gaia/scripts/migrate-config-split.sh`, a one-shot POSIX
  bash + `yq` helper that splits an existing `_gaia/_config/global.yaml` into
  the two-file layout (`config/project-config.yaml` for team-shared fields + a
  rewritten machine-local `global.yaml`). Ships with backup-before-write
  (`.bak.YYYYMMDD-HHMMSS`), refusal on pre-existing shared file unless
  `--force`, `--dry-run` plan preview, and round-trip equivalence verification
  via `resolve-config.sh`. 14 bats tests across 6 fixtures (mixed / local-only
  / shared-only inputs, missing-yq guard, overwrite refusal, round-trip). See
  `docs/migration/config-split.md` for operator instructions and the rollback
  procedure.

#### Changed

- `resolve-config.sh` now implements the two-file config split. The resolver
  reads the team-shared `config/project-config.yaml` first as a base layer,
  then overlays the machine-local `global.yaml` (via `--local <path>`), and
  finally applies `GAIA_*` environment overrides — final precedence is
  `env > local > shared`. Missing local or shared files degrade gracefully: the
  pre-split single-file invocation pattern is preserved via the `--config
  <path>` alias (equivalent to `--shared`) with an empty local layer.
  Required-field validation and the `project_path` traversal guard now run on
  the post-merge map, so security checks apply identically regardless of which
  layer contributed the value. Flattened-key merge (e.g.,
  `val_integration.template_output_review`) uses last-writer-wins at the
  dotted-key level. Smoke harness extended with eight new test cases and two
  edge-case tests covering disjoint-key merges, overlapping-key overrides,
  local-only and shared-only fallbacks, env-wins precedence, malformed-YAML
  file naming, and shared-sourced traversal rejection.
  `scripts/tests/smoke-resolve-config.sh` now runs 24 assertions, all green.

#### Documentation

- Flipped orchestrator `project_path` from `Gaia-framework` to `gaia-public`.
  The flip was verified against the running `_gaia/_config/global.yaml`, stale
  resolved-config entries were regenerated, and a sample workflow resolution
  confirmed `{project-path}` now maps to `{project-root}/gaia-public`. Sprint
  19 is now fully anchored on the `gaia-public` repo as the canonical GAIA
  product source.

- Fix architecture version drift. Realigned the downstream story copy to
  reference `Architecture v1.20.0`, matching the authoritative on-disk
  frontmatter in `docs/planning-artifacts/architecture.md`. Resolution
  direction: revert the story copy — a version bump was rejected because no
  real change justified it. This change is framework-internal (no public
  marketplace impact) but is logged here for sprint traceability.

- Documented empirical Claude Code plugin component discovery rules in README —
  eight scanned subdirectories, strict lowercase casing, frontmatter
  requirements, kebab-case conventions, and seven observed edge cases.

- Clarified in README that private marketplace authentication uses existing
  `gh auth` credentials — no Claude Code-specific auth layer is needed or
  planned.

- Documented `/reload-plugins` requirement and marketplace cache recovery steps
  in README.

#### Features

- Added `plugins/gaia/scripts/plugin-cache-recovery.sh` — guarded alternative
  to raw `rm -rf` of polluted marketplace cache entries. Validates slug,
  classifies cache state (absent / healthy / polluted), and refuses to remove a
  healthy clone without `--force`.

#### Foundation scripts (plugins/gaia/scripts/)

- `resolve-config.sh` — deterministic config resolution replacing LLM-driven
  inheritance chains.
- `checkpoint.sh` — atomic checkpoint writer with sha256 manifest.
- `lifecycle-event.sh` — lifecycle event emitter.
- `memory-loader.sh` — tier-aware agent sidecar loader.
- `review-gate.sh` — canonical gate status reader/writer.
- `validate-gate.sh` — composite gate validator.
- `template-header.sh`, `next-step.sh`, `init-project.sh` — scaffold helpers.
- `project-config.yaml` schema published under `plugins/gaia/config/`.
- Subagent frontmatter schema enforced in `plugins/gaia/agents/`.

---

*Entries older than sprint 19 are not yet backfilled.*
