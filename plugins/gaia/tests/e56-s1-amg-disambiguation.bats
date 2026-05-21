#!/usr/bin/env bats
# e56-s1-amg-disambiguation.bats — TC-AMG-1..5 conformance suite for the
# harness-Auto-Mode-vs-GAIA-YOLO disambiguation guard.
#
# Story:        E56-S1 (ADR-067 amendment — harness Auto Mode vs GAIA YOLO
#               disambiguation guard)
# Architecture: docs/planning-artifacts/architecture.md §10.32.5
#               ("Harness Auto Mode vs GAIA YOLO — Disambiguation Guard")
# ADR:          ADR-067 (amended 2026-04-28, AF-2026-04-28-5)
# Source:       AF-2026-04-28-5 (bug-report driver)
#
# Coverage matrix (Test Scenarios from the story file):
#   TC-AMG-1  GAIA YOLO active via direct flag        -> is_yolo exit 0
#   TC-AMG-2  GAIA YOLO active via inheritance        -> is_yolo exit 0
#   TC-AMG-3  Non-canonical override falls through    -> is_yolo exit 1
#   TC-AMG-4  Clean env (interactive default)         -> is_yolo exit 1
#   TC-AMG-5  Harness Auto Mode WITHOUT GAIA YOLO     -> is_yolo exit 1
#
# What this suite enforces (regression guard for the disambiguation guard):
#   1. yolo-mode.sh remains the SOLE source of truth for GAIA YOLO routing.
#   2. yolo-mode.sh checks ONLY GAIA_YOLO_FLAG, GAIA_YOLO_MODE,
#      GAIA_YOLO_OVERRIDE, and GAIA_CONTEXT (per architecture §10.30.4).
#   3. yolo-mode.sh MUST NOT branch on harness-Auto-Mode signals
#      (system-reminder text, harness env vars, session metadata).
#   4. A harness-Auto-Mode-only session (no GAIA YOLO env set) yields
#      interactive default — exit 1.
#
# Companion: see e41-s1-yolo-mode.bats for the full env-precedence regression
# matrix. This file is intentionally narrow: only the AF-2026-04-28-5
# disambiguation cases are covered here so future drift on the guard contract
# is caught by a focused suite.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/yolo-mode.sh"
}

teardown() { common_teardown; }

# Strip every YOLO-related env so each test starts from a clean baseline.
# Harness Auto Mode has no env footprint by design (per §10.32.5 dimension
# table: "Detection helper: None — harness owns it"), so the same clean_env
# also represents a "harness-Auto-Mode-only" session for TC-AMG-5.
clean_env() {
  unset GAIA_YOLO_FLAG GAIA_YOLO_MODE GAIA_YOLO_OVERRIDE GAIA_CONTEXT
}

# --- Sanity: helper exists ---------------------------------------------------

@test "amg: yolo-mode.sh exists and is executable" {
  [ -f "$SCRIPT" ]
  [ -x "$SCRIPT" ]
}

# --- TC-AMG-1: GAIA YOLO active via direct flag -----------------------------

@test "TC-AMG-1: GAIA_YOLO_FLAG=1 (direct flag) yields is_yolo exit 0" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_FLAG=1 is_yolo"
  [ "$status" -eq 0 ]
}

# --- TC-AMG-2: GAIA YOLO active via inheritance -----------------------------

@test "TC-AMG-2: GAIA_YOLO_MODE=1 (inheritance) yields is_yolo exit 0" {
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_MODE=1 is_yolo"
  [ "$status" -eq 0 ]
}

# --- TC-AMG-3: Non-canonical override falls through -------------------------

@test "TC-AMG-3: GAIA_YOLO_OVERRIDE=disabled (non-canonical) yields is_yolo exit 1" {
  # Only the literal string "no" is recognized as opt-out (architecture
  # §10.30.4 Rule 2). Any other override value falls through to the default
  # exit-1 branch — i.e., interactive default since no activation flag set.
  clean_env
  run bash -c "source '$SCRIPT' && GAIA_YOLO_OVERRIDE=disabled is_yolo"
  [ "$status" -eq 1 ]
}

# --- TC-AMG-4: Clean env (interactive default) ------------------------------

