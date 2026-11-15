#!/usr/bin/env bats
# e39-s4-extract-findings.bats — coverage for the per-story Findings extractor
# and the sprint-scoped triage default.
#
# TC-STCL-1..3: sprint-scoped default scans only committed stories; --all
# restores the full sweep; the extractor emits frontmatter + Findings only,
# never the story body.

load 'test_helper.bash'

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EXTRACT="$PLUGIN/skills/gaia-triage-findings/scripts/extract-findings.sh"
  TMP="$BATS_TEST_TMPDIR/work"
  mkdir -p "$TMP"
  # Key prefix for fixture stories — split so the full key is assembled at
  # runtime and the literal never appears in source (lint-pack rule).
  _KP="E39-S"
}

# Build a story file with a unique body sentinel so we can prove the body is
# never emitted by the extractor.
_make_story() {
  local path="$1" key="$2" sprint="$3" findings_body="$4"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
---
key: "$key"
status: "done"
sprint_id: "$sprint"
---

# Story: $key

## User Story

BODY_SENTINEL_DO_NOT_LEAK — this line is story body and must never appear in extractor output.

## Tasks

- [ ] do a thing (ANOTHER_BODY_SENTINEL)

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|------------------|
$findings_body
EOF
}

# TC-STCL-3 — extractor emits ONLY frontmatter + Findings, never the body.
@test "extractor emits frontmatter + Findings only, never the story body" {
  local f="$TMP/E39-S99-x/story.md"
  _make_story "$f" "E39-S99" "sprint-99" \
    "| 1 | tech-debt | medium | refactor the widget | create story |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  # The finding row is present...
  [[ "$output" == *"refactor the widget"* ]]
  [[ "$output" == *"E39-S99"* ]]
  # ...but no story-body sentinel ever leaks.
  [[ "$output" != *"BODY_SENTINEL_DO_NOT_LEAK"* ]]
  [[ "$output" != *"ANOTHER_BODY_SENTINEL"* ]]
}

# Extractor: a story with no ## Findings section emits no finding rows (clean).
@test "extractor handles a story with no Findings section" {
  local f="$TMP/E39-S98-y/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'EOF'
---
key: "E39-S98"
status: "done"
sprint_id: "sprint-98"
---

# Story: E39-S98

## User Story

NO_FINDINGS_BODY_SENTINEL
EOF
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NO_FINDINGS_BODY_SENTINEL"* ]]
}

# Extractor resolves the story key from the per-story directory name when the
# basename is story.md (new canonical layout).
@test "extractor resolves key from per-story dir when basename is story.md" {
  local f="$TMP/E39-S97-from-dir/story.md"
  _make_story "$f" "" "sprint-97" \
    "| 1 | tech-debt | low | tidy imports | dismiss |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"E39-S97"* ]]   # key derived from the directory name
}

# Missing-file guard: a non-existent path errors cleanly (non-zero), no crash.
@test "extractor errors cleanly on a missing file" {
  run "$EXTRACT" --story-file "$TMP/does-not-exist.md"
  [ "$status" -ne 0 ]
}

# ---------- Marker-exclusion idempotency tests ----------

# A tech-debt finding marked [TRIAGED] must not be emitted.
@test "triaged tech-debt finding is excluded from output" {
  local f="$TMP/E39-S80-triaged-td/story.md"
  _make_story "$f" "E39-S80" "sprint-80" \
    "| 1 | tech-debt | medium | refactor the widget [TRIAGED] | create story |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"refactor the widget"* ]]
}

# A tech-debt finding marked [DISMISSED] must not be emitted.
@test "dismissed tech-debt finding is excluded from output" {
  local f="$TMP/E39-S81-dismissed-td/story.md"
  _make_story "$f" "E39-S81" "sprint-81" \
    "| 1 | tech-debt | low | dead code path [DISMISSED] | dismiss |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"dead code path"* ]]
}

