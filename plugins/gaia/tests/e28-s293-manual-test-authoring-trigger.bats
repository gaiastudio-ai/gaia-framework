#!/usr/bin/env bats
# e28-s293-manual-test-authoring-trigger.bats — manual-test as a first-class,
# prompted authoring step symmetric with the acceptance-test offer.
#
# Root cause of the manual-test gap: the per-story-review manual-test gate is
# wired, but NO authoring skill set manual_verification, so the gate never
# fired. These tests drive the REAL deterministic surfaces that the authoring
# step uses:
#   - generate-frontmatter.sh emits manual_verification (false default,
#     true on --manual-verification opt-in)
#   - story-template.md carries the key + a ## Manual Test section
#   - validate-frontmatter.sh accepts the optional flag and format-checks it
#   - manual-verification-scan.sh reads the flag for sprint-plan annotation
# and asserts the end-to-end trigger->gate chain (flag set upstream -> review
# gate honors it).

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CREATE_SCRIPTS="$REPO_ROOT/plugins/gaia/skills/gaia-create-story/scripts"
  GEN="$CREATE_SCRIPTS/generate-frontmatter.sh"
  VALIDATE_FM="$CREATE_SCRIPTS/validate-frontmatter.sh"
  SCAFFOLD="$CREATE_SCRIPTS/scaffold-story.sh"
  TEMPLATE="$REPO_ROOT/plugins/gaia/skills/gaia-create-story/story-template.md"
  MVSCAN="$REPO_ROOT/plugins/gaia/scripts/manual-verification-scan.sh"
  # The canonical gate reader the per-story-review manual-test dispatcher uses to
  # decide whether a story REQUIRES manual verification. Test 14 drives it (not a
  # generator-output tautology) to prove the authoring trigger feeds the gate.
  MT_DISPATCH="$REPO_ROOT/plugins/gaia/scripts/manual-test-review-dispatch.sh"

  EPICS="$TEST_TMP/epics.md"
  cat > "$EPICS" <<'EOF'
# Epics and Stories

## Epic E1 — Test

### Story E1-S1: A user-facing story

- **Epic:** E1 — Test
- **Priority:** P2
- **Size:** S
- **Risk:** low
- **Depends on:** none
- **Blocks:** none
- **Traces to:** none
EOF

  CONFIG="$TEST_TMP/config.yaml"
  cat > "$CONFIG" <<'EOF'
project_root: "."
project_path: "."
memory_path: "_memory"
checkpoint_path: "_memory/checkpoints"
installed_path: "_gaia"
framework_version: "1.0.0"
date: "2026-06-30"
sizing_map:
  S: 1
  M: 3
  L: 8
  XL: 13
EOF
}

teardown() { common_teardown; }

# =====================================================================
# AC1: create-story (generator) sets the flag on opt-in, false by default
# =====================================================================

@test "generate-frontmatter defaults manual_verification: false (no-surface / no opt-in)" {
  run bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"manual_verification: false"* ]]
}

@test "generate-frontmatter --manual-verification sets manual_verification: true (opt-in)" {
  run bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG" --manual-verification
  [ "$status" -eq 0 ]
  [[ "$output" == *"manual_verification: true"* ]]
}

@test "the manual_verification key is ALWAYS emitted (explicit in frontmatter)" {
  # Both forms must carry the key — never silently absent.
  run bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG"
  [[ "$output" == *"manual_verification:"* ]]
}

# =====================================================================
# AC1: the story template carries the key + a ## Manual Test section
# =====================================================================

@test "story-template.md declares manual_verification in frontmatter" {
  grep -q '^manual_verification:' "$TEMPLATE"
}

@test "story-template.md has a ## Manual Test section" {
  grep -q '^## Manual Test' "$TEMPLATE"
}

@test "scaffold-story emits exactly the seven content sections (no regression from the new section)" {
  fm="$(bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG")"
  out="$TEST_TMP/story.md"
  sections="$(bash "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm")"
  count="$(printf '%s\n' "$sections" | grep -c .)"
  [ "$count" -eq 7 ]
}

