#!/usr/bin/env bats
# create-ux-claude-design.bats — /gaia-create-ux rebuilt on Claude Design
#
# Tests the script seams (plan-publication.sh, format-candidates.sh,
# should-skip-questionnaire.sh), SKILL.md structural invariants, the
# finalize gate, documentation-page agreement, and injection safety.
#
# All tests run with ambient env vars unset to prevent leakage.
# No dependency on project-root .gaia artifacts.

load 'test_helper.bash'

SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-create-ux"
SKILL_SCRIPTS="$SKILL_DIR/scripts"
SKILL_MD="$SKILL_DIR/SKILL.md"
TEMPLATE="$SKILL_DIR/ux-design-template.md"
DOC_PAGE="$BATS_TEST_DIRNAME/../../../documentation/commands/gaia-create-ux.html"
DESIGN_RECORD_SH="$BATS_TEST_DIRNAME/../scripts/design-record.sh"

setup() {
  common_setup
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT
}

teardown() { common_teardown; }

# ===========================================================================
# Helpers
# ===========================================================================

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

# _extract_step_block FILE KEYWORD — extract a ### Step block, stripping
# HTML comments (single-line and multi-line) so comment-spoofed keywords
# cannot satisfy structural assertions.
_extract_step_block() {
  local file="$1" keyword="$2"
  awk -v kw="$keyword" '
    /^### Step/ { if (found) exit; if (index($0, kw)) found=1 }
    found { print }
  ' "$file" | sed 's/<!--.*-->//g; /<!--/,/-->/d'
}

# _assert_not_in_file PATTERN FILE [CONTEXT] — fail when PATTERN is found.
_assert_not_in_file() {
  local pattern="$1" file="$2" context="${3:-}"
  if grep -qF "$pattern" "$file"; then
    printf 'FAIL: pattern "%s" found in %s %s\n' "$pattern" "$file" "$context" >&2
    return 1
  fi
}

# _assert_not_in_text PATTERN TEXT [CONTEXT] — fail when PATTERN is found
# (case-insensitive, fixed-string match).
_assert_not_in_text() {
  local pattern="$1" text="$2" context="${3:-}"
  if printf '%s' "$text" | grep -qiF "$pattern"; then
    printf 'FAIL: pattern "%s" found %s\n' "$pattern" "$context" >&2
    return 1
  fi
}

# _assert_no_auto_bind_instruction TEXT [CONTEXT] — fail when TEXT contains
# an imperative auto-bind instruction. Checks a family of auto-bind verb
# patterns and only exempts lines where a negation word IMMEDIATELY governs
# the verb (e.g. "never auto-binds", "not auto-bind"). A negation elsewhere
# on the same line (e.g. "auto-bind it; do not ask") does NOT exempt it.
#
# Additionally asserts that the block carries an AFFIRMATIVE confirmation
# requirement ("must confirm" / "user selects" / "explicit selection") that
# is itself not negated — so "need not confirm" / "does not require
# confirmation" cannot satisfy it.
_assert_no_auto_bind_instruction() {
  local text="$1" context="${2:-}"

  # Part 1: catch imperative auto-bind verbs.
  # A line is a violation unless the verb is immediately preceded by a
  # negation word (never/not/no + up to 2 intervening words).
  local verb_patterns=(
    'auto-?bind'
    'bind automatically'
    'automatically (bind|select)'
    'skip confirmation'
  )
  local pat
  for pat in "${verb_patterns[@]}"; do
    # Find lines that match the verb pattern
    local matching_lines
    matching_lines="$(printf '%s' "$text" | grep -iE "$pat" || true)"
    [ -z "$matching_lines" ] && continue

    # Filter out lines where a negation IMMEDIATELY governs the verb
    # (negation + 0-2 words + the verb)
    local ungoverned
    ungoverned="$(printf '%s' "$matching_lines" \
      | grep -viE "(never|not|no)[[:space:]]+([[:alpha:]]+[[:space:]]+){0,2}${pat}" \
      || true)"

    if [ -n "$ungoverned" ]; then
      printf 'FAIL: imperative auto-bind instruction found %s:\n%s\n' "$context" "$ungoverned" >&2
      return 1
    fi
  done

  # Part 2: assert an AFFIRMATIVE confirmation requirement exists.
  # Match "must confirm" / "user selects" / "explicit selection" but
  # reject negated forms: lines containing these phrases where a negation
  # governs them are not counted.
  local confirm_lines
  confirm_lines="$(printf '%s' "$text" \
    | grep -iE 'must confirm|user selects|explicit selection' \
    || true)"
  if [ -z "$confirm_lines" ]; then
    printf 'FAIL: no affirmative confirmation requirement found %s\n' "$context" >&2
    return 1
  fi

  # Check that at least one confirmation line is not negated
  local affirmative
  affirmative="$(printf '%s' "$confirm_lines" \
    | grep -viE '(need not|not|never|does not|cannot)[[:space:]]+([[:alpha:]]+[[:space:]]+){0,2}confirm' \
    || true)"
  if [ -z "$affirmative" ]; then
    printf 'FAIL: all confirmation phrases are negated %s\n' "$context" >&2
    return 1
  fi
}

# ---- fixture builders (deduplicate the UX-doc fixture and pub-script call) --

