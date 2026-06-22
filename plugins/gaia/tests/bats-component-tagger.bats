#!/usr/bin/env bats
# bats-component-tagger.bats — unit-pins the component tagger's classification
# rules, in particular the two accuracy fixes that corrected a materially-wrong
# manifest:
#   1. a literal `scripts/<name>.sh` ref is `scripts-core` ONLY when <name>.sh is
#      a real top-level script — a skill-relative `scripts/finalize.sh` (no such
#      top-level script exists; 80 skill-local copies do) must NOT inflate
#      scripts-core.
#   2. the `$BATS_TEST_DIRNAME/../scripts/<x>.sh` reference idiom (used by ~54
#      bats) resolves to a component — it was previously invisible (a whole
#      reference class fell to the no-ref catch-all).
# plus the sprint state-machine family carve-out (scripts-sprint).
#
# The tagger derives its top-level-script allowlist from its own directory (the
# real plugins/gaia/scripts/ tree, always present in the checkout), so these
# tests use a hermetic fixture tests-dir of synthetic .bats files while relying
# on stable facts about the real script tree (sprint-state.sh exists top-level;
# finalize.sh does not).

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  TAGGER="$SCRIPTS/bats-component-tagger.sh"
  FIX="$BATS_TEST_TMPDIR/tests"
  mkdir -p "$FIX"
}

# Helper: classify a single synthetic bats whose body is $1; echo its component.
_classify() {
  local body="$1" name="${2:-probe.bats}"
  printf '%s\n' "$body" > "$FIX/$name"
  bash "$TAGGER" --tests-dir "$FIX" --format tsv | awk -F'\t' -v n="$name" '$2==n {print $1}'
}

@test "a skill-relative scripts/finalize.sh ref does NOT classify as scripts-core (AC1)" {
  # $SKILL_DIR is a var the tagger does not track; the literal grep sees the
  # bare suffix scripts/finalize.sh. Since no top-level scripts/finalize.sh
  # exists, the ref is unresolved and the test falls to the core catch-all.
  local body
  body='@test "x" { run bash "$SKILL_DIR/scripts/finalize.sh"; }'
  [ "$(_classify "$body")" = "core" ]
}

@test "a real top-level scripts/<name>.sh ref still classifies as scripts-core (AC1)" {
  # gen-ci-config.sh is a genuine top-level foundation script (not sprint).
  local body
  body='@test "x" { run bash "$SCRIPTS_DIR/gen-ci-config.sh"; }'
  [ "$(_classify "$body")" = "scripts-core" ]
}

@test "a skills/<skill>/scripts/<name>.sh literal ref classifies as skills, not scripts-core (AC1)" {
  local body
  body='@test "x" { run bash "skills/gaia-add-feature/scripts/finalize.sh"; }'
  [ "$(_classify "$body")" = "skills" ]
}

@test "a BATS_TEST_DIRNAME/../scripts ref resolves instead of falling to no-ref core (AC2)" {
  # gen-ci-config.sh is top-level core; the BATS_TEST_DIRNAME idiom must resolve
  # it the same way SCRIPTS_DIR would.
  local body
  body='@test "x" { run bash "$BATS_TEST_DIRNAME/../scripts/gen-ci-config.sh"; }'
  [ "$(_classify "$body")" = "scripts-core" ]
}

@test "a braced BATS_TEST_DIRNAME ref into scripts/lib resolves to scripts-lib (AC2)" {
  local body
  body='@test "x" { run bash "${BATS_TEST_DIRNAME}/../scripts/lib/resolve-config.sh"; }'
  [ "$(_classify "$body")" = "scripts-lib" ]
}

@test "a multi-segment BATS_TEST_DIRNAME walk-up collapses correctly (AC2)" {
  local body
  body='@test "x" { run bash "$BATS_TEST_DIRNAME/../../../scripts/gen-ci-config.sh"; }'
  [ "$(_classify "$body")" = "scripts-core" ]
}

@test "a BATS_TEST_DIRNAME ref to a skill-local script classifies as skills (AC2)" {
  local body
  body='@test "x" { run bash "$BATS_TEST_DIRNAME/../skills/gaia-sprint-review/scripts/track-b-dispatch.sh"; }'
  [ "$(_classify "$body")" = "skills" ]
}

@test "a sprint state-machine script ref classifies as scripts-sprint (carve-out)" {
  local body
  body='@test "x" { run bash "$SCRIPTS_DIR/sprint-state.sh"; }'
  [ "$(_classify "$body")" = "scripts-sprint" ]
}

@test "a test mixing a sprint script and a non-sprint top-level script is cross-cutting core (carve-out)" {
  # sprint-state.sh (sprint) + gen-ci-config.sh (core) -> >1 component -> core.
  local body
  body='@test "x" { run bash "$SCRIPTS_DIR/sprint-state.sh"; run bash "$SCRIPTS_DIR/gen-ci-config.sh"; }'
  [ "$(_classify "$body")" = "core" ]
}

@test "a test with no code ref falls to core (conservatism)" {
  local body
  body='@test "x" { [ 1 -eq 1 ]; }'
  [ "$(_classify "$body")" = "core" ]
}
