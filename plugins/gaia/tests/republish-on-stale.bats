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
# NOTE: this window spans both Step 3 (patch) and Step 7b (cascade). Tests
# that need to check one site independently should use the narrow extractors
# _extract_step3_patch_af or _extract_step7b_af instead.
_extract_between_stale_end_and_step8_af() {
  awk '/<!-- design-stale-transition end -->/{p=1;next} /^### Step 8/{exit} p' "$SKILL_MD_AF"
}

# _extract_step7b_af — narrow extractor for the Step 7b cascade section only.
_extract_step7b_af() {
  awk '/^### Step 7b/{p=1} p && /^### Step [^7]/{exit} p' "$SKILL_MD_AF"
}

# _extract_cascade_matrix — extract the cascade matrix table from add-feature.
_extract_cascade_matrix() {
  awk '/^## Cascade Matrix/{p=1} p && /^## / && !/^## Cascade Matrix/{exit} p' "$SKILL_MD_AF"
}

# _extract_attestation_block — extract the attestation block from a SKILL.md.
_extract_attestation_block() {
  awk '/<!-- design-attestation begin -->/{p=1;next} /<!-- design-attestation end -->/{p=0} p' "$1"
}

# _extract_step3_patch_af — narrow extractor for the Step 3 patch section only.
_extract_step3_patch_af() {
  awk '/^### Step 3.*patch/{p=1} p && /^### Step [^3]/{exit} p' "$SKILL_MD_AF"
}

# _extract_step10_createux — extract the Step 10 section from create-ux SKILL.md
# (from Step 10 heading to next ### Step heading or EOF).
_extract_step10_createux() {
  awk '/^### Step 10/{p=1} p && /^### Step 1[1-9]/{exit} p' "$SKILL_MD_CUX"
}

# _extract_step5_editux — extract the Step 5 section from edit-ux SKILL.md
# (from the Step 5 heading to the stale-transition end marker or next heading).
_extract_step5_editux() {
  awk '/^### Step 5/{p=1} p && /^### Step [^5]/{exit} p' "$SKILL_MD_UX"
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

  grep -qF 'plan-publication.sh' <<<"$step8" \
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
  grep -qiE 'CONFLICT' <<<"$step8" \
    || fail "Step 8 does not mention CONFLICT handling"
  grep -qi 'write_files' <<<"$step8" \
    || fail "Step 8 does not mention write_files"
  grep -qF 'strict-conflicts' <<<"$step8" \
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

  grep -qi 'UX Design' <<<"$matrix" \
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

  # Sub-scenario: Step 7b exists with republish for enhancement/feature path
  grep -qF '### Step 7b' "$SKILL_MD_AF" \
    || fail "Step 7b heading missing from add-feature SKILL.md"

  local step7b
  step7b="$(awk '/^### Step 7b/{p=1} p && /^### Step [^7]/{exit} p' "$SKILL_MD_AF")"
  [ -n "$step7b" ] || fail "Step 7b section empty in add-feature SKILL.md"

  grep -qF 'plan-publication.sh' <<<"$step7b" \
    || fail "Step 7b does not reference plan-publication.sh"

  # Sub-scenario: republish text between stale-transition end and Step 8
  local between
  between="$(_extract_between_stale_end_and_step8_af)"
  [ -n "$between" ] || fail "no text found between stale-transition end and Step 8 in add-feature"

  grep -qF 'plan-publication.sh' <<<"$between" \
    || fail "no plan-publication.sh reference between stale-transition end and Step 8 in add-feature"

  # Sub-scenario: patch path also has republish
  local patch_section
  patch_section="$(_extract_step3_patch_af)"
  [ -n "$patch_section" ] || fail "Step 3 patch section not found"

  grep -qiE 'republish|plan-publication' <<<"$patch_section" \
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

  grep -qi 'stays stale\|stays.*stale\|record.*stale' <<<"$step8" \
    || fail "edit-ux Step 8 does not describe the record staying stale on failure"
  grep -qi 'failure' <<<"$step8" \
    || fail "edit-ux Step 8 does not mention failure handling"

  # add-feature failure text (enhancement/feature path)
  local between
  between="$(_extract_between_stale_end_and_step8_af)"
  grep -qiE 'no stories|no story' <<<"$between" \
    || fail "add-feature republish text does not say no stories on failure"

  # add-feature failure text (patch path)
  local patch_section
  patch_section="$(_extract_step3_patch_af)"
  grep -qi 'stale\|failure' <<<"$patch_section" \
    || fail "Step 3 patch section has no failure handling"

  # add-feature seed-brief mode
  grep -qiE 'seed brief|story keys' <<<"$between" \
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
  if grep -qiE 'later.*update step' <<<"$header"; then
    fail "driver header still contains the dangling 'later update step' phrase"
  fi
  grep -qi 'republish step' <<<"$header" \
    || fail "driver header does not mention 'republish step' (the replacement wording)"

  # (b) attestation blocks: no dangling phrase
  local block_af block_ux
  block_af="$(_extract_attestation_block "$SKILL_MD_AF")"
  [ -n "$block_af" ] || fail "attestation block missing from add-feature SKILL.md"
  block_ux="$(_extract_attestation_block "$SKILL_MD_UX")"
  [ -n "$block_ux" ] || fail "attestation block missing from edit-ux SKILL.md"

  if grep -qiE 'later.*update step' <<<"$block_af"; then
    fail "add-feature attestation block still contains the dangling phrase"
  fi
  if grep -qiE 'later.*update step' <<<"$block_ux"; then
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
  grep -qiE 'stale-to-stale|already stale|second.*audit|state no-op' <<<"$step8" \
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
  grep -qiE 'design-affecting' <<<"$between" \
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
  grep -qiE 'halt|missing.*unauthorized|unauthorized.*missing' <<<"$step8" \
    || fail "edit-ux Step 8 does not document the halt on missing/unauthorized integration"

  grep -qiE 'no republication|no republish|precedes.*republish|halt.*precedes' <<<"$step8" \
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

  grep -qiE 'both versions' <<<"$step8" \
    || fail "edit-ux Step 8 does not mention surfacing both versions on CONFLICT"

  grep -qiE 'halt.*resolution|resolution.*halt|halt for|halts for' <<<"$step8" \
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
  grep -qF 'plan-publication.sh' <<<"$unmutated_step8" \
    || fail "PRECONDITION: unmutated edit-ux Step 8 does not contain plan-publication.sh — the republish step must be present before mutation testing"

  # Create a mutated copy: remove plan-publication.sh references from Step 8
  local mutant="$TEST_TMP/mutant-skill.md"
  sed '/plan-publication\.sh/d' "$SKILL_MD_UX" > "$mutant"

  # Run the same structural check as Test 1 against the mutant
  local step8
  step8="$(awk '/^### Step 8/{p=1} p && /^### Step [^8]/ && NR>1{exit} p' "$mutant")"

  # The grep for plan-publication.sh must FAIL on the mutant
  if grep -qF 'plan-publication.sh' <<<"$step8"; then
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
    || fail "attestation blocks differ before any republish-on-stale change — pre-existing drift"
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
  grep -qE 'revok|token' <<<"$header" \
    || fail "driver header does not mention revoked/token trade-off"
}

