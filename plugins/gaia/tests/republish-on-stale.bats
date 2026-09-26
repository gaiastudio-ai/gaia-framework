#!/usr/bin/env bats
# republish-on-stale.bats — republish changed specs to the design project
# when the design record goes stale (edit-ux, add-feature, create-ux).
#
# Tests the republish step, cascade matrix UX row, dangling phrase removal,
# shared planner location, conflict detection, strict-conflicts flag,
# failure semantics, and publication procedure drift across skills.
#
# All tests must FAIL on a missing or broken target, never skip.
# No project-root .gaia/ access; all fixtures use mktemp.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
SKILLS_DIR="$PLUGIN_ROOT/skills"
SKILL_MD_AF="$SKILLS_DIR/gaia-add-feature/SKILL.md"
SKILL_MD_UX="$SKILLS_DIR/gaia-edit-ux/SKILL.md"
SKILL_MD_CUX="$SKILLS_DIR/gaia-create-ux/SKILL.md"
DRIVER_SCRIPT="$SCRIPTS_DIR/design-stale-transition.sh"
SHARED_PLANNER="$SCRIPTS_DIR/plan-publication.sh"
SHARED_CARD_BUILDER="$SCRIPTS_DIR/build-manifest-cards.sh"
DOC_DIR="$BATS_TEST_DIRNAME/../../../documentation"

setup() {
  common_setup
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------

fail() { printf '%s\n' "$1" >&2; return 1; }

# _extract_step8_editux — extract the Step 8 section from edit-ux SKILL.md
# (from the Step 8 heading to the next ### Step heading or EOF).
_extract_step8_editux() {
  awk '/^### Step 8/{p=1} p && /^### Step [^8]/ && NR>1{exit} p' "$SKILL_MD_UX"
}

# _extract_between_stale_end_and_step8_af — extract text between the
# stale-transition end marker and the Step 8 heading in add-feature SKILL.md.
_extract_between_stale_end_and_step8_af() {
  awk '/<!-- design-stale-transition end -->/{p=1;next} /^### Step 8/{exit} p' "$SKILL_MD_AF"
}

# _extract_cascade_matrix — extract the cascade matrix table from add-feature.
_extract_cascade_matrix() {
  awk '/^## Cascade Matrix/{p=1} p && /^## [^C]/{exit} p' "$SKILL_MD_AF"
}

# _extract_attestation_block — extract the attestation block from a SKILL.md.
_extract_attestation_block() {
  awk '/<!-- design-attestation begin -->/{p=1;next} /<!-- design-attestation end -->/{p=0} p' "$1"
}

# _extract_step10_createux — extract the Step 10 section from create-ux SKILL.md
# (from Step 10 heading to next ### Step heading or EOF).
_extract_step10_createux() {
  awk '/^### Step 10/{p=1} p && /^### Step 1[1-9]/{exit} p' "$SKILL_MD_CUX"
}

# ===========================================================================
# ATDD Test 1: (AC1) edit-ux republish
# ===========================================================================

@test "(AC1) edit-ux republishes changed specs after stale transition with conflict detection" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  # Sub-scenario: structural — republish present in Step 8
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"

  printf '%s' "$step8" | grep -qF 'plan-publication.sh' \
    || fail "Step 8 section does not reference plan-publication.sh"

  # Sub-scenario: ordering — stale-transition end marker BEFORE the
  # plan-publication.sh reference
  local stale_end_line pub_line
  stale_end_line="$(grep -nF '<!-- design-stale-transition end -->' "$SKILL_MD_UX" | head -1 | cut -d: -f1)"
  [ -n "$stale_end_line" ] || fail "stale-transition end marker missing from edit-ux SKILL.md"

  pub_line="$(grep -nF 'plan-publication.sh' "$SKILL_MD_UX" | head -1 | cut -d: -f1)"
  [ -n "$pub_line" ] || fail "plan-publication.sh reference missing from edit-ux SKILL.md"

  [ "$stale_end_line" -lt "$pub_line" ] \
    || fail "stale-transition end marker (line $stale_end_line) must precede plan-publication.sh reference (line $pub_line)"

  # Sub-scenario: conflict handling documented
  printf '%s' "$step8" | grep -qiE 'CONFLICT' \
    || fail "Step 8 does not mention CONFLICT handling"
  printf '%s' "$step8" | grep -qi 'write_files' \
    || fail "Step 8 does not mention write_files"
  printf '%s' "$step8" | grep -qF 'strict-conflicts' \
    || fail "Step 8 does not mention --strict-conflicts"

  # Sub-scenario: shared planner location
  [ -x "$SHARED_PLANNER" ] \
    || fail "shared plan-publication.sh not found at $SHARED_PLANNER"
}

