# gaia-public

GAIA Framework — Generative Agile Intelligence Architecture. Public Claude Code marketplace distributing the `gaia` plugin: 25 specialized agents, 62 workflows, and 8 shared skills.

## `.gaia/` Consolidation (ADR-111, Sprint-49)

Consumer-project runtime state lives entirely under `.gaia/` — five canonical subdirectories resolved through `scripts/lib/gaia-paths.sh`:

- `.gaia/config/` — project-config + machine-local overlay (was `config/`)
- `.gaia/artifacts/` — planning / implementation / test / creative / research artifacts (was `docs/*-artifacts/`)
- `.gaia/state/` — mutable runtime state including `sprint-status.yaml`, `action-items.yaml`, `.review-gate-ledger`
- `.gaia/memory/` — agent sidecars, checkpoints, lifecycle events (was `_memory/`)
- `.gaia/custom/` — user-extension seam (was top-level `custom/`)

A single `.gitignore` entry (`.gaia/`) covers the entire GAIA runtime tree. The 4-phase migration ships as `plugins/gaia/scripts/migrate/migrate-phase-{1..4}.sh`, guarded by per-file hash-manifest sentinels (`.gaia/memory/.migration-manifest`) and tarball+sha256 rollback. See ADR-111 in the architecture doc and `docs/planning-artifacts/assessment-AF-2026-05-19-1.md` for the full design.

## Pre-Release Notice (v1.127.x)

GAIA v2 (plugin-based) is currently in **early-adopter preview**. The v1 → v2 migration path (`/gaia-migrate apply`) is functional on a reference fixture but is still stabilizing on real v1 projects.

**If you are evaluating GAIA:** start a fresh project with the v2 plugin — do not migrate a production v1 project yet.

**If you must migrate a v1 project today:**

- Back up your `_gaia/`, `_memory/`, and `custom/` directories before running `/gaia-migrate apply`. The migrator creates its own backup under `.gaia-migrate-backup/`, but an independent copy is cheap insurance.
- After migration, run `plugins/gaia/scripts/audit-v2-migration.sh` (from the plugin install) against your project root and confirm zero failing skills before trusting any generated output.
- Some skills still reference legacy v1 paths (`_gaia/_config/*`) in their body prose and will fall back to a degraded-but-functional response on a freshly migrated project. Tracked under E28-S196 and the post-migration audit follow-ups.

We will remove this notice once the v2 migration regression gate is green and the remaining SKILL.md path references are closed out (tracked in E28-S195, E28-S196, and the B5 triage story).

## Install

```
/plugin marketplace add gaiastudio-ai/gaia-public
/plugin install gaia@gaiastudio-ai-gaia-public
/reload-plugins
```

The `/reload-plugins` step is **required** after `/plugin install` — without it, the plugin's agents, skills, and commands do not become available in the current Claude Code session. This is silent: no error is shown if you skip it, the components just never register. If you installed the plugin and your `/gaia` commands are missing, run `/reload-plugins` first before reporting a bug.

### Recovery from a polluted marketplace cache

If the initial `/plugin marketplace add` fails (for example, a transient network error or an earlier broken clone cached under `~/.claude/plugins/marketplaces/`), the failure can leave a polluted cache entry that causes every subsequent retry to fail with the same error. Clear the cache and retry:

```
rm -rf ~/.claude/plugins/marketplaces/gaiastudio-ai-gaia-public/
/plugin marketplace add gaiastudio-ai/gaia-public
```

The same pattern applies to the enterprise marketplace — replace `gaia-public` with `gaia-enterprise` in both the directory path and the `marketplace add` command.

