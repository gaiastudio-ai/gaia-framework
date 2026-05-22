#!/usr/bin/env bats
# e46-s10-product-brief-discover-inputs.bats — E46-S10 / FR-346 / FR-358 / ADR-062.
#
# Story-specific assertions for /gaia-product-brief INDEX_GUIDED restoration.
# Builds on E45-S4 (PR #249), which already declared discover_inputs across
# six lifecycle skills. This suite covers the E46-S10 deltas:
#
#   AC1 / AC5 / AC6 — declaration anchor (grep-verifiable per Subtask 3.1)
#   AC2            — brainstorm-specific INDEX_GUIDED scope
#   AC3            — graceful FULL_LOAD fallback for small/missing artifacts
#   AC4            — Step 1 prose explicitly carves brainstorm vs the smaller
#                    research artifacts (market / domain / technical)
#
# The audit-level checks (VCP-DSC-01..07 frontmatter declarations) are owned
# by tests/discover-inputs.bats — this file does NOT duplicate them.

load test_helper

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_FILE="$PLUGIN_ROOT/skills/gaia-product-brief/SKILL.md"
  export PLUGIN_ROOT SKILL_FILE
}

teardown() { common_teardown; }

# Extract the body of "### Step 1 — Discover Inputs" up to the next H3 marker.
# Underscore prefix flags this as an internal helper for NFR-052 coverage scans.
_step1_body() {
  awk '
    /^### Step 1 — Discover Inputs/ { capture=1; next }
    capture && /^### Step [0-9]/    { capture=0 }
    capture                          { print }
  ' "$1"
}

# ---------- AC5: documented grep incantation matches (Subtask 3.1) ----------

@test "AC5: grep -E 'discover_inputs:\\s*INDEX_GUIDED' matches at least once" {
  run grep -cE 'discover_inputs:[[:space:]]*INDEX_GUIDED' "$SKILL_FILE"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ---------- AC1 / AC6: declaration shape — uppercase, exact spelling ----------

@test "AC1: discover_inputs uses exact INDEX_GUIDED spelling (no aliases)" {
  # No lowercase or kebab-case aliases anywhere in the file
  run grep -E 'discover_inputs:[[:space:]]*(index_guided|index-guided|IndexGuided|index-first|index_first)' "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

# ---------- AC4: Step 1 prose anchors INDEX_GUIDED specifically to brainstorm ----------

@test "AC4: Step 1 prose explicitly mentions the brainstorm artifact" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  echo "$body" | grep -qiE 'brainstorm'
}

@test "AC4: Step 1 prose names INDEX_GUIDED in the body (not just frontmatter)" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  echo "$body" | grep -qE 'INDEX_GUIDED'
}

# ---------- AC4 / Subtask 2.3: research artifacts permitted to FULL_LOAD ----------

@test "AC4: Step 1 prose acknowledges FULL_LOAD is acceptable for smaller research artifacts" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  # The prose must explicitly note that research artifacts (market / domain /
  # technical) MAY use FULL_LOAD because they are smaller — INDEX_GUIDED is
  # narrowly scoped to the brainstorm artifact per E46-S10 Subtask 2.3.
  # We require both signals: a "smaller" / "typically small" qualifier AND
  # FULL_LOAD acceptance for non-brainstorm research artifacts.
  echo "$body" | grep -qE 'FULL_LOAD|full-load|full load'
  echo "$body" | grep -qiE 'smaller|typically small|under 20 ?kb|under 50 ?kb|small file'
}

@test "AC4: Step 1 prose narrows INDEX_GUIDED to the brainstorm artifact (Subtask 2.3)" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  # Look for an explicit narrowing phrase: "INDEX_GUIDED applies … brainstorm"
  # or equivalent. The prose must make it readable that brainstorm is the
  # primary INDEX_GUIDED target while other research artifacts may FULL_LOAD.
  echo "$body" | grep -qiE 'INDEX_GUIDED applies|INDEX_GUIDED.*brainstorm|brainstorm.*INDEX_GUIDED|narrowly|specifically.*brainstorm|brainstorm artifact'
}

@test "AC4: Step 1 prose names at least one of the research artifact types" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  echo "$body" | grep -qiE 'market research|domain research|technical research|tech research'
}

# ---------- AC2: brainstorm path is named so the runtime heuristic can target it ----------

@test "AC2: Step 1 prose references the brainstorm artifact glob" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  echo "$body" | grep -qE 'brainstorm-\*\.md|brainstorm\*\.md|(docs|\.gaia/artifacts)/creative-artifacts/brainstorm'
}

# ---------- AC3: graceful fallback prose (no halt for small artifacts) ----------

@test "AC3: Step 1 prose documents fallback when an artifact lacks a parseable index" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  echo "$body" | grep -qiE 'fall ?back|fallback|degrade|degrades gracefully'
}

# ---------- Regression: existing load-list bullets preserved verbatim (Subtask 2.2) ----------

@test "regression: Step 1 still scans market research, domain research, and technical research" {
  local body
  body="$(_step1_body "$SKILL_FILE")"
  echo "$body" | grep -qiE 'market research'
  echo "$body" | grep -qiE 'domain research'
  echo "$body" | grep -qiE 'technical research|tech research'
}

# ---------- Regression: output file path unchanged (DoD line) ----------

@test "regression: output path product-brief- is unchanged (canonical post-AF-21-20)" {
  # AF-2026-05-21-20 canonicalized this path. Accept canonical or legacy.
  grep -qE '(docs|\.gaia/artifacts)/creative-artifacts/product-brief-' "$SKILL_FILE"
}
