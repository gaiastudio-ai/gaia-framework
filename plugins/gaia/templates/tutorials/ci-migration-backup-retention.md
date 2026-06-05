# CI Migration Backup Retention

> **Audience:** GAIA maintainers who ran `/gaia-config-ci --regenerate` against an older project and now have one or more backup directories under `.gaia-backup/` to manage.
>
> **Reading time:** ~5 minutes.

## Where backups live

The auto-rename migration flow writes a fresh backup directory at the project-root sibling location:

```
.gaia-backup/ci-regen-{ISO-8601-timestamp}/
```

For example: `.gaia-backup/ci-regen-20260523T180530Z/`.

The backup directory contains:

- A byte-identical copy of every `.github/workflows/*.yml` file the migration was about to mutate (rename via Y- or N-branch).
- A `.sha256-manifest` file with one `<sha256>  <relpath>` line per backed-up file. This is the canonical integrity-verification source.

The backup is **always** under `.gaia-backup/` at the project root — NEVER under `.gaia/`. The location is deliberate: `.gaia/` is for runtime framework state, while `.gaia-backup/` is recovery state owned by you.

Each invocation of the migration creates a new timestamped sibling directory. Repeated migrations never overwrite an earlier backup.

## How to verify backup integrity

Before restoring from a backup, run the verification helper:

```bash
plugins/gaia/scripts/verify-backup-integrity.sh .gaia-backup/ci-regen-20260523T180530Z
```

- **Exit 0** — every file in the backup matches its manifest entry. Safe to restore.
- **Exit 1** — drift detected (mismatch, missing file, or extra file). The helper emits the canonical HALT message + per-file detail:

```
HALT: backup integrity check failed — .gaia-backup contents tampered (per SR-84)
Backup directory: .gaia-backup/ci-regen-20260523T180530Z
  - mismatch: ci.yml (expected abc...  got def...)
```

Do **NOT** restore from a backup that fails integrity verification — investigate the drift first.

## How to restore from a verified backup

1. Verify integrity (above).
2. Copy each file from the backup back to `.github/workflows/`:

   ```bash
   for f in .gaia-backup/ci-regen-20260523T180530Z/*.yml; do
     cp "$f" ".github/workflows/$(basename "$f")"
   done
   ```

3. Verify your `.github/workflows/` matches your pre-migration intent (`git diff` is usually enough).
4. If you want to RETRY the migration with different decisions, delete the prefix-suffixed files that the migration created (`gaia-*.yml`, `gaia-*.user-jobs.yml`, `gaia-*.user-steps.yml`, or `user-*.yml`) before re-running `/gaia-config-ci --regenerate`.

## Recommended retention

Keep migration backups for at least **30-day** after a successful regen-and-CI-green cycle. The 30-day window covers:

- The typical sprint cadence (one full sprint review + retrospective + one stretch period).
- Most accidental-mutation discovery latencies (a broken workflow usually surfaces within a few CI runs, not weeks later).
- The lifetime of any short-lived feature branches that may have been built against the pre-migration workflow shape.

After 30 days, you can safely delete old backup directories:

```bash
# Delete backups older than 30 days (BSD find)
find .gaia-backup -maxdepth 1 -type d -name 'ci-regen-*' -mtime +30 -exec rm -rf {} \;
```

Add `.gaia-backup/` to your project's `.gitignore` — backups are recovery state, not version-controlled artifacts.

## You'll know it worked when

- `verify-backup-integrity.sh <backup-dir>` exits 0.
- Your restored `.github/workflows/*.yml` files have sha256 hashes matching the manifest entries.
- A subsequent `/gaia-config-ci --regenerate` produces no surprises (the migration prompt does NOT re-fire for files you've already migrated).

## Common pitfalls

- **Don't run `chmod` or `sed` on files inside a backup directory** — that mutates content and trips the integrity check.
- **Don't commit `.gaia-backup/`** — `.gitignore` it. The backups are recovery state, not source-of-truth.
- **Don't archive a backup with `tar` or `zip` and then restore from the archive** without re-verifying — archiving can introduce metadata drift (newlines, mtimes). Always re-run `verify-backup-integrity.sh` after any round-trip.
