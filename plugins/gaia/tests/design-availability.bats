#!/usr/bin/env bats
# design-availability.bats — structural tests for the design-availability
# classification sub-block in create-ux, design-review, add-feature and
# edit-ux, and for the dual-path unauthorized remediation wording across
# all four script sites.
#
# All tests must FAIL on a missing or broken target, never skip.
# No project-root .gaia/ access; all fixtures use mktemp.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

PLUGIN_ROOT="$BATS_TEST_DIRNAME/.."
SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
SKILLS_DIR="$PLUGIN_ROOT/skills"
SKILL_MD_CUX="$SKILLS_DIR/gaia-create-ux/SKILL.md"
SKILL_MD_DR="$SKILLS_DIR/gaia-design-review/SKILL.md"
SKILL_MD_AF="$SKILLS_DIR/gaia-add-feature/SKILL.md"
SKILL_MD_UX="$SKILLS_DIR/gaia-edit-ux/SKILL.md"
PROBE_SCRIPT="$SCRIPTS_DIR/design-probe.sh"
STALE_DRIVER="$SCRIPTS_DIR/design-stale-transition.sh"
GATE_LIB="$SCRIPTS_DIR/lib/design-gate.sh"
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

# _extract_availability_subblock <file>
# Extracts the text between <!-- design-availability begin --> and
# <!-- design-availability end --> markers. Returns empty if absent.
_extract_availability_subblock() {
  awk '/<!-- design-availability begin -->/{p=1;next} /<!-- design-availability end -->/{p=0} p' "$1"
}

# _extract_availability_section <file>
# Extracts the full availability section from the heading
# ("Availability check" or "Integration availability") up to the
# <!-- availability-check end --> comment or the next heading (### or
# ##), whichever comes first. Returns empty if absent.
_extract_availability_section() {
  awk '
    /^\*\*Availability check\.\*\*|^### Precondition — Integration availability/ { p=1; print; next }
    p && (/^###[^#]|^## / || /<!-- availability-check end -->/) { exit }
    p { print }
  ' "$1"
}

# _assert_availability_identity <file> [<file> ...]
# Asserts the availability sub-block is present in every file,
# byte-identical across all of them, and free of design-probe
# references. Requires at least two files.
# Every assertion returns explicitly on failure — under bats `run`,
# errexit is off, so a bare `|| fail` would let the function return 0
# from a subsequent command.
_assert_availability_identity() {
  [ "$#" -ge 2 ] || { fail "identity helper requires at least two files"; return 1; }

  local ref_file="$1" ref_block
  ref_block="$(_extract_availability_subblock "$ref_file")"
  [ -n "$ref_block" ] \
    || { fail "availability sub-block missing from ${ref_file##*/}"; return 1; }

  if grep -qF 'design-probe.sh' <<< "$ref_block"; then
    fail "availability sub-block in ${ref_file##*/} must not reference design-probe.sh"
    return 1
  fi

  shift
  local f cur_block
  for f in "$@"; do
    cur_block="$(_extract_availability_subblock "$f")"
    [ -n "$cur_block" ] \
      || { fail "availability sub-block missing from ${f##*/}"; return 1; }

    diff <(printf '%s' "$ref_block") <(printf '%s' "$cur_block") >/dev/null 2>&1 \
      || { fail "availability sub-block differs between ${ref_file##*/} and ${f##*/}"; return 1; }
  done
}

# =========================================================================
# (AC4a) Classification sub-block identity across all four sites
# =========================================================================

@test "(AC4a) classification sub-block present and identical across all four sites" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  _assert_availability_identity "$SKILL_MD_CUX" "$SKILL_MD_DR" "$SKILL_MD_AF" "$SKILL_MD_UX"
}

# =========================================================================
# (AC4b) create-ux and design-review blocks halt on missing/unauthorized
# =========================================================================