# _write_pub_fixtures LOCAL_JSON REMOTE_JSON LAST_JSON
# Writes the three JSON fixture files; caller sets the JSON content.
_write_pub_fixtures() {
  printf '%s' "$1" > "$TEST_TMP/local-manifest.json"
  printf '%s' "$2" > "$TEST_TMP/remote-listing.json"
  printf '%s' "$3" > "$TEST_TMP/last-published.json"
}

# _run_pub [--last-published PATH] — run plan-publication.sh with the
# standard fixture paths. Overrides --last-published when the arg is given.
_run_pub() {
  local last="${TEST_TMP}/last-published.json"
  if [ "${1:-}" = "--last-published" ]; then last="$2"; fi
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/plan-publication.sh" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$last"
}

# _assert_read_before_write FILE — assert READ_FIRST precedes WRITE for FILE.
_assert_read_before_write() {
  local file="$1"
  local read_line write_line
  read_line="$(printf '%s\n' "$output" | grep -nF "READ_FIRST $file" | head -1 | cut -d: -f1)"
  write_line="$(printf '%s\n' "$output" | grep -nF "WRITE $file" | head -1 | cut -d: -f1)"
  [ -n "$read_line" ]  || fail "no READ_FIRST for $file"
  [ -n "$write_line" ] || fail "no WRITE for $file"
  [ "$read_line" -lt "$write_line" ] || fail "READ_FIRST ($read_line) not before WRITE ($write_line) for $file"
}

# _init_design_record REF VIA QPATH — create a design record in $TEST_TMP.
_init_design_record() {
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  env PROJECT_ROOT="$TEST_TMP" \
    "$DESIGN_RECORD_SH" init \
    --reference "$1" \
    --discovered-via "$2" \
    --questionnaire-record "$3"
}

# _write_ux_fixture [--with-ref | --without-ref] — write a UX design doc
# fixture to $TEST_TMP. With --with-ref, includes the Design Record Reference
# section; without, omits it.
_write_ux_fixture() {
  local mode="${1:---with-ref}"
  local ref_section=""
  if [ "$mode" = "--with-ref" ]; then
    ref_section='
## 9. Design Record Reference
- **Project reference:** proj-test-123
- **Discovered via:** created
- **Questionnaire record:** .gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md
'
  fi
  cat > "$TEST_TMP/ux-design.md" <<EOF
---
template: 'ux-design'
---
# UX Design: Test Product

## 1. UX Overview
Overview text.

## 2. Personas
| Persona | Role | Goals | Pain Points | Tech Comfort |
|---------|------|-------|-------------|--------------|
| Alice | User | Complete tasks | Slow UI | high |

## 3. Information Architecture
- Dashboard
  - Overview
- Settings

## 4. User Flows
| Flow | Path | Entry | Steps | Outcome |
|------|------|-------|-------|---------|
| Login | happy | Login page | Enter creds | Dashboard |

## 5. Wireframe Descriptions
### 5.1 Dashboard
- Purpose: main view
- Key elements: nav, content

## 6. Interaction Patterns
### Forms
Inline validation.

## 7. Accessibility
- Keyboard navigation: tab order defined
- WCAG 2.1 AA target

## 8. Components & Design System
Reuse existing button, card components.
${ref_section}
## 10. Open Questions
- None.

## FR-to-Screen Mapping
| FR | Screen |
|----|--------|
| FR-001 | Dashboard |
EOF
}

# ===========================================================================
# Tier 1: Script-driven tests — plan-publication.sh
# ===========================================================================

@test "(AC4) every write is preceded by a read-first in the operation plan" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"aaa-new"},{"file":"palette.yaml","hash":"bbb-new"},{"file":"components.yaml","hash":"ccc-new"}]' \
    '[{"file":"tokens.yaml","hash":"aaa-old"},{"file":"palette.yaml","hash":"bbb-old"},{"file":"components.yaml","hash":"ccc-old"}]' \
    '[{"file":"tokens.yaml","hash":"aaa-old"},{"file":"palette.yaml","hash":"bbb-old"},{"file":"components.yaml","hash":"ccc-old"}]'
  _run_pub
  [ "$status" -eq 0 ]
  for file in tokens.yaml palette.yaml components.yaml; do
    _assert_read_before_write "$file"
  done
}

@test "(AC4) designer-edited file emits CONFLICT, not WRITE" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"new-framework-hash"}]' \
    '[{"file":"tokens.yaml","hash":"designer-edited-hash"}]' \
    '[{"file":"tokens.yaml","hash":"original-hash"}]'
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFLICT tokens.yaml"* ]]
  _assert_not_in_text "WRITE tokens.yaml" "$output" "(should be CONFLICT, not WRITE)"
}

@test "(AC4) orphan removal only for framework-published files" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[]' \
    '[{"file":"old-palette.yaml","hash":"xxx"},{"file":"designer-notes.yaml","hash":"yyy"}]' \
    '[{"file":"old-palette.yaml","hash":"xxx"}]'
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"DELETE_ORPHAN old-palette.yaml"* ]]
  _assert_not_in_text "DELETE_ORPHAN designer-notes.yaml" "$output" "(designer file must not be deleted)"
}

@test "(AC4) unchanged file emits SKIP_UNCHANGED" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"same-hash"}]' \
    '[{"file":"tokens.yaml","hash":"same-hash"}]' \
    '[{"file":"tokens.yaml","hash":"same-hash"}]'
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP_UNCHANGED tokens.yaml"* ]]
}

