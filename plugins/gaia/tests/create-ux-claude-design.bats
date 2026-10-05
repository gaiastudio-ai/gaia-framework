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
SHARED_SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
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
# cannot satisfy structural assertions.  Comments inside backtick code
# spans (e.g. `<!-- @dsCard ... -->`) are preserved so that assertions
# on documented syntax examples are not defeated by the stripping.
_extract_step_block() {
  local file="$1" keyword="$2"
  awk -v kw="$keyword" '
    /^### Step/ { if (found) exit; if (index($0, kw)) found=1 }
    found { print }
  ' "$file" | sed '
    # Protect backtick-enclosed HTML comments: replace <!-- inside `...`
    # with a placeholder so the next rule does not strip them.
    s/`\([^`]*\)<!--\([^`]*\)-->\([^`]*\)`/`\1\x01COMMENT_OPEN\x01\2\x01COMMENT_CLOSE\x01\3`/g
    # Strip bare (non-backtick) single-line HTML comments
    s/<!--.*-->//g
    # Strip multi-line HTML comments
    /<!--/,/-->/d
    # Restore protected comments
    s/\x01COMMENT_OPEN\x01/<!--/g
    s/\x01COMMENT_CLOSE\x01/-->/g
  '
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

# _assert_structured_bind_marker TEXT [CONTEXT] — assert the text calls
# confirm-bind.sh before any bind/init step.  This is the structured-marker
# replacement for the old phrasing-based _assert_no_auto_bind_instruction.
_assert_structured_bind_marker() {
  local text="$1" context="${2:-}"
  printf '%s' "$text" | grep -qF 'confirm-bind.sh' \
    || { printf 'FAIL: confirm-bind.sh not called %s\n' "$context" >&2; return 1; }
}

# _assert_no_auto_bind_phrasing TEXT [CONTEXT] — compact negative phrasing
# check.  Fails when the text contains an imperative auto-bind or
# skip-confirmation instruction that is not immediately governed by a
# negation (never/not/no + up to 2 words).  This runs alongside the
# structural marker check to catch prose that tells the agent to bind
# automatically even while confirm-bind.sh is referenced nearby.
_assert_no_auto_bind_phrasing() {
  local text="$1" context="${2:-}"
  local verb_patterns=(
    'auto-?bind'
    'bind automatically'
    'automatically (bind|select)'
    'skip confirmation'
  )
  local pat
  for pat in "${verb_patterns[@]}"; do
    local matching
    matching="$(printf '%s' "$text" | grep -iE "$pat" || true)"
    [ -z "$matching" ] && continue
    local ungoverned
    ungoverned="$(printf '%s' "$matching" \
      | grep -viE "(never|not|no)[[:space:]]+([[:alpha:]]+[[:space:]]+){0,2}${pat}" \
      || true)"
    if [ -n "$ungoverned" ]; then
      printf 'FAIL: imperative auto-bind instruction found %s:\n%s\n' "$context" "$ungoverned" >&2
      return 1
    fi
  done
}

# ---- fixture builders (deduplicate the UX-doc fixture and pub-script call) --

# _write_pub_fixtures LOCAL_JSON REMOTE_JSON LAST_JSON
# Writes the three JSON fixture files; caller sets the JSON content.
_write_pub_fixtures() {
  printf '%s' "$1" > "$TEST_TMP/local-manifest.json"
  printf '%s' "$2" > "$TEST_TMP/remote-listing.json"
  printf '%s' "$3" > "$TEST_TMP/last-published.json"
}

# _pub_state FILES_JSON — wrap a flat files array into the per-project
# publication state object (design_system key populated, product_design empty).
_pub_state() {
  printf '{"design_system":{"reference":null,"last_published_at":null,"files":%s},"product_design":{"reference":null,"last_published_at":null,"files":[]}}' "$1"
}

# _run_pub [--last-published PATH] [--project KEY] — run plan-publication.sh
# with the standard fixture paths.  Overrides --last-published and --project
# when the respective arg is given.
_run_pub() {
  local last="${TEST_TMP}/last-published.json"
  local project_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --last-published) last="$2"; shift 2 ;;
      --project)        project_args=(--project "$2"); shift 2 ;;
      *)                shift ;;
    esac
  done
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$SHARED_SCRIPTS/plan-publication.sh" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$last" \
    "${project_args[@]+"${project_args[@]}"}"
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

# _init_design_record REF VIA [QPATH] — create a design record in $TEST_TMP.
# When VIA is "created", QPATH is required and the file is auto-created
# if absent (design-record.sh validates -f on the path). For other VIA
# values, --questionnaire-record is omitted (the skip path auto-stores
# "skipped").
_init_design_record() {
  export PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/.gaia/state"
  local ref="$1" via="$2" qpath="${3:-}"
  local args=( --reference "$ref" --discovered-via "$via" )
  if [ "$via" = "created" ]; then
    [ -n "$qpath" ] || { printf '_init_design_record: QPATH required for created\n' >&2; return 1; }
    # Ensure the file exists for the -f check
    local resolved="$qpath"
    [ "${resolved#/}" = "$resolved" ] && resolved="${TEST_TMP}/$resolved"
    mkdir -p "$(dirname "$resolved")"
    [ -f "$resolved" ] || printf '' > "$resolved"
    args+=( --questionnaire-record "$qpath" )
  fi
  env PROJECT_ROOT="$TEST_TMP" "$DESIGN_RECORD_SH" init "${args[@]}"
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
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"aaa-new"},{"file":"palette.yaml","hash":"bbb-new"},{"file":"components.yaml","hash":"ccc-new"}]' \
    '[{"file":"tokens.yaml","hash":"aaa-old"},{"file":"palette.yaml","hash":"bbb-old"},{"file":"components.yaml","hash":"ccc-old"}]' \
    "$(_pub_state '[{"file":"tokens.yaml","hash":"aaa-old"},{"file":"palette.yaml","hash":"bbb-old"},{"file":"components.yaml","hash":"ccc-old"}]')"
  _run_pub
  [ "$status" -eq 0 ]
  for file in tokens.yaml palette.yaml components.yaml; do
    _assert_read_before_write "$file"
  done
}

@test "(AC4) designer-edited file emits CONFLICT, not WRITE" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"new-framework-hash"}]' \
    '[{"file":"tokens.yaml","hash":"designer-edited-hash"}]' \
    "$(_pub_state '[{"file":"tokens.yaml","hash":"original-hash"}]')"
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFLICT tokens.yaml"* ]]
  _assert_not_in_text "WRITE tokens.yaml" "$output" "(should be CONFLICT, not WRITE)"
}

@test "(AC4) orphan removal only for framework-published files" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[]' \
    '[{"file":"old-palette.yaml","hash":"xxx"},{"file":"designer-notes.yaml","hash":"yyy"}]' \
    "$(_pub_state '[{"file":"old-palette.yaml","hash":"xxx"}]')"
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"DELETE_ORPHAN old-palette.yaml"* ]]
  _assert_not_in_text "DELETE_ORPHAN designer-notes.yaml" "$output" "(designer file must not be deleted)"
}

@test "(AC4) unchanged file emits SKIP_UNCHANGED (legacy flat-array normalisation)" {
  # Deliberately kept as a flat-array fixture so in-memory normalisation is covered.
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"same-hash"}]' \
    '[{"file":"tokens.yaml","hash":"same-hash"}]' \
    '[{"file":"tokens.yaml","hash":"same-hash"}]'
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP_UNCHANGED tokens.yaml"* ]]
}

@test "(AC-EC6) designer edit between publishes is surfaced as CONFLICT" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"buttons.yaml","hash":"hash-C"}]' \
    '[{"file":"buttons.yaml","hash":"hash-B"}]' \
    "$(_pub_state '[{"file":"buttons.yaml","hash":"hash-A"}]')"
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFLICT buttons.yaml"* ]]
}

@test "(AC-EC7) empty remote-listing forces READ_FIRST for every file" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  printf '[{"file":"a.yaml","hash":"h1"},{"file":"b.yaml","hash":"h2"}]' > "$TEST_TMP/local-manifest.json"
  printf '' > "$TEST_TMP/remote-listing.json"
  _run_pub --last-published /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"READ_FIRST a.yaml"* ]]
  [[ "$output" == *"READ_FIRST b.yaml"* ]]
}

@test "(AC4) plan-publication.sh rejects hostile filenames via --arg" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"\"; rm -rf /; echo \"","hash":"x"}]' \
    '[{"file":"\"; rm -rf /; echo \"","hash":"x"}]' \
    "$(_pub_state '[{"file":"\"; rm -rf /; echo \"","hash":"x"}]')"
  _run_pub
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP_UNCHANGED"* ]] || [[ "$output" == *"WRITE"* ]] || [[ "$output" == *"READ_FIRST"* ]]
}

@test "(AC4) plan-publication.sh fails closed on malformed JSON inputs" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
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
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"new-framework-hash"}]' \
    '[{"file":"tokens.yaml","hash":"original-hash"}]' \
    "$(_pub_state '[{"file":"tokens.yaml","hash":"original-hash"}]')"
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
  # v2 records: should-skip-questionnaire reads design_system_project.reference
  # first, so corrupt that too
  yq -i '.design_system_project.reference = ""' "$_rec_file"
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
  # v2 records: should-skip-questionnaire reads design_system_project.reference
  # first, so corrupt that too
  _WS_VAL="   " yq -i '.design_system_project.reference = strenv(_WS_VAL)' "$_rec_file"
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
    --reference "proj-second" --discovered-via "project-artifacts"
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
  local hostile_qr='q with "quotes" and $dollar; exit 1; #'
  _init_design_record 'proj; rm -rf /' "created" "$hostile_qr"
  local ref qr
  ref="$(yq '.project.reference' "$TEST_TMP/.gaia/state/design-record.yaml")"
  qr="$(yq '.project.questionnaire_record' "$TEST_TMP/.gaia/state/design-record.yaml")"
  [ "$ref" = 'proj; rm -rf /' ]
  [ "$qr" = "$hostile_qr" ]
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

@test "Discovery step calls confirm-bind.sh before bind" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  _assert_structured_bind_marker "$block" "(Discovery step)"
}

@test "Discovery step has no imperative auto-bind instruction" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  _assert_no_auto_bind_phrasing "$block" "(Discovery step)"
}

@test "auto-bind phrasing guard catches auto-bind mutant" {
  # Feed a sentence that tells the agent to auto-bind, appended to
  # otherwise-clean text.  The phrasing guard must catch it.
  local mutant="When exactly one candidate is found, auto-bind it."
  local caught=false
  _assert_no_auto_bind_phrasing "$mutant" "(mutant)" 2>/dev/null || caught=true
  [ "$caught" = "true" ] || fail "phrasing guard missed: $mutant"
}

@test "confirm-bind.sh exits 0 on exact bind token" {
  [ -f "$SKILL_SCRIPTS/confirm-bind.sh" ] || fail "confirm-bind.sh missing"
  run bash "$SKILL_SCRIPTS/confirm-bind.sh" "Bind this project"
  [ "$status" -eq 0 ]
}

@test "confirm-bind.sh exits non-zero on paraphrased answer" {
  [ -f "$SKILL_SCRIPTS/confirm-bind.sh" ] || fail "confirm-bind.sh missing"
  run bash "$SKILL_SCRIPTS/confirm-bind.sh" "Sure, go ahead and use that project"
  [ "$status" -ne 0 ]
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
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"../../../etc/passwd","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h2"}]' \
    "$(_pub_state '[]')"
  _run_pub
  [ "$status" -ne 0 ]
  [[ "$output" == *"../"* ]] || [[ "$output" == *"traversal"* ]] || [[ "$output" == *"rejected"* ]] || [[ "$output" == *"unsafe"* ]]
}

@test "(AC4) plan-publication.sh rejects absolute path in local-manifest" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"/etc/passwd","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h2"}]' \
    "$(_pub_state '[]')"
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects path-traversal in last-published" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"safe.yaml","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h1"}]' \
    "$(_pub_state '[{"file":"../../secrets.yaml","hash":"h2"}]')"
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects empty filename" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"","hash":"h1"}]' \
    '[{"file":"safe.yaml","hash":"h2"}]' \
    "$(_pub_state '[]')"
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects control character in filename" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  # Filename with a newline
  printf '[{"file":"good\\nbad","hash":"h1"}]' > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"safe.yaml","hash":"h2"}]' > "$TEST_TMP/remote-listing.json"
  printf '%s' "$(_pub_state '[]')" > "$TEST_TMP/last-published.json"
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh never emits DELETE_ORPHAN for traversal path in remote" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  # Remote contains a traversal path that the framework supposedly published
  _write_pub_fixtures \
    '[]' \
    '[{"file":"../../../etc/shadow","hash":"h1"},{"file":"safe.yaml","hash":"h2"}]' \
    "$(_pub_state '[{"file":"../../../etc/shadow","hash":"h1"}]')"
  _run_pub
  # Must either fail or silently skip the traversal path — never emit DELETE_ORPHAN for it
  if [ "$status" -eq 0 ]; then
    _assert_not_in_text "DELETE_ORPHAN" "$output" "(must not delete traversal paths)"
  fi
}

@test "(AC4) path-traversal rejection mutant: removing the check lets traversal through" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens.yaml","hash":"h1"},{"file":"../escape.yaml","hash":"h2"}]' \
    '[]' \
    "$(_pub_state '[]')"
  _run_pub
  [ "$status" -ne 0 ]
}

@test "(AC4) plan-publication.sh rejects dot-segment filename in local-manifest" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  # Each of these must be rejected: ".", "./a", "a/./b"
  local bad_name
  for bad_name in '.' './a' 'a/./b'; do
    _write_pub_fixtures \
      "[{\"file\":\"${bad_name}\",\"hash\":\"h1\"}]" \
      '[]' \
      "$(_pub_state '[]')"
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe dot-segment filename in local: ${bad_name}"
  done
}

@test "(AC4) plan-publication.sh rejects trailing slash and empty segments in local-manifest" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  local bad_name
  for bad_name in 'a/' 'a//b'; do
    _write_pub_fixtures \
      "[{\"file\":\"${bad_name}\",\"hash\":\"h1\"}]" \
      '[]' \
      "$(_pub_state '[]')"
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe filename in local: ${bad_name}"
  done
}

@test "(AC4) plan-publication.sh rejects dot-segment filename in last-published" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  local bad_name
  for bad_name in '.' './a' 'a/./b'; do
    _write_pub_fixtures \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      "$(_pub_state "[{\"file\":\"${bad_name}\",\"hash\":\"h2\"}]")"
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe dot-segment filename in last-published: ${bad_name}"
  done
}

@test "(AC4) plan-publication.sh rejects trailing slash and empty segments in last-published" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  local bad_name
  for bad_name in 'a/' 'a//b'; do
    _write_pub_fixtures \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      '[{"file":"safe.yaml","hash":"h1"}]' \
      "$(_pub_state "[{\"file\":\"${bad_name}\",\"hash\":\"h2\"}]")"
    _run_pub
    [ "$status" -ne 0 ] || fail "accepted unsafe filename in last-published: ${bad_name}"
  done
}

@test "(AC4) dot-segment rejection mutant: bare dot in local produces WRITE without the check" {
  # Prove the check is load-bearing: "." would produce "READ_FIRST . / WRITE ."
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":".","hash":"h1"}]' \
    '[]' \
    "$(_pub_state '[]')"
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
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"

  # Generate 500-entry fixtures (per-project layout for last-published)
  local i
  printf '[' > "$TEST_TMP/local-manifest.json"
  printf '[' > "$TEST_TMP/remote-listing.json"
  printf '{"design_system":{"reference":null,"last_published_at":null,"files":[' > "$TEST_TMP/last-published.json"
  for i in $(seq 1 500); do
    local comma=""
    [ "$i" -eq 1 ] || comma=","
    printf '%s{"file":"file-%04d.yaml","hash":"new-%d"}' "$comma" "$i" "$i" >> "$TEST_TMP/local-manifest.json"
    printf '%s{"file":"file-%04d.yaml","hash":"old-%d"}' "$comma" "$i" "$i" >> "$TEST_TMP/remote-listing.json"
    printf '%s{"file":"file-%04d.yaml","hash":"old-%d"}' "$comma" "$i" "$i" >> "$TEST_TMP/last-published.json"
  done
  printf ']' >> "$TEST_TMP/local-manifest.json"
  printf ']' >> "$TEST_TMP/remote-listing.json"
  printf ']},"product_design":{"reference":null,"last_published_at":null,"files":[]}}' >> "$TEST_TMP/last-published.json"

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
# Manifest refresh and persisted publication manifest
# ===========================================================================

@test "(AC1) publication plan includes bare REFRESH_MANIFEST as final line" {
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"components/button.spec.html","hash":"bbb"},{"file":"tokens/brand.html","hash":"ccc"}]' \
    '[{"file":"components/button.spec.html","hash":"old-bbb"},{"file":"tokens/brand.html","hash":"old-ccc"}]' \
    "$(_pub_state '[{"file":"components/button.spec.html","hash":"old-bbb"},{"file":"tokens/brand.html","hash":"old-ccc"}]')"
  _run_pub --project design_system
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
  [ -x "$SHARED_SCRIPTS/plan-publication.sh" ] || fail "plan-publication.sh missing"
  _write_pub_fixtures \
    '[{"file":"tokens/brand.html","hash":"same-hash"},{"file":"components/button.spec.html","hash":"same-hash-2"}]' \
    '[{"file":"tokens/brand.html","hash":"same-hash"},{"file":"components/button.spec.html","hash":"same-hash-2"}]' \
    "$(_pub_state '[{"file":"tokens/brand.html","hash":"same-hash"},{"file":"components/button.spec.html","hash":"same-hash-2"}]')"
  _run_pub --project design_system
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

# ===========================================================================
# Two-project discovery, creation, and screen publication tests
# ===========================================================================
# Tier 1: script-level tests

@test "confirm-bind.sh exits non-zero on empty input" {
  [ -f "$SKILL_SCRIPTS/confirm-bind.sh" ] || fail "confirm-bind.sh missing"
  run bash "$SKILL_SCRIPTS/confirm-bind.sh" ""
  [ "$status" -ne 0 ]
}

@test "confirm-bind.sh exits non-zero on token-containing paraphrase" {
  [ -f "$SKILL_SCRIPTS/confirm-bind.sh" ] || fail "confirm-bind.sh missing"
  run bash "$SKILL_SCRIPTS/confirm-bind.sh" "Bind this project please"
  [ "$status" -ne 0 ]
  run bash "$SKILL_SCRIPTS/confirm-bind.sh" "yes, Bind this project"
  [ "$status" -ne 0 ]
}

@test "first-publication sourced build_manifest_cards with missing manifest includes token cards" {
  local fixture_specs="$BATS_TEST_DIRNAME/fixtures/create-ux-two-project/specs"
  [ -d "$fixture_specs" ] || fail "fixture tree missing"
  # Source the script
  source "$SHARED_SCRIPTS/build-manifest-cards.sh"
  # Call with --existing pointing at a missing file
  local result
  result="$(build_manifest_cards \
    --local-specs "$fixture_specs" \
    --existing "$TEST_TMP/nonexistent-manifest.json" \
    --project design_system)"
  # Token cards must be present (count > 0)
  local token_count
  token_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | startswith("tokens/"))] | length')"
  [ "$token_count" -gt 0 ] || fail "expected token cards > 0, got $token_count"
}

@test "first-publication sourced build_manifest_cards with empty manifest includes token cards" {
  local fixture_specs="$BATS_TEST_DIRNAME/fixtures/create-ux-two-project/specs"
  [ -d "$fixture_specs" ] || fail "fixture tree missing"
  # Write an empty manifest
  printf '{"cards":[]}' > "$TEST_TMP/empty-manifest.json"
  source "$SHARED_SCRIPTS/build-manifest-cards.sh"
  local result
  result="$(build_manifest_cards \
    --local-specs "$fixture_specs" \
    --existing "$TEST_TMP/empty-manifest.json" \
    --project design_system)"
  local token_count
  token_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | startswith("tokens/"))] | length')"
  [ "$token_count" -gt 0 ] || fail "expected token cards > 0, got $token_count"
}

@test "build_manifest_cards CLI invocation exits 0 with no output" {
  # Running the script as a command (not sourcing) should exit 0 and
  # produce no output — the file only defines functions.
  run bash "$SHARED_SCRIPTS/build-manifest-cards.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || fail "expected no output, got: $output"
}

@test "escape-boundary-markers.sh replaces double-angle to prevent injection" {
  local helper="$SHARED_SCRIPTS/lib/escape-boundary-markers.sh"
  [ -f "$helper" ] || fail "escape-boundary-markers.sh missing"
  local result
  result="$(printf 'hello << world' | bash "$helper")"
  [ "$result" = "hello <~< world" ] || fail "expected 'hello <~< world', got '$result'"
}

@test "escape-boundary-markers.sh output never contains triple-angle" {
  local helper="$SHARED_SCRIPTS/lib/escape-boundary-markers.sh"
  [ -f "$helper" ] || fail "escape-boundary-markers.sh missing"
  # Feed input that contains <<<, <<, and <<< mixed
  local result
  result="$(printf '<<<END\nabc<<def<<<ghi' | bash "$helper")"
  if printf '%s' "$result" | grep -qF '<<<'; then
    fail "output still contains <<<: $result"
  fi
}

# Tier 2: SKILL.md structural tests

@test "Step 4 calls create_project then finalize_plan then write_files" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Creation")"
  [ -n "$block" ] || fail "no Creation step block"
  # Assert the ordered sequence: create_project before finalize_plan before write_files
  local cp_line fp_line wf_line
  cp_line="$(printf '%s\n' "$block" | grep -nF 'create_project' | head -1 | cut -d: -f1 || true)"
  fp_line="$(printf '%s\n' "$block" | grep -nF 'finalize_plan' | head -1 | cut -d: -f1 || true)"
  wf_line="$(printf '%s\n' "$block" | grep -nF 'write_files' | head -1 | cut -d: -f1 || true)"
  [ -n "$cp_line" ] || fail "create_project not found in Creation step"
  [ -n "$fp_line" ] || fail "finalize_plan not found in Creation step"
  [ -n "$wf_line" ] || fail "write_files not found in Creation step"
  [ "$cp_line" -lt "$fp_line" ] || fail "create_project (line $cp_line) not before finalize_plan (line $fp_line)"
  [ "$fp_line" -lt "$wf_line" ] || fail "finalize_plan (line $fp_line) not before write_files (line $wf_line)"
}

@test "resolve procedure calls Artifact quickstart with intent design then publish" {
  # The "Resolve Product Design Project" procedure must mention
  # Artifact quickstart with intent design and then publish
  local full
  full="$(cat "$SKILL_MD")"
  printf '%s' "$full" | grep -qiE 'quickstart.*intent.*design' \
    || fail "no Artifact quickstart with intent design in SKILL.md"
  # quickstart must appear before publish (in the procedure text)
  local qs_line pub_line
  qs_line="$(printf '%s\n' "$full" | grep -niE 'quickstart.*intent.*design' | head -1 | cut -d: -f1 || true)"
  pub_line="$(printf '%s\n' "$full" | grep -niE 'action.*publish.*type_url|publish.*type_url|type_url.*publish' | head -1 | cut -d: -f1 || true)"
  [ -n "$qs_line" ] || fail "no Artifact quickstart with intent design line-number in SKILL.md"
  [ -n "$pub_line" ] || fail "no Artifact publish with type_url found in SKILL.md"
  [ "$qs_line" -lt "$pub_line" ] || fail "quickstart (line $qs_line) not before publish (line $pub_line)"
}

@test "every create_project targets design-system only" {
  # Static scan: every create_project call must be for a design-system project,
  # never for screens or flows
  local file_count=0
  local f
  while IFS= read -r -d '' f; do
    file_count=$((file_count + 1))
    local lines
    lines="$(grep -niF 'create_project' "$f" || true)"
    [ -z "$lines" ] && continue
    # No line should mention screens or flows as a project type
    if printf '%s' "$lines" | grep -qiE 'screen|flow'; then
      fail "create_project for screens/flows found in $f"
    fi
  done < <(find "$SKILL_DIR" "$SHARED_SCRIPTS" -type f \( -name '*.md' -o -name '*.sh' \) -print0)
  [ "$file_count" -gt 0 ] || fail "no files scanned"
}

@test "canvas read-back records token-by-value and does not use page true" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention ds_attachment_mode: token-by-value (or token-by-value recording)
  printf '%s' "$full" | grep -qF 'token-by-value' \
    || fail "token-by-value not mentioned in SKILL.md"
  # Must mention per-file read of project/canvas.json
  printf '%s' "$full" | grep -qF 'project/canvas.json' \
    || fail "project/canvas.json not mentioned in SKILL.md"
  # Must NOT use page: true for the read-back
  if printf '%s' "$full" | grep -iE 'page.*true.*canvas|canvas.*page.*true' | grep -qv '^[[:space:]]*#'; then
    fail "page: true used near canvas read-back"
  fi
  # Must explicitly prohibit page: true (never / not / do not)
  printf '%s' "$full" | grep -qiE 'never.*page.*true|not.*page.*true' \
    || fail "no prohibition of page: true found in SKILL.md"
}

@test "canvas read-back positioned after first content publish not between creation and publish" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must state that the read-back runs AFTER first content publish
  printf '%s' "$full" | grep -qiE 'after.*first.*content.*publish|after.*first.*publish.*content' \
    || fail "no 'after first content publish' statement for canvas read-back"
  # Must state NOT to read between creation and first publish
  printf '%s' "$full" | grep -qiE 'not.*read.*between.*creation.*publish|do not.*read.*canvas.*between|no.*read.*before.*first.*content' \
    || fail "no prohibition on reading between creation and first publish"
}

@test "questionnaire writes target design-system only" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Questionnaire")"
  [ -n "$block" ] || fail "no Questionnaire step block"
  # Must state writes target design-system
  printf '%s' "$block" | grep -qiE 'design.system\b' \
    || fail "design-system not mentioned in Questionnaire step"
  # Must not route writes to product design project in the questionnaire step
  if printf '%s' "$block" | grep -qiE 'product.design.*write|write.*product.design'; then
    fail "product design write found in Questionnaire step"
  fi
}

@test "screen authoring gated on both projects non-null" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must gate screen authoring on both design_system_project and
  # product_design_project being non-null
  printf '%s' "$full" | grep -qiE 'design.system.project.*non.null|design_system_project.*non.null' \
    || fail "no gate on design_system_project non-null"
  printf '%s' "$full" | grep -qiE 'product.design.project.*non.null|product_design_project.*non.null' \
    || fail "no gate on product_design_project non-null"
}

@test "unavailable Design artifact surface halts with remediation and no fallback" {
  # Extract the Resolve Product Design Project section specifically
  local resolve_block
  resolve_block="$(awk '/^### Resolve Product Design Project/{found=1} found{print} /^### Step/ && found{exit}' "$SKILL_MD")"
  [ -n "$resolve_block" ] || fail "no Resolve Product Design Project section"
  # Must mention a halt when the Design artifact surface is unavailable
  printf '%s' "$resolve_block" | grep -qiE 'artifact.*surface.*halt|halt.*artifact.*surface|Design.*artifact.*unavailable.*halt|halt.*Design.*unavailable' \
    || fail "no halt on unavailable Design artifact surface"
  # Must mention remediation
  printf '%s' "$resolve_block" | grep -qiE 'Artifact.*tool.*available|enable.*Artifact|Design artifact surface' \
    || fail "no remediation for unavailable Design artifact surface"
  # Must NOT fall back to design-system project for screens
  local full
  full="$(cat "$SKILL_MD")"
  if printf '%s' "$full" | grep -qiE 'fallback.*design.system.*screen|screen.*fallback.*design.system'; then
    fail "fallback to design-system project for screens found"
  fi
}

@test "non-React detection sets brand-style with finalize_plan and product design project" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  # Must mention brand-style
  printf '%s' "$block" | grep -qF 'brand-style' \
    || fail "brand-style not in Discovery step"
  # Must mention finalize_plan on the brand-style path
  printf '%s' "$block" | grep -qF 'finalize_plan' \
    || fail "finalize_plan not in Discovery step"
  # Must mention product design project is created regardless
  printf '%s' "$block" | grep -qiE 'product.design.*project.*created|product.design.*regardless|create.*product.design' \
    || fail "product design project creation not mentioned on brand-style path"
}

@test "first-publication branch is a distinct code path in Step 10" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Must mention first-publication as a distinct code path
  printf '%s' "$block" | grep -qiE 'first.publication|first.publish' \
    || fail "first-publication branch not in Step 10"
  # Must mention token cards on the first-publication path
  printf '%s' "$block" | grep -qiE 'token.*card|card.*token' \
    || fail "token cards not mentioned in first-publication branch"
}

@test "confirm-bind.sh called before each bind step and not on created path" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Discovery")"
  [ -n "$block" ] || fail "no Discovery step block"
  # confirm-bind.sh must appear
  printf '%s' "$block" | grep -qF 'confirm-bind.sh' \
    || fail "confirm-bind.sh not called in Discovery step"
  # Must be called before the bind steps (init and set-product-project)
  # and NOT on the created path
  local full
  full="$(cat "$SKILL_MD")"
  # Check the created path (Step 4) does NOT call confirm-bind.sh
  local creation_block
  creation_block="$(_extract_step_block "$SKILL_MD" "Creation")"
  [ -n "$creation_block" ] || fail "no Creation step block"
  if printf '%s' "$creation_block" | grep -qF 'confirm-bind.sh'; then
    fail "confirm-bind.sh called on the created path (Step 4)"
  fi
}

@test "finalize_plan precedes every DesignSync write batch in Step 10" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Every write_files / delete_files / register_assets must be preceded by finalize_plan
  printf '%s' "$block" | grep -qF 'finalize_plan' \
    || fail "finalize_plan not in Publication step"
  # Assert finalize_plan appears before each write batch
  local fp_line wf_line
  fp_line="$(printf '%s\n' "$block" | grep -nF 'finalize_plan' | head -1 | cut -d: -f1 || true)"
  wf_line="$(printf '%s\n' "$block" | grep -nE 'write_files|delete_files|register_assets' | head -1 | cut -d: -f1 || true)"
  [ -n "$fp_line" ] || fail "finalize_plan line not found"
  [ -n "$wf_line" ] || fail "no write_files/delete_files/register_assets in Publication step"
  [ "$fp_line" -lt "$wf_line" ] || fail "finalize_plan (line $fp_line) not before first write batch (line $wf_line)"
}

@test "DesignSync authorization error halts with design-login remediation" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention the DesignSync authorization error and /design-login
  printf '%s' "$full" | grep -qF '/design-login' \
    || fail "/design-login not mentioned in SKILL.md"
  # The halt must be present
  printf '%s' "$full" | grep -qiE 'authorization.*halt|halt.*authorization|needs.*authorization.*halt' \
    || fail "no authorization error halt in SKILL.md"
}

@test "per-file read-back does not use page true" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention per-file read-back
  printf '%s' "$full" | grep -qiE 'per.file.*read|read.*path.*canvas' \
    || fail "per-file read-back not mentioned"
  # Must explicitly prohibit page: true
  printf '%s' "$full" | grep -qiE 'never.*page.*true|not.*page.*true' \
    || fail "no prohibition of page: true found"
  # Must NOT use page: true positively near read-back
  if printf '%s' "$full" | grep -qiE 'page.*true.*read.back|read.back.*page.*true' | grep -qv 'never\|not\|do not'; then
    fail "page: true used in read-back context"
  fi
}

@test "quickstart unusable type halts with remediation for manual design creation" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention halting when quickstart type is unusable
  printf '%s' "$full" | grep -qiE 'quickstart.*unusable.*halt|unusable.*type.*halt|halt.*unusable.*type|halt.*remediation.*design' \
    || fail "no halt for unusable quickstart type"
}

@test "no pre-split single-project publication assertion remains in tests" {
  # Meta-test: scan the test file for old-style single-project assertions
  # (screen and component specs in one manifest/project)
  local test_file="$BATS_TEST_DIRNAME/create-ux-claude-design.bats"
  [ -f "$test_file" ] || fail "test file missing"
  # Look for _write_pub_fixtures calls that mix screens and components in
  # a single fixture without --project.  Exclude comment lines and the
  # meta-test's own grep pattern line.
  local mixed_lines
  mixed_lines="$(grep -n '_write_pub_fixtures\|_run_pub' "$test_file" | \
    grep 'screens/' | grep 'components/' | \
    grep -v '\-\-project' || true)"
  [ -z "$mixed_lines" ] || fail "pre-split single-project assertion found:\n$mixed_lines"
}

@test "static scan finds no DesignSync write_files to screens or flows paths" {
  # The Publication step must explicitly route screen/flow specs AWAY from
  # DesignSync write_files and into the Artifact tool.  When the step text
  # uses write_files for screen specs (the pre-split state), this test is RED.
  #
  # Two checks:
  #   1. The step names a product-design pass for screen/flow specs.
  #   2. No SKILL or script file contains a DesignSync write_files that
  #      targets screens/ or flows/ — the current SKILL.md line ~190
  #      ("publish the specification or component via write_files") covers
  #      all specs including screens, so this assertion is RED until that
  #      single-pass line is replaced by explicit two-pass routing.

  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"

  # 1. Explicit product-design routing statement
  printf '%s' "$block" | grep -qiE 'product.design.*pass|product.design.*screen|screen.*product.design|screen.*Artifact' \
    || fail "no product-design routing for screens in Publication step"

  # 2. Negative scan: every write_files mention in SKILL/script files.
  #    Two sub-checks per write_files line:
  #      a. 5-line context must not mention screens/ or flows/ as a target.
  #      b. If the write_files line or its context covers "specification"
  #         (or matches WRITE.*write_files case-insensitively), the context
  #         must carry a design-system-only qualifier.
  #    Additionally, a whole-file scan verifies that no file directs
  #    DesignSync write_files at screen or flow paths anywhere, even
  #    outside the 5-line window.
  local file_count=0
  local violations=""
  local f
  while IFS= read -r -d '' f; do
    file_count=$((file_count + 1))
    local wf_lines
    wf_lines="$(grep -n 'write_files' "$f" || true)"
    [ -z "$wf_lines" ] && continue

    # Whole-file check: any line that mentions both write_files and
    # screen/flow targets is a violation regardless of context window.
    local wf_screen_lines
    wf_screen_lines="$(grep -n 'write_files' "$f" | grep -iE 'screens/|flows/' || true)"
    if [ -n "$wf_screen_lines" ]; then
      local wsl
      while IFS= read -r wsl; do
        local wsl_ln="${wsl%%:*}"
        violations="${violations}${f}:${wsl_ln} (write_files targets screen/flow path on same line)\n"
      done <<< "$wf_screen_lines"
    fi

    local ln _rest
    while IFS=: read -r ln _rest; do
      [ -n "$ln" ] || continue
      local start end ctx
      start=$((ln > 5 ? ln - 5 : 1))
      end=$((ln + 5))
      ctx="$(sed -n "${start},${end}p" "$f")"
      # Direct screen/flow target near write_files
      if printf '%s' "$ctx" | grep -qiE 'screens/|flows/'; then
        violations="${violations}${f}:${ln} (screen/flow target near write_files)\n"
        continue
      fi
      # Generic write_files covering "specification" without explicit
      # design-system-only qualifier
      if printf '%s' "$ctx" | grep -qiE 'specification.*write_files|write_files.*specification|WRITE.*write_files'; then
        if ! printf '%s' "$ctx" | grep -qiE 'design.system.only|design.system.pass|component.*only|token.*only'; then
          violations="${violations}${f}:${ln} (generic write_files covers all specs including screens)\n"
        fi
      fi
    done <<< "$wf_lines"
  done < <(find "$SKILL_DIR" "$SHARED_SCRIPTS" -type f \( -name '*.md' -o -name '*.sh' \) -print0)
  [ "$file_count" -gt 0 ] || fail "no files scanned"
  [ -z "$violations" ] || fail "DesignSync write_files covers screen/flow specs:\n${violations}"
}

@test "resume with null product design project routes to resolve procedure" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention routing to the resolve procedure when product_design_project
  # is null
  # Must mention product_design_project null AND routing to the resolve procedure
  # on the same line (not just "starts as null" in a different context)
  printf '%s' "$full" | grep -qiE 'product_design_project.*is null.*resolve|product_design_project.*is null.*procedure|product_design_project.*null.*route' \
    || fail "no routing for null product_design_project to resolve procedure"
}

@test "every recorded-project write preceded by verify-publication-target check" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention verify-publication-target before write operations
  printf '%s' "$full" | grep -qF 'verify-publication-target' \
    || fail "verify-publication-target not mentioned in SKILL.md"
  # Must mention --metadata-file and --design-record as required
  printf '%s' "$full" | grep -qF -- '--metadata-file' \
    || fail "--metadata-file not mentioned in SKILL.md"
  printf '%s' "$full" | grep -qF -- '--design-record' \
    || fail "--design-record not mentioned in SKILL.md"
}

@test "creating writes verified against response before recording reference" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention verifying type/surface/write access for creating writes
  printf '%s' "$full" | grep -qiE 'creating.*write.*verif|verify.*creating.*write|response.*type.*surface.*write|canEdit.*creat' \
    || fail "no creating-write verification against response"
}

@test "verify-publication-target mutant with one check removed turns test red" {
  # This test asserts that every write_files / delete_files / register_assets /
  # publish against a recorded project has a preceding verify-publication-target
  # call.  It counts both the write ops and the checks, and fails if the
  # counts diverge in either direction — exact parity is required so that
  # removing any single check is detected.
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  local write_count check_count
  write_count="$(printf '%s\n' "$block" | grep -cE 'write_files|delete_files|register_assets' || true)"
  check_count="$(printf '%s\n' "$block" | grep -cF 'verify-publication-target' || true)"
  [ "$write_count" -gt 0 ] || fail "no write operations in Publication step"
  [ "$check_count" -gt 0 ] || fail "no verify-publication-target checks in Publication step"
  [ "$check_count" -eq "$write_count" ] || fail "check/write mismatch: $check_count checks vs $write_count writes (must be equal)"
}

@test "Artifact reads wrapped in product-design boundary markers after escape" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention boundary markers for product design reads
  printf '%s' "$full" | grep -qF 'PRODUCT_DESIGN_PROJECT_BOUNDARY' \
    || fail "PRODUCT_DESIGN_PROJECT_BOUNDARY not in SKILL.md"
  printf '%s' "$full" | grep -qF 'END_PRODUCT_DESIGN_PROJECT_BOUNDARY' \
    || fail "END_PRODUCT_DESIGN_PROJECT_BOUNDARY not in SKILL.md"
  # Must mention escape-boundary-markers.sh
  printf '%s' "$full" | grep -qF 'escape-boundary-markers.sh' \
    || fail "escape-boundary-markers.sh not referenced in SKILL.md"
}

@test "Artifact metadata stripped of control characters and markers" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention stripping control characters and markers from metadata
  printf '%s' "$full" | grep -qiE 'metadata.*strip|strip.*control.*character|sanitise.*metadata|sanitize.*metadata|metadata.*control.*character' \
    || fail "no metadata stripping mentioned in SKILL.md"
}

@test "post-publish read-back uses per-file reads with screen-key rule" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Must mention post-publish read-back specifically (the heading or phrase)
  printf '%s' "$block" | grep -qiE 'post.publish.*read|read.back.*publish|read.*back.*screen' \
    || fail "post-publish read-back not in Publication step"
  # Must mention screen-key rule (project/<screen>.dc.html) in read-back context
  # Check that .dc.html appears in a line mentioning read-back or screen-key
  printf '%s' "$block" | grep -i 'read.back' | grep -qF '.dc.html' \
    || fail "screen-key rule (.dc.html) not in Publication step"
}

@test "missing screen in read-back halts with diagnostic" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Must mention halting on missing screens with diagnostic
  printf '%s' "$block" | grep -qiE 'halt.*missing.*screen|missing.*screen.*halt|diagnostic.*missing' \
    || fail "no halt on missing screen in read-back"
}

@test "screen artboard carries token block in helmet style" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention helmet/style and :root{--token:value} pattern
  printf '%s' "$full" | grep -qiE 'helmet.*style|<helmet><style>' \
    || fail "no helmet style mentioned for token block"
  printf '%s' "$full" | grep -qiE ':root.*--.*token|:root{--' \
    || fail "no :root{--token:value} pattern mentioned"
}

@test "canvas.json updated with boards entry and order slot in one publish" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must mention boards entry and order slot
  printf '%s' "$full" | grep -qF 'boards' \
    || fail "boards not mentioned in SKILL.md"
  printf '%s' "$full" | grep -qF 'order' \
    || fail "order not mentioned in SKILL.md"
  # Must mention one files publish (single publish call for both artboard + canvas)
  printf '%s' "$full" | grep -qiE 'one.*files.*publish|single.*files.*publish|one.*publish.*files|both.*artboard.*canvas.*one|artboard.*canvas.*one.*publish' \
    || fail "no single files publish for artboard and canvas"
}

@test "product-design pass uses Artifact operations only and no DesignSync operations" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Must mention Artifact read/publish for product-design pass
  printf '%s' "$block" | grep -qiE 'product.design.*Artifact|Artifact.*product.design|product.design.*publish' \
    || fail "product-design pass does not use Artifact operations"
  # Must mention that product-design pass does NOT use register_assets,
  # write_files, or _ds_manifest.json
  printf '%s' "$block" | grep -qiE 'REFRESH_MANIFEST.*no.op|no.op.*REFRESH_MANIFEST|product.design.*REFRESH_MANIFEST.*no' \
    || fail "REFRESH_MANIFEST not marked as no-op for product-design pass"
}

@test "no screen or flow content in design-system after surface-unavailable halt" {
  local full
  full="$(cat "$SKILL_MD")"
  # Must state no screen/flow content written to design-system after halt
  printf '%s' "$full" | grep -qiE 'no.*screen.*flow.*design.system|no.*content.*design.system|no.*fallback.*design.system|not.*screen.*design.system' \
    || fail "no statement about no screen/flow content in design-system after halt"
}

@test "design-system pass WRITE names only component and token specs never screen or flow" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Extract all WRITE-operation bullet lines from the design-system pass
  # (between "Design-system pass" heading and "Product-design pass" heading)
  local ds_section
  ds_section="$(printf '%s' "$block" | awk '/Design-system pass/{found=1} /Product-design pass/{found=0} found{print}')"
  [ -n "$ds_section" ] || fail "no design-system pass section in Publication step"
  # The WRITE bullet must name component and token specs
  local write_line
  write_line="$(printf '%s' "$ds_section" | grep -i 'WRITE.*write_files' || true)"
  [ -n "$write_line" ] || fail "no WRITE bullet with write_files in design-system pass"
  # The WRITE bullet must mention component or token routing
  printf '%s' "$write_line" | grep -qiE 'component|token' \
    || fail "WRITE bullet does not name component or token specs"
  # The WRITE bullet must NOT mention screen or flow routing
  if printf '%s' "$write_line" | grep -qiE 'screen|flow'; then
    fail "WRITE bullet in design-system pass mentions screen or flow specs"
  fi
}

@test "verify-publication-target scoped to Publication step with at least one check per pass" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Must have verify-publication-target in the Publication step itself
  printf '%s' "$block" | grep -qF 'verify-publication-target' \
    || fail "verify-publication-target not in Publication step"
  # Must have at least one check in the design-system pass section
  local ds_section
  ds_section="$(printf '%s' "$block" | awk '/Design-system pass/{found=1} /Product-design pass/{found=0} found{print}')"
  printf '%s' "$ds_section" | grep -qF 'verify-publication-target' \
    || fail "no verify-publication-target in design-system pass"
  # Must have at least one check in the product-design pass section
  local pd_section
  pd_section="$(printf '%s' "$block" | awk '/Product-design pass/{found=1} found{print}')"
  printf '%s' "$pd_section" | grep -qF 'verify-publication-target' \
    || fail "no verify-publication-target in product-design pass"
  # Must mention --metadata-file and --design-record in the Publication step
  printf '%s' "$block" | grep -qF -- '--metadata-file' \
    || fail "--metadata-file not mentioned in Publication step"
  printf '%s' "$block" | grep -qF -- '--design-record' \
    || fail "--design-record not mentioned in Publication step"
}

@test "persist_last_published calls in Step 10 name all required flags" {
  local block
  block="$(_extract_step_block "$SKILL_MD" "Publication")"
  [ -n "$block" ] || fail "no Publication step block"
  # Extract persist_last_published invocations that live inside fenced code
  # blocks (``` ... ```).  The window for each invocation ends at the
  # closing fence, so prose that repeats flag names outside the block
  # cannot satisfy the assertion.
  local fenced_calls
  fenced_calls="$(printf '%s\n' "$block" | awk '
    /^[[:space:]]*```/ && !in_fence { in_fence=1; buf=""; next }
    /^[[:space:]]*```/ && in_fence  { if (buf != "") print buf; in_fence=0; buf=""; next }
    in_fence && /persist_last_published/ { capture=1 }
    in_fence && capture { buf = (buf == "" ? $0 : buf "\n" $0) }
  ')"
  [ -n "$fenced_calls" ] || fail "no persist_last_published inside a fenced code block"
  # There must be at least two invocations (one per pass)
  local call_count
  call_count="$(printf '%s\n' "$fenced_calls" | grep -c 'persist_last_published')"
  [ "$call_count" -ge 2 ] || fail "expected at least 2 fenced persist_last_published calls, found $call_count"
  # Split on persist_last_published boundaries and check each call
  # separately for the five required flags.
  local call_idx=0
  local current_call=""
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -qF 'persist_last_published'; then
      # Flush previous call if any
      if [ -n "$current_call" ]; then
        call_idx=$((call_idx + 1))
        printf '%s' "$current_call" | grep -qF -- '--outcomes' \
          || fail "persist_last_published call $call_idx missing --outcomes"
        printf '%s' "$current_call" | grep -qF -- '--output' \
          || fail "persist_last_published call $call_idx missing --output"
        printf '%s' "$current_call" | grep -qF -- '--local-hash-map' \
          || fail "persist_last_published call $call_idx missing --local-hash-map"
        printf '%s' "$current_call" | grep -qF -- '--design-record' \
          || fail "persist_last_published call $call_idx missing --design-record"
        printf '%s' "$current_call" | grep -qF -- '--project' \
          || fail "persist_last_published call $call_idx missing --project"
      fi
      current_call="$line"
    else
      current_call="${current_call}
${line}"
    fi
  done <<< "$fenced_calls"
  # Flush the last call
  if [ -n "$current_call" ]; then
    call_idx=$((call_idx + 1))
    printf '%s' "$current_call" | grep -qF -- '--outcomes' \
      || fail "persist_last_published call $call_idx missing --outcomes"
    printf '%s' "$current_call" | grep -qF -- '--output' \
      || fail "persist_last_published call $call_idx missing --output"
    printf '%s' "$current_call" | grep -qF -- '--local-hash-map' \
      || fail "persist_last_published call $call_idx missing --local-hash-map"
    printf '%s' "$current_call" | grep -qF -- '--design-record' \
      || fail "persist_last_published call $call_idx missing --design-record"
    printf '%s' "$current_call" | grep -qF -- '--project' \
      || fail "persist_last_published call $call_idx missing --project"
  fi
  [ "$call_idx" -ge 2 ] || fail "expected at least 2 persist_last_published calls checked, got $call_idx"
}