@test "(AC4b) create-ux and design-review blocks halt on missing and unauthorized" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  # Non-vacuity: the availability sub-block must exist
  local block_cux block_dr
  block_cux="$(_extract_availability_subblock "$SKILL_MD_CUX")"
  block_dr="$(_extract_availability_subblock "$SKILL_MD_DR")"
  [ -n "$block_cux" ] || fail "availability sub-block missing from create-ux — cannot check halt"
  [ -n "$block_dr" ] || fail "availability sub-block missing from design-review — cannot check halt"

  local section_cux section_dr
  section_cux="$(_extract_availability_section "$SKILL_MD_CUX")"
  section_dr="$(_extract_availability_section "$SKILL_MD_DR")"
  [ -n "$section_cux" ] || fail "availability section not found in create-ux"
  [ -n "$section_dr" ] || fail "availability section not found in design-review"

  # Extract the missing and unauthorized remediation text separately
  # The expected pattern is: On `missing`, halt with: "..." / On `unauthorized`, halt with: "..."
  local missing_cux missing_dr unauth_cux unauth_dr

  missing_cux="$(echo "$section_cux" | sed -n '/On.*missing.*halt/,/^$/p')" || true
  missing_dr="$(echo "$section_dr" | sed -n '/On.*missing.*halt/,/^$/p')" || true
  unauth_cux="$(echo "$section_cux" | sed -n '/On.*unauthorized.*halt/,/^$/p')" || true
  unauth_dr="$(echo "$section_dr" | sed -n '/On.*unauthorized.*halt/,/^$/p')" || true

  [ -n "$missing_cux" ] || fail "create-ux availability section should halt on missing"
  [ -n "$missing_dr" ] || fail "design-review availability section should halt on missing"
  [ -n "$unauth_cux" ] || fail "create-ux availability section should halt on unauthorized"
  [ -n "$unauth_dr" ] || fail "design-review availability section should halt on unauthorized"

  # The missing and unauthorized remediations must differ (M5 killer)
  if [ "$missing_cux" = "$unauth_cux" ]; then
    fail "create-ux missing and unauthorized remediations must differ"
  fi
  if [ "$missing_dr" = "$unauth_dr" ]; then
    fail "design-review missing and unauthorized remediations must differ"
  fi

  # The unauthorized remediation must contain the exact dual-path wording
  local _expected_dual="Run \`/design-login\` (API-token sessions), or grant design access when prompted (claude.ai sessions)"
  echo "$unauth_cux" | grep -qF '/design-login' \
    || fail "create-ux unauthorized remediation should mention /design-login"
  echo "$unauth_cux" | grep -q 'API-token sessions' \
    || fail "create-ux unauthorized remediation should say API-token sessions"
  echo "$unauth_cux" | grep -q 'grant design access when prompted' \
    || fail "create-ux unauthorized remediation should say grant design access when prompted"
  echo "$unauth_dr" | grep -qF '/design-login' \
    || fail "design-review unauthorized remediation should mention /design-login"
  echo "$unauth_dr" | grep -q 'API-token sessions' \
    || fail "design-review unauthorized remediation should say API-token sessions"
  echo "$unauth_dr" | grep -q 'grant design access when prompted' \
    || fail "design-review unauthorized remediation should say grant design access when prompted"
}

# =========================================================================
# (AC4c) availability blocks contain no design-probe reference
# =========================================================================

