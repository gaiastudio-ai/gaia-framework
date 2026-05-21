# Retired Scripts

This directory holds scripts that have completed their useful life and have
been moved out of the active `scripts/` tree. They are preserved here (rather
than deleted outright) so git history is one click away and any unexpected
re-discovery of the work the script did has a documented landing spot.

A script lands here when:

1. The one-shot task it automated is complete and the result is on disk.
2. No active runtime path calls it.
3. Leaving it in `scripts/` would cause the E97-S5 CI regression guard
   (`path-migration-guard.bats`) to flag it as un-migrated noise.

If you find yourself reaching for one of these, first ask whether the
underlying need still applies — most one-shot tools are no longer relevant
because the migration they performed is itself complete.

## Retired entries

### `migrate-stories-to-canonical-layout.sh`

- **Retired:** 2026-05-21
- **Story:** E97-S2
- **Origin:** E79-S6 (`docs/`-flat → `epic-*/stories/` canonical migration)
- **Completion verified:** `find` over `.gaia/artifacts/implementation-artifacts/`
  on 2026-05-21 returned zero flat-layout story candidates. The migration
  reached steady state during sprint-48 (E79 epic close-out).
- **Original purpose:** one-shot mover that walked the flat layout, derived
  the target nested path from epic + story key in the frontmatter, then
  `git mv`'d each story file under
  `docs/implementation-artifacts/epic-<key>/stories/<story-key>-<slug>.md`.
  The script also reconciled `story-index.yaml` references.
- **If you need this again:** you almost certainly don't — the migration is
  complete. If a corner case surfaces (e.g., a freshly imported repo with
  legacy-flat stories), recover the script via
  `git log --diff-filter=A -- '*/scripts/migrate-stories-to-canonical-layout.sh'`
  and read it from the original sha, then port the relevant pieces into a
  fresh one-shot story under the current ADR-111 layout. Do **not**
  resurrect this file in place — its path-resolution logic predates ADR-111
  and would re-introduce the legacy `docs/`-vs-`.gaia/artifacts/`
  ambiguity that E96 + AF-2026-05-21-1 + this epic (E97) are closing out.
