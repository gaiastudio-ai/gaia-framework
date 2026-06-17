#!/usr/bin/env bats
# gaia-help-state-detection.bats — Step 3a state-detection branch (E86-S4).
#
# Story: E86-S4 — `/gaia-help` SKILL.md state-detection branch — 4-state
#                  enum per ADR-103.
# Traces: FR-471, ADR-103, SR-58, T-FVD-4, T-FVD-7,
#         TC-FVD-19..TC-FVD-40.
#
# Strategy: gaia-help is an LLM-driven skill (prose in SKILL.md). Tests
# use two complementary approaches:
#   (1) Structural grep against SKILL.md (AC1, AC2, AC8, AC9).
#   (2) Algorithmic reproduction of the SKILL.md pseudocode as
#       `_detect_state()` against fixture layouts (AC3-AC7).
# A drift guard (WARN-1 from plan-gate Val) asserts the SKILL.md
# pseudocode block contains all the expected tokens.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  SKILL_MD="$BATS_TEST_DIRNAME/../skills/gaia-help/SKILL.md"
  FIXTURE_DIR="$TEST_TMP/proj"
  mkdir -p "$FIXTURE_DIR"
}
teardown() { common_teardown; }

# ---- Algorithmic reproduction of the Step 3a pseudocode --------------

_detect_state() {
  local root="${1:-.}"
  local PROJECT_STATE="healthy"
  local BUILD_FILES=(package.json pyproject.toml go.mod Cargo.toml pom.xml Gemfile)
  local bf

  if [ ! -f "$root/config/project-config.yaml" ]; then
    PROJECT_STATE="greenfield"
  elif [ ! -d "$root/docs/planning-artifacts" ] || [ -z "$(ls -A "$root/docs/planning-artifacts" 2>/dev/null)" ]; then
    for bf in "${BUILD_FILES[@]}"; do
      if [ -f "$root/$bf" ]; then
        PROJECT_STATE="brownfield"
        break
      fi
    done
    if [ "$PROJECT_STATE" != "brownfield" ]; then
      if [ -f "$root/_memory/.framework-version-stale" ]; then
        PROJECT_STATE="post-update"
      fi
    fi
  elif [ -f "$root/_memory/.framework-version-stale" ]; then
    PROJECT_STATE="post-update"
  fi

  printf '%s\n' "$PROJECT_STATE"
}

mk_config() {
  mkdir -p "$FIXTURE_DIR/config"
  printf 'framework_version: "1.0.0"\n' > "$FIXTURE_DIR/config/project-config.yaml"
}

mk_planning_empty() {
  mkdir -p "$FIXTURE_DIR/docs/planning-artifacts"
}

mk_planning_populated() {
  mkdir -p "$FIXTURE_DIR/docs/planning-artifacts"
  printf '# placeholder\n' > "$FIXTURE_DIR/docs/planning-artifacts/prd.md"
}

mk_build_file() {
  printf '{}\n' > "$FIXTURE_DIR/$1"
}

mk_stale_marker() {
  mkdir -p "$FIXTURE_DIR/_memory"
  printf 'stale_since=2026-05-01T00:00:00Z installed=2.0.0 config=1.0.0\n' \
    > "$FIXTURE_DIR/_memory/.framework-version-stale"
}

# ===== AC3 / TC-FVD-19..21: greenfield ================================

@test "greenfield when config absent" {
  result="$(_detect_state "$FIXTURE_DIR")"
  [ "$result" = "greenfield" ]
}

@test "greenfield even when build files exist (config-absent is sufficient)" {
  mk_build_file "package.json"
  result="$(_detect_state "$FIXTURE_DIR")"
  [ "$result" = "greenfield" ]
}

@test "greenfield short-circuits before brownfield checks" {
  mk_build_file "package.json"
  mk_planning_empty
  result="$(_detect_state "$FIXTURE_DIR")"
  [ "$result" = "greenfield" ]
}

# ===== AC4 / TC-FVD-22..28: brownfield ================================