@test "(AC4c) availability blocks and sub-block contain no design-probe reference" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  # Non-vacuity guard: the sub-block must exist before we test its contents
  local block_cux block_dr
  block_cux="$(_extract_availability_subblock "$SKILL_MD_CUX")"
  block_dr="$(_extract_availability_subblock "$SKILL_MD_DR")"
  [ -n "$block_cux" ] || fail "availability sub-block missing from create-ux — non-vacuity guard"
  [ -n "$block_dr" ] || fail "availability sub-block missing from design-review — non-vacuity guard"

  # Extract the full section
  local section_cux section_dr
  section_cux="$(_extract_availability_section "$SKILL_MD_CUX")"
  section_dr="$(_extract_availability_section "$SKILL_MD_DR")"
  [ -n "$section_cux" ] || fail "availability section not found in create-ux"
  [ -n "$section_dr" ] || fail "availability section not found in design-review"

  # No design-probe.sh reference in the sub-block itself
  if echo "$block_cux" | grep -q 'design-probe\.sh'; then
    fail "create-ux availability sub-block must not reference design-probe.sh"
  fi
  if echo "$block_dr" | grep -q 'design-probe\.sh'; then
    fail "design-review availability sub-block must not reference design-probe.sh"
  fi

  # No positive usage of design-probe in the section (bash/run/source)
  if echo "$section_cux" | grep -qiE 'bash.*design-probe|run.*design-probe|source.*design-probe|fall back to.*design-probe|fallback.*design-probe'; then
    fail "create-ux availability section must not use design-probe.sh as a fallback"
  fi
  if echo "$section_dr" | grep -qiE 'bash.*design-probe|run.*design-probe|source.*design-probe|fall back to.*design-probe|fallback.*design-probe'; then
    fail "design-review availability section must not use design-probe.sh as a fallback"
  fi

  # No "own probe" / "its own probe" / "probe fallback"
  if echo "$section_cux" | grep -qiE 'own probe|its own probe|probe fallback'; then
    fail "create-ux availability section must not mention probe fallback"
  fi
  if echo "$section_dr" | grep -qiE 'own probe|its own probe|probe fallback'; then
    fail "design-review availability section must not mention probe fallback"
  fi

  # No --integration pass-through
  if echo "$section_cux" | grep -q '\-\-integration'; then
    fail "create-ux availability section must not have --integration pass-through"
  fi
  if echo "$section_dr" | grep -q '\-\-integration'; then
    fail "design-review availability section must not have --integration pass-through"
  fi
}

# =========================================================================
# (AC-EC4) all four unauthorized remediation sites name both paths
# =========================================================================

@test "(AC-EC4) all four unauthorized remediation sites name both paths in same order" {
  [ -f "$PROBE_SCRIPT" ] || fail "design-probe.sh not found"
  [ -f "$STALE_DRIVER" ] || fail "design-stale-transition.sh not found"
  [ -f "$GATE_LIB" ] || fail "lib/design-gate.sh not found"

  # The exact dual-path fragment that every site must contain
  local _dual_path='Run /design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)'

  # Site 1: design-probe.sh _MSG_UNAUTHORIZED
  local probe_line
  probe_line="$(grep '_MSG_UNAUTHORIZED=' "$PROBE_SCRIPT")"
  [ -n "$probe_line" ] || fail "design-probe.sh has no _MSG_UNAUTHORIZED"
  echo "$probe_line" | grep -qF "$_dual_path" \
    || fail "design-probe.sh unauthorized should contain the full dual-path wording"

  # Site 2: design-stale-transition.sh unauthorized printf
  local dst_line
  dst_line="$(grep 'unauthorized.*Run' "$STALE_DRIVER")"
  [ -n "$dst_line" ] || fail "design-stale-transition.sh has no unauthorized remediation line"
  echo "$dst_line" | grep -qF "$_dual_path" \
    || fail "design-stale-transition.sh unauthorized should contain the full dual-path wording"

  # Site 3: lib/design-gate.sh _dg_absent_remediation
  local absent_line
  absent_line="$(grep '_dg_absent_remediation=' "$GATE_LIB")"
  [ -n "$absent_line" ] || fail "design-gate.sh has no _dg_absent_remediation"
  echo "$absent_line" | grep -q 'design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)' \
    || fail "design-gate.sh absent remediation should contain the dual-path wording"

  # Site 4: lib/design-gate.sh _dg_halt_remediation
  local halt_line
  halt_line="$(grep '_dg_halt_remediation=' "$GATE_LIB")"
  [ -n "$halt_line" ] || fail "design-gate.sh has no _dg_halt_remediation"
  echo "$halt_line" | grep -q 'design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)' \
    || fail "design-gate.sh halt remediation should contain the dual-path wording"

  # Order check: design-login must appear before "grant design access" at each site
  local dl_pos gda_pos
  for line_var in "$probe_line" "$dst_line" "$absent_line" "$halt_line"; do
    dl_pos="$(echo "$line_var" | grep -bo 'design-login' | head -1 | cut -d: -f1)"
    gda_pos="$(echo "$line_var" | grep -bo 'grant design access' | head -1 | cut -d: -f1)"
    [ -n "$dl_pos" ] || fail "could not find design-login position"
    [ -n "$gda_pos" ] || fail "could not find grant design access position"
    [ "$dl_pos" -lt "$gda_pos" ] \
      || fail "design-login (pos $dl_pos) should appear before grant design access (pos $gda_pos)"
  done
}