This cache-pollution behaviour is tracked upstream at [anthropics/claude-code#48736](https://github.com/anthropics/claude-code/issues/48736) — we have requested that `/plugin marketplace add` either re-fetch on a failed parse or clean up the cache entry on clone failure so this recovery recipe becomes unnecessary. Until that lands, you can also run the automated helper `plugins/gaia/scripts/plugin-cache-recovery.sh --slug gaiastudio-ai-gaia-public` which encodes the same fix non-interactively.

### Private marketplace authentication

The enterprise marketplace lives in a private GitHub repo (`gaiastudio-ai/gaia-enterprise`). It works out of the box with your existing `gh auth` credentials — there is **no Claude Code-specific authentication layer** for private marketplaces and none is planned. If `gh auth status` shows you are logged in as a user with read access to `gaiastudio-ai/gaia-enterprise`, then `/plugin marketplace add gaiastudio-ai/gaia-enterprise` will succeed; if not, run `gh auth login` first. Distribution access is governed by GitHub repo ACLs. The only license enforcement that runs server-side is the CI `license-check` job in the enterprise repo's `plugin-ci.yml`, which gates publication on a valid `LICENSE` file, a populated `license` field in `plugin.json`, and SPDX headers on shipped markdown.

If you prefer a guarded, scriptable alternative to the raw `rm -rf`, the plugin ships `plugins/gaia/scripts/plugin-cache-recovery.sh`. It validates the slug, classifies the cache entry as `absent` / `healthy` / `polluted`, and refuses to remove a healthy clone unless `--force` is passed:

```
plugins/gaia/scripts/plugin-cache-recovery.sh --detect --slug gaiastudio-ai-gaia-public
plugins/gaia/scripts/plugin-cache-recovery.sh --slug gaiastudio-ai-gaia-public --dry-run
plugins/gaia/scripts/plugin-cache-recovery.sh --slug gaiastudio-ai-gaia-public
```

`--detect` exits `2` on a polluted entry so CI and workflow steps can branch on it without parsing text; `--dry-run` prints the intended target without touching the filesystem. See the script header for the full exit-code table and slug-validation rules.

## Migrate from GAIA v1

If your project already has a GAIA v1 install (the legacy `Gaia-framework` npm installer — presence of `_gaia/`, `_memory/`, `custom/` directories in the project root, plus `.claude/commands/gaia-*.md` stubs), the `gaia-migrate` skill automates the upgrade to the v2 plugin layout.

**Prerequisite:** the `gaia` plugin must be installed and loaded first (see the Install section above).

### Preview the migration (read-only)

```
/gaia:gaia-migrate --dry-run
```

The dry-run prints every planned operation — template conversions, sidecar rewrites, config file splits, legacy command stubs to delete, v1 directories to back up and remove, total backup size — without touching the filesystem. Safe to run as many times as you want.

### Apply the migration

```
/gaia:gaia-migrate apply
```

`apply` executes the plan. Each destructive step backs up before deleting, so a full restore to v1 state is always possible from the backup tree. In order:

1. Migrate templates from `_gaia/` into plugin skills.
2. Rewrite sidecar files under `_memory/`.
3. Split `_gaia/_config/global.yaml` into `config/project-config.yaml` (v2 shape).
4. Back up and delete legacy `.claude/commands/gaia-*.md` stubs (only files matching `gaia-*.md` — your own command files are untouched).
5. Back up and delete the v1 directories `_gaia/`, `_memory/`, `custom/`. This step requires `config/project-config.yaml` to be present and valid (safety gate) and prompts for an explicit `yes` confirmation. Pass `--yes` or `--force` to skip the prompt in CI / non-interactive contexts.
6. Print a rollback command so you can restore v1 state from the backup if anything went wrong.

### Smoke-test after apply

```
/gaia:gaia-help
```

The `gaia:` prefix is important — it resolves to the plugin's `gaia-help` skill unambiguously. After a successful migration there should be exactly one `/gaia:gaia-help` registration; the legacy `.claude/commands/gaia-help.md` stub has been removed by step 4 above.

If `/gaia:gaia-help` prints context-sensitive GAIA help, the migration succeeded. If it's unknown, re-run `/reload-plugins` and confirm the install (see "Install" above).

### Rollback

The apply command prints the exact rollback command at the end, of the form:

```
cp -a $BACKUP_ROOT/_gaia $BACKUP_ROOT/_memory $BACKUP_ROOT/custom .
cp -a $BACKUP_ROOT/.claude/commands/ .claude/
```

The backup tree is in the project root (timestamped directory like `.gaia-migrate-backup-<timestamp>/`). Delete the backup tree manually once you're satisfied with the v2 install.

### Idempotence

Re-running `/gaia:gaia-migrate apply` on a project that is already on v2 (no v1 markers, `config/project-config.yaml` present) is a no-op — it prints "Nothing to migrate — already on v2." and exits 0.

## Plugin component discovery rules

Claude Code auto-discovers plugin components at install time from conventional subdirectories under `plugins/gaia/`. The rules below are empirical (captured against Claude Code CLI `2.1.109` on 2026-04-15) and apply to any plugin authored in this marketplace, not just `gaia`. The full long-form writeup with source evidence lives in `docs/planning-artifacts/gaia-native-conversion-prereqs.md` §2.1.

**Scanned subdirectories (defaults, relative to the plugin root):**

| Subdir | What it registers | Notes |
|--------|-------------------|-------|
| `.claude-plugin/plugin.json` | Plugin manifest | Required. Plugin is ignored entirely if missing. Path is fixed. |
| `commands/*.md` | Slash commands | Flat scan only — nested dirs are **not** auto-recursed. Override with `"commands": [...]` in `plugin.json`. |
| `agents/*.md` | Subagents | Flat scan. Files whose basename starts with `_` (e.g. `_SCHEMA.md`, `_base-dev.md`) are treated as private payload and **not** registered as callable agents. |
| `skills/<slug>/SKILL.md` | Skills | One directory per skill. The entry file is **`SKILL.md`** (uppercase). Sibling `references/`, `examples/`, `scripts/` are payload. |
| `hooks/hooks.json` | Hook registrations | Single JSON file at a fixed path. Co-located scripts are payload — reach them via `${CLAUDE_PLUGIN_ROOT}/hooks/<file>`. Override with `"hooks": "./config/hooks.json"` or inline object. |
| `.mcp.json` | MCP servers | Single JSON file at plugin root, or inline `"mcpServers": { ... }`. |
| `scripts/`, `config/`, `test/` | — | **Not discovered.** Payload only. Reach them via `${CLAUDE_PLUGIN_ROOT}/<path>` from inside a command, hook, or skill body. |

**Case sensitivity:** subdirectory names are lowercase and strict (`commands/`, `agents/`, `skills/`, `hooks/`). `SKILL.md` is uppercase. macOS case-insensitive filesystems will mask casing bugs that surface only in Linux CI — treat casing as strict.

**Required frontmatter per component:**

- **Command** (`commands/<name>.md`): YAML frontmatter with `description` (required). Optional: `argument-hint`, `allowed-tools`.
- **Subagent** (`agents/<name>.md`): YAML frontmatter with `name` and `description` (both required). The `name` field **must** match the filename basename — a mismatch produces an unreachable agent.
- **Skill** (`skills/<slug>/SKILL.md`): YAML frontmatter with `name` and `description` (both required). The `name` field **must** match the parent directory name. The `description` is the trigger signature Claude Code matches against user intent — a weak description means the skill never fires.
- **Hook** (`hooks/hooks.json`): top-level `hooks` object keyed by event name (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, ...); each entry needs `type` and `command`. Optional: `matcher` (regex on tool name), `timeout`.

**Filename conventions:** kebab-case `.md` files for commands, agents, and skill directories. The plugin manifest `name` field must match `^[a-z][a-z0-9]*(-[a-z0-9]+)*$`. File extensions other than `.md` (for components) and `.json` (for hooks and MCP) are not scanned.

**Edge cases worth knowing:**

1. **Empty subdirectories install successfully.** The placeholder bootstrap pattern in E28-S4 / E28-S5 works because `/plugin install` never fails on an empty `skills/` or `hooks/` directory — the Plugin Details UI's `Will install: · Components will be discovered at installation` line is literal, not a preview.
2. **Nested command dirs are not auto-recursed.** `commands/ci/build.md` is invisible unless you list `"commands": ["./commands", "./commands/ci"]` in `plugin.json`.
3. **Malformed YAML frontmatter is silently skipped.** A subagent with an unquoted colon in its `description` will not appear in `/agents` and no error is shown during `/plugin install`. Debug by running `claude --debug` and grepping for the plugin load line, or by reducing the frontmatter to a minimal valid shape and adding fields back one at a time.
4. **Symlinks work on macOS/Linux but are a portability hazard.** `git archive` and the marketplace clone step do not always preserve symlink targets cleanly. This plugin deliberately avoids symlinks.
5. **Post-install `/reload-plugins` is mandatory** before newly installed components become callable in the current session. See the "Install" section above.

## CI regression gate: `audit-v2-migration`

Every pull request targeting `main` or `staging` runs the `audit-v2-migration` job in [.github/workflows/plugin-ci.yml](./.github/workflows/plugin-ci.yml). The job exercises every plugin skill's `setup.sh` and `finalize.sh` scripts through [scripts/audit-v2-migration.sh](./scripts/audit-v2-migration.sh) in `--fixture-mode enriched`, then gates the build on zero B1–B5 regressions:

- **Exit 0** — every skill lands in `OK` or `NO-SCRIPTS`; CI passes.
- **Exit 1** — one or more skills regressed (B1 path contract, B2 checkpoint target, B3 SKILL.md literal paths, B4 global.yaml overlay, B5 skill-contract). This is a **plugin regression** and the PR must be fixed before merge.
- **Exit 2** — the harness itself erred (misconfig, fixture prep failure). Diagnose the harness, not the plugin.

The machine-readable summary line `audit-v2-migration: result=<PASS|FAIL> total=<N> ok=<N> no_scripts=<N> failed=<N>` is written to stderr at end-of-run so you can grep for the outcome without parsing the CSV. The per-skill CSV is uploaded as the `audit-v2-migration-csv` workflow artifact on every run — download it from the Actions UI for failure diagnostics.

Contributors: your PR will be audited automatically. If the job fails, open the run page, download the `audit-v2-migration-csv` artifact, and inspect the bucket column to identify which regression class was hit.

## Updating

GAIA updates are delivered automatically. When Claude Code starts a new session, its background auto-update mechanism checks the marketplace for a newer `plugin.json` version. If one exists, Claude Code pulls the update silently. No user action is required in the normal case.

**Force refresh (if auto-update seems stuck):**

```
/plugin marketplace update gaiastudio-ai-gaia-public
```

Then restart Claude Code. After restart, `/plugin` should report the new version.

**Private-repo users:** set `GITHUB_TOKEN` in your shell environment before launching Claude Code. The marketplace clone step requires read access to the repository. If `gh auth status` shows you are authenticated with read access, updates work automatically.

## GAIA Review System v2 — Skills & Review Gate

The GAIA Review System v2 (PRD §4.38, ADR-077..ADR-082) splits verdict-producing
skills into two families and assembles them into a single composite Review Gate
per story. The canonical scope-edges document is [BOUNDARIES.md](./BOUNDARIES.md);
this section is the surface-level command-listing index.

### Review Gate (up to seven gates per story — ADR-082)

`/gaia-review-all` is the composite-verdict aggregator. It runs the pre-merge
gates declared by the project's `project-config.yaml` and emits a single
composite verdict (`APPROVE` / `REQUEST_CHANGES` / `BLOCKED`) per ADR-082.

**Five always-on gates:**

| # | Skill | Owner agent |
|---|---|---|
| 1 | `/gaia-review-code` | stack-specific reviewer (resolved by `agent-overlay.sh`) |
| 2 | `/gaia-review-qa` | Vera |
| 3 | `/gaia-review-security` | Zara |
| 4 | `/gaia-review-test` | Sable |
| 5 | `/gaia-review-perf` | Juno |

**Two conditional gates (up to seven gates total):**

| # | Skill | Trigger | Owner agent |
|---|---|---|---|
| 6 | `/gaia-review-a11y` | `compliance.ui_present: true` in `project-config.yaml` | Christy |
| 7 | `/gaia-review-mobile` | any mobile platform declared in `platforms[]` | Talia |

Skipped conditional gates contribute neutrally to the composite verdict per
ADR-082 — the seven-row Review Gate table renders `PASSED (skipped)` with a
`skip_reason` for any conditional gate that did not trigger. Earlier
documentation that referenced "the six review skills" matches the always-on +
single-conditional-mobile subset; the post-RSV2 count is **up to seven gates**
(five always plus two conditional, per ADR-082).

### Action skills (write-capable, not part of `/gaia-review-all`)

Action skills mutate the source tree (write code, run tests, deploy). They
are NEVER counted as review-skill rows in the Review Gate table.

| Skill | Purpose | Owner agent |
|---|---|---|
| `/gaia-test-automate` | Test-automation expansion — scaffolds and extends automated coverage for a story (sub-commands `--status`, `--add-scenario`, `--scaffold` per FR-RSV2-40) | Sable |
| `/gaia-test-run` | Manual any-environment test runner (FR-RSV2-39) | Sable |
| `/gaia-test-e2e` | Deployment-phase end-to-end smoke (Playwright/Cypress) | Sable |
| `/gaia-test-perf` | Deployment-phase performance smoke (k6/Lighthouse) | Sable |
| `/gaia-test-dast` | Deployment-phase DAST (OWASP ZAP) | Sable |
| `/gaia-test-a11y` | Deployment-phase a11y smoke (axe-core/pa11y) — shares rubrics with the planning-phase variant per FR-RSV2-25 | Sable |
| `/gaia-test-mobile-e2e` | Mobile e2e (Detox/Maestro/Appium/XCUITest/Espresso) | Talia |
| `/gaia-test-device-matrix` | Mobile device-matrix dispatcher (Firebase Test Lab/BrowserStack/Sauce Labs adapters) | Talia |
| `/gaia-deploy` | Deployment orchestrator (Pattern A — claude-driven, sequencing pre-deploy verdict → deploy → post-deploy smoke gates) | Soren |

`/gaia-test-automate` is an **action skill** — it writes test files and
maintains automation coverage. It is not a review skill and never appears as a
Review Gate row, regardless of how older internal docs may have classified it.

### New configuration and discovery commands (FR-RSV2-23)

| Command | Purpose |
|---|---|
| `/gaia-init` | Greenfield conversational setup — bootstraps `project-config.yaml` |
| `/gaia-config-env` | Edit `environments:` block |
| `/gaia-config-test` | Edit `test_execution:` block |
| `/gaia-config-tool` | Edit `tools:` block |
| `/gaia-config-compliance` | Edit `compliance.regimes` and `compliance.ui_present` |
| `/gaia-config-stack` | Edit `stacks:` block |
| `/gaia-config-rubric` | Edit `rubrics:` overrides |
| `/gaia-config-platform` | Edit `platforms:` block (mobile platform declaration) |
| `/gaia-config-device-target` | Edit `device_targets:` block |
| `/gaia-config-validate` | Validate the merged-rubric result against `rubric.schema.json` |
| `/gaia-config-show` | Render the resolved config (post-merge, post-availability-probe) |
| `/gaia-config-ci` | Generate or regenerate the CI workflow from `project-config.yaml` (replaces `/gaia-ci-setup`) |
| `/gaia-list-tools` | Enumerate built-in adapters by category |
| `/gaia-tool-info {tool}` | Full adapter metadata |
| `/gaia-validate-rubric {path}` | Validate a single rubric file against the schema |
| `/gaia-validate-design-a11y` | Planning-phase a11y validation (design-time, runs at end of UX phase) |
| `/gaia-test-strategy` | Test-plan design + framework scaffolding (collapses `/gaia-test-design` and `/gaia-test-framework` per FR-RSV2-24) |

### Deprecated command aliases → replacements

The following pre-RSV2 command names are deprecated. Each old name continues to
register a redirect to its replacement for one minor version; new code and new
documentation MUST use the canonical name on the right.

| Deprecated alias | Replacement | Rationale |
|---|---|---|
| `/gaia-ci-setup` | `/gaia-config-ci` | Honour the `gaia-{verb}-{noun}` naming convention; renamed per FR-RSV2-23 |
| `/gaia-test-design` | `/gaia-test-strategy` | Collapsed with `/gaia-test-framework` per FR-RSV2-24 |
| `/gaia-test-framework` | `/gaia-test-strategy` | Collapsed with `/gaia-test-design` per FR-RSV2-24 |
| `/gaia-code-review` | `/gaia-review-code` | Verb-noun rename per FR-RSV2-23 |
| `/gaia-qa-tests` | `/gaia-review-qa` | Verb-noun rename per FR-RSV2-23 |
| `/gaia-test-review` | `/gaia-review-test` | Verb-noun rename per FR-RSV2-23 |
| `/gaia-security-review` | `/gaia-review-security` | Verb-noun rename per FR-RSV2-23 |
| `/gaia-performance-review` | `/gaia-review-perf` | Verb-noun rename per FR-RSV2-23 |
| `/gaia-a11y-testing` | `/gaia-test-a11y` | Verb-noun rename per FR-RSV2-23 |
| `/gaia-performance-review` (anytime) | `/gaia-perf-deepdive` | Anytime variant disambiguated per FR-RSV2-23 |

For the canonical scope-edges between review skills and action skills, gate
phases, rubric layers, adapter origins, and verdict vocabularies, see
[BOUNDARIES.md](./BOUNDARIES.md).

## Documentation

For a discovery entry point into the GAIA artifact directories
(`planning-artifacts/`, `implementation-artifacts/`, `test-artifacts/`) and
the role of each, see [docs/INDEX.md](./docs/INDEX.md).

## Plugin cache refresh after merge

The Claude Code substrate caches plugin SKILL.md frontmatter and scripts
under `~/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/<version>/`
at session start. After merging a SKILL.md, `scripts/*.sh`, `agents/*.md`,
or `hooks/*.json` change on `staging` or `main`, the running session
still executes the pre-merge cached copy. Re-invoking the changed skill
in the same session runs the OLD code until the cache is refreshed.

This is a dogfooding-loop-specific friction. Marketplace consumers who
install AFTER the merge get the new behavior on first invocation —
they never see the gap.

**To refresh the cache after a merge:**

```bash
# Replace <version> with the value currently under the cache path:
rm -rf ~/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/<version>

# Re-invoke any GAIA slash command — Claude Code repopulates the cache
# from the published plugin source on next use.
```

**File types that REQUIRE the refresh** (cached at session start):

- `plugins/gaia/skills/*/SKILL.md` — skill frontmatter, hooks, allowed-tools.
- `plugins/gaia/skills/*/scripts/*.sh` — deterministic helper scripts.
- `plugins/gaia/agents/*.md` — agent personas.
- `plugins/gaia/hooks/*.json` — substrate-level hooks.

**File types that DO NOT need the refresh** (loaded fresh per invocation):

- `plugins/gaia/tests/*.bats` — re-loaded each `bats` invocation.
- `docs/**/*.md` — not part of the plugin cache.
- `CLAUDE.md` — loaded fresh at session start.

**Workflow advisory.** `/gaia-dev-story` Step 14b emits a single advisory
line to stderr after every merge that touches the file types above. The
advisory is non-blocking — it just reminds the operator to run the
refresh command before re-invoking the changed skill in the same
session.

## License

AGPL-3.0 — see [LICENSE](./LICENSE).
