#!/usr/bin/env bats
# ground-truth-staleness-capstone.bats — E109 verification capstone.
#
# This file owns ONLY the cross-cutting staleness cases that the per-subsection
# sibling files do not cover, plus the static marker-clear anti-pattern guard.
# The TC-GTS-1..21 family is split across FIVE files; ownership is:
#
#   ground-truth-stale-check.bats     → TC-GTS-1..6, 15  (marker/helper)
#   ground-truth-lifecycle-wiring.bats→ TC-GTS-7..14       (triggers)
#   stale-flag-registry.bats          → TC-GTS-18          (registry)
#   memory-loader.bats                → TC-GTS-19, 20       (backstop)
#   ground-truth-staleness-capstone.bats (THIS FILE) → TC-GTS-16, 17, 21
#
# Cross-cutting cases (this file):
#   TC-GTS-16 — the .ground-truth-stale marker is cleared ONLY by a successful
#               refresh (refresh finalize success path); it survives unrelated
#               operations.
#   TC-GTS-17 — a FAILED refresh does NOT clear the marker (no false-clear):
#               finalize.sh dies on a required step BEFORE the clear, so the
#               marker survives.
#   TC-GTS-21 — the manual `--agent all` full-refresh carve-out is unchanged:
#               the refresh SKILL.md still documents it, while the auto-trigger
#               diagnostics (gate lib) instruct `--incremental` and NEVER
#               `--agent all`.
#
# Static anti-pattern guard (T-GTR-4 residual-reducer):
#   The `.ground-truth-stale` REMOVAL (rm/clear of the marker) appears ONLY in
#   the refresh success path (gaia-refresh-ground-truth/scripts/finalize.sh) and
#   nowhere else in the framework script tree. This statically binds the clear
#   to a successful refresh, mirroring the sentinel↔dispatch static binding.
#
# Determinism: per-test tmpdir; MEMORY_PATH + CHECKPOINT_PATH pinned into the
# tmpdir so refresh finalize.sh's pre-clear steps (checkpoint.sh write,
# lifecycle-event.sh emit) behave deterministically on any CI host CWD.

load 'test_helper.bash'

setup() {
  common_setup

  # Refresh finalize.sh — the sanctioned (and only) marker-clear site.
  REFRESH_FINALIZE="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-refresh-ground-truth/scripts" && pwd)/finalize.sh"
  # Shared gate lib — the auto-trigger diagnostic source (S2).
  GATE_LIB="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)/ground-truth-gate.sh"
  # Refresh SKILL.md — documents the manual --agent all carve-out (FR-578).
  REFRESH_SKILL="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-refresh-ground-truth" && pwd)/SKILL.md"
  # Framework script trees the anti-pattern guard sweeps.
  SCRIPTS_TREE="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  SKILLS_TREE="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export REFRESH_FINALIZE GATE_LIB REFRESH_SKILL SCRIPTS_TREE SKILLS_TREE

  # Per-test project tree. MEMORY_PATH carries the marker; CHECKPOINT_PATH is
  # pinned into the tmpdir so checkpoint.sh (a required pre-clear step in
  # finalize.sh) writes deterministically instead of falling back to a
  # CWD-relative resolve-config path (the S2 Linux-CI failure mode).
  PROJ="$TEST_TMP/proj"
  MEM="$PROJ/.gaia/memory"
  CKPT="$MEM/checkpoints"
  MARKER="$MEM/.ground-truth-stale"
  mkdir -p "$CKPT"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  export MEMORY_PATH="$MEM"
  export CHECKPOINT_PATH="$CKPT"
  export PROJ MEM CKPT MARKER
}

teardown() { common_teardown; }

# Write the staleness marker into the per-test MEMORY_PATH.
write_marker() { : > "$MARKER"; }

# ---------------------------------------------------------------------------
# TC-GTS-16 — marker cleared ONLY by a successful refresh; survives other ops.
# ---------------------------------------------------------------------------