# =========================================================================
# Bounded extraction: create-ux availability section excludes discovery text
# =========================================================================

@test "create-ux availability extraction is bounded and excludes discovery text" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"

  # Work on a copy so we can inject a sentinel
  local copy="$TEST_TMP/create-ux-SKILL.md"
  cp "$SKILL_MD_CUX" "$copy"

  # Inject a sentinel into the discovery text that follows the availability
  # paragraphs (the DesignSync error handling or the design-system discovery).
  # Use a line that cannot appear in real availability text.
  local sentinel="__AVAIL_SENTINEL__"
  # Place sentinel after the "does NOT use design-probe.sh" paragraph —
  # in the next non-empty paragraph (DesignSync authorization error handling).
  awk -v s="$sentinel" '
    /DesignSync authorization error handling/ && !done { print s; done=1 }
    { print }
  ' "$copy" > "$copy.tmp" && mv "$copy.tmp" "$copy"

  # Sentinel guard: confirm the sentinel was actually injected
  grep -qF -- "$sentinel" "$copy" \
    || fail "sentinel was not injected into create-ux copy — test is vacuous"

  local section
  section="$(_extract_availability_section "$copy")"
  [ -n "$section" ] || fail "availability section not found in create-ux copy"

  # Must be at most 20 lines
  local line_count
  line_count="$(printf '%s\n' "$section" | wc -l | tr -d ' ')"
  [ "$line_count" -le 20 ] \
    || fail "create-ux availability extraction is $line_count lines (expected <= 20)"

  # Sentinel must be absent (proves extraction is bounded)
  if printf '%s\n' "$section" | grep -qF "$sentinel"; then
    fail "create-ux extraction should not contain the sentinel — extraction is not bounded"
  fi

  # Discovery text must be absent
  if printf '%s\n' "$section" | grep -q 'Discover an existing design system'; then
    fail "create-ux extraction must not contain discovery text"
  fi
  if printf '%s\n' "$section" | grep -q 'Pass 2'; then
    fail "create-ux extraction must not contain Pass 2 reference"
  fi

  # list_projects must appear exactly once (the availability paragraph itself)
  local lp_count
  lp_count="$(printf '%s\n' "$section" | grep -c 'list_projects' || true)"
  [ "$lp_count" -eq 1 ] \
    || fail "expected exactly 1 list_projects in bounded extraction, got $lp_count"

  # Boundary pin: the "does NOT use design-probe.sh" sentence must be inside
  # the extraction. Moving the end comment above that paragraph would lose it.
  grep -qF 'does NOT use' <<< "$section" \
    || fail "extraction must include the design-probe exclusion sentence"
}

# =========================================================================
# Bounded extraction: design-review availability section excludes stale-resume
# =========================================================================

@test "design-review availability extraction is bounded and excludes stale-resume" {
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  # Work on a copy so we can inject a sentinel
  local copy="$TEST_TMP/design-review-SKILL.md"
  cp "$SKILL_MD_DR" "$copy"

  # Inject a sentinel into the Stale-resume section
  local sentinel="__AVAIL_SENTINEL__"
  awk -v s="$sentinel" '
    /^### Precondition — Stale-resume/ && !done { print; print s; done=1; next }
    { print }
  ' "$copy" > "$copy.tmp" && mv "$copy.tmp" "$copy"

  # Sentinel guard: confirm the sentinel was actually injected
  grep -qF -- "$sentinel" "$copy" \
    || fail "sentinel was not injected into design-review copy — test is vacuous"

  local section
  section="$(_extract_availability_section "$copy")"
  [ -n "$section" ] || fail "availability section not found in design-review copy"

  # Must be at most 20 lines
  local line_count
  line_count="$(printf '%s\n' "$section" | wc -l | tr -d ' ')"
  [ "$line_count" -le 20 ] \
    || fail "design-review availability extraction is $line_count lines (expected <= 20)"

  # Sentinel must be absent
  if printf '%s\n' "$section" | grep -qF "$sentinel"; then
    fail "design-review extraction should not contain the sentinel — extraction is not bounded"
  fi

  # Stale-resume heading itself must be absent
  if printf '%s\n' "$section" | grep -q 'Stale-resume'; then
    fail "design-review extraction must not contain Stale-resume text"
  fi
}

