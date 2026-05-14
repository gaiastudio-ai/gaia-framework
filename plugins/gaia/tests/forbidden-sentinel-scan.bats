#!/usr/bin/env bats
# forbidden-sentinel-scan.bats — E88-S3
#
# Covers TC-DPD-11..15:
#   TC-DPD-11 — production STUB -> HALT
#   TC-DPD-12 — test-fixture STUB -> PASS (exempt path)
#   TC-DPD-13 — --allow-stub with valid ID prefix -> PASS + reason emission
#   TC-DPD-14 — --allow-stub with bare prose -> REJECT
#   TC-DPD-15 — load-taxonomy.sh enumerates THREE supported taxonomies
#
# Helper under test:
#   gaia-public/plugins/gaia/scripts/lib/forbidden-sentinel-scan.sh
#
# Invocation contract:
#   forbidden-sentinel-scan.sh --base-ref <branch> [--allow-stub <reason>]
#
# Behaviour:
#   - exits 0 if no forbidden sentinels in the production-path diff slice
#     (or --allow-stub override is accepted).
#   - exits 1 with canonical stderr on a production-path match.
#   - exits 1 with the canonical reason-regex-reject stderr on a malformed
#     --allow-stub value.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  HELPER="$LIB_DIR/forbidden-sentinel-scan.sh"
  export LIB_DIR HELPER

  # Stage a temp git repo with a base commit so `git diff` works
  # deterministically. All git config is local to TEST_TMP.
  REPO="$TEST_TMP/repo"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    git -c init.defaultBranch=main init -q
    git config user.email test@test
    git config user.name test
    mkdir -p gaia-public/plugins/gaia/scripts gaia-public/plugins/gaia/tests/fixtures
    printf 'clean baseline\n' > gaia-public/plugins/gaia/scripts/foo.sh
    git add -A
    git commit -q -m base
    git checkout -q -b feat-test
  )
  export REPO
}

teardown() {
  common_teardown
}

# Helper: write a file inside the repo and commit it on the current branch
# so that `git diff main..HEAD` (the helper's diff scope) includes it.
_stage_diff() {
  local path="$1"; shift
  local content="$1"; shift
  ( cd "$REPO" && mkdir -p "$(dirname "$path")" && printf '%s\n' "$content" > "$path" && git add -A && git commit -q -m "fixture: stage diff" )
}

# ---------------- TC-DPD-11: production STUB -> HALT ----------------
@test "TC-DPD-11: production-path STUB triggers HALT with canonical stderr" {
  _stage_diff gaia-public/plugins/gaia/scripts/foo.sh \
    'echo STUB  # placeholder'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"forbidden sentinel"* ]]
  [[ "$output" == *"STUB"* ]]
  [[ "$output" == *"gaia-public/plugins/gaia/scripts/foo.sh"* ]]
}

# ---------------- TC-DPD-12: test-fixture STUB -> PASS ----------------
@test "TC-DPD-12: test-fixture path STUB does NOT trigger HALT (exempt)" {
  _stage_diff gaia-public/plugins/gaia/tests/fixtures/example.sh \
    'echo STUB  # legitimate fixture stub'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPD-13: --allow-stub with valid ID prefix -> PASS ----------------
@test "TC-DPD-13: --allow-stub with valid story-ID prefix bypasses scan" {
  _stage_diff gaia-public/plugins/gaia/scripts/foo.sh \
    'echo STUB  # contract-only dispatch'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "E76-S10: contract-only dispatch"; cd "$OLDPWD"
  [ "$status" -eq 0 ]
  # The accepted reason MUST be echoed on stdout so the caller can pipe it
  # forward to pr-body.sh.
  [[ "$output" == *"E76-S10: contract-only dispatch"* ]]
}

@test "TC-DPD-13b: --allow-stub with valid AI-ID prefix bypasses scan" {
  _stage_diff gaia-public/plugins/gaia/scripts/foo.sh \
    'echo STUB  # AI-tracked'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "AI-2026-05-14-6: contract-only"; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# ---------------- TC-DPD-14: --allow-stub with bare prose -> REJECT ----------------
@test "TC-DPD-14: --allow-stub with bare prose is rejected" {
  _stage_diff gaia-public/plugins/gaia/scripts/foo.sh \
    'echo STUB'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "looks fine"; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--allow-stub reason must cite a story ID"* ]]
}

@test "TC-DPD-14b: --allow-stub with story ID lacking trailing colon is rejected" {
  _stage_diff gaia-public/plugins/gaia/scripts/foo.sh \
    'echo STUB'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "E76-S10 contract-only"; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must cite a story ID"* ]]
}

# ---------------- TC-DPD-15: load-taxonomy enumerates 3 names ----------------
@test "TC-DPD-15: load-taxonomy.sh --taxonomy unknown enumerates THREE supported names" {
  run bash -c '"$0" --taxonomy frobnicate 2>&1' "$LIB_DIR/load-taxonomy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *deferral* ]]
  [[ "$output" == *dispatch* ]]
  [[ "$output" == *forbidden-sentinels* ]]
}

# ---------------- TC-DPD-15b: load-taxonomy forbidden-sentinels works ----------------
@test "TC-DPD-15b: load-taxonomy --taxonomy forbidden-sentinels emits entries" {
  run "$LIB_DIR/load-taxonomy.sh" --taxonomy forbidden-sentinels
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB"* ]]
  [[ "$output" == *"MOCK"* ]]
  [[ "$output" == *"FIXME"* ]]
}

# ---------------- Diff-only scope: untouched production STUB does NOT HALT ----------------
@test "scope: untouched production file with STUB outside the diff is not flagged" {
  # Add a STUB to a file in the BASE commit, then make an unrelated change in feat.
  ( cd "$REPO" && git checkout -q main )
  printf 'pre-existing STUB content\n' > "$REPO/gaia-public/plugins/gaia/scripts/pre-existing.sh"
  ( cd "$REPO" && git add -A && git commit -q -m "base with stub" && git checkout -q feat-test )
  # Now stage an unrelated benign change and COMMIT it on feat-test.
  printf 'a benign change\n' > "$REPO/gaia-public/plugins/gaia/scripts/other.sh"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: benign" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  # The scan considers only files in the diff; the pre-existing.sh STUB is
  # not in the feat-test diff, so the helper should pass.
  [ "$status" -eq 0 ]
}