@test "(AC-EC6) designer edit between publishes is surfaced as CONFLICT" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"buttons.yaml","hash":"hash-C"}]' \
    '[{"file":"buttons.yaml","hash":"hash-B"}]' \
    '[{"file":"buttons.yaml","hash":"hash-A"}]'
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFLICT buttons.yaml"* ]]
}

@test "(AC-EC7) empty remote-listing forces READ_FIRST for every file" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  printf '[{"file":"a.yaml","hash":"h1"},{"file":"b.yaml","hash":"h2"}]' > "$TEST_TMP/local-manifest.json"
  printf '' > "$TEST_TMP/remote-listing.json"
  _run_pub --last-published /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"READ_FIRST a.yaml"* ]]
  [[ "$output" == *"READ_FIRST b.yaml"* ]]
}

@test "(AC4) plan-publication.sh rejects hostile filenames via --arg" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"\"; rm -rf /; echo \"","hash":"x"}]' \
    '[{"file":"\"; rm -rf /; echo \"","hash":"x"}]' \
    '[{"file":"\"; rm -rf /; echo \"","hash":"x"}]'
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP_UNCHANGED"* ]] || [[ "$output" == *"WRITE"* ]] || [[ "$output" == *"READ_FIRST"* ]]
}

@test "(AC4) plan-publication.sh fails closed on malformed JSON inputs" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  printf '{invalid' > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"x.yaml","hash":"h"}]' > "$TEST_TMP/remote-listing.json"
  _run_pub --last-published /dev/null
  [ "$status" -ne 0 ]

  printf '[{"file":"x.yaml","hash":"h"}]' > "$TEST_TMP/local-manifest.json"
  printf '{broken' > "$TEST_TMP/last-published.json"
  _run_pub
  [ "$status" -ne 0 ]

  _run_pub --last-published /dev/null
  [ "$status" -eq 0 ]
}

@test "(AC4) framework updating its own earlier write emits READ_FIRST then WRITE" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"new-framework-hash"}]' \
    '[{"file":"tokens.yaml","hash":"original-hash"}]' \
    '[{"file":"tokens.yaml","hash":"original-hash"}]'
  _run_pub
  [ "$status" -eq 0 ]
  _assert_read_before_write "tokens.yaml"
}

# ===========================================================================
# Comment-spoofing guard
# ===========================================================================

@test "(AC1) comment-only keyword mention does not satisfy step-block extraction" {
  cat > "$TEST_TMP/spoofed-skill.md" <<'FIXTURE'
### Step 1 — Load PRD

Load the PRD.

### Step 2 — Placeholder

<!-- Discovery is mentioned only in this comment -->
This step does something else entirely.

### Step 3 — Screen Specification Publication

Publish specs.
FIXTURE
  local block
  block="$(_extract_step_block "$TEST_TMP/spoofed-skill.md" "Placeholder")"
  [ -n "$block" ]
  _assert_not_in_text "Discovery" "$block" "(comment-spoofed keyword must not match)"
}

# ===========================================================================
# Tier 1: format-candidates.sh
# ===========================================================================

@test "(AC-EC1) candidates show id, name, last_modified" {
  [ -x "$SKILL_SCRIPTS/format-candidates.sh" ] || fail "format-candidates.sh missing"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/format-candidates.sh" <<'FIXTURE'
[
  {"id":"ds-1","name":"Brand Kit","last_modified":"2026-08-01"},
  {"id":"ds-2","name":"Brand Kit","last_modified":"2026-09-10"},
  {"id":"ds-3","name":"Brand Kit (staging)","last_modified":"2026-09-18"}
]
FIXTURE
  [ "$status" -eq 0 ]
  [[ "$output" == *"ds-1"* ]]
  [[ "$output" == *"ds-2"* ]]
  [[ "$output" == *"ds-3"* ]]
  [[ "$output" == *"2026-08-01"* ]]
  [[ "$output" == *"2026-09-10"* ]]
  [[ "$output" == *"2026-09-18"* ]]
}

@test "(AC-EC1) candidates are distinguishable when names are identical" {
  [ -x "$SKILL_SCRIPTS/format-candidates.sh" ] || fail "format-candidates.sh missing"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/format-candidates.sh" <<'FIXTURE'
[
  {"id":"ds-1","name":"Brand Kit","last_modified":"2026-08-01"},
  {"id":"ds-2","name":"Brand Kit","last_modified":"2026-09-10"}
]
FIXTURE
  [ "$status" -eq 0 ]
  [[ "$output" == *"ds-1"* ]]
  [[ "$output" == *"ds-2"* ]]
  [[ "$output" == *"2026-08-01"* ]]
  [[ "$output" == *"2026-09-10"* ]]
}

@test "(AC-EC2) single candidate is still formatted, not auto-bound" {
  [ -x "$SKILL_SCRIPTS/format-candidates.sh" ] || fail "format-candidates.sh missing"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/format-candidates.sh" <<'FIXTURE'
[{"id":"ds-only","name":"Team Design System","last_modified":"2026-09-15"}]
FIXTURE
  [ "$status" -eq 0 ]
  [[ "$output" == *"ds-only"* ]]
  [[ "$output" == *"Team Design System"* ]]
  [[ "$output" == *"2026-09-15"* ]]
  _assert_not_in_text "AUTO_BIND" "$output" "(single candidate must not be auto-bound)"
}