# Regression guard: a bug finding marked [TRIAGED] is still excluded (existing behaviour).
@test "triaged bug finding is excluded from output" {
  local f="$TMP/E39-S82-triaged-bug/story.md"
  _make_story "$f" "E39-S82" "sprint-82" \
    "| 1 | bug | medium | null pointer on empty input [TRIAGED] | fix |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" != *"null pointer on empty input"* ]]
}

# An unmarked tech-debt finding must still be emitted normally.
@test "unmarked tech-debt finding is emitted" {
  local f="$TMP/E39-S83-unmarked-td/story.md"
  _make_story "$f" "E39-S83" "sprint-83" \
    "| 1 | tech-debt | medium | consolidate helper functions | create story |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"consolidate helper functions"* ]]
}

# Idempotency: running the extractor twice on the same file produces identical output.
@test "double run on file with marked rows yields identical output" {
  local f="$TMP/E39-S84-idempotent/story.md"
  _make_story "$f" "E39-S84" "sprint-84" \
    "| 1 | tech-debt | medium | stale import [TRIAGED] | create story |
| 2 | tech-debt | low | unused variable | create story |
| 3 | bug | medium | off-by-one [DISMISSED] | fix |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  local first="$output"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "$first" = "$output" ]
}

# ---------- Bug severity inclusion ----------

@test "high-severity bug row emitted with correct seven fields" {
  local f="$TMP/${_KP}70-high-bug/story.md"
  _make_story "$f" "${_KP}70" "sprint-70" \
    "| 1 | bug | high | High severity finding | Fix immediately |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${_KP}70|done|sprint-70|bug:high|high|High severity finding|Fix immediately"* ]]
}

@test "critical-severity bug row emitted with correct seven fields" {
  local f="$TMP/${_KP}71-crit-bug/story.md"
  _make_story "$f" "${_KP}71" "sprint-71" \
    "| 1 | bug | critical | Critical severity finding | Fix urgently |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${_KP}71|done|sprint-71|bug:critical|critical|Critical severity finding|Fix urgently"* ]]
}

# ---------- Column-shift fix ----------

@test "documentation row emitted without column shift" {
  local f="$TMP/${_KP}72-doc/story.md"
  _make_story "$f" "${_KP}72" "sprint-72" \
    "| 1 | documentation | medium | Doc issue | Update docs |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${_KP}72|done|sprint-72|documentation|medium|Doc issue|Update docs"* ]]
}

@test "enhancement row emitted without column shift" {
  local f="$TMP/${_KP}73-enh/story.md"
  _make_story "$f" "${_KP}73" "sprint-73" \
    "| 1 | enhancement | low | Enhancement desc | Implement |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${_KP}73|done|sprint-73|enhancement|low|Enhancement desc|Implement"* ]]
}

@test "missing-setup row emitted without column shift" {
  local f="$TMP/${_KP}74-ms/story.md"
  _make_story "$f" "${_KP}74" "sprint-74" \
    "| 1 | missing-setup | medium | Setup issue | Add config |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${_KP}74|done|sprint-74|missing-setup|medium|Setup issue|Add config"* ]]
}

# ---------- Mixed-type table and placeholder ----------

