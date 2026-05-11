---
name: gaia-migrate
description: Automate the upgrade from GAIA v1 (workflow.xml engine) to v2 (Claude Code native plugin) — backup, migrate templates/memory/config, validate. Use after the v2 plugins have been installed via /plugin marketplace add.
when_to_use: When a user has an existing GAIA v1 installation (presence of _gaia/, _memory/, custom/) and wants to migrate to the v2 plugin layout. Run with `dry-run` first to see the planned operations. After `/gaia-migrate apply` completes, manually run `/gaia:gaia-help` (namespaced form) to smoke-test the post-migration install — filesystem-only validation cannot exercise skill invocation, so a live `/gaia:gaia-help` run is the only way to confirm slash-command routing, plugin discovery, and skill loading are wired up end-to-end. The `gaia:` prefix ensures the plugin's `gaia-help` skill is invoked, not any legacy `.claude/commands/gaia-help.md` stub that might still be present on older installs.
allowed-tools: [Read, Bash]
orchestration_class: light-procedural
---

## Mission

Automate the v1 → v2 migration documented in `gaia-public/docs/migration-guide-v2.md`. Per ADR-042 (scripts-over-LLM), filesystem operations delegate to `plugins/gaia/scripts/gaia-migrate.sh`. This SKILL.md drives the user-facing flow: confirm the user wants to migrate, run dry-run first, then apply, then surface the script's structured summary.

## When to use

- The user has run `/plugin marketplace add gaia-public` (and `gaia-enterprise` if licensed) and confirmed `/plugin list` shows them.
- The user's project root contains v1 markers: `_gaia/`, `_memory/`, `custom/`, and `_gaia/_config/global.yaml`.
- The user has read `gaia-public/docs/migration-guide-v2.md` (or wants the automated path).

If the user has NOT installed the v2 plugins yet, point them to §1 Prerequisites of the migration guide first — `/gaia-migrate` cannot install plugins.

## Steps

1. **Confirm intent.** Ask the user: "Run dry-run first to preview, or apply directly?" Default to dry-run.

2. **Run dry-run.** Invoke:
   ```bash
   plugins/gaia/scripts/gaia-migrate.sh dry-run --project-root .
   ```
   Surface the printed plan to the user. Highlight the backup destination, migration steps, and any HALT conditions.

3. **If user approves, run apply.** Invoke:
   ```bash
   plugins/gaia/scripts/gaia-migrate.sh apply --project-root .
   ```
   The script handles backup → migration → validation → summary. Stream the output.

4. **Surface the SUCCESS / FAILED banner.** On `SUCCESS`, confirm the migration is complete and remind the user the backup is at `.gaia-migrate-backup/{ts}/`. On `FAILED`, surface the printed restore command verbatim and instruct the user to inspect the backup before retrying.

5. **Manual follow-up items.** If the script printed any `manual follow-up:` lines, list them to the user with §-references back to the migration guide.

6. **Manual post-migration smoke-test.** Instruct the user to run `/gaia:gaia-help` (plugin-namespaced form) in the migrated project and confirm two things:
   (a) `/gaia:gaia-help` returns the context-sensitive help menu, AND
   (b) `/gaia:gaia-help` appears **exactly once** in Claude Code's slash-command palette (not twice).

   The `gaia:` prefix ensures the plugin's `gaia-help` skill is invoked, not any legacy `.claude/commands/gaia-help.md` stub that might still be present on older installs. Telling the user to run the unnamespaced form is ambiguous — it can be intercepted by a legacy stub, and the user cannot tell whether "plugin loaded correctly" or "legacy stub still working" from the output.

   Two `/gaia:gaia-help` entries mean legacy `.claude/commands/gaia-*.md` stubs were not removed by Step 4.4 of the migration script — either the user ran an older `gaia-migrate.sh` (pre-E28-S186) or has GAIA v1 installed globally at `~/.claude/commands/` which the project-local script cannot reach. For the global case, instruct the user to run `rm ~/.claude/commands/gaia-*.md` manually (the migration summary prints this reminder automatically). If `/gaia:gaia-help` does not respond at all, direct the user to §Troubleshooting of the migration guide.

   The script's filesystem-only validation cannot exercise skill invocation, so only a live `/gaia:gaia-help` run proves slash-command routing, plugin discovery, and skill loading survived the migration — and only a live palette inspection proves there is no dual registration.