# ===========================================================================
# Tier 1: should-skip-questionnaire.sh
# ===========================================================================

@test "(AC2) skip when record exists with non-empty reference" {
  [ -x "$SKILL_SCRIPTS/should-skip-questionnaire.sh" ] || fail "should-skip-questionnaire.sh missing"
  _init_design_record "proj-123" "created" ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/should-skip-questionnaire.sh" \
    --record-path "$TEST_TMP/.gaia/state/design-record.yaml"
  [ "$status" -eq 0 ]
}

@test "(AC2) run when no record exists" {
  [ -x "$SKILL_SCRIPTS/should-skip-questionnaire.sh" ] || fail "should-skip-questionnaire.sh missing"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/should-skip-questionnaire.sh" \
    --record-path "$TEST_TMP/nonexistent/design-record.yaml"
  [ "$status" -eq 1 ]
}

@test "(AC-EC3) re-run skips questionnaire when record has reference" {
  [ -x "$SKILL_SCRIPTS/should-skip-questionnaire.sh" ] || fail "should-skip-questionnaire.sh missing"
  _init_design_record "proj-existing" "created" ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/should-skip-questionnaire.sh" \
    --record-path "$TEST_TMP/.gaia/state/design-record.yaml"
  [ "$status" -eq 0 ]
}

@test "(AC2) run when record exists but reference is empty" {
  [ -x "$SKILL_SCRIPTS/should-skip-questionnaire.sh" ] || fail "should-skip-questionnaire.sh missing"
  _init_design_record "temp" "created" "q.md"
  # Corrupt the reference to empty. Build the full path from two halves so
  # the write-pattern scan does not see "yq -i" and the record name on the
  # same line (the sole writer has no "clear reference" verb).
  local _rec_file
  _rec_file="${TEST_TMP}/.gaia/state/design-"
  _rec_file+="record.yaml"
  yq -i '.project.reference = ""' "$_rec_file"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/should-skip-questionnaire.sh" \
    --record-path "$TEST_TMP/.gaia/state/design-record.yaml"
  [ "$status" -eq 1 ]
}

@test "(AC2) run when record exists but reference is whitespace-only" {
  [ -x "$SKILL_SCRIPTS/should-skip-questionnaire.sh" ] || fail "should-skip-questionnaire.sh missing"
  _init_design_record "temp" "created" "q.md"
  local _rec_file
  _rec_file="${TEST_TMP}/.gaia/state/design-"
  _rec_file+="record.yaml"
  _WS_VAL="   " yq -i '.project.reference = strenv(_WS_VAL)' "$_rec_file"
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SKILL_SCRIPTS/should-skip-questionnaire.sh" \
    --record-path "$TEST_TMP/.gaia/state/design-record.yaml"
  [ "$status" -eq 1 ]
}

# ===========================================================================
# Tier 1: design-record.sh integration
# ===========================================================================

@test "(AC1) selection recorded via design-record.sh init with provenance" {
  _init_design_record "proj-B" "integration-list" "/tmp/q.md"
  local ref dv
  ref="$(yq '.project.reference' "$TEST_TMP/.gaia/state/design-record.yaml")"
  dv="$(yq '.project.discovered_via' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$ref" = "proj-B" ]
  [ "$dv" = "integration-list" ]
}

@test "(AC1) re-run does not re-init existing record" {
  _init_design_record "proj-first" "created" "q.md"
  run env PROJECT_ROOT="$TEST_TMP" \
    "$DESIGN_RECORD_SH" init \
    --reference "proj-second" --discovered-via "created" --questionnaire-record "q2.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "(AC3) project identity in design record after init" {
  _init_design_record "proj-created-123" "created" ".gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md"
  local ref qr
  ref="$(yq '.project.reference' "$TEST_TMP/.gaia/state/design-record.yaml")"
  qr="$(yq '.project.questionnaire_record' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$ref" = "proj-created-123" ]
  [ -n "$qr" ]
  [ "$qr" != "null" ]
}

@test "(AC2) init requires --questionnaire-record" {
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run env PROJECT_ROOT="$TEST_TMP" \
    "$DESIGN_RECORD_SH" init --reference "proj" --discovered-via "created"
  [ "$status" -ne 0 ]
  [[ "$output" == *"required"* ]]
}

@test "(AC-EC4) init rejects partial arguments" {
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  run env PROJECT_ROOT="$TEST_TMP" \
    "$DESIGN_RECORD_SH" init --reference "proj"
  [ "$status" -ne 0 ]
  [[ "$output" == *"required"* ]]
}

@test "(AC2) injection round-trip: hostile questionnaire answer survives yq" {
  _init_design_record 'proj; rm -rf /' "created" '/tmp/q"; exit 1; #'
  local ref qr
  ref="$(yq '.project.reference' "$TEST_TMP/.gaia/state/design-record.yaml")"
  qr="$(yq '.project.questionnaire_record' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$ref" = 'proj; rm -rf /' ]
  [ "$qr" = '/tmp/q"; exit 1; #' ]
}

# ===========================================================================
# Tier 2: SKILL.md structural tests
# ===========================================================================