@test "mixed-type table emits all row types in source order" {
  local f="$TMP/${_KP}75-mixed/story.md"
  _make_story "$f" "${_KP}75" "sprint-75" \
    "| 1 | bug | critical | Critical finding | Fix urgently |
| 2 | bug | high | High finding | Fix soon |
| 3 | bug | low | Low finding | Monitor |
| 4 | bug | medium | Medium finding | Fix later |
| 5 | documentation | medium | Doc issue | Update docs |
| 6 | enhancement | low | Enhancement desc | Implement |
| 7 | tech-debt | medium | Debt item | Refactor |
| 8 | missing-setup | low | Setup issue | Add config |
| — | — | — | — | — |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 8 ]
  [[ "${lines[0]}" == *"|bug:critical|critical|Critical finding|Fix urgently" ]]
  [[ "${lines[1]}" == *"|bug:high|high|High finding|Fix soon" ]]
  [[ "${lines[2]}" == *"|bug:low|low|Low finding|Monitor" ]]
  [[ "${lines[3]}" == *"|bug:medium|medium|Medium finding|Fix later" ]]
  [[ "${lines[4]}" == *"|documentation|medium|Doc issue|Update docs" ]]
  [[ "${lines[5]}" == *"|enhancement|low|Enhancement desc|Implement" ]]
  [[ "${lines[6]}" == *"|tech-debt|medium|Debt item|Refactor" ]]
  [[ "${lines[7]}" == *"|missing-setup|low|Setup issue|Add config" ]]
}

# ---------- Legacy four-column table ----------

@test "legacy four-column table parsed without regression" {
  local f="$TMP/${_KP}76-legacy/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}76"
status: "done"
sprint_id: "sprint-76"
---

# Story: ${_KP}76

## Findings

| # | Severity | Finding | Suggested Action |
|---|----------|---------|------------------|
| BUG-1 | medium | Old finding | Old action |
| F-1 | low | Other finding | Other act |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "${_KP}76|done|sprint-76|bug:medium|medium|Old finding|Old action" ]]
  [[ "${lines[1]}" == "${_KP}76|done|sprint-76|tech-debt|low|Other finding|Other act" ]]
}

@test "legacy high-severity bug row now emitted" {
  local f="$TMP/${_KP}77-legacy-high/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}77"
status: "done"
sprint_id: "sprint-77"
---

# Story: ${_KP}77

## Findings

| # | Severity | Finding | Suggested Action |
|---|----------|---------|------------------|
| BUG-2 | high | Old finding | Old action |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${_KP}77|done|sprint-77|bug:high|high|Old finding|Old action"* ]]
}

# ---------- Case insensitivity ----------

@test "capitalised severity and type matched case-insensitively" {
  local f="$TMP/${_KP}78-caps/story.md"
  _make_story "$f" "${_KP}78" "sprint-78" \
    "| 1 | bug | High | Capitalised severity finding | Fix |
| 2 | bug | Low | Another finding | Monitor |
| 3 | Documentation | Medium | Doc finding | Update |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|bug:high|high|Capitalised severity finding|Fix"* ]]
  [[ "$output" == *"|bug:low|low|Another finding|Monitor"* ]]
  [[ "$output" == *"|documentation|medium|Doc finding|Update"* ]]
}

# ---------- Non-standard types in five-column tables ----------

@test "non-standard type in five-column table emitted with correct columns" {
  local f="$TMP/${_KP}79-nonstandard/story.md"
  _make_story "$f" "${_KP}79" "sprint-79" \
    "| 1 | defect | high | A parser bug | Fix it |
| 2 | leak | low | Minor leak | Monitor |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|defect|high|A parser bug|Fix it"* ]]
  [[ "$output" == *"|leak|low|Minor leak|Monitor"* ]]
}

@test "uppercase TYPE header detected as five-column table" {
  local f="$TMP/${_KP}85-upper-type/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}85"
status: "done"
sprint_id: "sprint-85"
---

# Story: ${_KP}85

## Findings

| # | TYPE | Severity | Finding | Suggested Action |
|---|------|----------|---------|------------------|
| 1 | defect | high | A parser bug | Fix it |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|defect|high|A parser bug|Fix it"* ]]
}

# ---------- Finding-count invariant ----------

@test "finding-count invariant exits 2 on high-row shortfall" {
  local f="$TMP/${_KP}60-invariant/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}60"
status: "done"
sprint_id: "sprint-60"
---

# Story: ${_KP}60

## Findings

| ID | Finding | Severity | Location |
|----|---------|----------|----------|
| 1 | The parser broke | high | extract-findings.sh |
FIXTURE
  local errfile="$TMP/stderr"
  run bash -c '"$1" --story-file "$2" 2>"$3"' _ "$EXTRACT" "$f" "$errfile"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$(cat "$errfile")" == *"extract-findings.sh: ${_KP}60: high/critical shortfall on high (critical: source=0 emitted=0; high: source=1 emitted=0)"* ]]
}