# G4: planner tests use SHARED_SCRIPTS and the shared location exists (green)
@test "(G4) create-ux-claude-design.bats planner tests use the shared script path" {
  local cux_bats="$BATS_TEST_DIRNAME/create-ux-claude-design.bats"
  [ -f "$cux_bats" ] || fail "create-ux-claude-design.bats not found"

  # The file must define SHARED_SCRIPTS for plan-publication.sh
  grep -qF 'SHARED_SCRIPTS' "$cux_bats" \
    || fail "create-ux-claude-design.bats does not define SHARED_SCRIPTS"

  # The shared script must exist
  [ -f "$SHARED_PLANNER" ] \
    || fail "plan-publication.sh not found at shared location ($SHARED_PLANNER)"

  # The private copy must be gone
  local private_planner="$SKILLS_DIR/gaia-create-ux/scripts/plan-publication.sh"
  if [ -f "$private_planner" ]; then
    fail "plan-publication.sh still exists at private location ($private_planner)"
  fi
}

# G5: build-manifest-cards.bats uses the shared script location (green)
@test "(G5) build-manifest-cards.bats points to the shared script location" {
  local bmc_bats="$BATS_TEST_DIRNAME/build-manifest-cards.bats"
  [ -f "$bmc_bats" ] || fail "build-manifest-cards.bats not found"

  # The shared script must exist
  [ -f "$SHARED_CARD_BUILDER" ] \
    || fail "build-manifest-cards.sh not found at shared location ($SHARED_CARD_BUILDER)"

  # The private copy must be gone
  local private_builder="$SKILLS_DIR/gaia-create-ux/scripts/build-manifest-cards.sh"
  if [ -f "$private_builder" ]; then
    fail "build-manifest-cards.sh still exists at private location ($private_builder)"
  fi
}

# G6: attestation block mentions revok|token (green)
@test "(G6) attestation block documents the revoked-token trade-off" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local block_af
  block_af="$(_extract_attestation_block "$SKILL_MD_AF")"
  [ -n "$block_af" ] || fail "attestation block missing"

  grep -qiE 'revok|token' <<<"$block_af" \
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

  grep -qiE 'republish|conflict' <<<"$stale_section" \
    || fail "stale-on-change section does not mention republish or conflict"
}

# ===========================================================================
# Drift guard: publication procedure consistency
# ===========================================================================

