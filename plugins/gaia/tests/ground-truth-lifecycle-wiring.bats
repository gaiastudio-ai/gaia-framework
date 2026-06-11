#!/usr/bin/env bats
# ground-truth-lifecycle-wiring.bats — TC-GTS-7..14
#
# Tests the four-point lifecycle wiring of the shared staleness predicate
# (scripts/lib/ground-truth-stale-check.sh) via the shared gate helper
# (scripts/lib/ground-truth-gate.sh) and its consumers:
#
#   BLOCKING set  : sprint-plan Step 0 entry  (ground-truth-gate.sh wrapper)
#                   add-feature finalize.sh   (before the lifecycle-event emit)
#   BEST-EFFORT   : sprint-close finalize.sh  (warn + continue)
#                   story-done transition     (warn + continue)
#
# Contract under test:
#   - Blocking gate: STALE → non-zero exit + diagnostic naming stale
#     ground-truth + the incremental-refresh instruction; FRESH → exit 0.
#   - Best-effort gate: STALE/failure → exit 0 + warning on stderr; FRESH →
#     exit 0 + silent.
#   - Blocking gate fires strictly BEFORE the lifecycle-event emit.
#   - The diagnostic instructs `--incremental`, never `--agent all`.
#
# Determinism: per-test tmpdir; CLAUDE_PROJECT_ROOT + MEMORY_PATH + root
# overrides point into the tmpdir; mtimes are driven by `touch -t`.

load 'test_helper.bash'

setup() {
  common_setup
  LIBDIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  GATE="$LIBDIR/ground-truth-gate.sh"
  export LIBDIR GATE

  PROJ="$TEST_TMP/proj"
  PLANNING="$PROJ/.gaia/artifacts/planning-artifacts"
  IMPL="$PROJ/.gaia/artifacts/implementation-artifacts"
  MEM="$PROJ/.gaia/memory"
  SIDECAR="$MEM/validator-sidecar"
  GT="$SIDECAR/ground-truth.md"
  MARKER="$MEM/.ground-truth-stale"
  mkdir -p "$PLANNING" "$IMPL" "$SIDECAR"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  export MEMORY_PATH="$MEM"
  export GAIA_GT_PLANNING_ROOT="$PLANNING"
  export GAIA_GT_IMPL_ROOT="$IMPL"
  export PLANNING IMPL MEM SIDECAR GT MARKER PROJ
}

teardown() { common_teardown; }

stamp() { touch -t "$2" "$1"; }

# Make the tree STALE: a planning source strictly newer than ground-truth.
make_stale() {
  printf 'gt\n'  > "$GT"
  printf 'prd\n' > "$PLANNING/prd.md"
  stamp "$GT" 202601010000
  stamp "$PLANNING/prd.md" 202601020000
}

# Make the tree FRESH: ground-truth strictly newest.
make_fresh() {
  printf 'prd\n' > "$PLANNING/prd.md"
  printf 'gt\n'  > "$GT"
  stamp "$PLANNING/prd.md" 202601010000
  stamp "$GT" 202601020000
}

# ---------------------------------------------------------------------------
# TC-GTS-7 (AC1): sprint-plan entry gate halts-with-diagnostic on stale.
# ---------------------------------------------------------------------------
@test "TC-GTS-7: sprint-plan entry gate halts-with-diagnostic on stale" {
  make_stale
  run bash "$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/scripts/ground-truth-gate.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi 'ground.truth'
  printf '%s\n' "$output" | grep -qi 'stale'
  printf '%s\n' "$output" | grep -qF -- '--incremental'
}