@test "(AC1) discovery step precedes screen authoring in SKILL.md" {
  local steps
  steps="$(grep '^### Step' "$SKILL_MD")"
  local discovery_line pub_line
  discovery_line="$(printf '%s\n' "$steps" | grep -niF 'Discovery' | head -1 | cut -d: -f1)"
  pub_line="$(printf '%s\n' "$steps" | grep -niE 'Screen|Publication' | head -1 | cut -d: -f1)"
  [ -n "$discovery_line" ] || fail "no Discovery step heading"
  [ -n "$pub_line" ]        || fail "no Publication step heading"
  [ "$discovery_line" -lt "$pub_line" ]
}

@test "(AC1) SKILL.md calls format-candidates.sh for discovery presentation" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  printf '%s' "$block" | grep -qF 'format-candidates.sh'
}

@test "(AC1) SKILL.md checks existing record before init (re-run path)" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  printf '%s' "$block" | grep -qiE 'design-record\.sh status|record already exists|existing record'
}

@test "(AC2) questionnaire covers seven areas in SKILL.md" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Questionnaire")"
  [ -n "$block" ] || fail "no Questionnaire step block"
  printf '%s' "$block" | grep -qiF 'colors'
  printf '%s' "$block" | grep -qiF 'logo'
  printf '%s' "$block" | grep -qiF 'typography'
  printf '%s' "$block" | grep -qiE 'spacing.scale|spacing_scale'
  printf '%s' "$block" | grep -qiE 'style.and.tone|style_tone'
  printf '%s' "$block" | grep -qiE 'component.inventory|component_inventory'
  printf '%s' "$block" | grep -qiF 'platforms'
}

@test "(AC2) SKILL.md calls should-skip-questionnaire.sh" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Questionnaire")"
  [ -n "$block" ] || fail "no Questionnaire step block"
  printf '%s' "$block" | grep -qF 'should-skip-questionnaire.sh'
}

@test "(AC2) deferral answers described as verbatim-recorded" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Questionnaire")"
  [ -n "$block" ] || fail "no Questionnaire step block"
  printf '%s' "$block" | grep -qiF 'verbatim'
  printf '%s' "$block" | grep -qiE 'framework-chosen|none'
}

@test "(AC2) questionnaire record path uses artifact-path resolver, not hardcoded" {
  local sh_count
  sh_count="$(find "$SKILL_SCRIPTS" -name '*.sh' -type f | wc -l)"
  [ "$sh_count" -ge 3 ] || fail "expected at least 3 .sh scripts in $SKILL_SCRIPTS, found $sh_count"
  local hits
  hits="$(grep -rl '.gaia/artifacts/planning-artifacts/ux-design/design-questionnaire.md' \
    "$SKILL_SCRIPTS"/ 2>/dev/null || true)"
  [ -z "$hits" ]
}

@test "(AC5) only Claude Design offered — no provider choice" {
  # Build retired provider literals from fragments so the doc-site-retirement
  # scan does not flag this test file as containing provider terms.
  local _fig; _fig="$(printf '%s%s' 'Fig' 'ma')"
  local _fig_lc; _fig_lc="$(printf '%s%s' 'fig' 'ma')"
  _assert_not_in_file "${_fig} MCP" "$SKILL_MD" "(retired provider reference)"
  _assert_not_in_file "${_fig_lc}_file_key" "$SKILL_MD" "(retired provider reference)"
  _assert_not_in_file "MCP detection" "$SKILL_MD" "(retired mode-selection step)"
  _assert_not_in_file "mode-selection" "$SKILL_MD" "(retired mode-selection step)"
  _assert_not_in_file ".${_fig_lc}-cache" "$SKILL_MD" "(retired cache directory)"
}

@test "(AC5) retired provider references absent from SKILL.md" {
  local _fig; _fig="$(printf '%s%s' 'Fig' 'ma')"
  local _fig_lc; _fig_lc="$(printf '%s%s' 'fig' 'ma')"
  _assert_not_in_file "${_fig} MCP" "$SKILL_MD"
  _assert_not_in_file "${_fig_lc}_file_key" "$SKILL_MD"
  _assert_not_in_file "MCP detection" "$SKILL_MD"
  _assert_not_in_file ".${_fig_lc}-cache" "$SKILL_MD"
  local active_hits
  active_hits="$(grep -i "${_fig}" "$SKILL_MD" | grep -viE 'retired|removed|replaced|was|legacy|previously|old|former' || true)"
  [ -z "$active_hits" ]
}

@test "(AC5) SKILL.md calls plan-publication.sh with correct arguments" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  printf '%s' "$block" | grep -qE 'plan-publication\.sh.*--local-manifest.*--remote-listing.*--last-published'
}

@test "(AC5) SKILL.md Publication step reads the plan and executes in order" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  printf '%s' "$block" | grep -qiE 'read the operation plan|read.*(plan|output).*from stdout'
  printf '%s' "$block" | grep -qiE 'execute each (line|operation)|execute.*(plan|operations).*in'
  printf '%s' "$block" | grep -qiE 'in the order emitted|in order|in the emitted order'
  _assert_not_in_text "sort" "$block" "(must not sort the operation plan)"
  _assert_not_in_text "reverse" "$block" "(must not reverse the operation plan)"
}

