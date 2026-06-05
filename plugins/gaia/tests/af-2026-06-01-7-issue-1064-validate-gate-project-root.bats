#!/usr/bin/env bats
# AF-2026-06-01-7 — issue #1064 — validate-gate.sh PROJECT_ROOT resolution.
#
# Before this AF: `PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"` fell straight from
# the env var to $PWD, with nothing in between. When a gate was invoked
# from a working directory other than the project root WITH PROJECT_ROOT
# unset, the script silently mapped artifact paths onto `docs/...` and
# HALTed with false "missing artifact" errors — even when the canonical
# `.gaia/artifacts/<type>/...` location existed at the real project root.
#
# After this AF, resolution precedence is:
#   1. env-var PROJECT_ROOT (unchanged — wins).
#   2. `resolve-config.sh project_root` (new positional exposure).
#   3. walk-up from $PWD looking for `.gaia/config/project-config.yaml`.
#   4. $PWD (last resort, preserves the pre-fix path for callers with
#      no project config at all).
#
# Bash 3.2 compatible. Wired into the cross-platform-portability matrix
# via the standard plugins/gaia/tests/ collection.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VG="$PLUGIN_ROOT/scripts/validate-gate.sh"
  RC="$PLUGIN_ROOT/scripts/resolve-config.sh"
}

teardown() { common_teardown; }

# ===========================================================================
# F-01 — resolve-config.sh now accepts `project_root` as a positional query
# ===========================================================================

@test "AF-32-5 #1064 F-01: resolve-config.sh allowlist includes project_root" {
  run grep -E 'project_root\|planning_artifacts\|implementation_artifacts' "$RC"
  [ "$status" -eq 0 ]
}

@test "AF-32-5 #1064 F-01: resolve-config.sh emit-case prints v_project_root" {
  run grep -F 'project_root)            printf' "$RC"
  [ "$status" -eq 0 ]
}

@test "AF-32-5 #1064 F-01: resolve-config.sh CLI surface project_root exits 0" {
  # Build a minimal-valid fixture project (resolve-config.sh enforces 7 required
  # top-level keys; mirror an existing fixture's shape).
  local proj
  proj="$(mktemp -d -t af325-1064-rc.XXXXXX)"
  mkdir -p "$proj/.gaia/config"
  cat > "$proj/.gaia/config/project-config.yaml" <<YAML
project_root: $proj
project_path: $proj
memory_path: $proj/.gaia/memory
checkpoint_path: $proj/.gaia/memory/checkpoints
installed_path: $proj/_gaia
framework_version: 1.182.9
date: 2026-06-01
YAML
  run env -u PROJECT_ROOT CLAUDE_PROJECT_ROOT="$proj" "$RC" project_root
  [ "$status" -eq 0 ]
  [ "$output" = "$proj" ]
  rm -rf "$proj"
}

# ===========================================================================
# F-02 — validate-gate.sh PROJECT_ROOT resolution helper exists + cites #1064
# ===========================================================================

@test "AF-32-5 #1064 F-02: validate-gate.sh declares _vg_resolve_project_root() helper" {
  run grep -F '_vg_resolve_project_root()' "$VG"
  [ "$status" -eq 0 ]
}

@test "AF-32-5 #1064 F-02: validate-gate.sh helper queries resolve-config.sh as a tier" {
  run grep -F 'resolve-config.sh' "$VG"
  [ "$status" -eq 0 ]
}

@test "AF-32-5 #1064 F-02: validate-gate.sh helper walks up looking for the canonical anchor" {
  run grep -F '.gaia/config/project-config.yaml' "$VG"
  [ "$status" -eq 0 ]
}


# ===========================================================================
# Behavioural — the originally-reported repro path now passes
# ===========================================================================

@test "AF-32-5 #1064 behavioural: gate passes when CWD = project root with PROJECT_ROOT unset" {
  local proj="$(mktemp -d -t af325-1064-a.XXXXXX)"
  mkdir -p "$proj/.gaia/config" "$proj/.gaia/artifacts/planning-artifacts"
  touch "$proj/.gaia/config/project-config.yaml"
  echo "# prd" > "$proj/.gaia/artifacts/planning-artifacts/prd.md"

  cd "$proj"
  run env -u PROJECT_ROOT "$VG" prd_exists
  [ "$status" -eq 0 ]

  cd /
  rm -rf "$proj"
}

@test "AF-32-5 #1064 behavioural: gate passes from a SUBDIR via walk-up with PROJECT_ROOT unset" {
  local proj="$(mktemp -d -t af325-1064-b.XXXXXX)"
  mkdir -p "$proj/.gaia/config" "$proj/.gaia/artifacts/planning-artifacts" "$proj/some/sub/dir"
  touch "$proj/.gaia/config/project-config.yaml"
  echo "# prd" > "$proj/.gaia/artifacts/planning-artifacts/prd.md"

  cd "$proj/some/sub/dir"
  run env -u PROJECT_ROOT "$VG" prd_exists
  [ "$status" -eq 0 ]

  cd /
  rm -rf "$proj"
}

@test "AF-32-5 #1064 behavioural: PROJECT_ROOT env-var STILL wins when set (precedence rule 1)" {
  # Two fixtures: one with the PRD, one without. PROJECT_ROOT points at the
  # one WITH the PRD; CWD is the one WITHOUT. The gate must follow the
  # env var, not the walk-up.
  local with_prd no_prd
  with_prd="$(mktemp -d -t af325-1064-c1.XXXXXX)"
  no_prd="$(mktemp -d -t af325-1064-c2.XXXXXX)"
  mkdir -p "$with_prd/.gaia/config" "$with_prd/.gaia/artifacts/planning-artifacts"
  mkdir -p "$no_prd/.gaia/config"
  touch "$with_prd/.gaia/config/project-config.yaml" "$no_prd/.gaia/config/project-config.yaml"
  echo "# prd" > "$with_prd/.gaia/artifacts/planning-artifacts/prd.md"

  cd "$no_prd"
  run env PROJECT_ROOT="$with_prd" "$VG" prd_exists
  [ "$status" -eq 0 ]

  cd /
  rm -rf "$with_prd" "$no_prd"
}

@test "AF-32-5 #1064 behavioural: legacy last-resort \$PWD fallback preserved when no anchor exists" {
  # A directory with no .gaia/config/ anywhere up to / or $HOME. The
  # gate must NOT crash; it just fails the gate (artifact really is
  # missing at $PWD/docs/...).
  local far="$(mktemp -d -t af325-1064-d.XXXXXX)"
  cd "$far"
  # Walking up from $TMPDIR-subdir to / will not find any .gaia/config/.
  run env -u PROJECT_ROOT "$VG" prd_exists
  # Exit 1 (gate failed) is the correct behaviour here — there really IS
  # no PRD anywhere. The fix is that this no longer SILENTLY shadows a
  # real project's artifacts.
  [ "$status" -eq 1 ]

  cd /
  rm -rf "$far"
}