@test "scaffold output carries the ## Manual Test section verbatim (deterministic, not a content placeholder)" {
  fm="$(bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG")"
  out="$TEST_TMP/story.md"
  bash "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm" >/dev/null
  grep -q '^## Manual Test' "$out"
  # The section is emitted verbatim — it must NOT be collapsed to a placeholder.
  ! grep -q 'MANUAL_TEST_PLACEHOLDER' "$out"
}

# =====================================================================
# AC1/AC6: validation accepts the flag and format-checks it
# =====================================================================

@test "validate-frontmatter accepts manual_verification: true" {
  # Build a full, canonical-layout story via the real scaffold (which includes
  # the ## Review Gate section + correct per-story dir name), so the only thing
  # under test here is the optional manual_verification field validating clean.
  fm="$(bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG" --manual-verification)"
  dir="$TEST_TMP/E1-S1-a-user-facing-story"
  mkdir -p "$dir"
  bash "$SCAFFOLD" --template "$TEMPLATE" --output "$dir/story.md" --frontmatter "$fm" >/dev/null
  # Confirm the scaffolded file actually carries the true flag.
  grep -qx 'manual_verification: true' "$dir/story.md"
  run bash "$VALIDATE_FM" --file "$dir/story.md"
  [ "$status" -eq 0 ]
}

@test "validate-frontmatter accepts a legacy story with manual_verification ABSENT (optional field)" {
  # A story authored before this change has no manual_verification key. Strip it
  # out of a freshly scaffolded story to simulate the legacy shape, then assert
  # the validator still passes (the field is optional, not required).
  fm="$(bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG")"
  dir="$TEST_TMP/E1-S1-a-user-facing-story"
  mkdir -p "$dir"
  bash "$SCAFFOLD" --template "$TEMPLATE" --output "$dir/story.md" --frontmatter "$fm" >/dev/null
  # Remove the manual_verification frontmatter line to mimic a pre-change story.
  grep -v '^manual_verification:' "$dir/story.md" > "$dir/story.md.tmp"
  mv "$dir/story.md.tmp" "$dir/story.md"
  ! grep -q '^manual_verification:' "$dir/story.md"
  run bash "$VALIDATE_FM" --file "$dir/story.md"
  [ "$status" -eq 0 ]
}

@test "validate-frontmatter REJECTS a non-boolean manual_verification (format-checked when present)" {
  # Start from a clean, canonical scaffold (otherwise-valid), then corrupt ONLY
  # the manual_verification value so the failure is unambiguously about it.
  fm="$(bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG")"
  dir="$TEST_TMP/E1-S1-a-user-facing-story"
  mkdir -p "$dir"
  bash "$SCAFFOLD" --template "$TEMPLATE" --output "$dir/story.md" --frontmatter "$fm" >/dev/null
  sed 's/^manual_verification: false/manual_verification: maybe/' "$dir/story.md" > "$dir/story.md.tmp"
  mv "$dir/story.md.tmp" "$dir/story.md"
  run bash "$VALIDATE_FM" --file "$dir/story.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manual_verification"* ]]
}

# =====================================================================
# AC3: sprint-plan reads the flag for candidate annotation
# =====================================================================

@test "manual-verification-scan annotates a flagged candidate and omits an unflagged one" {
  mkdir -p "$TEST_TMP/impl/epic-E1-test/E1-S1-foo"
  printf -- '---\nkey: "E1-S1"\nmanual_verification: true\n---\n' \
    > "$TEST_TMP/impl/epic-E1-test/E1-S1-foo/story.md"
  mkdir -p "$TEST_TMP/impl/epic-E1-test/E1-S2-bar"
  printf -- '---\nkey: "E1-S2"\nmanual_verification: false\n---\n' \
    > "$TEST_TMP/impl/epic-E1-test/E1-S2-bar/story.md"

  run bash "$MVSCAN" annotate "$TEST_TMP/impl/epic-E1-test/E1-S1-foo/story.md"
  [ "$output" = "[manual_verification]" ]

  run bash "$MVSCAN" annotate "$TEST_TMP/impl/epic-E1-test/E1-S2-bar/story.md"
  [ -z "$output" ]
}