@test "brownfield (package.json)" {
  mk_config; mk_planning_empty; mk_build_file "package.json"
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

@test "brownfield (pyproject.toml)" {
  mk_config; mk_planning_empty; mk_build_file "pyproject.toml"
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

@test "brownfield (go.mod)" {
  mk_config; mk_planning_empty; mk_build_file "go.mod"
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

@test "brownfield (Cargo.toml)" {
  mk_config; mk_planning_empty; mk_build_file "Cargo.toml"
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

@test "brownfield (pom.xml)" {
  mk_config; mk_planning_empty; mk_build_file "pom.xml"
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

@test "brownfield (Gemfile)" {
  mk_config; mk_planning_empty; mk_build_file "Gemfile"
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

@test "brownfield with missing planning-artifacts dir (treated as empty)" {
  mk_config; mk_build_file "package.json"
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

# ===== NOT brownfield disqualifications ===============================

@test "NOT brownfield when planning-artifacts is non-empty" {
  mk_config; mk_planning_populated; mk_build_file "package.json"
  result="$(_detect_state "$FIXTURE_DIR")"
  [ "$result" != "brownfield" ]
  [ "$result" = "healthy" ]
}

@test "NOT brownfield when no build-system file is present" {
  mk_config; mk_planning_empty
  result="$(_detect_state "$FIXTURE_DIR")"
  [ "$result" != "brownfield" ]
  [ "$result" = "healthy" ]
}

# ===== AC5 / TC-FVD-31..33: post-update ===============================

@test "post-update when stale marker + planning-artifacts populated" {
  mk_config; mk_planning_populated; mk_stale_marker
  [ "$(_detect_state "$FIXTURE_DIR")" = "post-update" ]
}

@test "post-update when stale marker + empty planning + no build file" {
  mk_config; mk_planning_empty; mk_stale_marker
  [ "$(_detect_state "$FIXTURE_DIR")" = "post-update" ]
}

@test "post-update suggestion text matches canonical string in SKILL.md" {
  # AC5 canonical text (verbatim):
  #   "Framework update detected. Run `/gaia-migrate` to reconcile your
  #    config, or `/gaia-help --verbose` for details."
  # Test all three distinguishing fragments to defeat partial-match drift (Tex W1).
  grep -F 'Framework update detected' "$SKILL_MD"
  grep -F '/gaia-migrate' "$SKILL_MD"
  grep -F '/gaia-help --verbose' "$SKILL_MD"
}

# ===== AC6 / TC-FVD-34..35: healthy ===================================

@test "healthy when config + populated planning + no stale marker" {
  mk_config; mk_planning_populated
  [ "$(_detect_state "$FIXTURE_DIR")" = "healthy" ]
}

@test "healthy when config + populated planning + build file (planning wins)" {
  mk_config; mk_planning_populated; mk_build_file "package.json"
  [ "$(_detect_state "$FIXTURE_DIR")" = "healthy" ]
}

# ===== TC-FVD-36: brownfield > post-update precedence =================

@test "brownfield wins over post-update when both apply" {
  mk_config; mk_planning_empty; mk_build_file "package.json"; mk_stale_marker
  [ "$(_detect_state "$FIXTURE_DIR")" = "brownfield" ]
}

# ===== AC2 / structural: enum present =================================

@test "SKILL.md documents the 4-state enum ordering" {
  grep -qE 'greenfield[[:space:]]*>[[:space:]]*brownfield[[:space:]]*>[[:space:]]*post-update[[:space:]]*>[[:space:]]*healthy' "$SKILL_MD"
}

# ===== AC1 / structural: Step 3a before Step 3 ========================

@test "Step 3a heading present in SKILL.md" {
  grep -qE '^### Step 3a' "$SKILL_MD"
}

@test "Step 3a appears BEFORE Step 3 in SKILL.md" {
  local step3a step3
  step3a=$(grep -nE '^### Step 3a' "$SKILL_MD" | head -1 | cut -d: -f1)
  step3=$(grep -nE '^### Step 3 — Detect Lifecycle Phase' "$SKILL_MD" | head -1 | cut -d: -f1)
  [ -n "$step3a" ]
  [ -n "$step3" ]
  [ "$step3a" -lt "$step3" ]
}

@test "existing Step 3 heading preserved unchanged" {
  grep -qE '^### Step 3 — Detect Lifecycle Phase' "$SKILL_MD"
}

# ===== AC9 / SR-58 / T-FVD-7: no build-file leak in brownfield text ===

@test "T-: brownfield suggestion text exists" {
  grep -F 'Existing project detected' "$SKILL_MD"
  grep -F '/gaia-brownfield' "$SKILL_MD"
}

@test "T-: brownfield suggestion line does not name any build file" {
  local line
  line="$(grep -F 'Existing project detected' "$SKILL_MD" | head -1)"
  [ -n "$line" ]
  ! [[ "$line" == *"package.json"* ]]
  ! [[ "$line" == *"pyproject.toml"* ]]
  ! [[ "$line" == *"go.mod"* ]]
  ! [[ "$line" == *"Cargo.toml"* ]]
  ! [[ "$line" == *"pom.xml"* ]]
  ! [[ "$line" == *"Gemfile"* ]]
}

# Tex W2: explicit per-build-file SR-58 enforcement — verify each of the
# 6 build-file names appears ONLY in the detection-pseudocode block, NOT
# in any user-visible suggestion subsection. Extract the "Suggestion text
# by state" subsection if present and assert no build-file appears.
@test "Tex W2): user-visible suggestion subsection contains no build-file name" {
  # The suggestion-text subsection is documented inline as part of Step 3a.
  # Identify it by the canonical sentence prefixes and assert none of the
  # build-file names appear within 5 lines below those anchor lines.
  local section
  # Grab the chunk between the brownfield suggestion line and the post-update
  # suggestion line (the SR-58-sensitive region).
  section="$(awk '/Existing project detected/,/Framework update detected/' "$SKILL_MD")"
  [ -n "$section" ]
  ! [[ "$section" == *"package.json"* ]]
  ! [[ "$section" == *"pyproject.toml"* ]]
  ! [[ "$section" == *"go.mod"* ]]
  ! [[ "$section" == *"Cargo.toml"* ]]
  ! [[ "$section" == *"pom.xml"* ]]
  ! [[ "$section" == *"Gemfile"* ]]
}

# ===== AC7 / TC-FVD-40: bounded I/O (no forbidden patterns) ============

@test "Step 3a pseudocode uses only existence-check patterns" {
  local block
  block="$(awk '/^### Step 3a /,/^### Step 3 —/' "$SKILL_MD")"
  [ -n "$block" ]
  ! [[ "$block" =~ [[:space:]]cat[[:space:]] ]]
  ! [[ "$block" =~ [[:space:]]head[[:space:]] ]]
  ! [[ "$block" =~ [[:space:]]tail[[:space:]] ]]
  ! [[ "$block" =~ grep[[:space:]]-r ]]
  ! [[ "$block" =~ [[:space:]]find[[:space:]] ]]
}

# ===== AC8: priority promotion documented ============================

@test "SKILL.md documents priority promotion for each non-healthy state" {
  grep -qE '/gaia-init' "$SKILL_MD"
  grep -qE '/gaia-brownfield' "$SKILL_MD"
  grep -qE '/gaia-migrate' "$SKILL_MD"
  grep -qE '\bhealthy\b' "$SKILL_MD"
}

# ===== Plan-gate WARN-1: spec-test drift guard ========================

@test "PLAN-GATE : bats _detect_state pseudocode tokens match SKILL.md block" {
  local block
  block="$(awk '/^### Step 3a /,/^### Step 3 —/' "$SKILL_MD")"
  [[ "$block" == *"package.json"* ]]
  [[ "$block" == *"pyproject.toml"* ]]
  [[ "$block" == *"go.mod"* ]]
  [[ "$block" == *"Cargo.toml"* ]]
  [[ "$block" == *"pom.xml"* ]]
  [[ "$block" == *"Gemfile"* ]]
  [[ "$block" == *"greenfield"* ]]
  [[ "$block" == *"brownfield"* ]]
  [[ "$block" == *"post-update"* ]]
  [[ "$block" == *"healthy"* ]]
}