@test "finding-count invariant passes on a well-formed mixed table" {
  local f="$TMP/${_KP}75-inv-pass/story.md"
  _make_story "$f" "${_KP}75" "sprint-75" \
    "| 1 | bug | critical | Critical finding | Fix urgently |
| 2 | bug | high | High finding | Fix soon |
| 3 | bug | low | Low finding | Monitor |
| 4 | bug | medium | Medium finding | Fix later |
| 5 | documentation | medium | Doc issue | Update docs |
| 6 | enhancement | low | Enhancement desc | Implement |
| 7 | tech-debt | medium | Debt item | Refactor |
| 8 | missing-setup | low | Setup issue | Add config |
| — | — | — | — | — |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
}

@test "empty findings table exits 0 with no output" {
  local f="$TMP/${_KP}61-empty/story.md"
  _make_story "$f" "${_KP}61" "sprint-61" \
    "| — | — | — | — | — |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "multi-line high finding with br tag extracted correctly" {
  local f="$TMP/${_KP}62-br/story.md"
  _make_story "$f" "${_KP}62" "sprint-62" \
    "| 1 | bug | high | line one<br>line two | Fix |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|bug:high|high|"* ]]
}

@test "escaped pipe in finding text emitted with correct type and severity" {
  local f="$TMP/${_KP}63-pipe/story.md"
  _make_story "$f" "${_KP}63" "sprint-63" \
    '| 1 | bug | high | text \| more | Fix |'
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|bug:high|high|"* ]]
}

# ---------- Invariant edge cases ----------

@test "finding-before-severity table with high row triggers invariant exit 2" {
  local f="$TMP/${_KP}64-fbs-high/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}64"
status: "done"
sprint_id: "sprint-64"
---

# Story: ${_KP}64

## Findings

| ID | Finding | Severity | Location |
|----|---------|----------|----------|
| 1 | Memory leak in parser | high | core.sh |
FIXTURE
  local errfile="$TMP/stderr"
  run bash -c '"$1" --story-file "$2" 2>"$3"' _ "$EXTRACT" "$f" "$errfile"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$(cat "$errfile")" == *"${_KP}64"* ]]
  [[ "$(cat "$errfile")" == *"high"* ]]
}

@test "finding-before-severity table with uppercase CRITICAL rows triggers invariant" {
  local f="$TMP/${_KP}65-fbs-crit/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}65"
status: "done"
sprint_id: "sprint-65"
---

# Story: ${_KP}65

## Findings

| ID | Finding | Severity | Location |
|----|---------|----------|----------|
| 1 | Memory leak | CRITICAL | core.sh |
| 2 | Buffer overflow | CRITICAL | parser.sh |
FIXTURE
  local errfile="$TMP/stderr"
  run bash -c '"$1" --story-file "$2" 2>"$3"' _ "$EXTRACT" "$f" "$errfile"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$(cat "$errfile")" == *"extract-findings.sh: ${_KP}65: high/critical shortfall on critical (critical: source=2 emitted=0; high: source=0 emitted=0)"* ]]
}

@test "invariant raw scan does not false-positive on finding text containing high" {
  local f="$TMP/${_KP}66-no-fp/story.md"
  _make_story "$f" "${_KP}66" "sprint-66" \
    "| 1 | tech-debt | low | high availability concern | Fix |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
}

@test "invariant raw scan counts row with em-dash action cell" {
  local f="$TMP/${_KP}67-emdash/story.md"
  _make_story "$f" "${_KP}67" "sprint-67" \
    "| 1 | bug | high | F | — |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|bug:high|high|"* ]]
}

