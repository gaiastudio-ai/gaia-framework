#!/usr/bin/env bats
# parse-force-design.bats — tests for the shared --force-design flag parser.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup
  PARSER="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/parse-force-design.sh"
}

teardown() { common_teardown; }

@test "parse-force-design.sh exists and is executable" {
  [ -f "$PARSER" ]
  [ -x "$PARSER" ]
}

@test "all four flags are parsed and exported" {
  source "$PARSER"
  _parse_force_design --force-design --reason "test reason text" --entry-point gaia-create-arch --sprint-id sprint-82
  [ "$FORCE_DESIGN" = "1" ]
  [ "$FORCE_DESIGN_REASON" = "test reason text" ]
  [ "$FORCE_DESIGN_ENTRY_POINT" = "gaia-create-arch" ]
  [ "$FORCE_DESIGN_SPRINT_ID" = "sprint-82" ]
}

@test "unrelated flags pass through to _PFD_REMAINING" {
  source "$PARSER"
  _parse_force_design --force-design --reason "r" --bypass gaia-threat-model --unknown-flag
  [ "$FORCE_DESIGN" = "1" ]
  [ "${#_PFD_REMAINING[@]}" -eq 3 ]
  [ "${_PFD_REMAINING[0]}" = "--bypass" ]
  [ "${_PFD_REMAINING[1]}" = "gaia-threat-model" ]
  [ "${_PFD_REMAINING[2]}" = "--unknown-flag" ]
}

@test "no args yields empty exports" {
  source "$PARSER"
  _parse_force_design
  [ -z "$FORCE_DESIGN" ]
  [ -z "$FORCE_DESIGN_REASON" ]
  [ -z "$FORCE_DESIGN_ENTRY_POINT" ]
  [ -z "$FORCE_DESIGN_SPRINT_ID" ]
  [ "${#_PFD_REMAINING[@]}" -eq 0 ]
}

@test "--reason without a value exits 2" {
  source "$PARSER"
  run _parse_force_design --force-design --reason
  [ "$status" -eq 2 ]
}

@test "--entry-point without a value exits 2" {
  source "$PARSER"
  run _parse_force_design --entry-point
  [ "$status" -eq 2 ]
}

@test "--sprint-id without a value exits 2" {
  source "$PARSER"
  run _parse_force_design --sprint-id
  [ "$status" -eq 2 ]
}

@test "double-source guard prevents re-initialization" {
  source "$PARSER"
  _parse_force_design --force-design --reason "first"
  [ "$FORCE_DESIGN" = "1" ]

  # Source again — the guard should prevent re-execution of the body
  source "$PARSER"
  # The function should still be available
  _parse_force_design --force-design --reason "second"
  [ "$FORCE_DESIGN_REASON" = "second" ]
}

# ---- Binding-rule tests: --reason binds to its preceding owning flag ----

@test "bypass-then-force: --bypass X --reason A --force-design --reason B" {
  source "$PARSER"
  _parse_force_design --bypass gaia-threat-model --reason "bypass reason" --force-design --reason "design reason"
  # --force-design owns the second --reason
  [ "$FORCE_DESIGN" = "1" ]
  [ "$FORCE_DESIGN_REASON" = "design reason" ]
  # --bypass and its --reason pass through in order
  [ "${#_PFD_REMAINING[@]}" -eq 4 ]
  [ "${_PFD_REMAINING[0]}" = "--bypass" ]
  [ "${_PFD_REMAINING[1]}" = "gaia-threat-model" ]
  [ "${_PFD_REMAINING[2]}" = "--reason" ]
  [ "${_PFD_REMAINING[3]}" = "bypass reason" ]
}

@test "force-then-bypass: --force-design --reason B --bypass X --reason A" {
  source "$PARSER"
  _parse_force_design --force-design --reason "design reason" --bypass gaia-threat-model --reason "bypass reason"
  # --force-design owns the first --reason
  [ "$FORCE_DESIGN" = "1" ]
  [ "$FORCE_DESIGN_REASON" = "design reason" ]
  # --bypass releases ownership; its --reason passes through
  [ "${#_PFD_REMAINING[@]}" -eq 4 ]
  [ "${_PFD_REMAINING[0]}" = "--bypass" ]
  [ "${_PFD_REMAINING[1]}" = "gaia-threat-model" ]
  [ "${_PFD_REMAINING[2]}" = "--reason" ]
  [ "${_PFD_REMAINING[3]}" = "bypass reason" ]
}