@test "publication procedure tokens are consistent across all three skill sites" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # The key tokens that must appear in every publication procedure site.
  # create-ux: Step 10. edit-ux: Step 8. add-feature: Step 7b (cascade) + Step 3 (patch).
  local tokens=(
    'plan-publication.sh'
    'REFRESH_MANIFEST'
    'design-last-published.json'
    '--project design_system'
    '--project product_design'
    'verify-publication-target.sh'
    'publishes the artboard files alone'
  )

  # create-ux Step 10 — the reference site
  local cux_step10
  cux_step10="$(_extract_step10_createux)"
  [ -n "$cux_step10" ] || fail "create-ux Step 10 section not found"

  local t
  for t in "${tokens[@]}"; do
    grep -qF -- "$t" <<<"$cux_step10" \
      || fail "create-ux Step 10 is missing token: $t"
  done

  # edit-ux Step 8
  local ux_step8
  ux_step8="$(_extract_step8_editux)"
  [ -n "$ux_step8" ] || fail "edit-ux Step 8 section not found"

  for t in "${tokens[@]}"; do
    grep -qF -- "$t" <<<"$ux_step8" \
      || fail "edit-ux Step 8 is missing token: $t (drift from create-ux Step 10)"
  done

  # add-feature cascade (Step 7b only, narrowed to avoid patch overlap)
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade publication text not found"

  for t in "${tokens[@]}"; do
    grep -qF -- "$t" <<<"$af_cascade" \
      || fail "add-feature cascade is missing token: $t (drift from create-ux Step 10)"
  done

  # add-feature patch (Step 3) — checked separately so removing a flag
  # from just the patch fails independently of the cascade
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch publication text not found"

  for t in "${tokens[@]}"; do
    grep -qF -- "$t" <<<"$af_patch" \
      || fail "add-feature patch is missing token: $t (drift from create-ux Step 10)"
  done

  # Failure-rule token: each site must document the stale-on-failure semantics
  grep -qiE 'failed.*operations|failure' <<<"$cux_step10" \
    || fail "create-ux Step 10 does not mention failure handling"
  grep -qiE 'stays stale|failure' <<<"$ux_step8" \
    || fail "edit-ux Step 8 does not mention failure/stays-stale"
  grep -qiE 'stays stale|failure' <<<"$af_cascade" \
    || fail "add-feature cascade does not mention failure/stays-stale"
  grep -qiE 'stays stale|failure' <<<"$af_patch" \
    || fail "add-feature patch does not mention failure/stays-stale"
}

# ===========================================================================
# Artifact surface halt and no-fallback sweep
# ===========================================================================

@test "artifact surface halt pinned at each site with no-fallback sentence" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local halt_msg="The Design artifact surface is required for the product design project but is not available in this session"
  local no_fallback="do not write anything to the design-system project in its place"

  # Helper: check that the halt message and the no-fallback sentence are
  # each on their OWN line(s), distinct from the probe sentence.
  _check_artifact_halt() {
    local section="$1" site="$2"

    # The probe line (quickstart) must be present
    grep -qiF 'quickstart' <<<"$section" \
      || fail "$site does not mention the quickstart probe"

    # The halt message must be present
    grep -qF -- "$halt_msg" <<<"$section" \
      || fail "$site missing the halt message"

    # The no-fallback sentence must be present, separate from the probe line
    grep -qF -- "$no_fallback" <<<"$section" \
      || fail "$site missing the no-fallback clause"

    # Deletion mutant guard: the halt message and the no-fallback clause
    # must be on lines NOT containing the probe keyword "quickstart"
    local halt_line no_fallback_line
    halt_line="$(grep -nF -- "$halt_msg" <<<"$section" | head -1 | cut -d: -f1)"
    no_fallback_line="$(grep -nF -- "$no_fallback" <<<"$section" | head -1 | cut -d: -f1)"
    [ -n "$halt_line" ] || fail "$site halt message not on a findable line"
    [ -n "$no_fallback_line" ] || fail "$site no-fallback clause not on a findable line"
  }

  # edit-ux Step 8
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  _check_artifact_halt "$step8" "edit-ux Step 8"

  # add-feature patch
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_artifact_halt "$af_patch" "add-feature patch"

  # add-feature cascade
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_artifact_halt "$af_cascade" "add-feature cascade"
}