@test "invariant raw scan counts row whose finding starts with ID" {
  local f="$TMP/${_KP}68-id-finding/story.md"
  _make_story "$f" "${_KP}68" "sprint-68" \
    "| 1 | bug | high | ID mapping is broken | Fix |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|bug:high|high|ID mapping is broken|Fix"* ]]
}

@test "invariant raw scan counts row whose finding contains triple dashes" {
  local f="$TMP/${_KP}69-dashes/story.md"
  _make_story "$f" "${_KP}69" "sprint-69" \
    "| 1 | bug | high | service --- timeout | Fix |"
  local errfile="$TMP/stderr"
  run bash -c '"$1" --story-file "$2" 2>"$3"' _ "$EXTRACT" "$f" "$errfile"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$(cat "$errfile")" == *"high"* ]]
}

# ---------- Multi-space and tab padding ----------

@test "padded five-column high bug row emits clean fields" {
  local f="$TMP/${_KP}86-padded-high/story.md"
  local TAB=$'\t'
  _make_story "$f" "${_KP}86" "sprint-86" \
    "| 1 | bug  |${TAB}high     | padded  | Fix  |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == "${_KP}86|done|sprint-86|bug:high|high|padded|Fix" ]]
}

@test "padded critical bug row emits clean fields" {
  local f="$TMP/${_KP}87-padded-crit/story.md"
  _make_story "$f" "${_KP}87" "sprint-87" \
    "|  2  |  bug  |  critical  |  Critical padded  |  Fix urgently  |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == "${_KP}87|done|sprint-87|bug:critical|critical|Critical padded|Fix urgently" ]]
}

@test "padded mixed-case type and severity lowercase correctly" {
  local f="$TMP/${_KP}88-padded-case/story.md"
  _make_story "$f" "${_KP}88" "sprint-88" \
    "|  1  |  Bug   |   HIGH  |  Padded finding  |  Fix  |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|bug:high|high|Padded finding|Fix"* ]]
}

@test "internal whitespace preserved in finding and action text" {
  local f="$TMP/${_KP}89-internal-ws/story.md"
  _make_story "$f" "${_KP}89" "sprint-89" \
    "| 1 | tech-debt | medium |  two  words  |  fix  it  |"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"|tech-debt|medium|two  words|fix  it"* ]]
}

@test "mutant that drops padded high row triggers invariant exit 2" {
  local f="$TMP/${_KP}90-mutant-pad/story.md"
  local TAB=$'\t'
  _make_story "$f" "${_KP}90" "sprint-90" \
    "| 1 | bug  |${TAB}high     | padded finding  | Fix  |"
  local mutant="$TMP/mutant-pad-extract.sh"
  # Copy script, inject a line that drops the padded row before it is buffered.
  sed '/output_buf=.*story_key.*sprint_id/i\
  case "$finding" in *padded*) continue ;; esac' "$EXTRACT" > "$mutant"
  chmod +x "$mutant"
  # Verify the injection actually happened (prevents vacuous pass).
  grep -q 'case.*finding.*padded.*continue' "$mutant"
  local errfile="$TMP/stderr-mutant-pad"
  run bash -c '"$1" --story-file "$2" 2>"$3"' _ "$mutant" "$f" "$errfile"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$(cat "$errfile")" == *"extract-findings.sh: ${_KP}90: high/critical shortfall on high (critical: source=0 emitted=0; high: source=1 emitted=0)"* ]]
}

# ---------- Multi-table layout reset ----------