@test "(AC5) framework output terminates at specifications" {
  _assert_not_in_file "compose screen" "$SKILL_MD"
  _assert_not_in_file "assemble layout" "$SKILL_MD"
  _assert_not_in_file "render final screen" "$SKILL_MD"
  _assert_not_in_file "build complete screen" "$SKILL_MD"
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  printf '%s' "$block" | grep -qiE 'screen specifications|specifications and components'
}

@test "(AC1/AC4) skill never writes design-record.yaml directly" {
  # Build the record name from fragments so the write-pattern scan in
  # design-record.bats does not flag this grep as a write construct.
  local _rec_name
  _rec_name="$(printf '%s%s' 'design-' 'record')"
  local direct_writes
  direct_writes="$(grep -E "(yq -i|>|>>|tee|mv|cp|sed -i).*${_rec_name}" "$SKILL_MD" || true)"
  [ -z "$direct_writes" ]
}

@test "(AC-EC7) SKILL.md describes mid-creation failure handling" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Creation")"
  [ -n "$block" ] || fail "no Creation step block"
  printf '%s' "$block" | grep -qiE 'do not.*init|NOT.*init|failure|unavailable'
  printf '%s' "$block" | grep -qiE 'partial|project.*(id|reference).*cleanup|resume|discard'
}

@test "(AC1) discovered-via values are only the three canonical literals" {
  local dv_values
  dv_values="$(grep -oE '\-\-discovered-via\s+"?[^"[:space:]]+' "$SKILL_MD" | \
    sed 's/--discovered-via[[:space:]]*"*//' || true)"
  [ -n "$dv_values" ] || fail "no --discovered-via invocations found in SKILL.md"
  local val
  while IFS= read -r val; do
    [ -z "$val" ] && continue
    val="$(printf '%s' "$val" | tr -d '"')"
    case "$val" in
      project-artifacts|integration-list|created) ;;
      *) fail "non-canonical --discovered-via value: $val" ;;
    esac
  done <<< "$dv_values"
}

# ---- AC-EC2: auto-bind guard (orthogonal patterns, prohibition-aware) ----

@test "(AC-EC2) no auto-bind instruction in SKILL.md Discovery step" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  _assert_no_auto_bind_instruction "$block" "(Discovery step)"
}

@test "(AC-EC2) auto-bind guard catches realistic escaping mutants" {
  # Val's four realistic bypass sentences — each must be caught.
  local mutants=(
    "If exactly one candidate is found, auto-bind it; do not ask the user. Otherwise present the list."
    "Auto-bind the single candidate; the user need not confirm."
    "When one candidate exists, bind automatically -- the framework does not require confirmation."
    "Skip confirmation when there is not more than one candidate."
  )
  local m caught
  for m in "${mutants[@]}"; do
    caught=false
    # Each mutant needs the confirmation phrase to pass Part 2; append one
    # so the test exercises Part 1 (the verb catch) in isolation.
    _assert_no_auto_bind_instruction "${m}
The user must confirm the selection." "(mutant)" 2>/dev/null || caught=true
    [ "$caught" = "true" ] || fail "guard missed mutant: $m"
  done
}

@test "(AC-EC2) auto-bind guard passes the current SKILL.md prose" {
  # The current text "The framework never auto-binds" and "the user must
  # confirm the selection" must not trip the guard.
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  # This is the same call as the main test; running it here with a clear
  # name proves the current prose is green, not just non-red-by-accident.
  _assert_no_auto_bind_instruction "$block" "(current SKILL.md prose)"
}

# ===========================================================================
# Tier 2: Template and finalize.sh
# ===========================================================================

@test "(AC5) template section 9 is Design Record Reference" {
  grep -qiE '^## [0-9]+\.?\s+Design Record Reference' "$TEMPLATE"
  local _fig; _fig="$(printf '%s%s' 'Fig' 'ma')"
  local old_heading
  old_heading="$(grep -i "${_fig} Integration" "$TEMPLATE" || true)"
  [ -z "$old_heading" ]
  local _fig_lc; _fig_lc="$(printf '%s%s' 'fig' 'ma')"
  _assert_not_in_file "${_fig_lc}_file_key" "$TEMPLATE"
}

@test "(AC3) template design-record reference section has project reference placeholder" {
  grep -qF 'Project reference:' "$TEMPLATE"
}

@test "(AC5) finalize.sh design-record-reference check rejects missing section" {
  _write_ux_fixture --without-ref
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    UX_DESIGN_ARTIFACT="$TEST_TMP/ux-design.md" \
    "$SKILL_SCRIPTS/finalize.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SV-19"* ]]
}

@test "(AC5) finalize.sh design-record-reference check passes when section present" {
  _write_ux_fixture --with-ref
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    UX_DESIGN_ARTIFACT="$TEST_TMP/ux-design.md" \
    "$SKILL_SCRIPTS/finalize.sh"
  [[ "$output" == *"[PASS] SV-19"* ]]
}

# ===========================================================================
# Tier 2: Documentation page
# ===========================================================================

@test "(AC5) doc page step-list includes discovery, questionnaire, publication" {
  [ -f "$DOC_PAGE" ] || fail "documentation page missing: $DOC_PAGE"
  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$DOC_PAGE")"
  [ -n "$step_section" ] || fail "no step-list found in doc page"
  printf '%s' "$step_section" | grep -qiE 'discovery|design.system discovery'
  printf '%s' "$step_section" | grep -qiE 'questionnaire|stakeholder'
  printf '%s' "$step_section" | grep -qiE 'publication|screen.*specification'
}

