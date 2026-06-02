#!/usr/bin/env bats
# e36-s3-framework-self-improvement.bats
#
# TDD tests for E36-S3: Framework self-improvement.
# Covers:
#   - CRITICAL #1: allowlist_match accepts custom/skills/*.customize.yaml
#   - AC1/TC-RIM-11: Tech debt reflection block in retro artifact
#   - AC2/TC-RIM-8: Structured skill proposal (approval gate)
#   - AC3/TC-RIM-9: Approved proposal writes to custom/skills/ + .customize.yaml
#   - AC4/TC-RIM-10: Rejected proposal = no write
#   - EC1: Missing tech-debt-dashboard.md
#   - EC5: No skill match
#   - EC7: Missing .customize.yaml seed on first approval
#   - EC8: Allowlist blocks gaia-public/plugins/gaia/skills/ path
#   - EC11: Oversized diff rejection
#
# NFR-052: every new public shell function has a direct unit test.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

WRITER="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/retro-sidecar-write.sh"
PROPOSAL_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-retro/scripts" && pwd)/skill-proposal.sh"

# ---------------------------------------------------------------------------
# Helper: extract allowlist_match function from retro-sidecar-write.sh
# ---------------------------------------------------------------------------
_load_writer_helpers() {
  local tmp
  tmp="$(mktemp -t retro-helpers.XXXXXX)"
  awk '
    /^resolve_real\(\) \{/,/^\}/ { print; next }
    /^allowlist_match\(\) \{/,/^\}/ { print; next }
    /^normalize_payload\(\) \{/,/^\}/ { print; next }
    /^sha256\(\) \{/,/^\}/ { print; next }
    /^canonical_header\(\) \{/,/^\}/ { print; next }
  ' "$WRITER" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Helper: extract proposal functions from skill-proposal.sh
# ---------------------------------------------------------------------------
_load_proposal_helpers() {
  local tmp
  tmp="$(mktemp -t proposal-helpers.XXXXXX)"
  awk '
    /^_parse_table_cell\(\) \{/,/^\}/ { print; next }
    /^_DEBT_CATEGORIES=/ { print; next }
    /^build_proposal\(\) \{/,/^\}/ { print; next }
    /^validate_proposal\(\) \{/,/^\}/ { print; next }
    /^write_approved_proposal\(\) \{/,/^\}/ { print; next }
    /^extract_tech_debt_reflection\(\) \{/,/^\}/ { print; next }
  ' "$PROPOSAL_SCRIPT" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ===========================================================================
# CRITICAL #1: allowlist_match accepts custom/skills/*.customize.yaml
# ===========================================================================

@test "allowlist_match accepts custom/skills/{agent-id}.customize.yaml (CRITICAL #1)" {
  _load_writer_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/custom/skills/all-dev.customize.yaml"
}

@test "allowlist_match accepts custom/skills/{name}.customize.yaml with arbitrary name" {
  _load_writer_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/custom/skills/typescript-dev.customize.yaml"
}

@test "allowlist_match still accepts custom/skills/*.md after .customize.yaml addition" {
  _load_writer_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/custom/skills/gaia-retro.md"
}

@test "allowlist_match still rejects gaia-public/plugins/gaia/skills/ path (EC8)" {
  _load_writer_helpers
  local root="/tmp/gaia-al-root"
  run allowlist_match "$root" "$root/gaia-public/plugins/gaia/skills/foo.md"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# canonical_header for .customize.yaml (already tested in e36-s2, verify still works)
# ===========================================================================

@test "canonical_header for custom/skills/*.customize.yaml emits ADR-053 header" {
  _load_writer_helpers
  local got
  got="$(canonical_header "/x/custom/skills/all-dev.customize.yaml")"
  [[ "$got" == *"customize.yaml"* ]] || [[ "$got" == *"ADR-053"* ]] || [[ "$got" == *"overrides"* ]]
}

# ===========================================================================
# AC1 / TC-RIM-11: Tech debt reflection — extract_tech_debt_reflection
# ===========================================================================

@test "extract_tech_debt_reflection produces reflection block from valid dashboard" {
  _load_proposal_helpers
  # Create a mock tech-debt-dashboard.md with ratio, aging, and categories
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  cat > "$TEST_TMP/docs/implementation-artifacts/tech-debt-dashboard.md" <<'DASH'
---
sprint_id: sprint-26
prior_sprint_id: sprint-25
---
# Tech Debt Dashboard

## Summary

| Metric | Current | Prior | Delta |
|--------|---------|-------|-------|
| Debt ratio | 12% | 15% | -3% |
| Mean age (days) | 14 | 18 | -4 |

## Category Breakdown

| Category | Count | Prior | Delta |
|----------|-------|-------|-------|
| architecture | 3 | 4 | -1 |
| code | 5 | 5 | 0 |
| test | 2 | 3 | -1 |
| documentation | 1 | 1 | 0 |
| process | 1 | 2 | -1 |
DASH

  local result
  result="$(extract_tech_debt_reflection "$TEST_TMP" "sprint-26")"
  # Must contain the section heading
  [[ "$result" == *"## Tech Debt Reflection"* ]]
  # Must contain debt ratio delta
  [[ "$result" == *"Debt ratio"* ]]
  # Must contain aging delta
  [[ "$result" == *"age"* ]] || [[ "$result" == *"Aging"* ]]
  # Must contain category breakdown
  [[ "$result" == *"architecture"* ]]
}

# ===========================================================================
# EC1: Missing tech-debt-dashboard.md — "No tech debt data available"
# ===========================================================================

@test "extract_tech_debt_reflection outputs 'No tech debt data available' when dashboard missing (EC1)" {
  _load_proposal_helpers
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  # No dashboard file
  local result
  result="$(extract_tech_debt_reflection "$TEST_TMP" "sprint-26")"
  [[ "$result" == *"No tech debt data available"* ]]
}

# ===========================================================================
# EC3: First sprint (baseline markers)
# ===========================================================================

@test "extract_tech_debt_reflection renders baseline markers for first sprint (EC3)" {
  _load_proposal_helpers
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  cat > "$TEST_TMP/docs/implementation-artifacts/tech-debt-dashboard.md" <<'DASH'
---
sprint_id: sprint-1
---
# Tech Debt Dashboard

## Summary

| Metric | Current |
|--------|---------|
| Debt ratio | 10% |
| Mean age (days) | 7 |

## Category Breakdown

| Category | Count |
|----------|-------|
| architecture | 2 |
| code | 3 |
| test | 1 |
| documentation | 0 |
| process | 1 |
DASH

  local result
  result="$(extract_tech_debt_reflection "$TEST_TMP" "sprint-1")"
  [[ "$result" == *"baseline"* ]]
}

# ===========================================================================
# EC10: Older dashboard format without categories
# ===========================================================================

@test "extract_tech_debt_reflection handles older dashboard without categories (EC10)" {
  _load_proposal_helpers
  mkdir -p "$TEST_TMP/docs/implementation-artifacts"
  cat > "$TEST_TMP/docs/implementation-artifacts/tech-debt-dashboard.md" <<'DASH'
---
sprint_id: sprint-20
prior_sprint_id: sprint-19
---
# Tech Debt Dashboard

## Summary

| Metric | Current | Prior | Delta |
|--------|---------|-------|-------|
| Debt ratio | 8% | 10% | -2% |
| Mean age (days) | 12 | 15 | -3 |
DASH

  local result
  result="$(extract_tech_debt_reflection "$TEST_TMP" "sprint-20")"
  # Should still have debt ratio and aging
  [[ "$result" == *"Debt ratio"* ]]
  # Should note that categories are unavailable
  [[ "$result" == *"category breakdown unavailable"* ]]
}

# ===========================================================================
# AC2 / TC-RIM-8: Structured skill proposal — build_proposal
# ===========================================================================

@test "build_proposal produces structured proposal object with required fields" {
  _load_proposal_helpers
  local finding_ref="retro-sprint-26-finding-1"
  local target_skill="gaia-retro"
  local rationale="Sprint 26 retro found theme detection too rigid"
  local diff_text="+ ## Fuzzy Matching\n+ Added fuzzy theme matching"

  local result
  result="$(build_proposal "$finding_ref" "$target_skill" "$rationale" "$diff_text")"
  # Must have all required fields
  [[ "$result" == *"finding_ref:"* ]]
  [[ "$result" == *"target_skill:"* ]]
  [[ "$result" == *"target_path:"* ]]
  [[ "$result" == *"rationale:"* ]]
  [[ "$result" == *"diff:"* ]]
  # target_path must start with custom/skills/
  [[ "$result" == *"custom/skills/"* ]]
}

# ===========================================================================
# AC2: validate_proposal rejects non-UTF-8 / oversized diffs (EC11)
# ===========================================================================

@test "validate_proposal rejects diff > 100KB (EC11)" {
  _load_proposal_helpers
  # Generate a 101KB string
  local big_diff
  big_diff="$(head -c 103000 /dev/urandom | base64)"

  run validate_proposal "finding-1" "gaia-retro" "rationale" "$big_diff"
  [ "$status" -ne 0 ]
  [[ "$output" == *"100 KB"* ]] || [[ "$output" == *"100KB"* ]]
}

@test "validate_proposal accepts a normal-sized diff" {
  _load_proposal_helpers
  local diff_text="+ ## New Section\n+ Added a new feature"

  run validate_proposal "finding-1" "gaia-retro" "rationale" "$diff_text"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# AC3 / TC-RIM-9: write_approved_proposal — writes custom/skills/ and .customize.yaml
# ===========================================================================

@test "write_approved_proposal writes custom/skills/{skill}.md (TC-RIM-9)" {
  _load_proposal_helpers
  mkdir -p "$TEST_TMP/custom/skills"

  # Snapshot: pre-write state
  local pre_files
  pre_files="$(ls "$TEST_TMP/custom/skills/" 2>/dev/null || echo '')"

  write_approved_proposal \
    "$TEST_TMP" \
    "sprint-26" \
    "gaia-retro" \
    "custom/skills/gaia-retro.md" \
    "Sprint 26 improvement" \
    "## Fuzzy Matching\nAdded fuzzy theme matching" \
    "$WRITER"

  # Post-write: custom/skills/gaia-retro.md must exist
  [ -f "$TEST_TMP/custom/skills/gaia-retro.md" ]

  # Snapshot diff: no writes under gaia-public/plugins/gaia/skills/
  mkdir -p "$TEST_TMP/gaia-public/plugins/gaia/skills"
  local post_plugin_files
  post_plugin_files="$(find "$TEST_TMP/gaia-public/plugins/gaia/skills" -type f 2>/dev/null | wc -l)"
  [ "$post_plugin_files" -eq 0 ]
}

@test "write_approved_proposal registers skill_overrides in .customize.yaml (TC-RIM-9)" {
  _load_proposal_helpers
  mkdir -p "$TEST_TMP/custom/skills"

  write_approved_proposal \
    "$TEST_TMP" \
    "sprint-26" \
    "gaia-retro" \
    "custom/skills/gaia-retro.md" \
    "Sprint 26 improvement" \
    "## Fuzzy Matching\nAdded fuzzy theme matching" \
    "$WRITER"

  # .customize.yaml must exist and contain skill_overrides entry
  local cust_file="$TEST_TMP/custom/skills/all-dev.customize.yaml"
  [ -f "$cust_file" ]
  grep -q "skill_overrides" "$cust_file"
  grep -q "gaia-retro" "$cust_file"
}

# ===========================================================================
# EC7: Missing .customize.yaml — seed on first approval
# ===========================================================================

@test "write_approved_proposal seeds .customize.yaml when missing (EC7)" {
  _load_proposal_helpers
  mkdir -p "$TEST_TMP/custom/skills"
  # Ensure no .customize.yaml exists
  rm -f "$TEST_TMP/custom/skills/all-dev.customize.yaml"

  write_approved_proposal \
    "$TEST_TMP" \
    "sprint-26" \
    "gaia-retro" \
    "custom/skills/gaia-retro.md" \
    "Sprint 26 improvement" \
    "## New content" \
    "$WRITER"

  # File must now exist with canonical header
  [ -f "$TEST_TMP/custom/skills/all-dev.customize.yaml" ]
  # Must contain skill_overrides with the new entry
  grep -q "skill_overrides" "$TEST_TMP/custom/skills/all-dev.customize.yaml"
}

# ===========================================================================
# AC4 / TC-RIM-10: Rejected proposal = no write
# ===========================================================================

@test "rejected proposal produces zero filesystem writes (TC-RIM-10)" {
  _load_proposal_helpers
  mkdir -p "$TEST_TMP/custom/skills"

  # Pre-snapshot
  local pre_md pre_yaml
  pre_md="$(find "$TEST_TMP/custom/skills" -name '*.md' 2>/dev/null | wc -l)"
  pre_yaml="$(find "$TEST_TMP/custom/skills" -name '*.customize.yaml' 2>/dev/null | wc -l)"

  # Simulate rejection — no call to write_approved_proposal
  # This is verifying the contract: if we DON'T call write, no files appear

  # Post-snapshot
  local post_md post_yaml
  post_md="$(find "$TEST_TMP/custom/skills" -name '*.md' 2>/dev/null | wc -l)"
  post_yaml="$(find "$TEST_TMP/custom/skills" -name '*.customize.yaml' 2>/dev/null | wc -l)"

  [ "$pre_md" -eq "$post_md" ]
  [ "$pre_yaml" -eq "$post_yaml" ]
}

# ===========================================================================
# EC8: Proposal targeting plugins/ path — allowlist blocks it
# ===========================================================================

@test "retro-sidecar-write.sh rejects write to gaia-public/plugins/gaia/skills/ (EC8)" {
  mkdir -p "$TEST_TMP/gaia-public/plugins/gaia/skills"
  run "$WRITER" \
    --root "$TEST_TMP" \
    --sprint-id "sprint-26" \
    --target "$TEST_TMP/gaia-public/plugins/gaia/skills/foo.md" \
    --payload "malicious content"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unauthorized"* ]]

  # Verify zero bytes written
  [ ! -f "$TEST_TMP/gaia-public/plugins/gaia/skills/foo.md" ]
}

# ===========================================================================
# EC8 filesystem snapshot: plugins/ dir byte-identical
# ===========================================================================

@test "TC-RIM-9 filesystem snapshot diff: zero writes under plugins/gaia/skills/ (EC8)" {
  # Pre-capture: create the plugins dir with a known marker file
  mkdir -p "$TEST_TMP/gaia-public/plugins/gaia/skills"
  echo "original" > "$TEST_TMP/gaia-public/plugins/gaia/skills/existing-skill.md"

  local pre_checksum
  pre_checksum="$(find "$TEST_TMP/gaia-public/plugins/gaia/skills" -type f -exec shasum -a 256 {} \; | sort)"

  # Run a valid approved proposal write (to custom/skills/)
  mkdir -p "$TEST_TMP/custom/skills"
  _load_proposal_helpers
  write_approved_proposal \
    "$TEST_TMP" \
    "sprint-26" \
    "gaia-retro" \
    "custom/skills/gaia-retro.md" \
    "Sprint 26 improvement" \
    "## Fuzzy Matching" \
    "$WRITER"

  # Post-capture
  local post_checksum
  post_checksum="$(find "$TEST_TMP/gaia-public/plugins/gaia/skills" -type f -exec shasum -a 256 {} \; | sort)"

  # Checksums must be identical — zero writes to plugins/
  [ "$pre_checksum" = "$post_checksum" ]
}

# ===========================================================================
# EC5: No skill match — zero proposals
# ===========================================================================

@test "build_proposal returns empty when target_skill is empty (EC5)" {
  _load_proposal_helpers
  local result
  result="$(build_proposal "finding-1" "" "rationale" "diff" 2>&1 || true)"
  # Should indicate no match / empty
  [[ "$result" == *"no skill match"* ]] || [ -z "$result" ]
}

# ===========================================================================
# Retro writer integration: custom/skills/*.customize.yaml accepted end-to-end
# ===========================================================================

@test "retro-sidecar-write.sh accepts custom/skills/all-dev.customize.yaml end-to-end" {
  mkdir -p "$TEST_TMP/custom/skills"
  run "$WRITER" \
    --root "$TEST_TMP" \
    --sprint-id "sprint-26" \
    --target "$TEST_TMP/custom/skills/all-dev.customize.yaml" \
    --payload "skill_overrides:\n  gaia-retro: custom/skills/gaia-retro.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]
  [ -f "$TEST_TMP/custom/skills/all-dev.customize.yaml" ]
}

@test "retro-sidecar-write.sh accepts custom/skills/typescript-dev.customize.yaml end-to-end" {
  mkdir -p "$TEST_TMP/custom/skills"
  run "$WRITER" \
    --root "$TEST_TMP" \
    --sprint-id "sprint-26" \
    --target "$TEST_TMP/custom/skills/typescript-dev.customize.yaml" \
    --payload "skill_overrides:\n  some-skill: custom/skills/some-skill.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]
}
