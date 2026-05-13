#!/usr/bin/env bats
# gaia-reconcile-allowlist.bats — fail-closed allowlist contract for E85-S11.
#
# Story: E85-S11 — Reconciler/hydrator allowlist alignment + fail-closed contract.
# Source: AF-2026-05-13-2 sub-fixes (a), (b), (c), (e).
# Test plan: §11.67.14 (TC-RV2-44, TC-RV2-47..52).
# Contract: ADR-098 (allowlist), ADR-101 §6 (reconciler never writes config_phase),
#           ADR-096 (config_phase monotonicity).

setup() {
  PLUGIN_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  HYDRATION="${PLUGIN_ROOT}/scripts/lib/config-hydration.sh"
  RECONCILER="${PLUGIN_ROOT}/scripts/gaia-reconcile-v2.sh"
  SCHEMA="${PLUGIN_ROOT}/schemas/project-config.schema.json"
  FIXTURE="${PLUGIN_ROOT}/tests/fixtures/config-v1-era-missing-33-sections.yaml"

  [ -f "$HYDRATION" ] || skip "config-hydration.sh not found"
  [ -f "$RECONCILER" ] || skip "gaia-reconcile-v2.sh not found"
  [ -f "$SCHEMA" ] || skip "project-config.schema.json not found"
  [ -f "$FIXTURE" ] || skip "fixture not found"

  TMPDIR_TEST="$(mktemp -d -t gaia-reconcile-allowlist.XXXXXX)"
  mkdir -p "$TMPDIR_TEST/config"
  cp "$FIXTURE" "$TMPDIR_TEST/config/project-config.yaml"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && [ -d "$TMPDIR_TEST" ] && rm -rf "$TMPDIR_TEST"
}

_get_allowlist() {
  bash -c "source '$HYDRATION' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_ALLOWLIST[@]}\""
}

_get_managed() {
  bash -c "source '$HYDRATION' 2>/dev/null; printf '%s\n' \"\${_CONFIG_HYDRATION_MANAGED_ELSEWHERE[@]:-}\""
}

@test "TC-RV2-44 — Curated allowlist contains configuration sections, excludes identity/state-machine/user-identity fields" {
  allowlist=$(_get_allowlist)
  managed=$(_get_managed)

  # Inclusion checks: at least these MUST be in the allowlist (representative curated set).
  for required in testing test_execution_bridge sprint review_gate team_conventions \
                  agent_customizations dev_story compliance tools test_execution \
                  severity gates stacks cross_service_tests environments ci_platform \
                  device_targets distribution health_check val_integration ci_cd \
                  platforms project_name sizing_map; do
    printf '%s\n' "$allowlist" | grep -Fxq "$required" || {
      printf 'FAIL: required allowlist member missing: %s\n' "$required" >&2
      return 1
    }
  done

  # Exclusion checks: these MUST NOT be in the allowlist.
  for excluded in project_root project_path memory_path checkpoint_path installed_path \
                  framework_version date config_phase schema_version \
                  user_name communication_language project_kind \
                  project_shape; do
    if printf '%s\n' "$allowlist" | grep -Fxq "$excluded"; then
      printf 'FAIL: forbidden allowlist member present: %s\n' "$excluded" >&2
      return 1
    fi
  done

  # Managed-elsewhere set MUST include the 4 artifact-bucket path fields (Val F2).
  for required_managed in planning_artifacts implementation_artifacts test_artifacts creative_artifacts; do
    printf '%s\n' "$managed" | grep -Fxq "$required_managed" || {
      printf 'FAIL: required managed-elsewhere member missing: %s (Val F2)\n' "$required_managed" >&2
      return 1
    }
  done

  # `project_shape` is deliberately retained in managed-elsewhere as a back-compat
  # shim (Val F3 / story Dev Notes): removed from the allowlist per AC1 because
  # it is NOT in schema v2.0.0, but kept here so legacy test fixtures (e.g.
  # gaia-reconcile-v2.bats write_schema helper) that still declare project_shape
  # do not trip the AC5 hard-error path. Pin this invariant explicitly.
  printf '%s\n' "$managed" | grep -Fxq "project_shape" || {
    printf 'FAIL: project_shape must remain in managed-elsewhere as back-compat shim (Val F3)\n' >&2
    return 1
  }
}