# ===========================================================================
# ATDD Test 2: (AC2) add-feature republish + cascade matrix
# ===========================================================================

@test "(AC2) add-feature republishes design changes before story creation and cascade matrix lists UX row" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # Sub-scenario: cascade matrix UX row
  local matrix
  matrix="$(_extract_cascade_matrix)"
  [ -n "$matrix" ] || fail "Cascade Matrix section not found"

  printf '%s' "$matrix" | grep -qi 'UX Design' \
    || fail "cascade matrix has no UX Design row"

  # Extract the UX Design row and assert YES in all three classification columns
  local ux_row
  ux_row="$(printf '%s' "$matrix" | grep -i 'UX Design')"
  [ -n "$ux_row" ] || fail "could not extract UX Design row"

  # The row must have YES in patch, enhancement, and feature columns
  local col_count
  col_count="$(printf '%s' "$ux_row" | grep -oi 'YES' | grep -c 'YES' || true)"
  [ "$col_count" -ge 3 ] \
    || fail "UX Design row has $col_count YES entries; expected at least 3 (patch, enhancement, feature)"

  # Count data rows (lines containing |...|...|...|...|)
  local row_count
  row_count="$(printf '%s' "$matrix" | grep -cE '^\|[^-]' || true)"
  # header row + at least 7 data rows = at least 8 lines with |
  [ "$row_count" -ge 8 ] \
    || fail "cascade matrix has $row_count pipe-rows; expected at least 8 (header + 7 data rows)"

  # Sub-scenario: republish text between stale-transition end and Step 8
  local between
  between="$(_extract_between_stale_end_and_step8_af)"
  [ -n "$between" ] || fail "no text found between stale-transition end and Step 8 in add-feature"

  printf '%s' "$between" | grep -qF 'plan-publication.sh' \
    || fail "no plan-publication.sh reference between stale-transition end and Step 8 in add-feature"

  # Sub-scenario: patch path also has republish
  local patch_section
  patch_section="$(awk '/^### Step 3.*patch/{p=1} p && /^### Step [^3]/{exit} p' "$SKILL_MD_AF")"
  [ -n "$patch_section" ] || fail "Step 3 patch section not found"

  printf '%s' "$patch_section" | grep -qiE 'republish|plan-publication' \
    || fail "Step 3 patch section has no republish reference"
}

# ===========================================================================
# ATDD Test 3: (AC3) republication failure semantics
# ===========================================================================

@test "(AC3) republication failure leaves record stale and creates no stories or seed briefs" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # edit-ux failure text
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"

  printf '%s' "$step8" | grep -qi 'stays stale\|stays.*stale\|record.*stale' \
    || fail "edit-ux Step 8 does not describe the record staying stale on failure"
  printf '%s' "$step8" | grep -qi 'failure' \
    || fail "edit-ux Step 8 does not mention failure handling"

  # add-feature failure text (enhancement/feature path)
  local between
  between="$(_extract_between_stale_end_and_step8_af)"
  printf '%s' "$between" | grep -qiE 'no stories|no story' \
    || fail "add-feature republish text does not say no stories on failure"

  # add-feature failure text (patch path)
  local patch_section
  patch_section="$(awk '/^### Step 3.*patch/{p=1} p && /^### Step [^3]/{exit} p' "$SKILL_MD_AF")"
  printf '%s' "$patch_section" | grep -qi 'stale\|failure' \
    || fail "Step 3 patch section has no failure handling"

  # add-feature seed-brief mode
  printf '%s' "$between" | grep -qiE 'seed brief|story keys' \
    || fail "add-feature republish text does not mention seed briefs or story keys on failure"
}