@test "successful refresh finalize clears the .ground-truth-stale marker" {
  write_marker
  [ -f "$MARKER" ]
  run bash "$REFRESH_FINALIZE"
  [ "$status" -eq 0 ]
  # The success path cleared the marker.
  [ ! -f "$MARKER" ]
  # And it announced the clear (single log line).
  [[ "$output" == *"cleared"* ]]
  [[ "$output" == *".ground-truth-stale"* ]]
}

@test "marker survives an unrelated operation (only refresh clears it)" {
  write_marker
  # An unrelated read-only operation: load ground-truth via memory-loader.
  # Per TC-GTS-19/20 (memory-loader.bats) the backstop NEVER clears the marker.
  mkdir -p "$MEM/val-sidecar"
  printf 'GT\n' > "$MEM/val-sidecar/ground-truth.md"
  run bash "$SCRIPTS_TREE/memory-loader.sh" val ground-truth
  [ "$status" -eq 0 ]
  # The marker is untouched by a non-refresh op.
  [ -f "$MARKER" ]
}

@test "clearing is idempotent — refresh with no marker present is a no-op success" {
  # No marker written. A successful refresh must still exit 0 (rm -f no-op).
  [ ! -f "$MARKER" ]
  run bash "$REFRESH_FINALIZE"
  [ "$status" -eq 0 ]
  [ ! -f "$MARKER" ]
}

# ---------------------------------------------------------------------------
# TC-GTS-17 — a FAILED refresh does NOT clear the marker (no false-clear).
# ---------------------------------------------------------------------------
# Drive the failure by making a REQUIRED finalize step die BEFORE the clear:
# point CHECKPOINT_PATH at a path that cannot be created (a non-directory
# parent), so checkpoint.sh write fails → finalize.sh `die`s non-zero before
# ever reaching the marker-clear. The clear is positioned AFTER the steps that
# can die, so a die means the marker is never removed.

@test "a failed refresh (finalize dies before the clear) leaves the marker intact" {
  write_marker
  [ -f "$MARKER" ]
  # Force the checkpoint pre-clear step to fail: CHECKPOINT_PATH's parent is a
  # regular file, so checkpoint.sh's `mkdir -p "$CHECKPOINT_PATH"` cannot create
  # the directory and the write dies non-zero.
  local blocker="$TEST_TMP/blocker_file"
  : > "$blocker"
  CHECKPOINT_PATH="$blocker/checkpoints" run bash "$REFRESH_FINALIZE"
  # finalize.sh exited non-zero (failed refresh).
  [ "$status" -ne 0 ]
  # The marker was NOT cleared — no false-clear on failure.
  [ -f "$MARKER" ]
}

@test "the marker-clear is positioned AFTER the steps that can die" {
  # Static structural proof: in finalize.sh, both required steps that can `die`
  # (checkpoint write, lifecycle-event emit) must appear BEFORE the marker-clear
  # rm. If the clear ever moved above a die-capable step, a failed refresh could
  # false-clear the marker (the TC-GTS-17 contract). This binds ordering, not
  # just presence.
  local clear_line ckpt_die_line lifecycle_die_line
  clear_line="$(grep -n 'rm -f "\$marker"' "$REFRESH_FINALIZE" | head -1 | cut -d: -f1)"
  ckpt_die_line="$(grep -n 'checkpoint.sh write failed' "$REFRESH_FINALIZE" | head -1 | cut -d: -f1)"
  lifecycle_die_line="$(grep -n 'lifecycle-event.sh emit failed' "$REFRESH_FINALIZE" | head -1 | cut -d: -f1)"
  [ -n "$clear_line" ]
  [ -n "$ckpt_die_line" ]
  [ -n "$lifecycle_die_line" ]
  [ "$clear_line" -gt "$ckpt_die_line" ]
  [ "$clear_line" -gt "$lifecycle_die_line" ]
}