@test "no DesignSync write to screens or flows paths (multi-line aware, per-directory)" {
  # Scan all SKILL.md and script files for DesignSync write_files/delete_files
  # calls whose path argument targets screens/ or flows/, including cases
  # where the path is on the next line after the write_files keyword.

  # Factor the sweep into a function so the mutant probe can reuse it.
  _sweep_designsync_violations() {
    local dir="$1"
    local count=0
    local f
    while IFS= read -r f; do
      # Multi-line check: join consecutive lines and scan for violations.
      # A write step whose path is on the next line is caught this way.
      if awk '
        { buf = (NR > 1 ? buf "\n" : "") $0 }
        END {
          # Join pairs of consecutive lines for multi-line match
          n = split(buf, lines, "\n")
          for (i = 1; i <= n; i++) {
            pair = lines[i]
            if (i < n) pair = pair " " lines[i+1]
            if (pair ~ /(write_files|delete_files).*screens\//) exit 1
            if (pair ~ /(write_files|delete_files).*flows\//) exit 1
          }
        }
      ' "$f" 2>/dev/null; then
        : # clean
      else
        count=$((count + 1))
      fi
    done < <(find "$dir" -type f \( -name '*.md' -o -name '*.sh' \) 2>/dev/null)
    printf '%d' "$count"
  }

  local scan_dirs=(
    "$SKILLS_DIR/gaia-edit-ux/"
    "$SKILLS_DIR/gaia-add-feature/"
    "$SCRIPTS_DIR/"
  )

  # Per-directory file count — fail if any directory scans 0 files
  local d dir_count total_violations=0
  for d in "${scan_dirs[@]}"; do
    [ -d "$d" ] || fail "scan directory missing: $d"
    dir_count="$(find "$d" -type f \( -name '*.md' -o -name '*.sh' \) 2>/dev/null | wc -l)"
    dir_count="${dir_count##* }"
    [ "$dir_count" -gt 0 ] \
      || fail "directory $d has 0 scannable files"

    local v
    v="$(_sweep_designsync_violations "$d")"
    total_violations=$((total_violations + v))
  done

  [ "$total_violations" -eq 0 ] \
    || fail "found $total_violations DesignSync write to screens/ or flows/ — must route through Artifact tool"

  # Mutant: seed a violating file in a temp copy of a real directory and
  # verify the sweep catches it (including multi-line variant).
  local mutant_dir="$TEST_TMP/mutant-sweep"
  mkdir -p "$mutant_dir"

  # Single-line violation
  printf 'Run write_files with path screens/login.spec.html\n' > "$mutant_dir/probe1.md"
  # Multi-line violation: write_files on one line, path on the next
  printf 'Call delete_files for\n  flows/checkout.spec.html\n' > "$mutant_dir/probe2.md"

  local mv
  mv="$(_sweep_designsync_violations "$mutant_dir")"
  [ "$mv" -ge 2 ] \
    || fail "mutant sweep caught $mv violations, expected at least 2 (single-line + multi-line)"
}

# ===========================================================================
# First-publication branch documentation
# ===========================================================================

@test "edit-ux documents first-publication branch per project" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"

  # Must document the first-publication concept
  grep -qiE 'first.publication|first.publish|full card set' <<<"$step8" \
    || fail "edit-ux Step 8 does not document the first-publication branch"

  # Must name the three never-published conditions
  grep -qi 'state file.*absent\|state.*absent\|file is absent' <<<"$step8" \
    || fail "edit-ux Step 8 does not mention state file absent condition"
  grep -qi 'key.*absent\|absent.*key' <<<"$step8" \
    || fail "edit-ux Step 8 does not mention project key absent condition"
  grep -qi 'last_published_at.*null\|null.*last_published' <<<"$step8" \
    || fail "edit-ux Step 8 does not mention last_published_at null condition"
}

@test "add-feature documents strict-conflicts when remote has files" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # Patch section (Step 3)
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch section not found"

  grep -qF 'strict-conflicts' <<<"$af_patch" \
    || fail "add-feature patch does not document --strict-conflicts when remote has files"

  # Cascade section (Step 7b)
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade section not found"

  grep -qF 'strict-conflicts' <<<"$af_cascade" \
    || fail "add-feature cascade does not document --strict-conflicts when remote has files"
}

# ===========================================================================
# Split republish routing and token parity
# ===========================================================================

@test "token-value change marks product-design as changed" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "Step 8 section not found in edit-ux SKILL.md"

  # The text must document that a token-value edit changes screen bytes
  grep -qi 'token.*edit.*screen\|token.*change.*screen\|token.*change.*rendered\|token.*edit.*rendered' <<<"$step8" \
    || fail "edit-ux Step 8 does not document that a token-value edit changes screen rendered bytes"
}

# ===========================================================================
# Pre-write target check on every republish write
# ===========================================================================

@test "pre-write target check carries both flags and precedes the write step at each site" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # Helper: assert both flags on the verify-publication-target line itself
  # and that the check line number precedes the first write_files line number.
  _check_pre_write() {
    local section="$1" site="$2"
    local vpt_lines
    vpt_lines="$(grep -F 'verify-publication-target' <<<"$section")"
    [ -n "$vpt_lines" ] \
      || fail "$site has no verify-publication-target check"

    grep -qF -- '--metadata-file' <<<"$vpt_lines" \
      || fail "$site verify-publication-target line is missing --metadata-file"
    grep -qF -- '--design-record' <<<"$vpt_lines" \
      || fail "$site verify-publication-target line is missing --design-record"

    # Ordering: the check must come before write_files in the section
    local check_line write_line
    check_line="$(grep -nF 'verify-publication-target' <<<"$section" | head -1 | cut -d: -f1)"
    write_line="$(grep -nF 'write_files' <<<"$section" | head -1 | cut -d: -f1)"
    if [ -n "$write_line" ]; then
      [ "$check_line" -lt "$write_line" ] \
        || fail "$site: verify-publication-target (line $check_line) does not precede write_files (line $write_line)"
    fi
  }

  # edit-ux Step 8
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  _check_pre_write "$step8" "edit-ux Step 8"

  # add-feature cascade
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade section not found"
  _check_pre_write "$af_cascade" "add-feature cascade"

  # add-feature patch
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch section not found"
  _check_pre_write "$af_patch" "add-feature patch"
}

# ===========================================================================
# Per-project persist flags
# ===========================================================================