# ===========================================================================
# ATDD Test 4: (AC4) dangling phrase + shared planner
# ===========================================================================

@test "(AC4) no dangling later-update-step phrase and publication planner is shared" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  # (a) driver header: no dangling phrase
  local header
  header="$(head -40 "$DRIVER_SCRIPT")"
  if printf '%s' "$header" | grep -qiE 'later.*update step'; then
    fail "driver header still contains the dangling 'later update step' phrase"
  fi
  printf '%s' "$header" | grep -qi 'republish step' \
    || fail "driver header does not mention 'republish step' (the replacement wording)"

  # (b) attestation blocks: no dangling phrase
  local block_af block_ux
  block_af="$(_extract_attestation_block "$SKILL_MD_AF")"
  [ -n "$block_af" ] || fail "attestation block missing from add-feature SKILL.md"
  block_ux="$(_extract_attestation_block "$SKILL_MD_UX")"
  [ -n "$block_ux" ] || fail "attestation block missing from edit-ux SKILL.md"

  if printf '%s' "$block_af" | grep -qiE 'later.*update step'; then
    fail "add-feature attestation block still contains the dangling phrase"
  fi
  if printf '%s' "$block_ux" | grep -qiE 'later.*update step'; then
    fail "edit-ux attestation block still contains the dangling phrase"
  fi

  # (c) attestation blocks byte-identical
  if ! diff <(printf '%s' "$block_af") <(printf '%s' "$block_ux") >/dev/null 2>&1; then
    fail "attestation blocks are not byte-identical between add-feature and edit-ux"
  fi

  # (d) shared planner at plugins/gaia/scripts/
  [ -x "$SHARED_PLANNER" ] \
    || fail "plan-publication.sh not found at shared location ($SHARED_PLANNER)"

  # private copy must be gone
  local private_planner="$SKILLS_DIR/gaia-create-ux/scripts/plan-publication.sh"
  if [ -f "$private_planner" ]; then
    fail "plan-publication.sh still exists at private location ($private_planner)"
  fi

  # (e) shared card builder at plugins/gaia/scripts/
  [ -x "$SHARED_CARD_BUILDER" ] \
    || fail "build-manifest-cards.sh not found at shared location ($SHARED_CARD_BUILDER)"

  # private copy must be gone
  local private_builder="$SKILLS_DIR/gaia-create-ux/scripts/build-manifest-cards.sh"
  if [ -f "$private_builder" ]; then
    fail "build-manifest-cards.sh still exists at private location ($private_builder)"
  fi

  # (f) create-ux-claude-design.bats uses SHARED_SCRIPTS
  local cux_bats="$BATS_TEST_DIRNAME/create-ux-claude-design.bats"
  [ -f "$cux_bats" ] || fail "create-ux-claude-design.bats not found"
  grep -qF 'SHARED_SCRIPTS' "$cux_bats" \
    || fail "create-ux-claude-design.bats does not define SHARED_SCRIPTS"
}

# ===========================================================================
# ATDD Test 5: (AC-EC1) stale-to-stale still republishes
# ===========================================================================

@test "(AC-EC1) stale-to-stale transition still republishes when local specs changed" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"

  # The republish text must address the stale-to-stale case
  printf '%s' "$step8" | grep -qiE 'stale-to-stale|already stale|second.*audit|state no-op' \
    || fail "edit-ux Step 8 does not document the stale-to-stale republish case"
}

# ===========================================================================
# ATDD Test 6: (AC-EC2) declined classification skips republication
# ===========================================================================

@test "(AC-EC2) declined design-stale classification skips republication and excludes UX from assessment" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # The republish text is conditional on "stale transition completed with
  # integration available" — when the user declines (--decision no), the
  # stale driver exits without a transition and no republish runs.

  # The stale block documents --decision no path
  local stale_block
  stale_block="$(awk '/<!-- design-stale-transition begin -->/{p=1} /<!-- design-stale-transition end -->/{p=0} p' "$SKILL_MD_AF")"
  [ -n "$stale_block" ] || fail "stale-transition block missing from add-feature"

  # The republish is gated on "design-affecting"
  local between
  between="$(_extract_between_stale_end_and_step8_af)"
  printf '%s' "$between" | grep -qiE 'design-affecting' \
    || fail "add-feature republish text is not gated on design-affecting classification"
}