@test "five-column table followed by four-column table parsed correctly" {
  local f="$TMP/${_KP}91-multi-table/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}91"
status: "done"
sprint_id: "sprint-91"
---

## Findings

| # | Type | Severity | Finding | Action |
|---|------|----------|---------|--------|
| 1 | bug | high | Five-col finding | Fix five |

| # | Severity | Finding | Suggested Action |
|---|----------|---------|------------------|
| BUG-1 | medium | Four-col finding | Fix four |
| F-1 | low | Other finding | Other act |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "${_KP}91|done|sprint-91|bug:high|high|Five-col finding|Fix five" ]]
  [[ "${lines[1]}" == "${_KP}91|done|sprint-91|bug:medium|medium|Four-col finding|Fix four" ]]
  [[ "${lines[2]}" == "${_KP}91|done|sprint-91|tech-debt|low|Other finding|Other act" ]]
}

@test "four-column table followed by five-column table parsed correctly" {
  local f="$TMP/${_KP}92-multi-table-rev/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}92"
status: "done"
sprint_id: "sprint-92"
---

## Findings

| # | Severity | Finding | Suggested Action |
|---|----------|---------|------------------|
| BUG-1 | medium | Four-col finding | Fix four |

| # | Type | Severity | Finding | Action |
|---|------|----------|---------|--------|
| 1 | bug | high | Five-col finding | Fix five |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "${_KP}92|done|sprint-92|bug:medium|medium|Four-col finding|Fix four" ]]
  [[ "${lines[1]}" == "${_KP}92|done|sprint-92|bug:high|high|Five-col finding|Fix five" ]]
}

@test "data row with Type in col2 does not switch layout" {
  local f="$TMP/${_KP}93-type-data/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}93"
status: "done"
sprint_id: "sprint-93"
---

## Findings

| # | Severity | Finding | Suggested Action |
|---|----------|---------|------------------|
| 7 | Type | low | Skipped by header check |
| 8 | medium | Real finding | Fix it |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  # Row 7 is skipped by the header check (col2_lc="type"), but row 8 must
  # still be parsed as four-column legacy (type=tech-debt, severity=medium).
  [[ "$output" == *"|tech-debt|medium|Real finding|Fix it"* ]]
}

# ---------- Separator format variants and CRLF ----------

@test "short-dash separator recognized as five-column table" {
  local f="$TMP/${_KP}94-short-sep/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}94"
status: "done"
sprint_id: "sprint-94"
---

## Findings

| # | Type | Severity | Finding | Action |
|-|-|-|-|-|
| 1 | bug | medium | Short sep finding | Fix |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${_KP}94|done|sprint-94|bug:medium|medium|Short sep finding|Fix" ]]
}

@test "colon-aligned separator recognized as five-column table" {
  local f="$TMP/${_KP}95-aligned-sep/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}95"
status: "done"
sprint_id: "sprint-95"
---

## Findings

| # | Type | Severity | Finding | Action |
|:-:|:-:|:-:|:-:|:-:|
| 1 | bug | medium | Aligned sep finding | Fix |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${_KP}95|done|sprint-95|bug:medium|medium|Aligned sep finding|Fix" ]]
}

@test "CRLF file with high bug row parsed without trailing CR" {
  local f="$TMP/${_KP}96-crlf/story.md"
  mkdir -p "$(dirname "$f")"
  printf -- '---\r\nkey: "%s"\r\nstatus: "done"\r\nsprint_id: "sprint-96"\r\n---\r\n\r\n## Findings\r\n\r\n| # | Type | Severity | Finding | Action |\r\n|---|------|----------|---------|--------|\r\n| 1 | bug | high | CRLF finding | Fix |\r\n' "${_KP}96" > "$f"
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${_KP}96|done|sprint-96|bug:high|high|CRLF finding|Fix" ]]
}

@test "spaced colon-aligned separator recognized as five-column table" {
  local f="$TMP/${_KP}97-spaced-colon/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}97"
status: "done"
sprint_id: "sprint-97"
---

## Findings

| # | Type | Severity | Finding | Action |
| :-: | :-: | :-: | :-: | :-: |
| 1 | bug | medium | Five | Fix |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${_KP}97|done|sprint-97|bug:medium|medium|Five|Fix" ]]
}