@test "force-design alone with no --reason" {
  source "$PARSER"
  _parse_force_design --force-design --entry-point gaia-create-arch
  [ "$FORCE_DESIGN" = "1" ]
  [ -z "$FORCE_DESIGN_REASON" ]
  [ "$FORCE_DESIGN_ENTRY_POINT" = "gaia-create-arch" ]
}

@test "bypass alone: all args pass through" {
  source "$PARSER"
  _parse_force_design --bypass gaia-threat-model --reason "bypass only"
  [ -z "$FORCE_DESIGN" ]
  [ -z "$FORCE_DESIGN_REASON" ]
  [ "${#_PFD_REMAINING[@]}" -eq 4 ]
  [ "${_PFD_REMAINING[0]}" = "--bypass" ]
  [ "${_PFD_REMAINING[1]}" = "gaia-threat-model" ]
  [ "${_PFD_REMAINING[2]}" = "--reason" ]
  [ "${_PFD_REMAINING[3]}" = "bypass only" ]
}

@test "--reason value starting with -- is preserved literally" {
  source "$PARSER"
  _parse_force_design --force-design --reason "--this-is-the-reason"
  [ "$FORCE_DESIGN_REASON" = "--this-is-the-reason" ]
}

@test "unowned --reason (no preceding flag) passes through" {
  source "$PARSER"
  _parse_force_design --reason "orphan reason"
  [ -z "$FORCE_DESIGN_REASON" ]
  [ "${#_PFD_REMAINING[@]}" -eq 2 ]
  [ "${_PFD_REMAINING[0]}" = "--reason" ]
  [ "${_PFD_REMAINING[1]}" = "orphan reason" ]
}

# Mutant: restore greedy consumption — must turn a binding test red
@test "mutant: greedy reason consumption misroutes the bypass reason" {
  source "$PARSER"
  # Save original function
  local orig_fn
  orig_fn="$(declare -f _parse_force_design)"

  # Redefine with greedy consumption (old bug)
  _parse_force_design() {
    FORCE_DESIGN=""
    FORCE_DESIGN_REASON=""
    FORCE_DESIGN_ENTRY_POINT=""
    FORCE_DESIGN_SPRINT_ID=""
    _PFD_REMAINING=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --force-design) FORCE_DESIGN=1; shift ;;
        --reason) FORCE_DESIGN_REASON="$2"; shift 2 ;;
        --entry-point) FORCE_DESIGN_ENTRY_POINT="$2"; shift 2 ;;
        --sprint-id) FORCE_DESIGN_SPRINT_ID="$2"; shift 2 ;;
        *) _PFD_REMAINING+=("$1"); shift ;;
      esac
    done
    export FORCE_DESIGN FORCE_DESIGN_REASON FORCE_DESIGN_ENTRY_POINT FORCE_DESIGN_SPRINT_ID
  }

  # The greedy parser consumes --reason "bypass reason", so _PFD_REMAINING
  # will NOT contain it — which means the bypass has no reason.
  _parse_force_design --bypass gaia-threat-model --reason "bypass reason" --force-design --reason "design reason"

  # FORCE_DESIGN_REASON ends up as "design reason" (last --reason wins in greedy mode)
  # but the bypass's --reason is NOT in _PFD_REMAINING — that is the bug.
  local has_bypass_reason=0
  local i
  for i in "${!_PFD_REMAINING[@]}"; do
    if [ "${_PFD_REMAINING[$i]}" = "--reason" ]; then
      has_bypass_reason=1
    fi
  done
  [ "$has_bypass_reason" -eq 0 ] || {
    echo "FAIL: greedy mutant did NOT eat the bypass reason — mutant is wrong" >&2
    return 1
  }

  # Restore original
  eval "$orig_fn"
}