## Authoritative source

The mechanical migration steps are documented in `gaia-public/docs/migration-guide-v2.md` (E28-S130). This skill automates that walkthrough; the guide remains the human-readable reference. If the script detects a state the guide doesn't cover (e.g., a corrupt v1 file), surface it as a `manual follow-up:` line and direct the user to the guide.

## Safety

- **Backup before any write.** The script's `_safe_write()` helper gates every `cp`, `mv`, `rm` behind the dry-run flag and runs the backup step BEFORE any migration step writes (AC2).
- **Dry-run is idempotent.** Running dry-run twice produces identical plans (AC5).
- **Restore command is always printed.** Both `SUCCESS` and `FAILED` summaries echo the exact `cp -a "{backup}" "{project-root}"` command for manual rollback (AC-EC8).
- **Script does NOT auto-restore on failure.** Explicit user action is required (per §safety doctrine — automatic restoration could mask real issues).
- **v1 directories are deleted after successful migration (E28-S188).** `/gaia-migrate apply` backs up `_gaia/`, `_memory/`, and `custom/` into `$BACKUP_ROOT/` and then removes them from the project root. Expect 50-100 MB of disk freed on a mature project. The final summary prints a `cp -a` rollback command that restores the v1 directories from the backup if you need to revert. The destructive step is gated by three safety rails: (a) `config/project-config.yaml` must exist with a non-empty `framework_version:` or `version:` field; (b) a sha256 manifest of the live source must match the backup snapshot (excluding `_gaia/_config/global.yaml`, which is intentionally rewritten in place by the config-split step — the pre-split copy is preserved in the backup); and (c) an interactive `yes/no` confirmation prompt (bypass with `--yes` or `--force`). In non-interactive contexts (CI, bats), you MUST pass `--yes` or the script exits 7 rather than hanging on the prompt.
- **Required resolver fields are preserved BEFORE the v1 delete step (E28-S191).** The resolver validates seven required fields — `project_root`, `project_path`, `memory_path`, `checkpoint_path`, `installed_path`, `framework_version`, `date` — that live in v1 `_gaia/_config/global.yaml`. Subtask 4.3 (`_migrate_config_split`) now derives all seven from the v1 source and appends them to `config/project-config.yaml` BEFORE subtask 4.5 runs the destructive delete. If any required field is missing or unparseable in the v1 source, the split aborts with a "required field missing from v1 config: {field}" error and the v1 directories are left intact for repair — the user never lands in a half-migrated state where the plugin cannot resolve config.
- **Idempotent re-run (E28-S188).** `/gaia-migrate dry-run` on a project that is already on v2 (no v1 dirs present, `config/project-config.yaml` present) exits 0 with "Nothing to migrate — already on v2." This is a success, not a HALT.

## References

- Migration guide (authoritative manual-steps source): `gaia-public/docs/migration-guide-v2.md` (E28-S130)
- Backing script: `plugins/gaia/scripts/gaia-migrate.sh`
- Manual integration-test plan (edge cases AC-EC2/3/5/7): `docs/test-artifacts/E28-S170-gaia-migrate-edge-cases-test-plan.md` (E28-S170) — reproducible steps, expected behavior, and environment setup for edge cases that are not bats-testable without dedicated scaffolding (tmpfs size caps, corrupt-byte fixtures, signal-interrupt timing)
- ADR-042: Scripts-over-LLM for Deterministic Operations
- ADR-048: Engine Deletion as Program-Closing Action
- FR-326: Config Split (drives subtask 4.3 partition rules)
- FR-328: Engine Deletion (program-closing motivation for the migration)
