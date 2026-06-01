#!/usr/bin/env bats
# AF-2026-05-30-1 — Test03 §7.3 consolidated-layout drifts.
#
# Closes two pre-existing drifts that survived AF-29-1/2/3:
#
# 1. Adversarial reports were written flat under planning-artifacts/ instead
#    of grouped under the dated-snapshot subdir adversarial/ (Test03 §7.3
#    Pillar 3 — joins the existing nfr-assessment/ + performance-test-plan/
#    pattern). Five consumer skills updated; the canonical write subdir is
#    .gaia/artifacts/planning-artifacts/adversarial/.
#
# 2. Test-artifacts mirror symmetry: §7.3 mandates per-story dirs under
#    test-artifacts/epic-X/stories/{key}-{slug}/ that mirror the
#    implementation-artifacts/ tree (so one story = two well-known paths,
#    identical sub-structure). The atdd and test-automate-plan producers
#    were writing flat; this AF adds a shared resolver
#    (scripts/lib/resolve-test-artifact-per-story.sh) + a one-time
#    migration helper (scripts/migrate-test-artifacts-to-per-story.sh)
#    + dual-path read acceptance in the gaia-sprint-plan ATDD existence
#    check and the gaia-test-automate Approval Gate pre-condition.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# Drift 1: adversarial/ subdir grouping
# ===========================================================================

@test "AF-30-1 adversarial: gaia-adversarial SKILL.md writes to adversarial/ subdir" {
  run grep -F '{planning_artifacts}/adversarial/adversarial-review-{target}-{date}.md' \
        "$PLUGIN_ROOT/skills/gaia-adversarial/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 adversarial: gaia-adversarial SKILL.md mkdir -p adversarial/ before write" {
  run grep -F 'mkdir -p {planning_artifacts}/adversarial/' \
        "$PLUGIN_ROOT/skills/gaia-adversarial/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 adversarial: gaia-brownfield Phase 8b writes to adversarial/ subdir" {
  run grep -F '.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-' \
        "$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 adversarial: gaia-edit-prd writes to adversarial/ subdir" {
  run grep -F '.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-' \
        "$PLUGIN_ROOT/skills/gaia-edit-prd/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 adversarial: gaia-edit-arch writes to adversarial/ subdir" {
  run grep -F '.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-architecture-' \
        "$PLUGIN_ROOT/skills/gaia-edit-arch/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 adversarial: gaia-edit-ux writes to adversarial/ subdir" {
  run grep -F '.gaia/artifacts/planning-artifacts/adversarial/adversarial-review-ux-design-' \
        "$PLUGIN_ROOT/skills/gaia-edit-ux/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 adversarial: legacy ungrouped path still documented as read-only fallback" {
  # The fallback wording should appear in every consumer so reviewers know
  # the dual-path acceptance is intentional during migration.
  for skill in gaia-adversarial gaia-brownfield gaia-edit-prd gaia-edit-arch gaia-edit-ux; do
    run grep -E 'read-only fallback|legacy ungrouped' "$PLUGIN_ROOT/skills/$skill/SKILL.md"
    [ "$status" -eq 0 ] || { echo "missing fallback wording in $skill"; return 1; }
  done
}

# ===========================================================================
# Drift 2: resolve-test-artifact-per-story.sh resolver behaviour
# ===========================================================================

@test "AF-30-1 resolver: --write returns new canonical per-story path" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/implementation-artifacts/epic-E1-some-epic/stories/E1-S1-some-story
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh" \
          atdd E1-S1 --write
  [ "$status" -eq 0 ]
  # AF-32-1 / Test15 F-20-L: the new write path drops the `stories/` middle
  # level so the test-artifacts mirror is symmetric with the review-gate
  # mirror (Test14 F-15: epic-{slug}/{key}-{slug}/, no stories/ level).
  [[ "$output" =~ test-artifacts/epic-E1-some-epic/E1-S1-some-story/atdd\.md$ ]]
  # Parent dir should have been created
  [ -d "$TEST_TMP/.gaia/artifacts/test-artifacts/epic-E1-some-epic/E1-S1-some-story" ]
}

@test "AF-30-1 resolver: read precedence — new per-story wins over legacy flat" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/implementation-artifacts/epic-E1-some-epic/stories/E1-S1-some-story
  mkdir -p .gaia/artifacts/test-artifacts/epic-E1-some-epic/E1-S1-some-story
  echo "new" > .gaia/artifacts/test-artifacts/epic-E1-some-epic/E1-S1-some-story/atdd.md
  echo "old" > .gaia/artifacts/test-artifacts/atdd-E1-S1.md
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh" \
          atdd E1-S1
  [ "$status" -eq 0 ]
  # AF-32-1 F-20-L: new canonical home is epic-{slug}/{key}-{slug}/ (no stories/).
  [[ "$output" =~ test-artifacts/epic-E1-some-epic/E1-S1-some-story/atdd\.md$ ]]
}

@test "AF-30-1 resolver: read falls back to legacy flat when new home absent" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/test-artifacts
  echo "old" > .gaia/artifacts/test-artifacts/atdd-E1-S1.md
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh" \
          atdd E1-S1
  [ "$status" -eq 0 ]
  [[ "$output" =~ test-artifacts/atdd-E1-S1\.md$ ]]
}

@test "AF-30-1 resolver: --existing-only exits 1 when no rung exists" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/test-artifacts
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh" \
          atdd E1-S1 --existing-only
  [ "$status" -eq 1 ]
}

@test "AF-30-1 resolver: prefix-boundary guard — E1-S1 query does not match E1-S10-*" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/implementation-artifacts/epic-E1-some-epic/stories/E1-S10-other-story
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh" \
          atdd E1-S1 --write
  [ "$status" -eq 0 ]
  # AF-32-1 F-20-L: when no per-story dir exists yet, the resolver synthesises
  # `epic-{EID}/{key}/{type}.md` from the bare story key (no `stories/` level
  # post-F-20-L; the canonical write path is symmetric with the review-gate
  # mirror).
  [[ "$output" =~ /epic-E1/E1-S1/atdd\.md$ ]]
}

@test "AF-30-1 resolver: rejects unknown type" {
  run bash "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh" \
        bogus E1-S1
  [ "$status" -eq 1 ]
  [[ "$output" =~ "unknown type" ]] || [[ "${stderr:-}" =~ "unknown type" ]]
}

@test "AF-30-1 resolver: test-automate-plan type writes plan.md basename" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/implementation-artifacts/epic-E1-some-epic/stories/E1-S1-some-story
  run env PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/lib/resolve-test-artifact-per-story.sh" \
          test-automate-plan E1-S1 --write
  [ "$status" -eq 0 ]
  [[ "$output" =~ /test-automate-plan\.md$ ]]
}

