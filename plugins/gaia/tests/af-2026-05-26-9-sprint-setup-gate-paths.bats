#!/usr/bin/env bats
# AF-2026-05-26-9: four F-17-class lifecycle-gate path bugs in the sprint-setup
# path that blocked /gaia-sprint-plan on ADR-072 strategy/-placement projects
# under strict-lifecycle mode. All four delegate path-resolution to
# validate-gate.sh (flat | strategy/ | sharded) while preserving the existing
# strict-mode + bypass-record wrapper.
#
# F1: gaia-sprint-plan/setup.sh traceability gate (bootstrap probe + active gate)
#     accepts all 3 placements, not flat-only.
# F2: gaia-dev-story/setup.sh F-33 gate resolves the sharded index.md form too.
# F3: gaia-readiness-check/setup.sh zero-byte guard resolves all 3 placements
#     before the -s check (no false "exists but empty" on a strategy/ matrix).
# F4: gaia-sprint-plan/setup.sh readiness gate keys off the readiness-report
#     frontmatter status (PASS/CONDITIONAL), not the never-written
#     readiness-check-ledger.yaml.

load 'test_helper.bash'

setup() {
  common_setup
  # AF-2026-06-02-2: derive PLUGIN from $BATS_TEST_DIRNAME directly so the
  # tests don't break under the gaia-public → gaia-framework dir rename
  # (and survive any future working-tree dir rename equally well).
  # $BATS_TEST_DIRNAME is .../plugins/gaia/tests; PLUGIN is one level up.
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
  SP_SETUP="$PLUGIN/skills/gaia-sprint-plan/scripts/setup.sh"
  DS_SETUP="$PLUGIN/skills/gaia-dev-story/scripts/setup.sh"
  RC_SETUP="$PLUGIN/skills/gaia-readiness-check/scripts/setup.sh"
  VALIDATE_GATE="$PLUGIN/scripts/validate-gate.sh"
}

teardown() { common_teardown; }

# --- F1: sprint-plan traceability gate is multi-path ---

@test "AF-26-9 F1: sprint-plan setup delegates traceability to validate-gate.sh (multi-path)" {
  grep -qF 'traceability_exists' "$SP_SETUP"
  grep -qF '_trace_present' "$SP_SETUP"
}

@test "AF-26-9 F1: sprint-plan no longer hardcodes the flat-only TRACE_ART probe" {
  # The old flat-only active-gate assignment is gone.
  run grep -F 'TRACE_ART="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/test-artifacts/traceability-matrix.md"' "$SP_SETUP"
  [ "$status" -ne 0 ]
}

@test "AF-26-9 F1: sprint-plan preserves the strict-mode + bypass wrapper" {
  grep -qF -- '--bypass gaia-trace' "$SP_SETUP"
  grep -qF '_has_bypass_for' "$SP_SETUP"
  grep -qF 'strict_mode_on' "$SP_SETUP"
}

@test "AF-26-9 F1: _trace_present fallback accepts flat | strategy/ | sharded" {
  # AF-2026-05-26-9 (follow-up): the fallback was refactored to build paths from
  # a resolver-aligned base dir ($td = _resolve_test_dir, always ending in
  # test-artifacts) instead of inlining the GAIA_ARTIFACTS_DIR literal. Assert
  # the three placements against the $td-relative form. _resolve_test_dir is the
  # base-dir helper that mirrors validate-gate.sh's PLANNING/TEST_ARTIFACTS
  # precedence (uppercase env → .gaia/artifacts → docs/).
  grep -qF '_resolve_test_dir' "$SP_SETUP"
  for p in '$td/traceability-matrix.md' '$td/strategy/traceability-matrix.md' '$td/traceability-matrix/index.md'; do
    grep -qF "$p" "$SP_SETUP" || { echo "missing placement $p in sprint-plan fallback"; false; }
  done
}

# --- F2: dev-story F-33 gate resolves the sharded form ---

@test "AF-26-9 F2: dev-story setup resolves the sharded traceability-matrix/index.md form" {
  grep -qF 'traceability-matrix/index.md' "$DS_SETUP"
}

@test "AF-26-9 F2: dev-story still resolves strategy/ and flat placements" {
  grep -qF 'strategy/traceability-matrix.md' "$DS_SETUP"
  # flat form is resolved via the $_ta base-dir variable: $_ta/traceability-matrix.md
  grep -qF '$_ta/traceability-matrix.md' "$DS_SETUP"
}

# --- F3: readiness-check zero-byte guard is multi-path ---

@test "AF-26-9 F3: readiness-check resolves all 3 placements before the -s zero-byte check" {
  grep -qF 'strategy/traceability-matrix.md' "$RC_SETUP"
  grep -qF 'traceability-matrix/index.md' "$RC_SETUP"
}

@test "AF-26-9 F3: readiness-check no longer emits the misleading 'exists but empty' for a strategy/ matrix" {
  # The die message was reworded to name all three accepted placements.
  grep -qF 'any accepted placement' "$RC_SETUP"
}

# --- F4: sprint-plan readiness gate keys off the report, not the phantom ledger ---

@test "AF-26-9 F4: sprint-plan readiness gate keys off readiness-report frontmatter status" {
  grep -qF 'readiness_report_exists' "$SP_SETUP"
  grep -qE 'status:\[\[:space:\]\]\*\(PASS\|PASSED\|CONDITIONAL\)' "$SP_SETUP" \
    || grep -qF 'status:[[:space:]]*(PASS|PASSED|CONDITIONAL)' "$SP_SETUP"
}

