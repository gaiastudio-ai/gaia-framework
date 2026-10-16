#!/usr/bin/env bats
# sprint-state-wrapper-sync.bats — wrapper-sync invariant.
#
# Verifies the secondary copy at
#   plugins/gaia/skills/gaia-dev-story/scripts/sprint-state.sh
# stays in step with the canonical
#   plugins/gaia/scripts/sprint-state.sh
#
# The canonical script is the source of truth and the secondary copy is kept
# byte-identical to it (the post-transition snapshot hook and every other
# change must land in both).  The last test fails on any byte of drift; the
# subcommand tests name the surface a drifted copy would lose.

load 'test_helper.bash'

setup() {
  common_setup
  CANONICAL="$SCRIPTS_DIR/sprint-state.sh"
  WRAPPER="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)/sprint-state.sh"
  export CANONICAL WRAPPER
  # Run from the per-test temp dir: the scripts treat the working directory
  # as the project and create .gaia/state there.
  cd "$TEST_TMP"
}
teardown() { common_teardown; }

# extract_subcommands <help-text-file>
#   Parse the canonical `--help` output and emit one subcommand token per
#   line on stdout. The canonical help format prints a "Usage:" block where
#   each line is of the form
#     "  sprint-state.sh <subcommand>   <args...>"
#   The second whitespace-separated token on each such line is the
#   subcommand name. The block ends at the first non-indented line.
#
#   The `--help` token is excluded — it is a flag, not a subcommand, and
#   wrappers may handle it specially (or print their own help).
#
#   awk pattern uses explicit start/stop state instead of awk's range form
#   to avoid the well-known awk range-bug (gaia-shell-idioms) where
#   /start/,/end/ silently mis-bounds when start and end overlap on a line.
extract_subcommands() {
  local help_file="$1"
  awk '
    /^Usage:[[:space:]]*$/             { in_block = 1; next }
    in_block && /^[^[:space:]]/        { in_block = 0 }
    in_block && /sprint-state\.sh[[:space:]]+[A-Za-z][A-Za-z0-9_-]*/ {
      # $1 = "sprint-state.sh", $2 = subcommand or flag
      if ($2 != "--help" && $2 ~ /^[A-Za-z]/) print $2
    }
  ' "$help_file"
}

@test "sprint-state-wrapper-sync: canonical script exists and is executable" {
  [ -f "$CANONICAL" ]
  [ -x "$CANONICAL" ]
}

@test "sprint-state-wrapper-sync: wrapper script exists and is executable" {
  [ -f "$WRAPPER" ]
  [ -x "$WRAPPER" ]
}

@test "sprint-state-wrapper-sync: canonical --help advertises at least one subcommand" {
  local help_file="$TEST_TMP/canonical-help.txt"
  "$CANONICAL" --help > "$help_file" 2>&1 || true

  local count
  count="$(extract_subcommands "$help_file" | wc -l | tr -d '[:space:]')"

  # Sanity: parser regression guard. If the canonical help format changes
  # in a way that breaks extract_subcommands, this assertion fires before
  # the per-subcommand loop produces a misleading green.
  [ "$count" -ge 1 ]
}

@test "sprint-state-wrapper-sync: wrapper accepts --help" {
  run "$WRAPPER" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]] || [[ "$output" == *"Subcommands:"* ]]
}

@test "sprint-state-wrapper-sync: wrapper accepts every canonical subcommand" {
  local help_file="$TEST_TMP/canonical-help.txt"
  "$CANONICAL" --help > "$help_file" 2>&1 || true

  local subcommands
  subcommands="$(extract_subcommands "$help_file")"
  [ -n "$subcommands" ]

  local missing=()
  local sub
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue

    # Run the wrapper with the subcommand and no args. The wrapper may
    # exit non-zero (usage error from missing required flags) — that is
    # FINE. What we are guarding against is the wrapper's argument parser
    # rejecting the token outright with an "unknown subcommand" error,
    # which is the fingerprint of sync drift.
    run "$WRAPPER" "$sub"

    # Match a few common phrasings of the unknown-subcommand error.
    # sprint-state.sh emits "Unknown subcommand: <name>" — case-insensitive
    # match via shopt -s nocasematch is too invasive for one test; a small
    # alternation pattern is sufficient and explicit.
    if [[ "$output" == *"Unknown subcommand"* ]] \
       || [[ "$output" == *"unknown subcommand"* ]] \
       || [[ "$output" == *"unrecognized command"* ]]; then
      missing+=("$sub")
    fi
  done <<< "$subcommands"

  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'Wrapper rejected %d canonical subcommand(s): %s\n' \
      "${#missing[@]}" "${missing[*]}" >&2
    return 1
  fi
}

@test "sprint-state-wrapper-sync: wrapper copy is byte-identical to the canonical script" {
  run cmp "$CANONICAL" "$WRAPPER"
  [ "$status" -eq 0 ]
}
