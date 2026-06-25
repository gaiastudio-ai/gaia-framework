#!/usr/bin/env bats
# ground-truth-stale-check.bats — TC-GTS-1..6 + TC-GTS-15 + TC-GTS-22..30
#
# Tests the shared ground-truth staleness predicate:
#   scripts/lib/ground-truth-stale-check.sh :: check_ground_truth_staleness
#
# Contract under test:
#   - Compared roots = planning-artifacts + implementation-artifacts ONLY.
#   - STALE when any tracked source under a compared root is newer than the
#     validator-sidecar ground-truth.md.
#   - FRESH when ground-truth.md is the newest path → writes NO marker.
#   - UNCERTAIN (absent gt.md / equal mtime / unresolvable) → STALE (fail-safe).
#   - On STALE: write the `.ground-truth-stale` marker at the TOP LEVEL of the
#     memory dir; never touch compared-input mtimes; idempotent.
#   - Same-session exemption: a file newer than ground-truth whose mtime is >=
#     the current session's start reference is "same-session materialization" and
#     does NOT cause STALE. A file newer than ground-truth AND older than the
#     session start is genuine prior-session drift → STALE. When session identity
#     is unavailable the exemption is disabled (CI/cron parity).
#
# Determinism: per-test tmpdir, CLAUDE_PROJECT_ROOT + MEMORY_PATH + root
# overrides all point into the tmpdir; mtimes are driven by `touch -t`.

load 'test_helper.bash'

setup() {
  common_setup
  LIB="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/ground-truth-stale-check.sh"
  export LIB

  # Isolated project tree under the per-test tmpdir.
  PROJ="$TEST_TMP/proj"
  PLANNING="$PROJ/.gaia/artifacts/planning-artifacts"
  IMPL="$PROJ/.gaia/artifacts/implementation-artifacts"
  MEM="$PROJ/.gaia/memory"
  SIDECAR="$MEM/validator-sidecar"
  GT="$SIDECAR/ground-truth.md"
  MARKER="$MEM/.ground-truth-stale"
  mkdir -p "$PLANNING" "$IMPL" "$SIDECAR"

  # Env hygiene: clear session variables so no-session tests deterministically
  # exercise the pure-mtime path even when bats runs inside a Claude Code session.
  unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID GAIA_GT_SESSION_REF

  export CLAUDE_PROJECT_ROOT="$PROJ"
  export MEMORY_PATH="$MEM"
  export GAIA_GT_PLANNING_ROOT="$PLANNING"
  export GAIA_GT_IMPL_ROOT="$IMPL"
  export PLANNING IMPL MEM SIDECAR GT MARKER PROJ
}

teardown() { common_teardown; }

# Helper: stamp a file at an explicit mtime (UTC, deterministic).
stamp() { touch -t "$2" "$1"; }

# Helper: portable epoch-seconds mtime. GNU coreutils `stat -f` means
# `--file-system` and succeeds with the wrong value, so probe GNU (`-c %Y`)
# FIRST and only fall back to BSD (`-f %m`); validate all-digits.
mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" ;; esac
  printf '%s' "$m"
}

# TC-GTS-1 (AC1): a tracked source newer than ground-truth.md → STALE.
@test "planning source newer than ground-truth → STALE" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601020000   # newer than gt

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

