#!/usr/bin/env bash
# parity_helpers.bash — shared helpers for the per-skill parity bats suites
# under tests/review-parity/ (E75-S2, FR-RSV2-46, FR-RSV2-47).
#
# Each per-skill bats file (`evidence-judgment-parity.bats` for review skills,
# `action-skill-contract.bats` for action skills) sources this helper plus the
# top-level test_helper.bash. The helpers below encapsulate the three-tier
# pipeline assertions documented in ADR-075:
#
#   tier 1 — evidence collection produces structured analysis-results JSON
#   tier 2 — judgment maps evidence to findings with severities
#   tier 3 — verdict resolver emits exactly one of APPROVE | REQUEST_CHANGES | BLOCKED
#
# The story (E75-S2) refers to verdict labels as PASSED / FAILED / UNVERIFIED
# (the canonical Review Gate vocabulary). The verdict-resolver.sh script emits
# the equivalent ADR-075 vocabulary APPROVE / REQUEST_CHANGES / BLOCKED. The
# helper `assert_verdict_canonical` accepts either vocabulary so per-skill bats
# files remain stable across the two naming conventions.
#
# Refs: ADR-075, ADR-077, FR-RSV2-46, FR-RSV2-47, E66-S5 (base parity bats).

# Resolve the plugin root from any review-parity/<skill>/*.bats file.
# BATS_TEST_DIRNAME is review-parity/<skill>/, so plugin root is three levels up.
parity_plugin_root() {
  cd "$BATS_TEST_DIRNAME/../../.." && pwd
}

# AC6 contract — source the shared E66-S5 test_helper.bash. The shared helper
# resolves SCRIPTS_DIR via BATS_TEST_DIRNAME/../scripts, which assumes bats
# files live directly under tests/. Per-skill parity bats files are two
# directories deeper (tests/review-parity/<skill>/). We shim BATS_TEST_DIRNAME
# to the tests/ directory while sourcing the helper so its `cd` succeeds, then
# restore the bats-supplied value afterwards. Net effect: shared helper
# functions (common_setup, common_teardown, run_script) become available with
# the correct SCRIPTS_DIR resolved relative to tests/.
PARITY_PLUGIN_ROOT="$(parity_plugin_root)"
__parity_real_test_dirname="${BATS_TEST_DIRNAME}"
BATS_TEST_DIRNAME="${PARITY_PLUGIN_ROOT}/tests"
# shellcheck source=/dev/null
. "${PARITY_PLUGIN_ROOT}/tests/test_helper.bash"
BATS_TEST_DIRNAME="${__parity_real_test_dirname}"
unset __parity_real_test_dirname

# Resolve the verdict-resolver.sh path (canonical script).
parity_verdict_resolver() {
  printf '%s/scripts/verdict-resolver.sh' "$(parity_plugin_root)"
}

# Tier 1 — evidence is structured JSON matching the analysis-results schema.
# Asserts: file is valid JSON, contains schema_version and checks fields.
assert_evidence_structured() {
  local fixture="$1"
  [ -f "$fixture" ] || { printf 'evidence fixture missing: %s\n' "$fixture" >&2; return 1; }
  jq -e . "$fixture" >/dev/null 2>&1 || { printf 'evidence fixture is not valid JSON: %s\n' "$fixture" >&2; return 1; }
  jq -e '.schema_version == "1.0"' "$fixture" >/dev/null 2>&1 || { printf 'evidence fixture missing schema_version=1.0: %s\n' "$fixture" >&2; return 1; }
  jq -e '.checks | type == "array"' "$fixture" >/dev/null 2>&1 || { printf 'evidence fixture missing checks array: %s\n' "$fixture" >&2; return 1; }
}

# Tier 2 — judgment fixture is an LLM-findings JSON with a findings array.
# Asserts: each finding has a severity field (when findings is non-empty).
assert_judgment_findings() {
  local fixture="$1"
  [ -f "$fixture" ] || { printf 'findings fixture missing: %s\n' "$fixture" >&2; return 1; }
  jq -e . "$fixture" >/dev/null 2>&1 || { printf 'findings fixture is not valid JSON: %s\n' "$fixture" >&2; return 1; }
  jq -e '.findings | type == "array"' "$fixture" >/dev/null 2>&1 || { printf 'findings fixture missing findings array: %s\n' "$fixture" >&2; return 1; }
  # If findings is non-empty, each entry must have a severity field.
  local count
  count="$(jq '.findings | length' "$fixture")"
  if [ "$count" -gt 0 ]; then
    jq -e '.findings | all(.severity != null and (.severity | type == "string"))' "$fixture" >/dev/null 2>&1 \
      || { printf 'findings fixture has entry without severity: %s\n' "$fixture" >&2; return 1; }
  fi
}

# Tier 3 — verdict resolver emits a canonical verdict for the fixtures.
# Accepts either ADR-075 (APPROVE/REQUEST_CHANGES/BLOCKED) or Review-Gate
# (PASSED/FAILED/UNVERIFIED) vocabulary.
assert_verdict_canonical() {
  local verdict="$1"
  case "$verdict" in
    APPROVE|REQUEST_CHANGES|BLOCKED) return 0 ;;
    PASSED|FAILED|UNVERIFIED) return 0 ;;
    *) printf 'verdict not canonical: %s\n' "$verdict" >&2; return 1 ;;
  esac
}

# Run the verdict resolver against the evidence + findings fixtures and echo
# the verdict on stdout. Caller can capture and assert against the expected
# verdict fixture.
run_verdict_resolver() {
  local skill="$1"
  local evidence="$2"
  local findings="$3"
  "$(parity_verdict_resolver)" --skill "$skill" --analysis-results "$evidence" --llm-findings "$findings"
}

# Action-mode variant — exercises the action-skill verdict contract per E67-S2.
# Requires an analysis-results document with action-skill outcome flags.
run_verdict_resolver_action_mode() {
  local skill="$1"
  local evidence="$2"
  "$(parity_verdict_resolver)" --skill "$skill" --action-mode --analysis-results "$evidence"
}
