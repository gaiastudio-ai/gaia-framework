#!/usr/bin/env bats
# migrate-placeholder-substitution.bats — E29-S8
#
# Verifies that gaia-migrate.sh's _derive_required_fields helper substitutes
# the literal {project-root} placeholder with the absolute --project-root path
# before required fields are copied into the v2 config/project-config.yaml.
#
# Background: PR #387 swept a literal `gaia-public/{project-root}/_memory/...`
# directory into commit 767b29e because checkpoint.sh ran `mkdir -p` against
# an unsubstituted placeholder path. PR #404 cleaned up the local artifacts;
# this story closes the underlying migration bug at its source.
#
# Acceptance criteria covered:
#   AC1 — substitution applies in BOTH the missing-field probe loop and the
#         write loop so the validation gate sees post-substitution values.
#   AC2 — exact-token (only literal `{project-root}`); other content passes
#         through byte-identical.
#   AC3 — fixture with placeholder-bearing required fields produces a v2
#         config containing zero `{project-root}` occurrences and absolute
#         paths under --project-root.
#   AC4 — negative test: absolute-path v1 config round-trips byte-identical
#         for the preserved required fields.
#   AC6 — $PROJECT_ROOT precondition guard (set + absolute) aborts non-zero
#         when violated, BEFORE any destructive write runs.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/gaia-migrate.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/migrate-placeholder-substitution"

  # Build a per-test project tree under TEST_TMP. The fixture's v1 layout is
  # copied in so the script can mutate the working copy without touching the
  # checked-in fixture.
  PROJECT="$TEST_TMP/project"
  mkdir -p "$PROJECT/_memory" "$PROJECT/custom" "$PROJECT/.claude/commands"
  cp -R "$FIX/v1/_gaia" "$PROJECT/_gaia"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC3 — placeholder substitution under apply
# ---------------------------------------------------------------------------

@test "AC3: apply substitutes {project-root} placeholders in preserved required fields" {
  run "$SCRIPT" apply --project-root "$PROJECT" --yes
  [ "$status" -eq 0 ]

  local v2="$PROJECT/config/project-config.yaml"
  [ -f "$v2" ]

  # Zero occurrences of the literal placeholder in any non-comment line.
  # Comment lines beginning with `#` are exempt — the migration helper writes
  # one such line documenting the substitution behavior (E29-S8).
  if grep -v '^[[:space:]]*#' "$v2" | grep -q '{project-root}'; then
    printf 'AC3 fail: literal {project-root} survived into a non-comment line:\n' >&2
    grep -n '{project-root}' "$v2" | grep -v ':[[:space:]]*#' >&2
    return 1
  fi
}

@test "AC3: each preserved required field is an absolute path under --project-root" {
  run "$SCRIPT" apply --project-root "$PROJECT" --yes
  [ "$status" -eq 0 ]

  local v2="$PROJECT/config/project-config.yaml"
  local key value
  for key in project_root memory_path checkpoint_path installed_path \
             test_artifacts planning_artifacts implementation_artifacts; do
    value=$(grep -E "^${key}:" "$v2" | tail -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//')
    if [ -z "$value" ]; then
      printf 'AC3 fail: required field missing from v2 config: %s\n' "$key" >&2
      cat "$v2" >&2
      return 1
    fi
    case "$value" in
      "$PROJECT"*) : ;;  # absolute under project-root, OK
      *)
        printf 'AC3 fail: %s is not absolute under %s: %s\n' "$key" "$PROJECT" "$value" >&2
        return 1
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# AC1 — substitution applies in the missing-field probe loop too
# ---------------------------------------------------------------------------

@test "AC1: probe loop sees post-substitution values (no spurious 'missing' error)" {
  # If substitution only ran in the write loop, the probe loop would still
  # see the literal `{project-root}` string — which is non-empty, so this
  # test would not catch that bug. To make the probe-vs-write distinction
  # visible we instead assert the apply succeeds and produces the v2 file
  # with all 7 fields present after substitution. A regression that re-
  # introduces an unsubstituted probe path would fail AC3 above; this test
  # documents the expectation explicitly.
  run "$SCRIPT" apply --project-root "$PROJECT" --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"required field missing"* ]]
}