# ===========================================================================
# ATDD Test 7: (AC-EC3) missing/unauthorized halts before republish
# ===========================================================================

@test "(AC-EC3) missing or unauthorized integration halts before republish with record staying stale" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"

  # The republish text must document: halts when missing/unauthorized,
  # no republication attempted
  printf '%s' "$step8" | grep -qiE 'halt|missing.*unauthorized|unauthorized.*missing' \
    || fail "edit-ux Step 8 does not document the halt on missing/unauthorized integration"

  printf '%s' "$step8" | grep -qiE 'no republication\|no republish\|precedes.*republish\|halt.*precedes' \
    || fail "edit-ux Step 8 does not say halts precede republish"
}

# ===========================================================================
# ATDD Test 8: (AC-EC4) CONFLICT surfaced with both versions
# ===========================================================================

@test "(AC-EC4) planner CONFLICT surfaced to user with both versions and skill halts" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"

  printf '%s' "$step8" | grep -qiE 'both versions' \
    || fail "edit-ux Step 8 does not mention surfacing both versions on CONFLICT"

  printf '%s' "$step8" | grep -qiE 'halt.*resolution\|resolution.*halt\|halt for\|halts for' \
    || fail "edit-ux Step 8 does not say skill halts for resolution on CONFLICT"

  # Script-driven: --strict-conflicts must exist in the planner
  [ -x "$SHARED_PLANNER" ] \
    || fail "shared plan-publication.sh not found at $SHARED_PLANNER"

  # Run the planner with a three-way divergence fixture
  local local_json remote_json last_json
  local_json='[{"file":"login.md","hash":"abc123"}]'
  remote_json='[{"file":"login.md","hash":"xyz789"}]'
  last_json='[{"file":"login.md","hash":"def456"}]'

  printf '%s' "$local_json" > "$TEST_TMP/local.json"
  printf '%s' "$remote_json" > "$TEST_TMP/remote.json"
  printf '%s' "$last_json" > "$TEST_TMP/last.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SHARED_PLANNER" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/last.json"

  [ "$status" -eq 0 ] || fail "planner exited $status"
  [[ "$output" == *"CONFLICT login.md"* ]] \
    || fail "planner did not emit CONFLICT for three-way divergence; got: $output"
}

# ===========================================================================
# ATDD Test 9: (AC-EC5) absent manifest + strict-conflicts
# ===========================================================================

