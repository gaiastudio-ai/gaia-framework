#!/usr/bin/env bats
# af-2026-05-27-4-review-report-paths.bats
#
# AF-2026-05-27-4 / Test05 F-046 (+ F-047 note) — E105-S4 producer migration.
#
# The six review skills now resolve their report DIRECTORY via the shared
# resolve-review-report-path.sh helper: per-story epic-{slug}/{key}-{slug}/reviews/
# for new-layout stories (E105-S1), flat implementation-artifacts/ otherwise. The
# FR-402 type-first basename is unchanged. F-047: execution-evidence.json is a
# separate artifact already written by qa-test-runner.sh — unchanged.

load 'test_helper.bash'

setup() {
  common_setup
  P="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RES="$P/scripts/resolve-review-report-path.sh"
  IA="$TEST_TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IA"
  export IMPLEMENTATION_ARTIFACTS="$IA"
}
teardown() { common_teardown; }

_write_story() { # $1 path ; $2 key
  mkdir -p "$(dirname "$1")"
  printf -- '---\ntemplate: %s\nkey: "%s"\ntitle: "Foo"\nstatus: done\nepic: "%s"\n---\n# S\n' \
    "'story'" "$2" "${2%%-*}" > "$1"
}

# ---------- resolver behaviour ----------

@test "F-046: resolver returns the per-story reviews/ path for a new-layout story (and creates it)" {
  _write_story "$IA/epic-E1-x/E1-S1-foo/story.md" "E1-S1"
  run bash "$RES" --key E1-S1 --type code-review
  [ "$status" -eq 0 ]
  [[ "$output" == *"/epic-E1-x/E1-S1-foo/reviews/code-review-E1-S1.md" ]]
  [ -d "$IA/epic-E1-x/E1-S1-foo/reviews" ]
}

@test "F-046: resolver returns the flat path for a legacy-flat story" {
  _write_story "$IA/E2-S1-bar.md" "E2-S1"
  run bash "$RES" --key E2-S1 --type qa-tests
  [ "$status" -eq 0 ]
  [[ "$output" == *"/implementation-artifacts/qa-tests-E2-S1.md" ]]
}

@test "F-046: resolver returns the flat path for a legacy epic-*/stories/ story" {
  _write_story "$IA/epic-E3-y/stories/E3-S1-baz.md" "E3-S1"
  run bash "$RES" --key E3-S1 --type security-review
  [ "$status" -eq 0 ]
  [[ "$output" == *"/implementation-artifacts/security-review-E3-S1.md" ]]
}

@test "resolver basename is type-first for every review type" {
  _write_story "$IA/E4-S1-x.md" "E4-S1"
  for t in code-review qa-tests security-review test-automate-review test-review performance-review; do
    run bash "$RES" --key E4-S1 --type "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/${t}-E4-S1.md" ]]
  done
}

@test "F-046: resolver requires --key and --type" {
  run bash "$RES" --key E1-S1
  [ "$status" -ne 0 ]
  run bash "$RES" --type code-review
  [ "$status" -ne 0 ]
}

@test "resolver passes bash -n syntax + has no rm -rf" {
  bash -n "$RES"
  run bash -c "grep -vE '^[[:space:]]*#' '$RES' | grep -E 'rm[[:space:]]+-rf' || true"
  [ -z "$output" ]
}

# ---------- the six review skills reference the resolver ----------

@test "all six review skills resolve their path via the shared helper" {
  for s in gaia-code-review gaia-qa-tests gaia-test-review gaia-review-perf gaia-test-automate; do
    grep -qF 'resolve-review-report-path.sh' "$P/skills/$s/SKILL.md" \
      || { echo "missing resolver ref in $s"; false; }
  done
  # gaia-run-all-reviews documents the resolver as the single source of the dir.
  grep -qF 'resolve-review-report-path.sh' "$P/skills/gaia-run-all-reviews/SKILL.md"
}

# ---------- F-047: execution-evidence is a separate, already-produced artifact ----------

@test "F-047: qa-tests still documents the separate execution-evidence.json artifact" {
  grep -qF 'execution-evidence.json' "$P/skills/gaia-qa-tests/SKILL.md"
  grep -qF '.gaia/state/review/qa-tests/' "$P/skills/gaia-qa-tests/SKILL.md"
}