# ===========================================================================
# Drift 2: producer SKILL.md path references
# ===========================================================================

@test "AF-30-1 atdd: SKILL.md references the per-story resolver" {
  run grep -F 'resolve-test-artifact-per-story.sh atdd' \
        "$PLUGIN_ROOT/skills/gaia-atdd/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 test-automate: SKILL.md references the per-story resolver" {
  run grep -F 'resolve-test-artifact-per-story.sh test-automate-plan' \
        "$PLUGIN_ROOT/skills/gaia-test-automate/SKILL.md"
  [ "$status" -eq 0 ]
}

@test "AF-30-1 sprint-plan: ATDD existence check goes through the resolver" {
  run grep -F 'resolve-test-artifact-per-story.sh atdd' \
        "$PLUGIN_ROOT/skills/gaia-sprint-plan/SKILL.md"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Migration helper
# ===========================================================================

@test "AF-30-1 migrate: helper is executable and supports --dry-run" {
  [ -x "$PLUGIN_ROOT/scripts/migrate-test-artifacts-to-per-story.sh" ]
}

@test "AF-30-1 migrate: --dry-run on empty test-artifacts is a no-op" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/test-artifacts .gaia/artifacts/implementation-artifacts
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/migrate-test-artifacts-to-per-story.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ moved=0 ]]
}

@test "AF-30-1 migrate: moves a flat atdd file when story dir exists" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/implementation-artifacts/epic-E1-some-epic/stories/E1-S1-some-story
  mkdir -p .gaia/artifacts/test-artifacts
  echo "atdd body" > .gaia/artifacts/test-artifacts/atdd-E1-S1.md
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/migrate-test-artifacts-to-per-story.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ moved=1 ]]
  [ ! -f .gaia/artifacts/test-artifacts/atdd-E1-S1.md ]
  [ -f .gaia/artifacts/test-artifacts/epic-E1-some-epic/stories/E1-S1-some-story/atdd.md ]
}

@test "AF-30-1 migrate: leaves stragglers (story dir absent) at flat path" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/test-artifacts .gaia/artifacts/implementation-artifacts
  echo "orphan" > .gaia/artifacts/test-artifacts/atdd-E99-S99.md
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/migrate-test-artifacts-to-per-story.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ stragglers=1 ]]
  [ -f .gaia/artifacts/test-artifacts/atdd-E99-S99.md ]
}

@test "AF-30-1 migrate: skips target collision rather than overwriting" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/implementation-artifacts/epic-E1-some-epic/stories/E1-S1-some-story
  mkdir -p .gaia/artifacts/test-artifacts/epic-E1-some-epic/stories/E1-S1-some-story
  echo "FLAT" > .gaia/artifacts/test-artifacts/atdd-E1-S1.md
  echo "NESTED" > .gaia/artifacts/test-artifacts/epic-E1-some-epic/stories/E1-S1-some-story/atdd.md
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/migrate-test-artifacts-to-per-story.sh"
  [ "$status" -eq 0 ]
  # The flat file should remain — the helper refuses to overwrite the target.
  [ -f .gaia/artifacts/test-artifacts/atdd-E1-S1.md ]
  # The nested file should be untouched (still says NESTED).
  run cat .gaia/artifacts/test-artifacts/epic-E1-some-epic/stories/E1-S1-some-story/atdd.md
  [[ "$output" == "NESTED" ]]
}

@test "AF-30-1 migrate: second run is idempotent (everything already moved)" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/implementation-artifacts/epic-E1-some-epic/stories/E1-S1-some-story
  mkdir -p .gaia/artifacts/test-artifacts
  echo "body" > .gaia/artifacts/test-artifacts/atdd-E1-S1.md
  env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
    bash "$PLUGIN_ROOT/scripts/migrate-test-artifacts-to-per-story.sh" >/dev/null
  run env CLAUDE_PROJECT_ROOT="$TEST_TMP" \
        bash "$PLUGIN_ROOT/scripts/migrate-test-artifacts-to-per-story.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ moved=0 ]]
}
