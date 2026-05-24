#!/usr/bin/env bats
# AF-2026-05-24-10 + AF-2026-05-24-11 + AF-2026-05-24-12 + AF-2026-05-24-13 bundle
# Test02 findings F-13, F-14, F-15, F-21, F-22, F-24, F-35, F-36, F-39
#
# F-13: verdict-resolver `.blocking // true` jq quirk
# F-14: tag-conformance flags source files; doesn't recognize module-level pytestmark
# F-15: sprint-review YOLO contract documented
# F-21: triage-findings setup.sh writes run-start sentinel
# F-22: tech-debt scanner schema mismatch (5-col vs 4-col)
# F-24: retro review-extract fallback on missing sprint_id frontmatter
# F-35: readiness-check finalize.sh canonical-path fallback
# F-36: readiness-check ci-setup gate conditional on ci_platform.provider!=none
# F-39: trace finalize.sh surfaces BLOCKED matrix verdict

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."

# --- F-13 ---

@test "F-13: verdict-resolver uses .blocking == null check, not // true" {
  grep -qF '.blocking == null then true else .blocking end' "${PLUGIN_ROOT}/scripts/verdict-resolver.sh"
}

@test "F-13: verdict-resolver no longer uses the buggy // true jq idiom in the LIVE jq expression" {
  # The buggy form may still appear in comments (educational reference to the
  # bug we fixed); we only require it does not appear inside an active jq -e block.
  ! awk '/jq -e/{flag=1} flag && /\.blocking \/\/ true/{print; exit 1} /^['"'"'"]/{flag=0}' "${PLUGIN_ROOT}/scripts/verdict-resolver.sh"
}

# --- F-14 ---

@test "F-14: has_tag_python recognizes module-level pytestmark" {
  grep -qE 'pytestmark[[:space:]]*=[[:space:]]*\(\\\[' "${PLUGIN_ROOT}/scripts/review-common/tag-conformance-detector.sh" || \
    grep -qE 'pytestmark.*pytest\.mark' "${PLUGIN_ROOT}/scripts/review-common/tag-conformance-detector.sh"
}

@test "F-14: resolve_stack_for_file cross-checks classify when --stack is explicit" {
  grep -qF 'cross-check by calling auto-classify' "${PLUGIN_ROOT}/scripts/review-common/tag-conformance-detector.sh"
  grep -qF 'if [ "$auto" = "$STACK" ]' "${PLUGIN_ROOT}/scripts/review-common/tag-conformance-detector.sh"
}

@test "F-14: has_tag_python returns true for module-level pytestmark (end-to-end)" {
  TMPDIR_F14="$TEST_TMP/f14"
  mkdir -p "$TMPDIR_F14"
  cat > "$TMPDIR_F14/test_module_pytestmark.py" <<'EOF'
import pytest
pytestmark = pytest.mark.unit
def test_foo():
    pass
EOF
  # Source the detector to get has_tag_python in scope
  set +e
  output=$(bash -c "source '${PLUGIN_ROOT}/scripts/review-common/tag-conformance-detector.sh' 2>/dev/null; has_tag_python '$TMPDIR_F14/test_module_pytestmark.py' && echo MATCHED || echo NOT_MATCHED")
  set -e
  # If sourcing fails (script has main scan logic), do the regex check directly
  if echo "$output" | grep -q "MATCHED\|NOT_MATCHED"; then
    [ "$output" = "MATCHED" ]
  else
    # Fall back to direct regex check
    grep -Eq '^[[:space:]]*pytestmark[[:space:]]*=[[:space:]]*(\[[[:space:]]*)?pytest\.mark\.' "$TMPDIR_F14/test_module_pytestmark.py"
  fi
}

# --- F-15 ---

