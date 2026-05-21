#!/usr/bin/env bats
# path-migration-completion.bats — E97-S1 (ADR-111 migration completion)
#
# Covers TC-PRC-1..5 + TC-BC-1..3.
#
# Asserts that config-hydration.sh and gaia-help/SKILL.md (the two Class A
# consumers identified by AF-2026-05-21-1 Val F3) resolve canonical
# .gaia/config/ and .gaia/artifacts/ paths first, with legacy config/ and
# docs/ fallback retained on pre-migration installs.

load 'test_helper.bash'

setup() {
  common_setup
  PROJECT_ROOT="$( cd "$TEST_TMP" && pwd -P )"
  export CLAUDE_PROJECT_ROOT="$PROJECT_ROOT"
  cd "$PROJECT_ROOT"
  CH="$SCRIPTS_DIR/lib/config-hydration.sh"
  SKILL_MD="$( cd "$BATS_TEST_DIRNAME/../skills/gaia-help" && pwd )/SKILL.md"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT _GAIA_PATHS_LOADED _CONFIG_HYDRATION_LOADED \
        GAIA_CONFIG_DIR GAIA_ARTIFACTS_DIR GAIA_STATE_DIR \
        GAIA_MEMORY_DIR GAIA_CUSTOM_DIR \
        CONFIG_HYDRATION_TARGET
  common_teardown
}

# ---------- Fixture helpers ----------

seed_gaia_canonical() {
  mkdir -p "$PROJECT_ROOT/.gaia/config" "$PROJECT_ROOT/.gaia/artifacts/planning-artifacts"
  cat > "$PROJECT_ROOT/.gaia/config/project-config.yaml" << EOF
project: test
config_phase: full
EOF
}

seed_legacy_only() {
  mkdir -p "$PROJECT_ROOT/config" "$PROJECT_ROOT/docs/planning-artifacts"
  cat > "$PROJECT_ROOT/config/project-config.yaml" << EOF
project: test
config_phase: full
EOF
}

seed_hybrid() {
  seed_gaia_canonical
  seed_legacy_only
  # Marker so we can tell which was read.
  printf 'canonical\n' > "$PROJECT_ROOT/.gaia/config/project-config.yaml"
  printf 'legacy\n' > "$PROJECT_ROOT/config/project-config.yaml"
}

# Helper that drives config-hydration.sh's resolve-target block.
# Sourcing the script defines _config_hydrate_section but never invokes it;
# we invoke a synthetic call that just returns the resolved target via the
# config_hydration_resolve_target helper added by this story.
resolve_target() {
  ( set +e
    # shellcheck source=/dev/null
    source "$CH" >/dev/null 2>&1
    # config_hydration_resolve_target is the new helper (no-op API) added
    # under AC1; if the symbol is missing the test fails fast.
    if ! declare -F config_hydration_resolve_target >/dev/null 2>&1; then
      echo "MISSING_HELPER"; return 1
    fi
    config_hydration_resolve_target
  )
}

# ---------- TC-PRC-1..5: canonical-first resolution ----------

@test "TC-PRC-1: gaia-canonical fixture resolves \${GAIA_CONFIG_DIR}/project-config.yaml" {
  seed_gaia_canonical
  run resolve_target
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/config/project-config.yaml" ]]
}

@test "TC-PRC-2: hybrid fixture prefers .gaia/config/ over legacy config/" {
  seed_hybrid
  run resolve_target
  [ "$status" -eq 0 ]
  [[ "$output" == *"/.gaia/config/project-config.yaml" ]]
  [[ "$output" != *"$PROJECT_ROOT/config/project-config.yaml" ]]
}

@test "TC-PRC-3: gaia-only project-phase detector references .gaia/ first" {
  # SKILL.md sweep: detector code at lines 60-90 must reference .gaia/ artifacts/config.
  run grep -nE '\.gaia/config|\.gaia/artifacts' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # At least one canonical-first reference in the detector code block (lines 60-90).
  run awk 'NR>=60 && NR<=95 && /\.gaia\/(config|artifacts)/{c++} END{exit !c}' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-PRC-4: pre-migration fixture (legacy only) still resolves legacy config/" {
  seed_legacy_only
  run resolve_target
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJECT_ROOT/config/project-config.yaml" ]]
}

@test "TC-PRC-5: legacy-only-baseline byte-identical to pre-fix" {
  # AC3 invariant: legacy resolution behavior is unchanged.
  seed_legacy_only
  run resolve_target
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Verifies the legacy path is returned exactly as composed.
  expected="$PROJECT_ROOT/config/project-config.yaml"
  [ "$output" = "$expected" ]
}

# ---------- TC-BC-1..3: back-compat invariants ----------

@test "TC-BC-1: config-hydration helper present on pre-migration install" {
  seed_legacy_only
  run bash -c "source '$CH' && declare -F config_hydration_resolve_target"
  [ "$status" -eq 0 ]
}

@test "TC-BC-2: gaia-help detector code still contains legacy fallback" {
  # AC3 back-compat: legacy paths must still appear as fallback in the detector.
  run grep -nE '^[^#]*config/project-config\.yaml|^[^#]*docs/planning-artifacts' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-BC-3: hybrid install with stale legacy file — canonical wins, legacy still readable" {
  seed_hybrid
  # Canonical wins
  run resolve_target
  [[ "$output" == *"/.gaia/config/project-config.yaml" ]]
  # Legacy file still on disk (we don't delete it)
  [ -f "$PROJECT_ROOT/config/project-config.yaml" ]
  # CLAUDE_PROJECT_ROOT override pointing at non-existent .gaia/config falls back to legacy
  rm -rf "$PROJECT_ROOT/.gaia"
  unset _CONFIG_HYDRATION_LOADED _GAIA_PATHS_LOADED
  run resolve_target
  [[ "$output" == *"$PROJECT_ROOT/config/project-config.yaml" ]]
}