@test "TC-RV2-47 — Reconciler exits 5 with rollback on allowlist-mismatch rc=2" {
  # Setup: synthesize a schema that declares a section neither in
  # _CONFIG_HYDRATION_ALLOWLIST nor in _CONFIG_HYDRATION_MANAGED_ELSEWHERE.
  # The bidirectional invariants (TC-RV2-45, TC-RV2-46) guarantee the
  # production schema never has such a section — this test exercises the
  # fail-closed path that fires if a future schema bump adds a section
  # without an allowlist decision.
  cd "$TMPDIR_TEST"
  # Mirror the plugin layout under tmpdir: real helper + synthetic schema.
  # CLAUDE_PLUGIN_ROOT will point at tmpdir so the reconciler picks up
  # the synthetic schema; the helper is sourced from the same tree.
  mkdir -p schemas scripts/lib
  ln -sf "${PLUGIN_ROOT}/scripts/lib/config-hydration.sh" scripts/lib/config-hydration.sh
  cat > schemas/project-config.schema.json <<'JSON'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "GAIA project-config.yaml — test schema with unclassified section v9.9.9",
  "type": "object",
  "properties": {
    "schema_version":         { "type": "string" },
    "project_name":           { "type": "string" },
    "uncategorized_section":  { "type": "object" }
  }
}
JSON

  cat > config/project-config.yaml <<'YAML'
schema_version: "9.0.0"
project_name: "test"
YAML

  pre_sha=$(shasum -a 256 config/project-config.yaml | awk '{print $1}')

  run env CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" bash "$RECONCILER" apply --project-root . --yes
  printf 'reconciler stderr:\n%s\n' "$output" >&2

  # AC5: exit code 5 = allowlist mismatch.
  [ "$status" -eq 5 ]

  # AC5: stderr names the offending section(s).
  printf '%s\n' "$output" | grep -Fq "is declared in schema but not in hydration allowlist or managed-elsewhere set"

  # AC5: config rolled back (byte-identical to pre-write state).
  post_sha=$(shasum -a 256 config/project-config.yaml | awk '{print $1}')
  [ "$pre_sha" = "$post_sha" ]
}

@test "TC-RV2-48 — Reconciler skips managed-elsewhere sections cleanly (no hard error)" {
  # Setup: a config that is missing only managed-elsewhere fields (config_phase,
  # schema_version) but has every allowlisted section present. Should exit 0.
  cd "$TMPDIR_TEST"
  rm config/project-config.yaml

  cat > config/project-config.yaml <<'YAML'
# A config with every allowlisted section present but missing
# managed-elsewhere fields (config_phase, schema_version).
project_name: "test"
ci_cd: {}
testing: {}
test_execution_bridge: {}
sprint: {}
review_gate: {}
team_conventions: {}
agent_customizations: {}
dev_story: {}
compliance: {}
tools: {}
test_execution: {}
severity: {}
gates: {}
stacks: {}
cross_service_tests: {}
environments: {}
ci_platform: "github-actions"
platforms: []
sizing_map: {}
device_targets: {}
distribution: {}
health_check: {}
val_integration: {}
project_root: "."
project_path: "."
memory_path: "_memory"
checkpoint_path: "_memory/checkpoints"
installed_path: "."
framework_version: "1.151.0"
date: "2026-05-13"
user_name: "test"
communication_language: "en"
project_kind: "framework"
planning_artifacts: "docs/planning-artifacts"
implementation_artifacts: "docs/implementation-artifacts"
test_artifacts: "docs/test-artifacts"
creative_artifacts: "docs/creative-artifacts"
YAML

  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RECONCILER" apply --project-root . --yes
  printf 'reconciler stderr:\n%s\n' "$output" >&2

  # AC6: managed-elsewhere absence does NOT trigger the AC5 hard error.
  [ "$status" -ne 5 ]
}

@test "TC-RV2-49 — advance-phase --to full idempotent + refuses backward transitions" {
  cd "$TMPDIR_TEST"
  rm config/project-config.yaml
  cat > config/project-config.yaml <<'YAML'
config_phase: partial
project_name: "test"
YAML

  # Forward: partial -> full
  run bash "$HYDRATION" advance-phase --to full
  [ "$status" -eq 0 ]
  phase_after=$(grep '^config_phase:' config/project-config.yaml | awk '{print $2}')
  [ "$phase_after" = "full" ]

  # Idempotent: re-run is exit 0, no diff.
  sha_before=$(shasum -a 256 config/project-config.yaml | awk '{print $1}')
  run bash "$HYDRATION" advance-phase --to full
  [ "$status" -eq 0 ]
  sha_after=$(shasum -a 256 config/project-config.yaml | awk '{print $1}')
  [ "$sha_before" = "$sha_after" ]

  # Backward: full -> partial is rejected with rc=3.
  run bash "$HYDRATION" advance-phase --to partial
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -Fq "backward config_phase transition"
}