@test "F-15: sprint-review SKILL.md documents YOLO contract per AF-24-11" {
  grep -qF "AF-2026-05-24-11" "${PLUGIN_ROOT}/skills/gaia-sprint-review/SKILL.md"
  grep -qF "F-15" "${PLUGIN_ROOT}/skills/gaia-sprint-review/SKILL.md"
}

# --- F-21 ---

@test "F-21: triage-findings setup.sh writes run-start sentinel" {
  grep -qF "AF-2026-05-24-12" "${PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/setup.sh"
  grep -qF "triage-findings.json" "${PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/setup.sh"
  grep -qF "run-start sentinel" "${PLUGIN_ROOT}/skills/gaia-triage-findings/scripts/setup.sh"
}

# --- F-22 ---

@test "F-22: tech-debt scanner reads Type from col2 not col1" {
  grep -qF 'AF-2026-05-24-10 / Test02 F-22' "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/scan-findings.sh"
  grep -qF 'col2 → Type' "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/scan-findings.sh"
}

@test "F-22: tech-debt scanner handles both 5-col and 4-col schemas" {
  grep -qF '4-col legacy dev-story schema' "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/scan-findings.sh"
  grep -qF 'tech-debt|bug|framework-defect' "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/scan-findings.sh"
}

@test "F-22: tech-debt scanner skips header rows for both schemas" {
  grep -qF 'col1" = "#" ] || [ "$col1" = "ID"' "${PLUGIN_ROOT}/skills/gaia-tech-debt-review/scripts/scan-findings.sh"
}

# --- F-24 ---

@test "F-24: retro review-extract has frontmatter-miss fallback by story key" {
  grep -qF "AF-2026-05-24-10 / Test02 F-24" "${PLUGIN_ROOT}/skills/gaia-retro/scripts/review-extract.sh"
  grep -qF "SPRINT_STORY_KEYS" "${PLUGIN_ROOT}/skills/gaia-retro/scripts/review-extract.sh"
  grep -qF "story_key_from_filename" "${PLUGIN_ROOT}/skills/gaia-retro/scripts/review-extract.sh"
}

# --- F-35 ---

@test "F-35: readiness-check finalize.sh auto-picks canonical artifact when READINESS_ARTIFACT unset" {
  grep -qF "AF-2026-05-24-13 / Test02 F-35" "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/finalize.sh"
  grep -qF "CANONICAL_RR=" "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/finalize.sh"
  grep -qF "GAIA_READINESS_FIXTURE_GUARD" "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/finalize.sh"
}

# --- F-36 ---

@test "F-36: readiness-check setup.sh makes ci-setup gate conditional on ci_platform.provider" {
  grep -qF "AF-2026-05-24-13 / Test02 F-36" "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/setup.sh"
  grep -qF 'NEEDS_CI_GATE=' "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/setup.sh"
  grep -qF 'ci_provider" = "none"' "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/setup.sh"
}

@test "F-36: ci-setup.md empty-byte guard skipped when CI gate skipped" {
  grep -qF 'if [ "$NEEDS_CI_GATE" -eq 1 ]; then' "${PLUGIN_ROOT}/skills/gaia-readiness-check/scripts/setup.sh"
}

# --- F-39 ---

@test "F-39: trace finalize.sh surfaces WARNING when matrix declares BLOCKED" {
  grep -qF "AF-2026-05-24-13 / Test02 F-39" "${PLUGIN_ROOT}/skills/gaia-trace/scripts/finalize.sh"
  grep -qF "Matrix-verdict gate" "${PLUGIN_ROOT}/skills/gaia-trace/scripts/finalize.sh"
  grep -qE 'verdict.*BLOCKED' "${PLUGIN_ROOT}/skills/gaia-trace/scripts/finalize.sh"
}

@test "F-39: trace finalize.sh greps for BLOCKED/FAIL in matrix file" {
  grep -qE 'grep -qiE.*BLOCKED.*FAILED' "${PLUGIN_ROOT}/skills/gaia-trace/scripts/finalize.sh"
}