# ---------------------------------------------------------------------------
# TC-GTS-21 — manual `--agent all` carve-out unchanged; auto-triggers never use it.
# ---------------------------------------------------------------------------

@test "refresh SKILL.md still documents the manual --agent all full-refresh carve-out" {
  [ -f "$REFRESH_SKILL" ]
  # The manual full-refresh carve-out is documented (FR-578).
  grep -q -- '--agent all' "$REFRESH_SKILL"
}

@test "the auto-trigger gate diagnostic instructs --incremental, never --agent all" {
  [ -f "$GATE_LIB" ]
  # The auto-trigger remediation hint points at the incremental refresh.
  grep -q -- '--incremental' "$GATE_LIB"
  # And no EXECUTABLE (non-comment) line emits the full --agent all refresh as a
  # remediation hint. Comments may *prohibit* `--agent all` (that prose is the
  # contract documentation) — strip comment lines before asserting the absence
  # of an actual `--agent all` instruction in the gate's emitted output/hint.
  run bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -- "--agent all"' _ "$GATE_LIB"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# T-GTR-4 anti-pattern guard — clear↔successful-refresh static binding.
# ---------------------------------------------------------------------------
# Greps the whole framework script tree for any REMOVAL of the
# `.ground-truth-stale` marker (rm/unlink/clear). The ONLY file permitted to
# remove it is the refresh success path (gaia-refresh-ground-truth/finalize.sh).
# Any other clear site is an anti-pattern: it would decouple the marker from a
# successful refresh and could false-clear it. This is the load-bearing
# residual-reducer — it mirrors the Val sentinel↔dispatch static binding.

@test "T- guard: the .ground-truth-stale marker-clear appears ONLY in the refresh finalize success path" {
  # Find every line in scripts/ + skills/ that removes the marker. We match an
  # `rm`/`unlink` on the same line that names the marker, plus the canonical
  # `rm -f "$marker"` idiom where $marker is the resolved marker path.
  local offenders
  offenders="$(
    grep -rEln 'ground-truth-stale' "$SCRIPTS_TREE" "$SKILLS_TREE" 2>/dev/null \
    | while IFS= read -r f; do
        # A file is a "clear site" if it contains a removal that targets the
        # marker: either a literal rm/unlink of a *.ground-truth-stale path, or
        # the `rm -f "$marker"` idiom in a file that resolves $marker to the
        # ground-truth-stale path.
        if grep -Eq '(rm|unlink)[^#]*ground-truth-stale' "$f" \
           || { grep -Eq 'marker=.*ground-truth-stale' "$f" \
                && grep -Eq 'rm -f "\$marker"' "$f"; }; then
          printf '%s\n' "$f"
        fi
      done
  )"
  # Exactly one clear site, and it is the refresh finalize.sh.
  [ "$(printf '%s\n' "$offenders" | grep -c .)" -eq 1 ]
  [ "$offenders" = "$REFRESH_FINALIZE" ]
}

@test "T- guard: the refresh finalize success path DOES contain the marker-clear" {
  # The positive half of the binding: the sanctioned site actually clears it.
  grep -Eq 'marker=.*ground-truth-stale' "$REFRESH_FINALIZE"
  grep -Eq 'rm -f "\$marker"' "$REFRESH_FINALIZE"
}

@test "T- guard: the memory-loader backstop must NOT clear the marker" {
  # The lazy backstop (S4) only WARNS; clearing it there would couple a passive
  # read to the refresh contract.
  run grep -Eq '(rm|unlink)[^#]*ground-truth-stale' "$SCRIPTS_TREE/memory-loader.sh"
  [ "$status" -ne 0 ]
}

@test "T- guard: the lifecycle gates must NOT clear the marker" {
  # The blocking/best-effort gates (S2) only detect + diagnose staleness.
  run grep -Eq '(rm|unlink)[^#]*ground-truth-stale' "$GATE_LIB"
  [ "$status" -ne 0 ]
}
