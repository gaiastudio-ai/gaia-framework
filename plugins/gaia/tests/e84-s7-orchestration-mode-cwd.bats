#!/usr/bin/env bats
# e84-s7-orchestration-mode-cwd.bats — TC-ORM-1..4.
# detect-orchestration-mode.sh must resolve the project root by walking up to
# find .gaia/, so Mode B engages regardless of the prelude's CWD.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DETECT="$PLUGIN/scripts/detect-orchestration-mode.sh"
  # Build an isolated fake project tree with orchestration.mode: team so the
  # real project config (which this repo also has) cannot interfere.
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.gaia/config" "$PROJ/src/components"
  cat > "$PROJ/.gaia/config/project-config.yaml" <<'EOF'
orchestration:
  mode: team
EOF
}

# TC-ORM-1 — from a NESTED SUBDIR, with both signals set, returns team.
@test "TC-ORM-1: detector returns team from a nested subdir of the project root" {
  run env -u CLAUDE_PROJECT_ROOT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      bash -c "cd '$PROJ/src/components' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "team" ]
}

# TC-ORM-2 — neither signal present → subagent (no false-positive).
@test "TC-ORM-2: detector returns subagent when no signals are set" {
  # No env var, and run from a CWD with no discoverable .gaia/ (a bare tmp dir).
  bare="$BATS_TEST_TMPDIR/bare"; mkdir -p "$bare"
  run env -u CLAUDE_PROJECT_ROOT -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
      bash -c "cd '$bare' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "subagent" ]
}

# TC-ORM-3 — CLAUDE_PROJECT_ROOT override still wins.
@test "TC-ORM-3: CLAUDE_PROJECT_ROOT override is honored (no walk-up needed)" {
  # Run from an unrelated CWD; point CLAUDE_PROJECT_ROOT at the fake project.
  bare="$BATS_TEST_TMPDIR/bare2"; mkdir -p "$bare"
  run env CLAUDE_PROJECT_ROOT="$PROJ" CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      bash -c "cd '$bare' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "team" ]
}

# TC-ORM-4 — the walk-up is bounded: it must not escape past $HOME / root and
# pick up an unrelated .gaia/ above $HOME. Set HOME to the project's parent so
# the walk from a sibling dir is bounded and finds nothing.
@test "TC-ORM-4: walk-up is bounded by \$HOME (does not escape upward)" {
  # A sibling tree with NO .gaia/, under a HOME that stops the walk before PROJ.
  sib="$BATS_TEST_TMPDIR/home/elsewhere"; mkdir -p "$sib"
  run env -u CLAUDE_PROJECT_ROOT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      HOME="$BATS_TEST_TMPDIR/home" \
      bash -c "cd '$sib' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  # No .gaia/ discoverable within the HOME-bounded walk → subagent, not team.
  [ "$output" = "subagent" ]
}