# =========================================================================
# Mutant: removing create-ux availability block fails identity check
# =========================================================================

@test "create-ux mutant with removed availability block fails identity check" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  # Generate mutant: delete the design-availability markers and everything
  # between them — the sub-block extraction should then return empty.
  local mutant="$TEST_TMP/mutant-create-ux.md"
  sed '/<!-- design-availability begin -->/,/<!-- design-availability end -->/d' \
    "$SKILL_MD_CUX" > "$mutant"

  # Mutant must fail the identity check with a "missing" message
  run _assert_availability_identity "$mutant" "$SKILL_MD_DR"
  [ "$status" -ne 0 ] \
    || fail "mutant create-ux should fail identity check but exited $status"
  grep -qF "missing" <<< "$output" \
    || fail "expected 'missing' in failure output, got: $output"
}

# =========================================================================
# Mutant: removing design-review availability block fails identity check
# =========================================================================

@test "design-review mutant with removed availability block fails identity check" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  # Generate mutant: delete the design-availability markers and everything
  # between them from design-review.
  local mutant="$TEST_TMP/mutant-design-review.md"
  sed '/<!-- design-availability begin -->/,/<!-- design-availability end -->/d' \
    "$SKILL_MD_DR" > "$mutant"

  # Mutant must fail the identity check with a "missing" message
  run _assert_availability_identity "$SKILL_MD_CUX" "$mutant"
  [ "$status" -ne 0 ] \
    || fail "mutant design-review should fail identity check but exited $status"
  grep -qF "missing" <<< "$output" \
    || fail "expected 'missing' in failure output, got: $output"
}

# =========================================================================
# Real skill texts pass availability identity check
# =========================================================================

@test "real skill texts pass availability identity check" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"
  [ -f "$SKILL_MD_UX" ] || fail "edit-ux SKILL.md not found"

  run _assert_availability_identity "$SKILL_MD_CUX" "$SKILL_MD_DR" "$SKILL_MD_AF" "$SKILL_MD_UX"
  [ "$status" -eq 0 ] \
    || fail "real files should pass identity check: $output"
}

# =========================================================================
# Mutant: one-byte change in availability block triggers differ failure
# =========================================================================

@test "one-byte mutant in availability block triggers differ failure" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"
  [ -f "$SKILL_MD_AF" ] || fail "add-feature SKILL.md not found"

  # Generate a mutant with a one-byte change inside the shared block.
  local mutant="$TEST_TMP/mutant-onebyte-dr.md"
  awk '
    /<!-- design-availability begin -->/ { inside=1 }
    /<!-- design-availability end -->/   { inside=0 }
    inside && !flipped && /available/ {
      sub(/available/, "availablX"); flipped=1
    }
    { print }
  ' "$SKILL_MD_DR" > "$mutant"

  # Place the mutant in the middle (not last) so a missing return-after-fail
  # in the helper would let the loop continue to a passing final file and
  # mask the failure.
  run _assert_availability_identity "$SKILL_MD_CUX" "$mutant" "$SKILL_MD_AF"
  [ "$status" -ne 0 ] \
    || fail "one-byte mutant should fail identity check"
  grep -qF "differs" <<< "$output" \
    || fail "expected 'differs' in failure output, got: $output"
}

# =========================================================================
# Mutant: design-probe smuggled into all copies triggers probe failure
# =========================================================================