@test "(AC-EC5) absent manifest falls back to strict-conflicts treating every diff as conflict" {
  [ -x "$SHARED_PLANNER" ] \
    || fail "shared plan-publication.sh not found at $SHARED_PLANNER"

  # Sub-scenario: absent manifest + --strict-conflicts
  local local_json remote_json
  local_json='[{"file":"login.md","hash":"aaa"},{"file":"dashboard.md","hash":"bbb"}]'
  remote_json='[{"file":"login.md","hash":"ccc"},{"file":"dashboard.md","hash":"bbb"}]'

  printf '%s' "$local_json" > "$TEST_TMP/local.json"
  printf '%s' "$remote_json" > "$TEST_TMP/remote.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SHARED_PLANNER" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published /dev/null \
    --strict-conflicts

  [ "$status" -eq 0 ] || fail "planner exited $status with --strict-conflicts"
  [[ "$output" == *"CONFLICT login.md"* ]] \
    || fail "with --strict-conflicts, differing file should be CONFLICT, got: $output"
  [[ "$output" == *"SKIP_UNCHANGED dashboard.md"* ]] \
    || fail "matching hashes should still be SKIP_UNCHANGED, got: $output"
  [[ "$output" != *"WRITE login.md"* ]] \
    || fail "--strict-conflicts should prevent WRITE for differing files"

  # Sub-scenario: create-ux first publish (no strict flag) — no spurious CONFLICTs
  local first_local first_remote
  first_local='[{"file":"s1.md","hash":"x1"},{"file":"s2.md","hash":"x2"}]'
  first_remote='[]'

  printf '%s' "$first_local" > "$TEST_TMP/first-local.json"
  printf '%s' "$first_remote" > "$TEST_TMP/first-remote.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SHARED_PLANNER" \
    --local-manifest "$TEST_TMP/first-local.json" \
    --remote-listing "$TEST_TMP/first-remote.json" \
    --last-published /dev/null

  [ "$status" -eq 0 ] || fail "first-publish planner exited $status"
  [[ "$output" == *"WRITE s1.md"* ]] \
    || fail "first publish should emit WRITE, got: $output"
  [[ "$output" != *"CONFLICT"* ]] \
    || fail "first publish without --strict-conflicts should have no CONFLICTs"

  # Sub-scenario: with manifest present, framework-edited spec is WRITE
  local manifest_local manifest_remote manifest_last
  manifest_local='[{"file":"login.md","hash":"new"}]'
  manifest_remote='[{"file":"login.md","hash":"old"}]'
  manifest_last='[{"file":"login.md","hash":"old"}]'

  printf '%s' "$manifest_local" > "$TEST_TMP/m-local.json"
  printf '%s' "$manifest_remote" > "$TEST_TMP/m-remote.json"
  printf '%s' "$manifest_last" > "$TEST_TMP/m-last.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SHARED_PLANNER" \
    --local-manifest "$TEST_TMP/m-local.json" \
    --remote-listing "$TEST_TMP/m-remote.json" \
    --last-published "$TEST_TMP/m-last.json"

  [ "$status" -eq 0 ] || fail "manifest-present planner exited $status"
  [[ "$output" == *"WRITE login.md"* ]] \
    || fail "with manifest, framework-edited spec should be WRITE, got: $output"
  [[ "$output" != *"CONFLICT login.md"* ]] \
    || fail "with manifest, clean framework edit should not be CONFLICT"
}

# ===========================================================================
# ATDD Test 10: (AC-EC6) mutant removes republish step
# ===========================================================================

@test "(AC-EC6) mutant: removing edit-ux republish step turns a named test red" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  # PRECONDITION: the unmutated edit-ux Step 8 MUST contain the planner
  # reference. Without this, the sed below is a no-op and the test passes
  # vacuously.
  local unmutated_step8
  unmutated_step8="$(awk '/^### Step 8/{p=1} p && /^### Step [^8]/ && NR>1{exit} p' "$SKILL_MD_UX")"
  [ -n "$unmutated_step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"
  printf '%s' "$unmutated_step8" | grep -qF 'plan-publication.sh' \
    || fail "PRECONDITION: unmutated edit-ux Step 8 does not contain plan-publication.sh — the republish step must be present before mutation testing"

  # Create a mutated copy: remove plan-publication.sh references from Step 8
  local mutant="$TEST_TMP/mutant-skill.md"
  sed '/plan-publication\.sh/d' "$SKILL_MD_UX" > "$mutant"

  # Run the same structural check as Test 1 against the mutant
  local step8
  step8="$(awk '/^### Step 8/{p=1} p && /^### Step [^8]/ && NR>1{exit} p' "$mutant")"

  # The grep for plan-publication.sh must FAIL on the mutant
  if printf '%s' "$step8" | grep -qF 'plan-publication.sh'; then
    fail "mutant still contains plan-publication.sh — the mutation did not work"
  fi

  # Confirm: Test 1's assertion would fail on this mutant (this test passes)
  # The assertion is: the Step 8 section MUST contain plan-publication.sh
  # On the mutant, it does not — so Test 1 would turn red.
}

# ===========================================================================
# Green-before-change regression guards
# ===========================================================================