@test "implementation-tree source newer than ground-truth → STALE" {
  printf 'gt\n' > "$GT"
  printf 'story\n' > "$IMPL/story.md"
  stamp "$GT" 202601010000
  stamp "$IMPL/story.md" 202601020000

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-2 (AC2): ground-truth.md newest → FRESH, and NO marker written.
@test "ground-truth newest → FRESH and no marker written" {
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'story\n' > "$IMPL/story.md"
  printf 'gt\n' > "$GT"
  stamp "$PLANNING/prd.md" 202601010000
  stamp "$IMPL/story.md" 202601010000
  stamp "$GT" 202601020000   # newest

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-2 also asserts test-artifacts / state are NOT compared roots (AC1).
@test "newer test-artifacts/state files do NOT make it stale (out of compared roots)" {
  mkdir -p "$PROJ/.gaia/artifacts/test-artifacts" "$PROJ/.gaia/state"
  printf 'gt\n' > "$GT"
  printf 'tp\n' > "$PROJ/.gaia/artifacts/test-artifacts/test-plan.md"
  printf 'ss\n' > "$PROJ/.gaia/state/sprint-status.yaml"
  stamp "$GT" 202601010000
  stamp "$PROJ/.gaia/artifacts/test-artifacts/test-plan.md" 202601090000
  stamp "$PROJ/.gaia/state/sprint-status.yaml" 202601090000

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-3 (AC3): UNCERTAIN → STALE. Absent gt.md.
@test "absent ground-truth.md → STALE (fail-safe)" {
  printf 'prd\n' > "$PLANNING/prd.md"
  # No $GT file at all.
  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-3 (AC3): equal mtime → STALE (find -newer is strict; tie is ambiguous → fail-safe).
@test "equal mtime source vs ground-truth → STALE (fail-safe)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  touch -r "$GT" "$PLANNING/prd.md"   # exactly equal mtime

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-3 (AC3): unresolvable / missing memory dir → STALE.
@test "unresolvable ground-truth (missing sidecar dir) → STALE" {
  rm -rf "$SIDECAR"
  printf 'prd\n' > "$PLANNING/prd.md"
  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-4 (AC3): CI checkout mtime-reset — all files get the SAME fresh mtime.
# find -newer is strict so equal mtimes are not "newer"; tie → UNCERTAIN → STALE.
# This guards against a false-negative (false-FRESH) on a CI checkout.
@test "CI checkout resets all mtimes equal → UNCERTAIN → STALE (no false-negative)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'story\n' > "$IMPL/story.md"
  # Simulate a git checkout: every tracked file stamped identically.
  touch -t 202602020202 "$GT" "$PLANNING/prd.md" "$IMPL/story.md"

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-5 (AC5/AC6): sourceable smoke — file sources cleanly and exposes the fn.
@test "helper is sourceable and exposes check_ground_truth_staleness" {
  run bash -c '. "$LIB"; type -t check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "sourcing the helper has no side effects (writes no marker on load)" {
  printf 'gt\n' > "$GT"
  stamp "$GT" 202601010000
  run bash -c '. "$LIB"; true'
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-6 (AC4): idempotent + read-only w.r.t. compared inputs.
@test "STALE run is idempotent and never mutates input mtimes" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'story\n' > "$IMPL/story.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601050000   # newer → STALE
  stamp "$IMPL/story.md" 202601030000

  # Capture input mtimes before.
  before_prd="$(mtime "$PLANNING/prd.md")"
  before_story="$(mtime "$IMPL/story.md")"
  before_gt="$(mtime "$GT")"

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Second run — still STALE, marker still present (idempotent).
  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Input mtimes unchanged.
  after_prd="$(mtime "$PLANNING/prd.md")"
  after_story="$(mtime "$IMPL/story.md")"
  after_gt="$(mtime "$GT")"
  [ "$before_prd" = "$after_prd" ]
  [ "$before_story" = "$after_story" ]
  [ "$before_gt" = "$after_gt" ]
}

# TC-GTS-15 (AC4): STALE verdict writes the marker at the marker path,
# discoverable by a maxdepth-1 `_memory/.*-stale` scan.
@test "STALE writes .ground-truth-stale marker at memory-dir top level" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601020000

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Discoverable by the registry scanner's maxdepth-1 contract.
  run bash -c 'find "$MEM" -maxdepth 1 -type f -name ".*-stale"'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF '.ground-truth-stale'
}

# ---------------------------------------------------------------------------
# Same-session exemption (TC-GTS-22..25).
#
# Timeline for deterministic testing (UTC touch -t stamps):
#   gt_mtime      = 202601010000  (Jan 1 — ground-truth.md)
#   prior_file    = 202601020000  (Jan 2 — newer than gt, OLDER than session)
#   session_start = 202601030000  (Jan 3 — session begins)
#   same_file     = 202601040000  (Jan 4 — newer than gt AND >= session start)
#
# GAIA_GT_SESSION_REF is the test-override epoch for the session start.
# CLAUDE_CODE_SESSION_ID signals "a session is active" (any non-empty value).
# ---------------------------------------------------------------------------

# Helper: compute the epoch for a deterministic touch stamp.
epoch_of() {
  local f="$TEST_TMP/.epoch_probe"
  printf '' > "$f"
  TZ=UTC touch -t "$1" "$f"
  mtime "$f"
}

# TC-GTS-22: a source newer than gt but written within the current session
# (mtime >= session-start ref) → FRESH (the exemption).
@test "same-session file newer than gt is exempt → FRESH (AC1)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601040000   # newer than gt, within session

  local session_epoch
  session_epoch="$(epoch_of 202601030000)"

  CLAUDE_CODE_SESSION_ID="test-session-1" \
  GAIA_GT_SESSION_REF="$session_epoch" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-23: a source newer than gt AND older than session start (prior-session
# drift) → STALE (still blocks).
@test "prior-session file newer than gt but before session start → STALE (AC2)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601020000   # newer than gt, BEFORE session

  local session_epoch
  session_epoch="$(epoch_of 202601030000)"

  CLAUDE_CODE_SESSION_ID="test-session-2" \
  GAIA_GT_SESSION_REF="$session_epoch" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]
}

# TC-GTS-24: session identity unavailable (CLAUDE_CODE_SESSION_ID unset) →
# behaves as today: any newer file → STALE (fail-safe / CI parity).
@test "no session identity → no exemption, newer file → STALE (AC3)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601040000   # newer than gt

  # Explicitly unset both session signals.
  unset CLAUDE_CODE_SESSION_ID
  unset CLAUDE_SESSION_ID
  unset GAIA_GT_SESSION_REF

  run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# TC-GTS-25: mixed — one file is same-session (exempt), another is prior-session
# (not exempt) → STALE (the prior-session file dominates).
@test "mixed same-session and prior-session files → prior-session dominates → STALE (AC4)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'story\n' > "$IMPL/story.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601040000   # same-session (exempt)
  stamp "$IMPL/story.md" 202601020000     # prior-session (NOT exempt)

  local session_epoch
  session_epoch="$(epoch_of 202601030000)"

  CLAUDE_CODE_SESSION_ID="test-session-3" \
  GAIA_GT_SESSION_REF="$session_epoch" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]
}

# TC-GTS-26: session ref set to epoch 0 (edge case) — every file is "within
# session" so everything is exempt → FRESH. Verifies the >= comparison.
@test "session ref at epoch 0 exempts everything newer than gt → FRESH (AC5)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601020000   # newer than gt

  CLAUDE_CODE_SESSION_ID="test-session-4" \
  GAIA_GT_SESSION_REF="0" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-27: existing fail-safes (absent gt, tie-window) still hold even when
# a session is active. The exemption does not weaken them.
@test "absent gt still STALE even with active session (fail-safe preserved) (AC6)" {
  printf 'prd\n' > "$PLANNING/prd.md"
  # No $GT file.
  local session_epoch
  session_epoch="$(epoch_of 202601030000)"

  CLAUDE_CODE_SESSION_ID="test-session-5" \
  GAIA_GT_SESSION_REF="$session_epoch" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

@test "equal-mtime tie still STALE even with active session (fail-safe preserved) (AC7)" {
  printf 'gt\n' > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601030000
  touch -r "$GT" "$PLANNING/prd.md"   # exact mtime tie

  local session_epoch
  session_epoch="$(epoch_of 202601020000)"   # session started before both

  CLAUDE_CODE_SESSION_ID="test-session-6" \
  GAIA_GT_SESSION_REF="$session_epoch" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

# ---------------------------------------------------------------------------
# Production marker-file session resolution (TC-GTS-28..30).
#
# These tests set CLAUDE_CODE_SESSION_ID WITHOUT GAIA_GT_SESSION_REF, so
# _gts_session_start_epoch resolves via the real <memory>/.gt-session marker
# file path instead of the fast-path test seam.
# ---------------------------------------------------------------------------

# TC-GTS-28: First call in a session (marker absent). The predicate creates
# the marker bound to the session id; a file touched AFTER that implicit
# marker creation has mtime >= session start → exempt → FRESH.
@test "marker-file resolution: first call creates marker, same-session file exempt (AC8)" {
  printf 'gt\n' > "$GT"
  stamp "$GT" 202601010000

  # Invoke the predicate once to implicitly create the .gt-session marker.
  # This first call has no newer source files so it will be FRESH.
  CLAUDE_CODE_SESSION_ID="marker-sess-1" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]

  # Verify the marker was created and contains the session id.
  [ -f "$MEM/.gt-session" ]
  run bash -c 'head -n1 "$MEM/.gt-session"'
  [ "$output" = "marker-sess-1" ]

  # Now write a source file whose mtime is "now" (>= marker creation).
  # It is newer than gt but within the session → exempt.
  printf 'prd\n' > "$PLANNING/prd.md"

  CLAUDE_CODE_SESSION_ID="marker-sess-1" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
  [ ! -e "$MARKER" ]
}

# TC-GTS-29: Session rollover (marker exists with a DIFFERENT session id).
# The predicate detects the mismatch, overwrites the marker (resetting the
# session-start reference to ~now). A file that was newer-than-gt but
# older-than-the-new-session-start is genuine prior-session drift → STALE.
# This is the safety-critical rollover case.
@test "marker-file resolution: session rollover overwrites marker, prior file STALE (AC9)" {
  printf 'gt\n' > "$GT"
  stamp "$GT" 202601010000

  # Pre-create a .gt-session marker for a DIFFERENT session with an OLD mtime.
  mkdir -p "$MEM"
  printf 'old-session-id\n' > "$MEM/.gt-session"
  stamp "$MEM/.gt-session" 202601020000   # old marker

  # Write a source file newer than gt but from the "old" session era.
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$PLANNING/prd.md" 202601030000

  # Now invoke with a DIFFERENT session id. The predicate must:
  #   1. Read .gt-session, see "old-session-id" != "new-session-id"
  #   2. Overwrite marker with "new-session-id" (mtime resets to ~now)
  #   3. prd.md (Jan 3) is newer than gt (Jan 1) but OLDER than the new
  #      session start (~now) → prior-session drift → STALE
  CLAUDE_CODE_SESSION_ID="new-session-id" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Verify the marker was overwritten with the new session id.
  run bash -c 'head -n1 "$MEM/.gt-session"'
  [ "$output" = "new-session-id" ]
}

# TC-GTS-30: Corrupt / empty marker file. The predicate must not crash and
# must produce a sound verdict — the mismatch path re-creates the marker.
@test "marker-file resolution: corrupt marker does not crash, yields sound verdict (AC10)" {
  printf 'gt\n' > "$GT"
  stamp "$GT" 202601010000

  # Write a corrupt (empty) .gt-session marker.
  mkdir -p "$MEM"
  printf '' > "$MEM/.gt-session"
  stamp "$MEM/.gt-session" 202601020000

  # Source file newer than gt.
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$PLANNING/prd.md" 202601030000

  # The empty marker's stored_sid="" != current sid → mismatch → overwrite.
  # Same logic as rollover: prd.md is prior-session drift → STALE.
  CLAUDE_CODE_SESSION_ID="fresh-session" \
    run bash -c 'set -e; . "$LIB"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
  [ -f "$MARKER" ]

  # Verify the marker was overwritten with the current session id.
  run bash -c 'head -n1 "$MEM/.gt-session"'
  [ "$output" = "fresh-session" ]
}