@test "TC-AMG-4: clean env (no YOLO vars set) yields is_yolo exit 1" {
  clean_env
  run bash -c "source '$SCRIPT' && is_yolo"
  [ "$status" -eq 1 ]
}

# --- TC-AMG-5: Harness Auto Mode WITHOUT GAIA YOLO --------------------------

@test "TC-AMG-5: harness-Auto-Mode-only session (no GAIA YOLO env) yields is_yolo exit 1" {
  # Simulates a session where the Claude Code harness has Auto Mode active
  # (system-reminder injected) but the user has NOT activated GAIA YOLO.
  # Per the §10.32.5 disambiguation guard, the helper has no harness
  # detection by design — so behavior is identical to TC-AMG-4.
  clean_env
  run bash -c "source '$SCRIPT' && is_yolo"
  [ "$status" -eq 1 ]
}

# --- Disambiguation-guard contract assertions (clauses 1 & 2) ---------------
#
# These are documentation-grade structural assertions over yolo-mode.sh
# itself — they fail if a future edit accidentally extends the helper to
# read a harness-injected signal (clause 1) or introduces a system-reminder
# parser (clause 2). Per the §10.32.5 guard clauses 1 and 2.

@test "amg-guard: is_yolo references ONLY canonical YOLO env vars + sentinel path vars" {
  # Build a regex that matches GAIA_<X> references that are NOT canonical.
  # If any such reference exists in is_yolo or its helpers, the guard has
  # been violated.
  #
  # Canonical four (architecture §10.30.4):
  #   GAIA_YOLO_FLAG, GAIA_YOLO_MODE, GAIA_YOLO_OVERRIDE, GAIA_CONTEXT
  #
  # Sentinel path-resolution vars (AF-2026-05-21-4 Finding 2 — added for
  # cross-Bash-tool-call YOLO state persistence). These are NOT auto-mode
  # signals — they only control WHERE the .yolo-active sentinel lives:
  #   GAIA_STATE_DIR        — canonical .gaia/state/ resolution (ADR-111)
  #   GAIA_YOLO_SENTINEL    — explicit sentinel path override (tests)
  #
  # Strategy: extract every GAIA_<TOKEN> occurrence from yolo-mode.sh, then
  # subtract the canonical + sentinel-path allowlist. The remaining set
  # MUST be empty.
  local found
  found="$(grep -oE 'GAIA_[A-Z_]+' "$SCRIPT" | sort -u \
    | grep -vE '^(GAIA_YOLO_FLAG|GAIA_YOLO_MODE|GAIA_YOLO_OVERRIDE|GAIA_CONTEXT|GAIA_STATE_DIR|GAIA_YOLO_SENTINEL)$' \
    || true)"
  [ -z "$found" ]
}

@test "amg-guard: is_yolo does NOT parse harness Auto Mode system-reminder text" {
  # The harness signal is the literal phrase "Auto mode is active" emitted
  # in a system-reminder. yolo-mode.sh MUST NOT contain that string or any
  # known harness-detection token.
  ! grep -qE '(Auto mode is active|auto-mode|harness)' "$SCRIPT"
}

@test "amg-guard: is_yolo body uses ONLY canonical YOLO env vars + sentinel path vars" {
  # Tighter scope: extract just the is_yolo function body and reapply the
  # subtraction. Catches a regression where someone adds a harness check
  # only inside is_yolo while leaving the rest of the file pristine.
  # AF-2026-05-21-4 Finding 2: GAIA_STATE_DIR + GAIA_YOLO_SENTINEL are
  # allowed for sentinel-file path resolution (NOT auto-mode signals).
  local body
  body="$(awk '/^is_yolo\(\)[[:space:]]*\{/,/^\}$/' "$SCRIPT")"
  local found
  found="$(printf '%s\n' "$body" | grep -oE 'GAIA_[A-Z_]+' | sort -u \
    | grep -vE '^(GAIA_YOLO_FLAG|GAIA_YOLO_MODE|GAIA_YOLO_OVERRIDE|GAIA_CONTEXT|GAIA_STATE_DIR|GAIA_YOLO_SENTINEL)$' \
    || true)"
  [ -z "$found" ]
}
