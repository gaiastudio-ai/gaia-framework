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
@test "detector returns team from a nested subdir of the project root" {
  run env -u CLAUDE_PROJECT_ROOT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      bash -c "cd '$PROJ/src/components' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "team" ]
}

# TC-ORM-2 — neither signal present → subagent (no false-positive).
@test "detector returns subagent when no signals are set" {
  # No env var, and run from a CWD with no discoverable .gaia/ (a bare tmp dir).
  bare="$BATS_TEST_TMPDIR/bare"; mkdir -p "$bare"
  run env -u CLAUDE_PROJECT_ROOT -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
      bash -c "cd '$bare' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "subagent" ]
}

# TC-ORM-3 — CLAUDE_PROJECT_ROOT override still wins.
@test "CLAUDE_PROJECT_ROOT override is honored (no walk-up needed)" {
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
@test "walk-up is bounded by \$HOME (does not escape upward)" {
  # A sibling tree with NO .gaia/, under a HOME that stops the walk before PROJ.
  sib="$BATS_TEST_TMPDIR/home/elsewhere"; mkdir -p "$sib"
  run env -u CLAUDE_PROJECT_ROOT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      HOME="$BATS_TEST_TMPDIR/home" \
      bash -c "cd '$sib' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  # No .gaia/ discoverable within the HOME-bounded walk → subagent, not team.
  [ "$output" = "subagent" ]
}

# TC-ORM-5 — a child dir carrying its own CONFIG-LESS .gaia/ (runtime state or a
# tracked CI slice, NOT project-config.yaml) must NOT shadow the config-bearing
# project root one level up. The walk-up prefers the nearest ancestor whose
# .gaia/config/project-config.yaml actually exists, so Mode B still engages.
# Regression guard for the silent team→subagent down-shift observed when running
# from inside an in-tree sub-repo (e.g. gaia-public/) that has its own .gaia/.
@test "a config-less child .gaia does not shadow the config-bearing project root" {
  # PROJ has the real config (mode: team). PROJ/subrepo has a .gaia/ with only
  # runtime state — no project-config.yaml.
  mkdir -p "$PROJ/subrepo/.gaia/state" "$PROJ/subrepo/src"
  printf 'placeholder\n' > "$PROJ/subrepo/.gaia/state/run.txt"
  run env -u CLAUDE_PROJECT_ROOT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      bash -c "cd '$PROJ/subrepo/src' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "team" ]
}

# TC-ORM-6 — fallback preserved: when the nearest .gaia/ has no config AND no
# ancestor has a config either, the bare-.gaia/ fallback still resolves a root
# (greenfield / partial-setup back-compat) and terminates cleanly. With no
# config anywhere, the mode is subagent (no team signal).
@test "bare-.gaia fallback still resolves when no config exists anywhere" {
  green="$BATS_TEST_TMPDIR/green"; mkdir -p "$green/.gaia/state" "$green/work"
  run env -u CLAUDE_PROJECT_ROOT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
      bash -c "cd '$green/work' && bash '$DETECT'"
  [ "$status" -eq 0 ]
  [ "$output" = "subagent" ]
}