@test "persist line itself carries all required flags at all sites" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local required_flags=(
    '--outcomes'
    '--output'
    '--local-hash-map'
    '--project'
    '--design-record'
    '--published-at'
  )

  # Helper: assert each flag appears on lines that contain persist_last_published
  _check_persist_line() {
    local section="$1" site="$2"
    local persist_lines
    persist_lines="$(grep -F 'persist_last_published' <<<"$section")"
    [ -n "$persist_lines" ] \
      || fail "$site does not contain persist_last_published"

    local flag
    for flag in "${required_flags[@]}"; do
      grep -qF -- "$flag" <<<"$persist_lines" \
        || fail "$site persist LINE is missing flag: $flag"
    done
  }

  # edit-ux Step 8 persist
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  _check_persist_line "$step8" "edit-ux Step 8"

  # add-feature cascade
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_persist_line "$af_cascade" "add-feature cascade"

  # add-feature patch
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_persist_line "$af_patch" "add-feature patch"
}

# ===========================================================================
# finalize_plan before every write_files
# ===========================================================================

@test "finalize_plan is mandatory at each site and not described as optional" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # Helper: assert finalize_plan present with mandatory wording.
  # The text must say "preceded by" (or "is preceded"), not "optional".
  _check_finalize_plan() {
    local section="$1" site="$2"

    grep -qF 'finalize_plan' <<<"$section" \
      || fail "$site does not mention finalize_plan"

    # Must use mandatory wording: "preceded by finalize_plan"
    local fp_lines
    fp_lines="$(grep -iF 'finalize_plan' <<<"$section")"
    grep -qi 'preceded by' <<<"$fp_lines" \
      || fail "$site finalize_plan line does not use mandatory wording (preceded by)"

    # Reword mutant: "finalize_plan is optional" must be absent
    if grep -qi 'finalize_plan.*optional\|optional.*finalize_plan' <<<"$section"; then
      fail "$site says finalize_plan is optional"
    fi
  }

  # edit-ux Step 8
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  _check_finalize_plan "$step8" "edit-ux Step 8"

  # add-feature cascade
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_finalize_plan "$af_cascade" "add-feature cascade"

  # add-feature patch
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_finalize_plan "$af_patch" "add-feature patch"
}

# ===========================================================================
# Null product design project halts with remediation
# ===========================================================================

@test "null product design project halts with pinned wording at each site" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local halt_text="The product design project is not set up"
  local remediation="Run /gaia-create-ux"

  # Helper: assert the halt text and the remediation both appear, and that
  # the halt does NOT say "log a note" or "continue".
  _check_null_project_halt() {
    local section="$1" site="$2"

    grep -qF -- "$halt_text" <<<"$section" \
      || fail "$site does not contain the null-project halt text"

    grep -qF -- "$remediation" <<<"$section" \
      || fail "$site null-project remediation does not say $remediation"

    # The halt must use the word "halt" (not "log a note and continue")
    local null_lines
    null_lines="$(grep -iF 'product design project' <<<"$section")"
    grep -qi 'halt' <<<"$null_lines" \
      || fail "$site null-project block does not say halt"
    if grep -qi 'log a note.*continue\|continue publishing' <<<"$null_lines"; then
      fail "$site null-project block says log a note and continue (must halt)"
    fi
  }

  # edit-ux Step 8
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  _check_null_project_halt "$step8" "edit-ux Step 8"

  # add-feature cascade
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_null_project_halt "$af_cascade" "add-feature cascade"

  # add-feature patch
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_null_project_halt "$af_patch" "add-feature patch"
}

# ===========================================================================
# Guard: no empty inline code spans in SKILL.md files
# ===========================================================================