# G1: attestation blocks are currently byte-identical (green before change)
@test "(G1) attestation blocks are byte-identical before any change" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local block_af block_ux
  block_af="$(_extract_attestation_block "$SKILL_MD_AF")"
  block_ux="$(_extract_attestation_block "$SKILL_MD_UX")"
  [ -n "$block_af" ] || fail "attestation block missing from add-feature"
  [ -n "$block_ux" ] || fail "attestation block missing from edit-ux"

  diff <(printf '%s' "$block_af") <(printf '%s' "$block_ux") >/dev/null 2>&1 \
    || fail "attestation blocks differ before any S17 change — pre-existing drift"
}

# G2: stale marker precedes Step 8 in add-feature (green before change)
@test "(G2) stale marker precedes Step 8 in add-feature SKILL.md" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local marker_line step8_line
  marker_line="$(grep -nF '<!-- design-stale-transition begin -->' "$SKILL_MD_AF" | head -1 | cut -d: -f1)"
  [ -n "$marker_line" ] || fail "stale-transition begin marker missing"

  step8_line="$(grep -n 'Step 8' "$SKILL_MD_AF" | head -1 | cut -d: -f1)"
  [ -n "$step8_line" ] || fail "Step 8 heading missing"

  [ "$marker_line" -lt "$step8_line" ] \
    || fail "stale marker (line $marker_line) does not precede Step 8 (line $step8_line)"
}

# G3: design-stale-transition.sh header mentions revok|token (green)
@test "(G3) stale driver header documents the authorization-expiry trade-off" {
  [ -f "$DRIVER_SCRIPT" ] || fail "design-stale-transition.sh not found"

  local header
  header="$(head -40 "$DRIVER_SCRIPT")"
  printf '%s' "$header" | grep -qE 'revok|token' \
    || fail "driver header does not mention revoked/token trade-off"
}

# G4: existing planner tests reference the skill-private path (green)
@test "(G4) create-ux-claude-design.bats planner tests are green with the current path" {
  local cux_bats="$BATS_TEST_DIRNAME/create-ux-claude-design.bats"
  [ -f "$cux_bats" ] || fail "create-ux-claude-design.bats not found"

  # The file currently uses $SKILL_SCRIPTS for plan-publication.sh
  grep -qF 'SKILL_SCRIPTS' "$cux_bats" \
    || fail "create-ux-claude-design.bats does not define SKILL_SCRIPTS"

  # The private script currently exists
  local private_planner="$SKILLS_DIR/gaia-create-ux/scripts/plan-publication.sh"
  [ -f "$private_planner" ] \
    || fail "plan-publication.sh not found at private location (expected green before move)"
}

# G5: build-manifest-cards.bats points to skill-private path (green)
@test "(G5) build-manifest-cards.bats points to the current script location" {
  local bmc_bats="$BATS_TEST_DIRNAME/build-manifest-cards.bats"
  [ -f "$bmc_bats" ] || fail "build-manifest-cards.bats not found"

  local private_builder="$SKILLS_DIR/gaia-create-ux/scripts/build-manifest-cards.sh"
  [ -f "$private_builder" ] \
    || fail "build-manifest-cards.sh not found at private location (expected green before move)"
}

# G6: attestation block mentions revok|token (green)
@test "(G6) attestation block documents the revoked-token trade-off" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local block_af
  block_af="$(_extract_attestation_block "$SKILL_MD_AF")"
  [ -n "$block_af" ] || fail "attestation block missing"

  printf '%s' "$block_af" | grep -qiE 'revok|token' \
    || fail "attestation block does not mention revoked/token"
}

# G7: driver script exists and is executable (green)
@test "(G7) design-stale-transition.sh exists and is executable" {
  [ -x "$DRIVER_SCRIPT" ] || fail "driver script missing or not executable"
}

# G8: stale marker precedes first "Step 8" in add-feature (mirrors stale-propagation ~232)
@test "(G8) stale marker line precedes first Step 8 line in add-feature SKILL.md" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local marker_line step8_line
  marker_line="$(grep -nF '<!-- design-stale-transition begin -->' "$SKILL_MD_AF" | head -1 | cut -d: -f1)"
  [ -n "$marker_line" ] || fail "stale-transition begin marker missing"

  step8_line="$(grep -n 'Step 8' "$SKILL_MD_AF" | head -1 | cut -d: -f1)"
  [ -n "$step8_line" ] || fail "Step 8 not found in add-feature SKILL.md"

  [ "$marker_line" -lt "$step8_line" ] \
    || fail "stale marker (line $marker_line) must precede the first 'Step 8' mention (line $step8_line)"
}

