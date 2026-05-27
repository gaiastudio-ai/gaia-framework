#!/usr/bin/env bats
# e107-s3-for-sprint-materializer.bats — E107-S3
#
# materialize-sprint-stories.sh is the DETERMINISTIC core of /gaia-create-story
# --for-sprint: read the sprint's selected story keys, skip already-materialized
# ones (idempotent, create-if-missing), scaffold the missing ones into the
# E105-S1 per-story layout (epic-{slug}/{key}-{slug}/story.md) with
# priority_flag: null, and emit a per-key result + an elaboration manifest (the
# scaffolded {CONTENT_PLACEHOLDER} bodies are filled by the main-turn LLM loop —
# Val W1: elaboration is NOT scriptable, so the script scaffolds skeletons +
# flags them for elaboration). --refresh re-scaffolds a rollover but guards
# against clobbering an in-progress/review/done story.
#
# ALL tests use a temp --impl-root; they NEVER touch the live .gaia tree.
#
# Maps to AC1-AC5, AC-INT1. Refs: ADR-128, ADR-127/E105-S1, FR-559,
# feedback_priority_flag_never_auto_set, Test02 F-9 / Test01 E2.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  MAT="$REPO_ROOT/plugins/gaia/scripts/materialize-sprint-stories.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/for-sprint-materializer"
  EPICS="$FX/epics-and-stories.md"
  CONFIG="$FX/config/project-config.yaml"
  TEST_TMP="$BATS_TEST_TMPDIR/e107s3-$$"
  mkdir -p "$TEST_TMP/impl"
  IMPL="$TEST_TMP/impl"
}
teardown() { rm -rf "$TEST_TMP" 2>/dev/null || true; }

# count story.md files under the per-story layout in the impl root
count_stories() { find "$IMPL" -type f -name 'story.md' 2>/dev/null | wc -l | tr -d ' '; }

# ---------- AC1 / TS1: batch materialize N missing keys in one run ----------

@test "AC1/TS1: --keys materializes every missing selected story in one invocation" {
  run bash "$MAT" --keys "E900-S1,E900-S2,E900-S3" --epics "$EPICS" --impl-root "$IMPL"
  [ "$status" -eq 0 ] \
    || { echo "materialize should succeed, got $status: $output" >&2; false; }
  [ "$(count_stories)" -eq 3 ] \
    || { echo "expected 3 materialized story.md files, got $(count_stories)" >&2; find "$IMPL" -type f >&2; false; }
}

# ---------- AC1 / TS2: idempotent re-run ----------

@test "AC1/TS2: re-run is idempotent (no new files, skips already-materialized)" {
  bash "$MAT" --keys "E900-S1,E900-S2,E900-S3" --epics "$EPICS" --impl-root "$IMPL"
  before="$(count_stories)"
  run bash "$MAT" --keys "E900-S1,E900-S2,E900-S3" --epics "$EPICS" --impl-root "$IMPL"
  [ "$status" -eq 0 ]
  [ "$(count_stories)" -eq "$before" ] \
    || { echo "re-run must not create new files (idempotent), before=$before after=$(count_stories)" >&2; false; }
  echo "$output" | grep -Eiq 'skip|already|exists' \
    || { echo "re-run should report skipped/already-materialized, got:" >&2; echo "$output" >&2; false; }
}

@test "AC1: partial materialization — only the missing key is created on a mixed run" {
  bash "$MAT" --keys "E900-S1" --epics "$EPICS" --impl-root "$IMPL"
  [ "$(count_stories)" -eq 1 ]
  run bash "$MAT" --keys "E900-S1,E900-S2" --epics "$EPICS" --impl-root "$IMPL"
  [ "$status" -eq 0 ]
  [ "$(count_stories)" -eq 2 ]  # S1 skipped, S2 created
}

# ---------- AC4 / TS4: priority_flag null + per-story layout ----------

@test "AC4/TS4: materialized stories have priority_flag null and land in the per-story layout" {
  bash "$MAT" --keys "E900-S1" --epics "$EPICS" --impl-root "$IMPL"
  sf="$(find "$IMPL" -type f -name 'story.md' | head -1)"
  [ -n "$sf" ]
  # per-story layout: parent dir is E900-S1-<slug>, grandparent is epic-E900-<slug>
  parent="$(basename "$(dirname "$sf")")"
  echo "$parent" | grep -Eq '^E900-S1-' \
    || { echo "story.md should be in a per-story E900-S1-<slug>/ dir, got parent: $parent" >&2; false; }
  grep -Eq '^priority_flag:[[:space:]]*(null|~)?[[:space:]]*$' "$sf" \
    || { echo "priority_flag must be null, got:" >&2; grep priority_flag "$sf" >&2; false; }
}