@test "design-probe smuggled into shared block triggers probe failure" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  # Smuggle a design-probe.sh mention into the shared block of both files,
  # keeping them byte-identical so the diff check would pass — the probe
  # check must still catch it.
  local mut_cux="$TEST_TMP/mutant-probe-cux.md"
  local mut_dr="$TEST_TMP/mutant-probe-dr.md"

  _smuggle_probe() {
    awk '
      /<!-- design-availability begin -->/ { inside=1 }
      /<!-- design-availability end -->/ && inside && !injected {
        print "- Use design-probe.sh to verify."
        injected=1; inside=0
      }
      { print }
    ' "$1"
  }
  _smuggle_probe "$SKILL_MD_CUX" > "$mut_cux"
  _smuggle_probe "$SKILL_MD_DR" > "$mut_dr"

  run _assert_availability_identity "$mut_cux" "$mut_dr"
  [ "$status" -ne 0 ] \
    || fail "design-probe smuggle should fail identity check"
  grep -qF "design-probe" <<< "$output" \
    || fail "expected 'design-probe' in failure output, got: $output"
}

# =========================================================================
# Boundary pin: moving end comment above design-probe sentence goes red
# =========================================================================

@test "moving end comment above the design-probe exclusion sentence goes red" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"

  # Create a mutant where the end comment is moved one paragraph up —
  # placed right before the "does NOT use design-probe.sh" line.
  local mutant="$TEST_TMP/mutant-endcomment-cux.md"
  awk '
    /does NOT use.*design-probe/ && !injected {
      print "<!-- availability-check end -->"
      injected=1
    }
    /<!-- availability-check end -->/ && injected { next }
    { print }
  ' "$SKILL_MD_CUX" > "$mutant"

  local section
  section="$(_extract_availability_section "$mutant")"
  [ -n "$section" ] || fail "extraction returned empty for mutant"

  # The extraction should now be MISSING the exclusion sentence, proving
  # the boundary pin catches this move.
  if grep -qF 'does NOT use' <<< "$section"; then
    fail "mutant with moved end comment should lose the exclusion sentence"
  fi
}

# =========================================================================
# (AC1) create-ux availability check precedes first application-level call
# =========================================================================

@test "(AC1) create-ux availability check precedes first application-level Claude Design call" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"

  # Find the design-availability begin marker line
  local avail_line
  avail_line="$(grep -n '<!-- design-availability begin -->' "$SKILL_MD_CUX" | head -1 | cut -d: -f1)" || true
  [ -n "$avail_line" ] || fail "design-availability begin marker not found in create-ux"

  # Find the first application-level list_projects reference in the Steps section
  # (the availability block itself mentions list_projects for classification —
  # we need the SECOND occurrence which is the real application call in Pass 2)
  local steps_start
  steps_start="$(grep -n '^## Steps' "$SKILL_MD_CUX" | head -1 | cut -d: -f1)" || true
  [ -n "$steps_start" ] || fail "## Steps heading not found in create-ux"

  local app_call_line
  app_call_line="$(sed -n "${steps_start},\$p" "$SKILL_MD_CUX" \
    | grep -n 'list_projects' \
    | tail -1 \
    | cut -d: -f1)" || true
  [ -n "$app_call_line" ] || fail "no list_projects reference found after ## Steps"

  # Convert to absolute line number
  app_call_line=$((steps_start + app_call_line - 1))

  [ "$avail_line" -lt "$app_call_line" ] \
    || fail "availability marker (line $avail_line) must precede the application-level list_projects call (line $app_call_line)"
}

# =========================================================================
# (AC2) design-review availability check precedes stale-resume and Step 1
# =========================================================================