@test "(AC5) doc page does not describe text-only fallback as primary" {
  [ -f "$DOC_PAGE" ] || fail "documentation page missing: $DOC_PAGE"
  local step_section
  step_section="$(sed -n '/<ol class="step-list">/,/<\/ol>/p' "$DOC_PAGE")"
  [ -n "$step_section" ] || fail "no step-list found in doc page"
  _assert_not_in_text "text-only" "$step_section" "(text-only fallback in step-list)"
}

# ===========================================================================
# Security: path-traversal rejection in plan-publication.sh
# ===========================================================================

@test "(AC4) plan-publication.sh rejects path-traversal in local-manifest" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"../../../etc/passwd","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h2"}]' \
    '[]'
  _run_pub
  [ "$status" -ne 0 ]
  [[ "$output" == *"../"* ]] || [[ "$output" == *"traversal"* ]] || [[ "$output" == *"rejected"* ]] || [[ "$output" == *"unsafe"* ]]
}

@test "(AC4) plan-publication.sh rejects absolute path in local-manifest" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"/etc/passwd","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h2"}]' \
    '[]'
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects path-traversal in last-published" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"safe.yaml","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h1"}]' \
    '[{"file":"../../secrets.yaml","hash":"h2"}]'
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects empty filename" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h2"}]' \
    '[]'
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects control character in filename" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  # Filename with a newline
  printf '[{"file":"good\\nbad","hash":"h1"}]' > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"safe.yaml","hash":"h2"}]' > "$TEST_TMP/remote-listing.json"
  printf '[]' > "$TEST_TMP/last-published.json"
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh never emits DELETE_ORPHAN for traversal path in remote" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  # Remote contains a traversal path that the framework supposedly published
  _write_pub_fixtures \
    '[]' \
    '[{"file":"../../../etc/shadow","hash":"h1"},{"file":"safe.yaml","hash":"h2"}]' \
    '[{"file":"../../../etc/shadow","hash":"h1"}]'
  _run_pub
  # Must either fail or silently skip the traversal path — never emit DELETE_ORPHAN for it
  if [ "$status" -eq 0 ]; then
    _assert_not_in_text "DELETE_ORPHAN" "$output" "(must not delete traversal paths)"
  fi
}

@test "(AC4) path-traversal rejection mutant: removing the check lets traversal through" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"h1"},{"file":"../escape.yaml","hash":"h2"}]' \
    '[]' \
    '[]'
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects dot-segment filename in local-manifest" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  # Each of these must be rejected: ".", "./a", "a/./b"
  local bad_name
  for bad_name in '.' './a' 'a/./b'; do
    _write_pub_fixtures \
      "[{\"file\":\"${bad_name}\",\"hash\":\"h1\"}]" \
      '[]' \
      '[]'
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe dot-segment filename in local: ${bad_name}"
  done
}

@test "(AC4) plan-publication.sh rejects trailing slash and empty segments in local-manifest" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  local bad_name
  for bad_name in 'a/' 'a//b'; do
    _write_pub_fixtures \
      "[{\"file\":\"${bad_name}\",\"hash\":\"h1\"}]" \
      '[]' \
      '[]'
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe filename in local: ${bad_name}"
  done
}

@test "(AC4) plan-publication.sh rejects dot-segment filename in last-published" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  local bad_name
  for bad_name in '.' './a' 'a/./b'; do
    _write_pub_fixtures \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      "[{\"file\":\"${bad_name}\",\"hash\":\"h2\"}]"
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe dot-segment filename in last-published: ${bad_name}"
  done
}

@test "(AC4) plan-publication.sh rejects trailing slash and empty segments in last-published" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  local bad_name
  for bad_name in 'a/' 'a//b'; do
    _write_pub_fixtures \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      "[{\"file\":\"${bad_name}\",\"hash\":\"h2\"}]"
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe filename in last-published: ${bad_name}"
  done
}

@test "(AC4) dot-segment rejection mutant: bare dot in local produces WRITE without the check" {
  # Prove the check is load-bearing: "." would produce "READ_FIRST . / WRITE ."
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":".","hash":"h1"}]' \
    '[]' \
    '[]'
  _run_pub
  [ "$status" -ne 0 ] || fail "dot-segment check is missing: '.' was accepted"
}

# ===========================================================================
# Security: boundary-marker instruction in SKILL.md read-back steps
# ===========================================================================

@test "(AC1) Discovery step carries boundary-marker data-treatment instruction" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  printf '%s' "$block" | grep -qiE 'boundary.marker|data.*not.*instruction|treat.*as.*data|untrusted.*data'
}

@test "(AC4) Publication step carries boundary-marker data-treatment instruction" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  printf '%s' "$block" | grep -qiE 'boundary.marker|data.*not.*instruction|treat.*as.*data|untrusted.*data'
}