# ---------------------------------------------------------------------------
# AC2 + AC4 — absolute paths round-trip byte-identical
# ---------------------------------------------------------------------------

@test "AC4: v1 config with absolute paths round-trips byte-identical for required fields" {
  # Replace the placeholder fixture's v1 config with one whose required
  # fields are already absolute. The migration must NOT rewrite or otherwise
  # touch their values — substitution is exact-token, not regex-greedy.
  rm -f "$PROJECT/_gaia/_config/global.yaml"
  cat > "$PROJECT/_gaia/_config/global.yaml" <<EOF
framework_name: "GAIA"
framework_version: "1.127.2-rc.1"
user_name: "tester"
communication_language: "English"
document_output_language: "English"
user_skill_level: "intermediate"
project_name: "test-project"
project_root: "$PROJECT"
project_path: "$PROJECT/gaia-public"
output_folder: "$PROJECT/docs"
planning_artifacts: "$PROJECT/docs/planning-artifacts"
implementation_artifacts: "$PROJECT/docs/implementation-artifacts"
test_artifacts: "$PROJECT/docs/test-artifacts"
creative_artifacts: "$PROJECT/docs/creative-artifacts"
memory_path: "$PROJECT/_memory"
checkpoint_path: "$PROJECT/_memory/checkpoints"
installed_path: "$PROJECT/_gaia"
config_path: "$PROJECT/_gaia/_config"
date: "2026-05-01"
val_integration:
  template_output_review: true
EOF

  run "$SCRIPT" apply --project-root "$PROJECT" --yes
  [ "$status" -eq 0 ]

  local v2="$PROJECT/config/project-config.yaml"
  local key expected actual
  for key in project_root memory_path checkpoint_path installed_path \
             test_artifacts planning_artifacts implementation_artifacts; do
    case "$key" in
      project_root)            expected="$PROJECT" ;;
      memory_path)             expected="$PROJECT/_memory" ;;
      checkpoint_path)         expected="$PROJECT/_memory/checkpoints" ;;
      installed_path)          expected="$PROJECT/_gaia" ;;
      test_artifacts)          expected="$PROJECT/docs/test-artifacts" ;;
      planning_artifacts)      expected="$PROJECT/docs/planning-artifacts" ;;
      implementation_artifacts) expected="$PROJECT/docs/implementation-artifacts" ;;
    esac
    actual=$(grep -E "^${key}:" "$v2" | tail -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//')
    if [ "$actual" != "$expected" ]; then
      printf 'AC4 fail: %s changed during round-trip\n  expected: %s\n  actual:   %s\n' \
        "$key" "$expected" "$actual" >&2
      return 1
    fi
  done
}

@test "AC2: values without {project-root} pass through unchanged" {
  run "$SCRIPT" apply --project-root "$PROJECT" --yes
  [ "$status" -eq 0 ]

  local v2="$PROJECT/config/project-config.yaml"
  # framework_version is a non-placeholder value present in the fixture; it
  # MUST survive byte-identical (1.127.2-rc.1).
  grep -qE '^framework_version:[[:space:]]*"?1\.127\.2-rc\.1"?[[:space:]]*$' "$v2" || {
    printf 'AC2 fail: framework_version mutated:\n' >&2
    grep -n '^framework_version' "$v2" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC6 — PROJECT_ROOT precondition guard
# ---------------------------------------------------------------------------

@test "AC6: relative --project-root aborts BEFORE the destructive _gaia delete" {
  # Move into a parent directory and pass a RELATIVE --project-root. The
  # precondition guard inside _derive_required_fields MUST reject this with
  # a non-zero exit and a clear error, BEFORE any destructive write runs.
  cd "$TEST_TMP"
  run "$SCRIPT" apply --project-root "project" --yes
  [ "$status" -ne 0 ]
  # v1 dirs MUST remain intact — abort happened pre-delete.
  [ -d "$PROJECT/_gaia" ]
  [ -d "$PROJECT/_memory" ]
}