@test "(AC2) design-review availability check precedes stale-resume and Step 1" {
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  local avail_line
  avail_line="$(grep -n '<!-- design-availability begin -->' "$SKILL_MD_DR" | head -1 | cut -d: -f1)" || true
  [ -n "$avail_line" ] || fail "design-availability begin marker not found in design-review"

  local stale_line
  stale_line="$(grep -n 'Precondition.*Stale-resume\|Precondition.*Stale.resume' "$SKILL_MD_DR" | head -1 | cut -d: -f1)" || true
  [ -n "$stale_line" ] || fail "Stale-resume precondition not found in design-review"

  local step1_line
  step1_line="$(grep -n '### Step 1' "$SKILL_MD_DR" | head -1 | cut -d: -f1)" || true
  [ -n "$step1_line" ] || fail "Step 1 heading not found in design-review"

  [ "$avail_line" -lt "$stale_line" ] \
    || fail "availability marker (line $avail_line) must precede stale-resume (line $stale_line)"
  [ "$stale_line" -lt "$step1_line" ] \
    || fail "stale-resume (line $stale_line) must precede Step 1 (line $step1_line)"
}

# =========================================================================
# (AC1) create-ux availability block does not use design-probe
# =========================================================================

@test "(AC1) create-ux availability block does not reference design-probe" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"

  local block
  block="$(_extract_availability_subblock "$SKILL_MD_CUX")"
  [ -n "$block" ] || fail "availability sub-block missing from create-ux — non-vacuity guard"

  # The sub-block itself must not reference design-probe
  if echo "$block" | grep -q 'design-probe'; then
    fail "create-ux availability sub-block must not reference design-probe"
  fi

  # The section must not positively use design-probe (bash/run/source/fallback)
  local section
  section="$(_extract_availability_section "$SKILL_MD_CUX")"
  [ -n "$section" ] || fail "availability section not found in create-ux"

  if echo "$section" | grep -qiE 'bash.*design-probe|run.*design-probe|source.*design-probe|fall back to.*design-probe|fallback.*design-probe'; then
    fail "create-ux availability section must not use design-probe as a fallback"
  fi
}

# =========================================================================
# (AC2) design-review availability block does not use design-probe
# =========================================================================

@test "(AC2) design-review availability block does not reference design-probe" {
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  local block
  block="$(_extract_availability_subblock "$SKILL_MD_DR")"
  [ -n "$block" ] || fail "availability sub-block missing from design-review — non-vacuity guard"

  # The sub-block itself must not reference design-probe
  if echo "$block" | grep -q 'design-probe'; then
    fail "design-review availability sub-block must not reference design-probe"
  fi

  # The section must not positively use design-probe
  local section
  section="$(_extract_availability_section "$SKILL_MD_DR")"
  [ -n "$section" ] || fail "availability section not found in design-review"

  if echo "$section" | grep -qiE 'bash.*design-probe|run.*design-probe|source.*design-probe|fall back to.*design-probe|fallback.*design-probe'; then
    fail "design-review availability section must not use design-probe as a fallback"
  fi
}

# =========================================================================
# (AC4c) create-ux and design-review have no --integration pass-through
# =========================================================================

@test "(AC4c) create-ux and design-review availability blocks have no --integration pass-through" {
  [ -f "$SKILL_MD_CUX" ] || fail "create-ux SKILL.md not found"
  [ -f "$SKILL_MD_DR" ] || fail "design-review SKILL.md not found"

  # Non-vacuity
  local block_cux block_dr
  block_cux="$(_extract_availability_subblock "$SKILL_MD_CUX")"
  block_dr="$(_extract_availability_subblock "$SKILL_MD_DR")"
  [ -n "$block_cux" ] || fail "availability sub-block missing from create-ux — non-vacuity guard"
  [ -n "$block_dr" ] || fail "availability sub-block missing from design-review — non-vacuity guard"

  local section_cux section_dr
  section_cux="$(_extract_availability_section "$SKILL_MD_CUX")"
  section_dr="$(_extract_availability_section "$SKILL_MD_DR")"
  [ -n "$section_cux" ] || fail "availability section not found in create-ux"
  [ -n "$section_dr" ] || fail "availability section not found in design-review"

  if echo "$section_cux" | grep -q '\-\-integration'; then
    fail "create-ux availability section must not have --integration"
  fi
  if echo "$section_dr" | grep -q '\-\-integration'; then
    fail "design-review availability section must not have --integration"
  fi
}

# =========================================================================
# (AC3) design-probe unauthorized message names both session types
# =========================================================================