@test "TC-RV2-50 — Reconciler invokes phase advancement after full hydration pass" {
  # Setup: a config at config_phase=partial with all allowlisted sections present.
  # After reconciler runs, config_phase MUST be 'full' (advancement dispatched).
  cd "$TMPDIR_TEST"
  rm config/project-config.yaml
  cat > config/project-config.yaml <<'YAML'
config_phase: partial
schema_version: "2.0.0"
project_name: "test"
ci_cd: {}
testing: {}
test_execution_bridge: {}
sprint: {}
review_gate: {}
team_conventions: {}
agent_customizations: {}
dev_story: {}
compliance: {}
tools: {}
test_execution: {}
severity: {}
gates: {}
stacks: {}
cross_service_tests: {}
environments: {}
ci_platform: "github-actions"
platforms: []
sizing_map: {}
device_targets: {}
distribution: {}
health_check: {}
val_integration: {}
project_root: "."
project_path: "."
memory_path: "_memory"
checkpoint_path: "_memory/checkpoints"
installed_path: "."
framework_version: "1.151.0"
date: "2026-05-13"
user_name: "test"
communication_language: "en"
project_kind: "framework"
planning_artifacts: "docs/planning-artifacts"
implementation_artifacts: "docs/implementation-artifacts"
test_artifacts: "docs/test-artifacts"
creative_artifacts: "docs/creative-artifacts"
YAML

  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RECONCILER" apply --project-root . --yes
  [ "$status" -eq 0 ]

  phase_after=$(grep '^config_phase:' config/project-config.yaml | awk '{print $2}')
  [ "$phase_after" = "full" ]

  # AC8 idempotency: re-running is a no-op (byte-identical).
  sha_before=$(shasum -a 256 config/project-config.yaml | awk '{print $1}')
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RECONCILER" apply --project-root . --yes
  [ "$status" -eq 0 ]
  sha_after=$(shasum -a 256 config/project-config.yaml | awk '{print $1}')
  [ "$sha_before" = "$sha_after" ]
}

@test "TC-RV2-51 — 2026-05-13 reproduction fixture is fully hydrated under fixed behavior" {
  # AC9 was originally written assuming the fixture would trigger the exit-5
  # path. After the allowlist expansion (sub-fix a + AC4 reverse-invariant),
  # every schema property the fixture is missing is now in EITHER the
  # allowlist (auto-hydrated) OR managed-elsewhere (skipped cleanly). The
  # FIXED behavior is therefore exit 0 with every allowlisted section
  # added — which is precisely the outcome the defect prevented in the
  # 2026-05-13 broken behavior (only 4 of 40 sections hydrated, 33 silently
  # skipped). This test pins the FIXED post-condition.
  cd "$TMPDIR_TEST"

  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$RECONCILER" apply --project-root . --yes
  printf 'reconciler output:\n%s\n' "$output" >&2

  # Under fixed behavior: exit 0 (successful reconciliation).
  [ "$status" -eq 0 ]

  # Every allowlisted section the fixture was missing MUST now be present.
  # Spot-check 5 representative sections that were silently skipped in the
  # 2026-05-13 broken-behavior run: testing, sprint, review_gate, gates, severity.
  for required in testing sprint review_gate gates severity; do
    if ! grep -q "^${required}:" config/project-config.yaml; then
      printf 'FAIL: section %s not present after fixed reconciliation (was silently skipped on 2026-05-13)\n' "$required" >&2
      return 1
    fi
  done

  # The audit trail MUST show the reconciliation completed (not the silent skip pattern).
  printf '%s\n' "$output" | grep -Fq "reconciliation complete"

  # Reproduction-pin telemetry: the broken 2026-05-13 run hydrated 4 sections;
  # the fixed run MUST hydrate strictly more than 4 (covers the 33 previously skipped).
  hydrated_count=$(printf '%s\n' "$output" | grep -c "hydrated missing section:")
  [ "$hydrated_count" -gt 4 ]
}

@test "TC-RV2-52 — Existing TC-RV2-1..43 suite continues to pass (regression guard)" {
  # This test is a thin regression guard: invoke the existing bats suite and
  # assert it still passes after the breaking-change rollout.
  # If gaia-reconcile-v2.bats fails after this change, the breaking change
  # touched something it shouldn't have.
  local existing="${PLUGIN_ROOT}/tests/gaia-reconcile-v2.bats"
  [ -f "$existing" ] || skip "existing suite not found at $existing"

  if command -v bats >/dev/null 2>&1; then
    run bats "$existing"
    [ "$status" -eq 0 ]
  else
    skip "bats not in PATH — cannot run regression sub-suite"
  fi
}