# ===========================================================================
# Doc sync structural tests
# ===========================================================================

@test "(D1) edit-ux doc page describes the republish step" {
  local page="$DOC_DIR/commands/gaia-edit-ux.html"
  [ -f "$page" ] || fail "gaia-edit-ux.html not found at $page"

  grep -qiE 'republish|Republish' "$page" \
    || fail "gaia-edit-ux.html does not describe the republish step"
}

@test "(D2) add-feature doc page describes republish-on-stale" {
  local page="$DOC_DIR/commands/gaia-add-feature.html"
  [ -f "$page" ] || fail "gaia-add-feature.html not found at $page"

  grep -qiE 'republish|conflict detection' "$page" \
    || fail "gaia-add-feature.html does not describe republish-on-stale"
}

@test "(D3) design-lifecycle stale-on-change section describes republish" {
  local page="$DOC_DIR/design-lifecycle.html"
  [ -f "$page" ] || fail "design-lifecycle.html not found at $page"

  # Extract the stale-on-change section
  local stale_section
  stale_section="$(awk '/<section id="stale-on-change">/{p=1} p && /<\/section>/{print;exit} p' "$page")"
  [ -n "$stale_section" ] || fail "stale-on-change section not found in design-lifecycle.html"

  printf '%s' "$stale_section" | grep -qiE 'republish|conflict' \
    || fail "stale-on-change section does not mention republish or conflict"
}

# ===========================================================================
# Drift guard (Val INFO F4): publication procedure consistency
# ===========================================================================

@test "(F4) publication procedure tokens are consistent across all three skill sites" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # The key tokens that must appear in every publication procedure site.
  # create-ux: Step 10. edit-ux: Step 8. add-feature: Step 7b + patch.
  local tokens=(
    'plan-publication.sh'
    'REFRESH_MANIFEST'
    'design-last-published.json'
  )

  # create-ux Step 10 — the reference site
  local cux_step10
  cux_step10="$(_extract_step10_createux)"
  [ -n "$cux_step10" ] || fail "create-ux Step 10 section not found"

  local t
  for t in "${tokens[@]}"; do
    printf '%s' "$cux_step10" | grep -qF "$t" \
      || fail "create-ux Step 10 is missing token: $t"
  done

  # edit-ux Step 8
  local ux_step8
  ux_step8="$(_extract_step8_editux)"
  [ -n "$ux_step8" ] || fail "edit-ux Step 8 section not found"

  for t in "${tokens[@]}"; do
    printf '%s' "$ux_step8" | grep -qF "$t" \
      || fail "edit-ux Step 8 is missing token: $t (drift from create-ux Step 10)"
  done

  # add-feature — check the combined text between stale-transition-end
  # and Step 8, PLUS the patch section in Step 3
  local af_combined
  af_combined="$(_extract_between_stale_end_and_step8_af)"
  local patch_section
  patch_section="$(awk '/^### Step 3.*patch/{p=1} p && /^### Step [^3]/{exit} p' "$SKILL_MD_AF")"
  af_combined="${af_combined}${patch_section}"
  [ -n "$af_combined" ] || fail "add-feature publication procedure text not found"

  for t in "${tokens[@]}"; do
    printf '%s' "$af_combined" | grep -qF "$t" \
      || fail "add-feature publication procedure is missing token: $t (drift from create-ux Step 10)"
  done

  # Failure-rule token: each site must document the stale-on-failure semantics
  printf '%s' "$cux_step10" | grep -qiE 'failed.*operations|failure' \
    || fail "create-ux Step 10 does not mention failure handling"
  printf '%s' "$ux_step8" | grep -qiE 'stays stale|failure' \
    || fail "edit-ux Step 8 does not mention failure/stays-stale"
  printf '%s' "$af_combined" | grep -qiE 'stays stale|failure' \
    || fail "add-feature publication procedure does not mention failure/stays-stale"
}