@test "manual-verification-scan scan-keys lists only the flagged keys" {
  for k in E1-S1 E1-S2 E1-S3; do
    mkdir -p "$TEST_TMP/impl/epic-E1-test/${k}-x"
  done
  printf -- '---\nkey: "E1-S1"\nmanual_verification: true\n---\n'  > "$TEST_TMP/impl/epic-E1-test/E1-S1-x/story.md"
  printf -- '---\nkey: "E1-S2"\nmanual_verification: false\n---\n' > "$TEST_TMP/impl/epic-E1-test/E1-S2-x/story.md"
  printf -- '---\nkey: "E1-S3"\n---\n'                              > "$TEST_TMP/impl/epic-E1-test/E1-S3-x/story.md"

  run bash "$MVSCAN" scan-keys "$TEST_TMP/impl" E1-S1 E1-S2 E1-S3
  [ "$status" -eq 0 ]
  [[ "$output" == *"E1-S1"* ]]
  [[ "$output" != *"E1-S2"* ]]
  [[ "$output" != *"E1-S3"* ]]
}

@test "manual-verification-scan enabled is fail-safe: only the literal true opts in" {
  d="$TEST_TMP/fs"; mkdir -p "$d"
  printf -- '---\nkey: "X"\nmanual_verification: TRUE\n---\n' > "$d/up.md"
  printf -- '---\nkey: "X"\nmanual_verification: 1\n---\n'    > "$d/one.md"
  # Neither "TRUE" nor "1" is the literal lowercase true -> not enabled.
  run bash "$MVSCAN" enabled "$d/up.md"; [ "$status" -ne 0 ]
  run bash "$MVSCAN" enabled "$d/one.md"; [ "$status" -ne 0 ]
}

# =====================================================================
# AC4: end-to-end trigger -> gate (flag set upstream is honored at review)
# =====================================================================

@test "end-to-end: the canonical gate reader honors a story authored WITHOUT the flag as not-required (no-op)" {
  # Drive the REAL gate consumer (manual-test-review-dispatch.sh), not the
  # generator output. A story authored with no opt-in (manual_verification:
  # false) must be treated as not-requiring manual verification → the dispatcher
  # is a no-op (exit 0) and logs "not required". This proves the gate reads the
  # authored flag, and that the default does not over-require.
  [ -f "$MT_DISPATCH" ] || skip "manual-test-review-dispatch.sh not present"
  fm="$(bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG")"
  dir="$TEST_TMP/E1-S1-a-user-facing-story"
  mkdir -p "$dir"
  bash "$SCAFFOLD" --template "$TEMPLATE" --output "$dir/story.md" --frontmatter "$fm" >/dev/null
  run bash "$MT_DISPATCH" --story-file "$dir/story.md" --story E1-S1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not required"* ]] || [[ "$output" == *"no-op"* ]] || [[ "$output" == *"does not declare"* ]]
}

@test "end-to-end: a story authored WITH --manual-verification is recognized by the gate as requiring verification" {
  # The opt-in path: a story authored with --manual-verification scaffolds to
  # manual_verification: true, and the REAL gate reader recognizes it as
  # requiring verification (it does NOT take the not-required no-op branch). This
  # is the load-bearing trigger->gate link, driven through real code.
  [ -f "$MT_DISPATCH" ] || skip "manual-test-review-dispatch.sh not present"
  fm="$(bash "$GEN" --story-key E1-S1 --epics-file "$EPICS" --project-config "$CONFIG" --manual-verification)"
  dir="$TEST_TMP/E1-S1-a-user-facing-story"
  mkdir -p "$dir"
  bash "$SCAFFOLD" --template "$TEMPLATE" --output "$dir/story.md" --frontmatter "$fm" >/dev/null
  grep -qx 'manual_verification: true' "$dir/story.md"
  # The gate must NOT emit the not-required no-op message for an opted-in story.
  run bash "$MT_DISPATCH" --story-file "$dir/story.md" --story E1-S1
  [[ "$output" != *"not required"* ]] && [[ "$output" != *"does not declare"* ]]
}