@test "(AC3) design-probe unauthorized message names both session types" {
  [ -f "$PROBE_SCRIPT" ] || fail "design-probe.sh not found"

  local msg_line
  msg_line="$(grep '_MSG_UNAUTHORIZED=' "$PROBE_SCRIPT")"
  [ -n "$msg_line" ] || fail "design-probe.sh has no _MSG_UNAUTHORIZED"

  echo "$msg_line" | grep -qF 'Run /design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)' \
    || fail "design-probe.sh unauthorized should contain the full dual-path wording"
}

# =========================================================================
# (AC3) design-stale-transition unauthorized names both session types
# =========================================================================

@test "(AC3) design-stale-transition unauthorized message names both session types" {
  [ -f "$STALE_DRIVER" ] || fail "design-stale-transition.sh not found"

  local unauth_line
  unauth_line="$(grep 'unauthorized.*Run\|unauthorized.*design-login' "$STALE_DRIVER")"
  [ -n "$unauth_line" ] || fail "design-stale-transition.sh has no unauthorized remediation line"

  echo "$unauth_line" | grep -qF 'Run /design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)' \
    || fail "stale-transition unauthorized should contain the full dual-path wording"
}

# =========================================================================
# (AC3) design-gate absent-record remediation names both session types
# =========================================================================

@test "(AC3) design-gate absent-record remediation names both session types" {
  [ -f "$GATE_LIB" ] || fail "lib/design-gate.sh not found"

  local absent_line
  absent_line="$(grep '_dg_absent_remediation=' "$GATE_LIB")"
  [ -n "$absent_line" ] || fail "design-gate.sh has no _dg_absent_remediation"

  echo "$absent_line" | grep -q 'design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)' \
    || fail "design-gate.sh absent remediation should contain the dual-path wording"
}

# =========================================================================
# (AC3) design-gate state-based halt remediation names both session types
# =========================================================================

@test "(AC3) design-gate state-based halt remediation names both session types" {
  [ -f "$GATE_LIB" ] || fail "lib/design-gate.sh not found"

  local halt_line
  halt_line="$(grep '_dg_halt_remediation=' "$GATE_LIB")"
  [ -n "$halt_line" ] || fail "design-gate.sh has no _dg_halt_remediation"

  echo "$halt_line" | grep -q 'design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)' \
    || fail "design-gate.sh halt remediation should contain the dual-path wording"
}

# =========================================================================
# Doc-sync tests
# =========================================================================

@test "(AC1) create-ux doc page documents availability halt" {
  local doc_page="$DOC_DIR/commands/gaia-create-ux.html"
  [ -s "$doc_page" ] || fail "create-ux doc page not found at documentation/commands/gaia-create-ux.html"

  local ts_section
  ts_section="$(sed -n '/<section id="troubleshooting">/,/<\/section>/p' "$doc_page")"
  [ -n "$ts_section" ] || fail "troubleshooting section not found in create-ux doc page"

  echo "$ts_section" | grep -qi 'unavailable\|unauthorized' \
    || fail "create-ux doc page troubleshooting should mention unavailable or unauthorized"
}

@test "(AC2) design-review doc page documents availability halt" {
  local doc_page="$DOC_DIR/commands/gaia-design-review.html"
  [ -s "$doc_page" ] || fail "design-review doc page not found at documentation/commands/gaia-design-review.html"

  local ts_section
  ts_section="$(sed -n '/<section id="troubleshooting">/,/<\/section>/p' "$doc_page")"
  [ -n "$ts_section" ] || fail "troubleshooting section not found in design-review doc page"

  echo "$ts_section" | grep -qi 'unavailable\|unauthorized' \
    || fail "design-review doc page troubleshooting should mention unavailable or unauthorized"
}

@test "(AC3) design-lifecycle page documents availability check with both paths" {
  local doc_page="$DOC_DIR/design-lifecycle.html"
  [ -s "$doc_page" ] || fail "design-lifecycle.html not found"

  grep -q 'design-login' "$doc_page" \
    || fail "design-lifecycle.html should mention design-login"
  grep -qi 'grant.*design access' "$doc_page" \
    || fail "design-lifecycle.html should mention granting design access"
}