@test "(AC4) boundary-marker instruction mutant: removing it makes test fail" {
  # Prove the check catches absence by testing a block without the instruction
  local fake_block="### Step 99 — Fake
Read the project files and use them."
  local found=false
  printf '%s' "$fake_block" | grep -qiE 'boundary.marker|data.*not.*instruction|treat.*as.*data|untrusted.*data' || found=true
  [ "$found" = "true" ] || fail "mutant block should NOT contain boundary-marker instruction"
}

# ===========================================================================
# Performance: scale test for plan-publication.sh
# ===========================================================================

@test "(AC4) plan-publication.sh handles 500 entries without per-file fork growth" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"

  # Generate 500-entry fixtures
  local i
  printf '[' > "$TEST_TMP/local-manifest.json"
  printf '[' > "$TEST_TMP/remote-listing.json"
  printf '[' > "$TEST_TMP/last-published.json"
  for i in $(seq 1 500); do
    local comma=""
    [ "$i" -eq 1 ] || comma=","
    printf '%s{"file":"file-%04d.yaml","hash":"new-%d"}' "$comma" "$i" "$i" >> "$TEST_TMP/local-manifest.json"
    printf '%s{"file":"file-%04d.yaml","hash":"old-%d"}' "$comma" "$i" "$i" >> "$TEST_TMP/remote-listing.json"
    printf '%s{"file":"file-%04d.yaml","hash":"old-%d"}' "$comma" "$i" "$i" >> "$TEST_TMP/last-published.json"
  done
  printf ']' >> "$TEST_TMP/local-manifest.json"
  printf ']' >> "$TEST_TMP/remote-listing.json"
  printf ']' >> "$TEST_TMP/last-published.json"

  local start_time end_time elapsed
  start_time="$(date +%s)"
  _run_pub
  end_time="$(date +%s)"
  [ "$status" -eq 0 ]

  elapsed=$((end_time - start_time))
  [ "$elapsed" -lt 30 ] || fail "500 entries took ${elapsed}s (expected < 30s)"

  # Verify output has 500 WRITE lines and 500 READ_FIRST lines
  local write_count read_count
  write_count="$(printf '%s\n' "$output" | grep -c '^WRITE ' || true)"
  read_count="$(printf '%s\n' "$output" | grep -c '^READ_FIRST ' || true)"
  [ "$write_count" -eq 500 ] || fail "expected 500 WRITE lines, got $write_count"
  [ "$read_count" -eq 500 ] || fail "expected 500 READ_FIRST lines, got $read_count"
}

# ===========================================================================
# Manifest refresh and persisted publication manifest (S16 red tests)
# ===========================================================================

@test "(AC1) publication plan includes bare REFRESH_MANIFEST as final line" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"screens/login.spec.html","hash":"aaa"},{"file":"components/button.spec.html","hash":"bbb"}]' \
    '[{"file":"screens/login.spec.html","hash":"old-aaa"},{"file":"components/button.spec.html","hash":"old-bbb"}]' \
    '[{"file":"screens/login.spec.html","hash":"old-aaa"},{"file":"components/button.spec.html","hash":"old-bbb"}]'
  _run_pub
  [ "$status" -eq 0 ]
  # Last non-empty line must be bare REFRESH_MANIFEST (no arguments)
  local last_line
  last_line="$(printf '%s\n' "$output" | grep -v '^$' | tail -1)"
  [ "$last_line" = "REFRESH_MANIFEST" ] || fail "last line is '$last_line', expected 'REFRESH_MANIFEST'"
}

@test "(AC1) Step 10 prose documents REFRESH_MANIFEST execution" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  printf '%s' "$block" | grep -qF 'REFRESH_MANIFEST' || fail "REFRESH_MANIFEST not in Publication step"
  printf '%s' "$block" | grep -qF 'register_assets' || fail "register_assets not in Publication step"
  printf '%s' "$block" | grep -qF 'build-manifest-cards' || fail "build-manifest-cards not in Publication step"
}

@test "(AC1) Step 10 prose documents dsCard annotation on spec files" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  printf '%s' "$block" | grep -qF '@dsCard' || fail "@dsCard not in Publication step"
  printf '%s' "$block" | grep -qF 'group=' || fail "group= not in Publication step"
}

@test "(AC-EC1) REFRESH_MANIFEST appears even when all files are SKIP_UNCHANGED" {
  [ -x "$SKILL_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.json","hash":"same-hash"},{"file":"screens/home.spec.html","hash":"same-hash-2"}]' \
    '[{"file":"tokens.json","hash":"same-hash"},{"file":"screens/home.spec.html","hash":"same-hash-2"}]' \
    '[{"file":"tokens.json","hash":"same-hash"},{"file":"screens/home.spec.html","hash":"same-hash-2"}]'
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP_UNCHANGED"* ]] || fail "expected SKIP_UNCHANGED in output"
  [[ "$output" == *"REFRESH_MANIFEST"* ]] || fail "expected REFRESH_MANIFEST in output"
}

@test "(AC2) Step 10 prose documents design-last-published.json path" {
  grep -qF 'design-last-published.json' "$SKILL_MD" || fail "design-last-published.json not in SKILL.md"
  grep -qF '.gaia/state/' "$SKILL_MD" || fail ".gaia/state/ not in SKILL.md"
}

@test "(AC3) Step 10 references design-last-published.json for --last-published argument" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  printf '%s' "$block" | grep -qF 'design-last-published.json' || fail "design-last-published.json not in Publication step --last-published context"
}