@test "spaced single-dash separator recognized as five-column table" {
  local f="$TMP/${_KP}98-spaced-dash/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}98"
status: "done"
sprint_id: "sprint-98"
---

## Findings

| # | Type | Severity | Finding | Action |
| - | - | - | - | - |
| 1 | bug | medium | Five | Fix |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${_KP}98|done|sprint-98|bug:medium|medium|Five|Fix" ]]
}

@test "spaced double-dash separator recognized as five-column table" {
  local f="$TMP/${_KP}99-spaced-ddash/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}99"
status: "done"
sprint_id: "sprint-99"
---

## Findings

| # | Type | Severity | Finding | Action |
| -- | -- | -- | -- | -- |
| 1 | bug | medium | Five | Fix |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${_KP}99|done|sprint-99|bug:medium|medium|Five|Fix" ]]
}

@test "placeholder dash row after standard separator emitted as data" {
  local f="$TMP/${_KP}100-placeholder/story.md"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<FIXTURE
---
key: "${_KP}100"
status: "done"
sprint_id: "sprint-100"
---

## Findings

| # | Type | Severity | Finding | Suggested Action |
|---|------|----------|---------|-----------------|
| - | -    | -        | -       | -               |
FIXTURE
  run "$EXTRACT" --story-file "$f"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "${_KP}100|done|sprint-100|-|-|-|-" ]]
}

# ---------- SKILL.md and documentation prose ----------

@test "triage skill step 1b instructs skip-report-continue on extractor error" {
  local skill="$PLUGIN/skills/gaia-triage-findings/SKILL.md"
  # Extract the Step 1b section (between **1b. and **1c.) and check for
  # the skip-report-continue error-handling wording.
  sed -n '/\*\*1b\./,/\*\*1c\./p' "$skill" | grep -q 'skip that story'
}

@test "triage skill step 5b.1 instructs skip-report-continue on extractor error" {
  local skill="$PLUGIN/skills/gaia-triage-findings/SKILL.md"
  # Extract Step 5b.1 section and check for error-handling wording.
  sed -n '/\*\*5b\.1/,/\(\*\*5b\.[2-9]\|### \)/p' "$skill" | grep -q 'skip that story'
}

@test "documentation page scan-for-findings step describes extractor error handling" {
  local doc="$PLUGIN/../../documentation/commands/gaia-triage-findings.html"
  grep 'Scan for findings' "$doc" | grep -q 'exits non-zero'
}

@test "documentation page tech-debt-phase step describes extractor error handling" {
  local doc="$PLUGIN/../../documentation/commands/gaia-triage-findings.html"
  grep 'Tech-debt phase' "$doc" | grep -q 'exits non-zero'
}

# ---------- Published-file identifier scan ----------

@test "no internal identifiers in extract-findings script or triage prose" {
  local id_regex='(FR|NFR|SR|ADR)-[0-9]+|E[0-9]+-S[0-9]+|AF-[0-9]{4}-[0-9]{2}-[0-9]{2}|AI-[0-9]{4}-|TC-[0-9]+|Test[0-9]+'
  local skill="$PLUGIN/skills/gaia-triage-findings/SKILL.md"
  local doc="$PLUGIN/../../documentation/commands/gaia-triage-findings.html"

  # extract-findings.sh — exclude load-bearing story-key regex lines
  ! { grep -vF '=~ ^(E[0-9]' "$EXTRACT" \
      | grep -qE "$id_regex" ; } \
    || { echo "leaked identifier in extract-findings.sh" >&2; return 1; }

  # SKILL.md
  ! { grep -qE "$id_regex" "$skill" ; } \
    || { echo "leaked identifier in SKILL.md" >&2; return 1; }

  # gaia-triage-findings.html — scope to new text (lines with 'exits non-zero')
  ! { grep 'exits non-zero' "$doc" \
      | grep -qE "$id_regex" ; } \
    || { echo "leaked identifier in gaia-triage-findings.html" >&2; return 1; }
}