@test "AF-26-9 F4: sprint-plan no longer greps the never-written ledger verdict line" {
  # The dead `readiness-check-ledger.yaml` verdict grep is gone from the gate.
  run grep -F 'verdict:[[:space:]]*PASSED' "$SP_SETUP"
  [ "$status" -ne 0 ]
}

# --- basis: validate-gate predicates accept the placements the fixes rely on ---

@test "AF-26-9 basis: validate-gate.sh traceability_exists accepts the strategy/ placement" {
  local ta="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$ta/strategy"
  printf 'matrix\n' > "$ta/strategy/traceability-matrix.md"
  TEST_ARTIFACTS="$ta" run bash "$VALIDATE_GATE" traceability_exists
  [ "$status" -eq 0 ]
}

@test "AF-26-9 basis: validate-gate.sh traceability_exists accepts the sharded index.md form" {
  local ta="$BATS_TEST_TMPDIR/test-artifacts"
  mkdir -p "$ta/traceability-matrix"
  printf 'matrix\n' > "$ta/traceability-matrix/index.md"
  TEST_ARTIFACTS="$ta" run bash "$VALIDATE_GATE" traceability_exists
  [ "$status" -eq 0 ]
}

@test "AF-26-9 basis: validate-gate.sh readiness_report_exists accepts the canonical report" {
  local pa="$BATS_TEST_TMPDIR/planning-artifacts"
  mkdir -p "$pa"
  printf -- '---\nstatus: CONDITIONAL\n---\n' > "$pa/readiness-report.md"
  PLANNING_ARTIFACTS="$pa" run bash "$VALIDATE_GATE" readiness_report_exists
  [ "$status" -eq 0 ]
}

# --- follow-up (audit-v2-migration regression): a placeholder readiness-report
#     with NO SV-20 status: field is bootstrap/fixture context, not a hard fail.
#     A real report (status: present) still gates. Mirrors the docs/ idiom the
#     enriched audit fixture uses (uppercase PLANNING_ARTIFACTS/TEST_ARTIFACTS). ---

# Seed a minimal config/project-config.yaml under $1 pointing the artifact dirs
# at the project's docs/ tree — required because setup.sh's FIRST step is
# resolve-config.sh, which dies (exit 1) when no project-config.yaml is found
# (the audit-v2-migration enriched fixture seeds exactly this; without it the
# gate body under test is never reached). Mirrors prepare_enriched_fixture in
# scripts/audit-v2-migration.sh.
_seed_fixture_config() {
  local root="$1" cfg="$1/config/project-config.yaml"
  mkdir -p "$1/config"
  # Full required-field set — resolve-config.sh requires checkpoint_path (and
  # the memory/installed paths) or it dies before the gate runs. Matches
  # prepare_enriched_fixture in scripts/audit-v2-migration.sh.
  cat > "$cfg" <<YAML
framework_version: "1.0.0-fixture"
date: "2026-01-01"
project_root: "$root"
project_path: "."
memory_path: "$root/_memory"
checkpoint_path: "$root/_memory/checkpoints"
installed_path: "$root/_gaia"
planning_artifacts: "$root/docs/planning-artifacts"
implementation_artifacts: "$root/docs/implementation-artifacts"
test_artifacts: "$root/docs/test-artifacts"
YAML
}

@test "AF-26-9 follow-up: statusless placeholder readiness-report → setup warns, exits 0" {
  local root="$BATS_TEST_TMPDIR/proj"
  local pa="$root/docs/planning-artifacts" ta="$root/docs/test-artifacts"
  mkdir -p "$pa" "$ta"
  _seed_fixture_config "$root"
  # Seed a traceability matrix (so the bootstrap-skip does NOT fire — this is
  # the exact condition that exposed the regression) + a STATUSLESS readiness
  # placeholder (no `status:` frontmatter), exactly like the enriched fixture.
  printf '# placeholder\n' > "$ta/traceability-matrix.md"
  printf '# placeholder\n' > "$pa/readiness-report.md"
  run env CLAUDE_SKILL_DIR="$PLUGIN/skills/gaia-sprint-plan" \
          CLAUDE_PROJECT_ROOT="$root" \
          TEST_ARTIFACTS="$ta" PLANNING_ARTIFACTS="$pa" \
          IMPLEMENTATION_ARTIFACTS="$root/docs/implementation-artifacts" \
          bash "$SP_SETUP"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'no SV-20 status: field'
}

@test "AF-26-9 follow-up: real readiness-report with status: FAIL still gates (strict)" {
  local root="$BATS_TEST_TMPDIR/proj2"
  local pa="$root/docs/planning-artifacts" ta="$root/docs/test-artifacts"
  mkdir -p "$pa" "$ta"
  _seed_fixture_config "$root"
  printf '# placeholder\n' > "$ta/traceability-matrix.md"
  # A REAL report carries the SV-20 status: field — status: FAIL is a genuine
  # verdict and must NOT be treated as a stub; the gate still dies in strict mode.
  printf -- '---\nstatus: FAIL\n---\n' > "$pa/readiness-report.md"
  run env CLAUDE_SKILL_DIR="$PLUGIN/skills/gaia-sprint-plan" \
          CLAUDE_PROJECT_ROOT="$root" \
          TEST_ARTIFACTS="$ta" PLANNING_ARTIFACTS="$pa" \
          IMPLEMENTATION_ARTIFACTS="$root/docs/implementation-artifacts" \
          bash "$SP_SETUP"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'no PASS/CONDITIONAL'
}