# ---------------------------------------------------------------------------
# TC-GTS-8 (AC1): sprint-plan entry gate passes (exit 0) when fresh.
# ---------------------------------------------------------------------------
@test "TC-GTS-8: sprint-plan entry gate passes (exit 0) when fresh" {
  make_fresh
  run bash "$BATS_TEST_DIRNAME/../skills/gaia-sprint-plan/scripts/ground-truth-gate.sh"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-GTS-9 (AC2): add-feature completion gate halts-with-diagnostic on stale.
# ---------------------------------------------------------------------------
@test "TC-GTS-9: add-feature finalize gate halts-with-diagnostic on stale" {
  make_stale
  # FEATURE_ID unset → Val-sentinel guard is skipped; the staleness gate must
  # still fire and BLOCK before the lifecycle-event emit.
  run bash "$BATS_TEST_DIRNAME/../skills/gaia-add-feature/scripts/finalize.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi 'ground.truth'
  printf '%s\n' "$output" | grep -qi 'stale'
  printf '%s\n' "$output" | grep -qF -- '--incremental'
}

# ---------------------------------------------------------------------------
# TC-GTS-10 (AC2/AC5): blocking gate fires strictly BEFORE the lifecycle
# event emit. We assert the finalize.sh DID NOT reach the emit by checking the
# "lifecycle event emitted" success log is absent, and that the staleness
# diagnostic IS present.
# ---------------------------------------------------------------------------
@test "TC-GTS-10: add-feature blocking gate fires strictly before lifecycle-event emit" {
  make_stale
  run bash "$BATS_TEST_DIRNAME/../skills/gaia-add-feature/scripts/finalize.sh"
  [ "$status" -ne 0 ]
  # The gate diagnostic must appear...
  printf '%s\n' "$output" | grep -qi 'stale'
  # ...and the lifecycle-event success line must NOT (emit never reached).
  ! printf '%s\n' "$output" | grep -qi 'lifecycle event emitted'
}

# ---------------------------------------------------------------------------
# TC-GTS-11 (AC2): blocking gate not bypassed by yolo / best-effort flags.
# ---------------------------------------------------------------------------
@test "TC-GTS-11: blocking gate not bypassed by yolo/best-effort env flags" {
  make_stale
  GAIA_YOLO_MODE=1 GAIA_YOLO_FLAG=1 GAIA_GT_BEST_EFFORT=1 \
    run bash "$BATS_TEST_DIRNAME/../skills/gaia-add-feature/scripts/finalize.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi 'stale'
}

# ---------------------------------------------------------------------------
# TC-GTS-12 (AC3): sprint-close warns-and-continues on stale (exit 0, stderr).
# ---------------------------------------------------------------------------
@test "TC-GTS-12: sprint-close finalize warns-and-continues on stale" {
  make_stale
  run bash "$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/finalize.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi 'ground.truth'
  printf '%s\n' "$output" | grep -qi 'stale'
}

# ---------------------------------------------------------------------------
# TC-GTS-13 (AC3): story-done warns-and-continues on stale. Exercise the
# best-effort gate directly through the shared gate helper (the same function
# transition-story-status.sh sources in its --to done path), proving warn +
# exit 0 even when STALE.
# ---------------------------------------------------------------------------
@test "TC-GTS-13: story-done best-effort gate warns-and-continues on stale" {
  make_stale
  run bash -c '. "$GATE"; gt_gate_best_effort "story-done"'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qi 'stale'
}

# ---------------------------------------------------------------------------
# TC-GTS-14 (AC3): best-effort points are silent when fresh.
# ---------------------------------------------------------------------------
@test "TC-GTS-14: best-effort gate is silent when fresh" {
  make_fresh
  run bash -c '. "$GATE"; gt_gate_best_effort "story-done"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "TC-GTS-14b: sprint-close finalize is quiet about ground-truth when fresh" {
  make_fresh
  run bash "$BATS_TEST_DIRNAME/../skills/gaia-sprint-close/scripts/finalize.sh"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -qi 'ground.truth.*stale'
}

# ---------------------------------------------------------------------------
# AC4: STALE diagnostic instructs the INCREMENTAL refresh, never --agent all.
# ---------------------------------------------------------------------------
@test "AC4: blocking diagnostic instructs --incremental and never --agent all" {
  make_stale
  run bash -c '. "$GATE"; gt_gate_blocking "sprint-plan-entry"'
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF -- '--incremental'
  ! printf '%s\n' "$output" | grep -qF -- '--agent all'
}

@test "AC4b: best-effort diagnostic instructs --incremental and never --agent all" {
  make_stale
  run bash -c '. "$GATE"; gt_gate_best_effort "sprint-close"'
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- '--incremental'
  ! printf '%s\n' "$output" | grep -qF -- '--agent all'
}

# ---------------------------------------------------------------------------
# Perf-guard (mandatory precondition): tie-detection performs ZERO per-file
# stat forks. We trace the predicate on a tie tree with `stat` shadowed by a
# counter; the count must be small and bounded (NOT O(file-count)).
# ---------------------------------------------------------------------------
@test "PERF-GUARD: tie-detection issues no per-file stat fork (bounded stat count)" {
  # Worst case for the OLD per-file probe: NO tie and NO newer file — every
  # artifact is strictly OLDER than ground-truth. The old probe had to walk +
  # stat-fork EVERY file to confirm "no equal-mtime sibling" before returning
  # FRESH. The optimized probe answers this with find-walks only, zero
  # per-file forks.
  local i
  for i in $(seq 1 60); do printf 'x' > "$PLANNING/p$i.md"; done
  for i in $(seq 1 60); do printf 'x' > "$IMPL/i$i.md"; done
  printf 'gt\n' > "$GT"
  # All artifacts strictly older than ground-truth → FRESH via the tie probe.
  touch -t 202601010000 "$PLANNING"/p*.md "$IMPL"/i*.md
  touch -t 202602020202 "$GT"

  # Shadow `stat` with a wrapper that increments a counter file, then delegates.
  local shim="$TEST_TMP/bin"
  mkdir -p "$shim"
  local counter="$TEST_TMP/stat.count"
  : > "$counter"
  cat > "$shim/stat" <<SHIM
#!/usr/bin/env bash
printf 'x' >> "$counter"
exec /usr/bin/stat "\$@"
SHIM
  chmod +x "$shim/stat"

  LIB="$LIBDIR/ground-truth-stale-check.sh"
  run env PATH="$shim:$PATH" bash -c '. "'"$LIB"'"; check_ground_truth_staleness'
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]   # all older, no tie, none newer → FRESH

  local n
  n="$(wc -c < "$counter" | tr -d ' ')"
  # With 120 artifact files all older than gt, the OLD per-file probe forks
  # stat ~120+ times (it must confirm no equal-mtime sibling). The optimized
  # probe reads ground-truth's mtime at most a couple of times and NEVER per
  # file. Bound generously well below the file count.
  [ "$n" -lt 10 ]
}