# ---------- AC3 / TS4: ready-for-dev transition (manifest / elaboration flag) ----------

@test "AC3: materializer emits an elaboration manifest naming the newly-scaffolded keys" {
  run bash "$MAT" --keys "E900-S1,E900-S2" --epics "$EPICS" --impl-root "$IMPL" --manifest "$TEST_TMP/manifest.txt"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/manifest.txt" ] \
    || { echo "an elaboration manifest should be written" >&2; false; }
  grep -q 'E900-S1' "$TEST_TMP/manifest.txt" && grep -q 'E900-S2' "$TEST_TMP/manifest.txt" \
    || { echo "manifest should name the scaffolded keys, got:" >&2; cat "$TEST_TMP/manifest.txt" >&2; false; }
}

# ---------- Val W-1: epic-dir matches the canonical resolve-epic-slug.sh ----------

@test "W-1: materialized epic-dir matches resolve-epic-slug.sh (parenthetical/long epic name)" {
  # E901's epic name has a parenthetical + long clause; the canonical resolver
  # drops the parens + truncates. The materializer must land the story under the
  # SAME dir the resolver/transition-story-status.sh expect — not an ad-hoc slug.
  expected_dir="$(bash "$REPO_ROOT/plugins/gaia/scripts/lib/resolve-epic-slug.sh" --epic-key E901 --epics-file "$EPICS")"
  run bash "$MAT" --keys "E901-S1" --epics "$EPICS" --impl-root "$IMPL"
  [ "$status" -eq 0 ]
  sf="$(find "$IMPL" -type f -name 'story.md' | head -1)"
  [ -n "$sf" ]
  # the grandparent dir (epic dir) must equal the canonical resolver output
  epic_dir_actual="$(basename "$(dirname "$(dirname "$sf")")")"
  [ "$epic_dir_actual" = "$expected_dir" ] \
    || { echo "epic dir must match resolve-epic-slug ('$expected_dir'), got '$epic_dir_actual'" >&2; false; }
}

# ---------- AC2 / TS3: --refresh guards in-progress stories ----------

@test "AC2/TS3: --refresh does NOT clobber an in-progress story (status guard)" {
  bash "$MAT" --keys "E900-S1" --epics "$EPICS" --impl-root "$IMPL"
  sf="$(find "$IMPL" -type f -name 'story.md' | head -1)"
  # simulate the story progressing to in-progress
  perl -0pi -e 's/^status:.*$/status: in-progress/m' "$sf"
  printf 'HANDCRAFTED-IN-PROGRESS-CONTENT\n' >> "$sf"
  run bash "$MAT" --keys "E900-S1" --epics "$EPICS" --impl-root "$IMPL" --refresh
  [ "$status" -eq 0 ]
  # the in-progress edit must survive the refresh (guarded)
  grep -q 'HANDCRAFTED-IN-PROGRESS-CONTENT' "$sf" \
    || { echo "--refresh must NOT clobber an in-progress story" >&2; false; }
  echo "$output" | grep -Eiq 'guard|skip|in-progress|protected'
}

# ---------- robustness ----------

@test "missing --keys fails with usage error" {
  run bash "$MAT" --epics "$EPICS" --impl-root "$IMPL"
  [ "$status" -ne 0 ]
}

@test "--help prints usage and exits 0" {
  run bash "$MAT" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eiq 'for-sprint|materializ'
}

# ---------- AC3 doc: SKILL.md documents the --for-sprint mode ----------

@test "AC1/AC3: gaia-create-story SKILL.md documents the --for-sprint batch mode" {
  SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-create-story/SKILL.md"
  grep -Eiq -- '--for-sprint' "$SKILL" \
    || { echo "create-story SKILL.md should document the --for-sprint mode" >&2; false; }
  # ready-for-dev via transition-story-status.sh (not a direct edit)
  grep -Eiq 'transition-story-status' "$SKILL"
}