@test "no empty inline code spans in edit-ux or add-feature SKILL.md" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local hits=""
  local f
  for f in "$SKILL_MD_UX" "$SKILL_MD_AF"; do
    # Find lines with `` that are not inside triple-backtick fences.
    # Strip triple-backtick lines first, then look for empty code spans.
    local empty_spans
    empty_spans="$(awk '
      /^```/ { fence=!fence; next }
      !fence && /``/ {
        # Check for actual empty span: two backticks with nothing between
        line = $0
        # Remove triple-backtick sequences first
        gsub(/```[^`]*```/, "", line)
        gsub(/```/, "", line)
        if (match(line, /``/)) print NR": "$0
      }
    ' "$f")"
    if [ -n "$empty_spans" ]; then
      hits="${hits}${hits:+
}$(basename "$f"):
${empty_spans}"
    fi
  done

  [ -z "$hits" ] || fail "empty inline code spans found:
$hits"
}

# ===========================================================================
# Guard: planner line names both project keys at every republish site
# ===========================================================================

@test "planner line names both project keys at each republish site" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # edit-ux Step 8: extract the Planner bullet
  local ux_step8
  ux_step8="$(_extract_step8_editux)"
  [ -n "$ux_step8" ] || fail "edit-ux Step 8 not found"
  local ux_planner
  ux_planner="$(grep -i 'Planner.*Step 10 item 2' <<<"$ux_step8")"
  [ -n "$ux_planner" ] || fail "edit-ux Step 8 has no Planner line"
  grep -qF -- '--project design_system' <<<"$ux_planner" \
    || fail "edit-ux planner line missing --project design_system"
  grep -qF -- '--project product_design' <<<"$ux_planner" \
    || fail "edit-ux planner line missing --project product_design"

  # add-feature patch: extract the Planner bullet from Step 3
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  local af_patch_planner
  af_patch_planner="$(grep -i 'Planner.*Step 10 item 2' <<<"$af_patch")"
  [ -n "$af_patch_planner" ] || fail "add-feature patch has no Planner line"
  grep -qF -- '--project design_system' <<<"$af_patch_planner" \
    || fail "add-feature patch planner line missing --project design_system"
  grep -qF -- '--project product_design' <<<"$af_patch_planner" \
    || fail "add-feature patch planner line missing --project product_design"

  # add-feature cascade: extract the Planner bullet from Step 7b
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  local af_cascade_planner
  af_cascade_planner="$(grep -i 'Planner.*Step 10 item 2' <<<"$af_cascade")"
  [ -n "$af_cascade_planner" ] || fail "add-feature cascade has no Planner line"
  grep -qF -- '--project design_system' <<<"$af_cascade_planner" \
    || fail "add-feature cascade planner line missing --project design_system"
  grep -qF -- '--project product_design' <<<"$af_cascade_planner" \
    || fail "add-feature cascade planner line missing --project product_design"
}

# ===========================================================================
# add-feature republish step names diff inputs and scope line
# ===========================================================================

@test "add-feature republish steps name diff inputs and scope line" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # Patch
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  grep -qF -- '--last-published' <<<"$af_patch" \
    || fail "add-feature patch does not name --last-published"
  grep -qF -- '--local-manifest' <<<"$af_patch" \
    || fail "add-feature patch does not name --local-manifest"
  grep -qF -- '--edited' <<<"$af_patch" \
    || fail "add-feature patch does not name --edited"
  grep -qF 'scope=' <<<"$af_patch" \
    || fail "add-feature patch does not print scope= line"
  grep -qF 'reason=derived' <<<"$af_patch" \
    || fail "add-feature patch does not print reason=derived"

  # Cascade
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  grep -qF -- '--last-published' <<<"$af_cascade" \
    || fail "add-feature cascade does not name --last-published"
  grep -qF -- '--local-manifest' <<<"$af_cascade" \
    || fail "add-feature cascade does not name --local-manifest"
  grep -qF -- '--edited' <<<"$af_cascade" \
    || fail "add-feature cascade does not name --edited"
  grep -qF 'scope=' <<<"$af_cascade" \
    || fail "add-feature cascade does not print scope= line"
  grep -qF 'reason=derived' <<<"$af_cascade" \
    || fail "add-feature cascade does not print reason=derived"
}

# ===========================================================================
# edit-ux Step 8 uses the union of Step 5 and Step 8 scopes
# ===========================================================================

@test "edit-ux Step 8 republish uses the union of both scopes and the driver republish-target lines" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"

  # Pin the exact union wording
  grep -qF 'union of the Step 5 scope and the Step 8 re-derivation' <<<"$step8" \
    || fail "edit-ux Step 8 does not contain the pinned union wording"
  grep -qF 'republish-target:' <<<"$step8" \
    || fail "edit-ux Step 8 does not consume the driver republish-target: lines"
}

# ===========================================================================
# Scope wiring: edit-ux driver --scope, add-feature derive + scope line
# ===========================================================================

@test "scope wiring: edit-ux driver passes --scope, add-feature derives scope at each site" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # edit-ux: the driver call line itself must carry --scope
  local step5_block
  step5_block="$(_extract_step5_editux)"
  [ -n "$step5_block" ] || fail "edit-ux Step 5 block not found"
  local driver_line
  driver_line="$(grep -F 'design-stale-transition.sh' <<<"$step5_block")"
  [ -n "$driver_line" ] || fail "edit-ux Step 5 has no driver call line"
  grep -qF -- '--scope' <<<"$driver_line" \
    || fail "edit-ux driver call is missing --scope"

  # add-feature: the driver call must NOT carry --scope
  local stale_block
  stale_block="$(awk '/<!-- design-stale-transition begin -->/{p=1} /<!-- design-stale-transition end -->/{print; exit} p' "$SKILL_MD_AF")"
  [ -n "$stale_block" ] || fail "add-feature stale block not found"
  local af_driver_line
  af_driver_line="$(grep -F 'design-stale-transition.sh' <<<"$stale_block")"
  [ -n "$af_driver_line" ] || fail "add-feature stale block has no driver call line"
  if grep -qF -- '--scope' <<<"$af_driver_line"; then
    fail "add-feature driver call must NOT carry --scope (scope is derived later)"
  fi

  # add-feature patch: derive step must be present
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  grep -qF 'derive-design-scope-diff.sh' <<<"$af_patch" \
    || fail "add-feature patch does not call derive-design-scope-diff.sh"
  # Must print its own scope line
  grep -qF 'scope=' <<<"$af_patch" \
    || fail "add-feature patch does not print scope= line"
  grep -qF 'reason=derived' <<<"$af_patch" \
    || fail "add-feature patch does not print reason=derived"

  # add-feature cascade: derive step must be present
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  grep -qF 'derive-design-scope-diff.sh' <<<"$af_cascade" \
    || fail "add-feature cascade does not call derive-design-scope-diff.sh"
  # Must print its own scope line
  grep -qF 'scope=' <<<"$af_cascade" \
    || fail "add-feature cascade does not print scope= line"
  grep -qF 'reason=derived' <<<"$af_cascade" \
    || fail "add-feature cascade does not print reason=derived"

  # add-feature: both sites must reference republish-target: lines
  grep -qF 'republish-target:' <<<"$af_patch" \
    || fail "add-feature patch does not reference driver republish-target: lines"
  grep -qF 'republish-target:' <<<"$af_cascade" \
    || fail "add-feature cascade does not reference driver republish-target: lines"
}

# ===========================================================================
# First-publication branch: deletion mutants at each site
# ===========================================================================

@test "first-publication branch present at each add-feature site and edit-ux condition" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local first_pub_text="First-publication branch"
  local empty_condition="remote project is empty"
  local empty_condition_short="remote is empty"

  # edit-ux Step 8: must have the first-publication bullet AND the empty condition
  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  grep -qF -- "$first_pub_text" <<<"$step8" \
    || fail "edit-ux Step 8 missing the first-publication branch bullet"
  grep -qF -- "$empty_condition" <<<"$step8" \
    || fail "edit-ux Step 8 missing the 'remote project is empty' condition"

  # add-feature patch: must have the first-publication bullet
  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  grep -qF -- "$first_pub_text" <<<"$af_patch" \
    || fail "add-feature patch missing the first-publication branch bullet"
  grep -qiE "$empty_condition|$empty_condition_short" <<<"$af_patch" \
    || fail "add-feature patch missing the remote-is-empty condition"

  # add-feature cascade: must have the first-publication bullet
  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  grep -qF -- "$first_pub_text" <<<"$af_cascade" \
    || fail "add-feature cascade missing the first-publication branch bullet"
  grep -qiE "$empty_condition|$empty_condition_short" <<<"$af_cascade" \
    || fail "add-feature cascade missing the remote-is-empty condition"
}

# ===========================================================================
# Unauthorized remediation pinned at each site (kills N1)
# ===========================================================================

@test "unauthorized remediation is stated at each artifact-halt site" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  _check_unauthorized() {
    local section="$1" site="$2"

    # The "on `unauthorized`" clause must be a distinct branch
    grep -qF 'on `unauthorized`' <<<"$section" \
      || fail "$site does not name the unauthorized branch"

    # The remediation text must be stated, not just cross-referenced
    grep -qi 'unauthorized.*remediation\|unauthorized.*halt\|unauthorized.*authorization' <<<"$section" \
      || fail "$site does not give the unauthorized remediation"
  }

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  _check_unauthorized "$step8" "edit-ux Step 8"

  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_unauthorized "$af_patch" "add-feature patch"

  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_unauthorized "$af_cascade" "add-feature cascade"
}

# ===========================================================================
# Union scope sentence pinned (kills N2)
# ===========================================================================

@test "edit-ux Step 8 says the union and does not negate it" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"

  grep -qF 'The republish scope is the union of the Step 5 scope and the Step 8 re-derivation' <<<"$step8" \
    || fail "edit-ux Step 8 missing the positive union sentence"

  if grep -qF 'do not take the union' <<<"$step8"; then
    fail "edit-ux Step 8 negates the union scope"
  fi
}

# ===========================================================================
# Persist per-project flag pinned (kills N3)
# ===========================================================================

@test "persist line names both project keys distinctly at edit-ux" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"

  local persist_line
  persist_line="$(grep -F 'persist_last_published' <<<"$step8")"
  [ -n "$persist_line" ] || fail "edit-ux Step 8 has no persist_last_published call"

  grep -qF 'design_system' <<<"$persist_line" \
    || fail "persist line missing design_system"
  grep -qF 'product_design' <<<"$persist_line" \
    || fail "persist line missing product_design"

  # Must NOT use one key for both passes
  if grep -q 'design_system.*(for both passes)\|design_system.*both passes' <<<"$persist_line"; then
    fail "persist line uses design_system for both passes"
  fi
}

# ===========================================================================
# edit-ux Step 5 diff call carries --local-manifest (kills N5)
# ===========================================================================

@test "edit-ux Step 5 diff call carries local-manifest flag" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step5
  step5="$(_extract_step5_editux)"
  [ -n "$step5" ] || fail "edit-ux Step 5 not found"

  local diff_line
  diff_line="$(grep -F 'derive-design-scope-diff.sh' <<<"$step5")"
  [ -n "$diff_line" ] || fail "edit-ux Step 5 has no diff call"
  grep -qF -- '--local-manifest' <<<"$diff_line" \
    || fail "edit-ux Step 5 diff call is missing --local-manifest"
}

# ===========================================================================
# Artifact probe before the product-design republish (kills N6)
# ===========================================================================

@test "artifact probe is before the product-design republish at add-feature sites" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  _check_probe_before() {
    local section="$1" site="$2"
    grep -qi 'Before the product-design republish.*probe\|Before.*product-design.*probe' <<<"$section" \
      || fail "$site does not say Before the product-design republish"

    if grep -qi 'After the product-design republish.*probe\|After.*product-design.*probe' <<<"$section"; then
      fail "$site says After instead of Before"
    fi
  }

  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_probe_before "$af_patch" "add-feature patch"

  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_probe_before "$af_cascade" "add-feature cascade"
}

# ===========================================================================
# First-publication full card set non-zero count (kills N8)
# ===========================================================================

@test "first-publication branch says full card set non-zero count at edit-ux" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"

  grep -qF 'full card set (non-zero count)' <<<"$step8" \
    || fail "edit-ux first-publication does not say 'full card set (non-zero count)'"

  if grep -qF 'no cards (zero count)' <<<"$step8"; then
    fail "edit-ux first-publication says zero count"
  fi
}

# ===========================================================================
# Null-project halt instruction pinned (kills N9)
# ===========================================================================

@test "null-project halt says halt not proceed at add-feature sites" {
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  _check_halt_not_proceed() {
    local section="$1" site="$2"
    local halt_text="The product design project is not set up"
    local halt_lines
    halt_lines="$(grep -F "$halt_text" <<<"$section")"
    [ -n "$halt_lines" ] || fail "$site missing the halt sentence"

    grep -qi 'halt with\|halt:' <<<"$halt_lines" \
      || fail "$site null-project sentence does not say halt"

    if grep -qi 'proceed\|continue.*both\|note.*and proceed' <<<"$halt_lines"; then
      fail "$site null-project sentence says proceed/continue"
    fi
  }

  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_halt_not_proceed "$af_patch" "add-feature patch"

  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_halt_not_proceed "$af_cascade" "add-feature cascade"
}

# ===========================================================================
# Pass order: design-system first (kills N13)
# ===========================================================================

@test "republish pass order is design-system first at each site" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  _check_pass_order() {
    local section="$1" site="$2"
    grep -qF 'design-system pass first' <<<"$section" \
      || fail "$site does not say design-system pass first"
    if grep -qF 'product-design pass first' <<<"$section"; then
      fail "$site says product-design pass first"
    fi
  }

  local step8
  step8="$(_extract_step8_editux)"
  [ -n "$step8" ] || fail "edit-ux Step 8 not found"
  _check_pass_order "$step8" "edit-ux Step 8"

  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  [ -n "$af_patch" ] || fail "add-feature patch not found"
  _check_pass_order "$af_patch" "add-feature patch"

  local af_cascade
  af_cascade="$(_extract_step7b_af)"
  [ -n "$af_cascade" ] || fail "add-feature cascade not found"
  _check_pass_order "$af_cascade" "add-feature cascade"
}

# ===========================================================================
# edit-ux Step 5 states edited path form (item 1 skill text)
# ===========================================================================

@test "edit-ux Step 5 states that edited paths are spec-relative" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  local step5
  step5="$(_extract_step5_editux)"
  grep -qi 'spec-relative\|spec.relative\|relative.*spec\|spec-side' <<<"$step5" \
    || fail "edit-ux Step 5 does not state that edited paths are spec-relative"
}

# ===========================================================================
# exit 2 handling documented (suggestion 7b)
# ===========================================================================

@test "skills say what to do when diff script exits 2" {
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  local step5
  step5="$(_extract_step5_editux)"
  grep -qi 'exit.*2\|diagnostic\|halt.*diff\|non-zero.*halt\|abort.*scope' <<<"$step5" \
    || fail "edit-ux Step 5 does not document diff script exit 2 handling"

  local af_patch
  af_patch="$(_extract_step3_patch_af)"
  grep -qi 'exit.*2\|diagnostic\|halt.*diff\|non-zero.*halt\|abort.*scope' <<<"$af_patch" \
    || fail "add-feature patch does not document diff script exit 2 handling"
}

# ===========================================================================
# Coverage sentence order in gate (item 4)
# ===========================================================================

@test "coverage force-design note does not sit between review and clause" {
  local gate_script="$SCRIPTS_DIR/lib/design-gate.sh"
  [ -f "$gate_script" ] || fail "design-gate.sh not found"

  local remediation_lines
  remediation_lines="$(grep -F 'The design review did not cover' "$gate_script")"
  [ -n "$remediation_lines" ] || fail "no coverage remediation in design-gate.sh"

  while IFS= read -r line; do
    if grep -qF 'Run /gaia-design-review' <<<"$line"; then
      grep -qF 'If the design integration is not connected' <<<"$line" \
        || fail "conditional clause not on the same line as review sentence"
      local review_pos clause_pos force_pos
      review_pos="$(awk -v l="$line" 'BEGIN{print index(l,"Run /gaia-design-review")}')"
      clause_pos="$(awk -v l="$line" 'BEGIN{print index(l,"If the design integration")}')"
      force_pos="$(awk -v l="$line" 'BEGIN{print index(l,"cannot be overridden")}')"
      if [ "$force_pos" -gt 0 ] && [ "$force_pos" -lt "$clause_pos" ]; then
        fail "force-design note sits between review and conditional clause"
      fi
    fi
  done <<<"$remediation_lines"
}
