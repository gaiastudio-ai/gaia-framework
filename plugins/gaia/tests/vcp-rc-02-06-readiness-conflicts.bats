#!/usr/bin/env bats
# vcp-rc-02-06-readiness-conflicts.bats — E46-S4 / FR-352
#
# Validates that the gaia-readiness-check SKILL.md documents the three
# parity restorations introduced by E46-S4:
#
#   - Priority/schedule conflict detection (Step 7) — VCP-RC-03, VCP-RC-04
#   - Compliance timeline estimation        (Step 7) — VCP-RC-05
#   - Self-contradiction sweep              (Step 10) — VCP-RC-02
#   - No false positives when fixtures lack compliance — VCP-RC-06
#
# These are LLM-checkable behaviours at runtime; the bats layer asserts the
# textual contract on SKILL.md so the spec cannot regress silently. The full
# end-to-end runs in a Claude Code validation session per §11.46 convention.
#
# NFR-052 coverage gate: helpers carry leading-underscore prefix.
# vcp-cpt-09 step-count gate: this test does NOT introduce new
#   `### Step N — Title` headings — additions live as bullets within the
#   existing Step 7 and Step 10 sections (story Tech Notes).
#
# Refs: docs/implementation-artifacts/E46-S4-*.md
#       docs/test-artifacts/test-plan.md §11.46.12
#       docs/planning-artifacts/prd.md §4.33 FR-352

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$BATS_TEST_DIRNAME/../skills/gaia-readiness-check"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"
}
teardown() { common_teardown; }

# ---------- helpers ----------

_extract_step_block() {
  # _extract_step_block <step_number>
  # Echoes the body of `### Step N — ...` up to (but not including) the next
  # `### Step ` heading. Used to scope grep assertions to a specific step.
  local n="$1"
  awk -v n="$n" '
    BEGIN { inblock=0 }
    /^### Step [0-9]+ — / {
      if (inblock) { exit }
      if ($0 ~ "^### Step " n " — ") { inblock=1; next }
    }
    inblock { print }
  ' "$SKILL_FILE"
}

_step_count() {
  grep -cE '^### Step [0-9]+ —' "$SKILL_FILE"
}

# ---------- fixtures present ----------

@test "04 fixture exists: readiness-compliance-conflict/epics-and-stories.md" {
  [ -f "$FIXTURES_DIR/readiness-compliance-conflict/epics-and-stories.md" ]
}

@test "fixture exists: readiness-compliance-mix/epics-and-stories.md" {
  [ -f "$FIXTURES_DIR/readiness-compliance-mix/epics-and-stories.md" ]
}

@test "fixture exists: readiness-no-compliance/epics-and-stories.md" {
  [ -f "$FIXTURES_DIR/readiness-no-compliance/epics-and-stories.md" ]
}

@test "fixture exists: readiness-self-contradiction/readiness-report.md" {
  [ -f "$FIXTURES_DIR/readiness-self-contradiction/readiness-report.md" ]
}

# ---------- compliance-conflict fixture content ----------

@test "compliance-conflict fixture contains a P0 GDPR story under a Post-MVP epic" {
  local f="$FIXTURES_DIR/readiness-compliance-conflict/epics-and-stories.md"
  grep -qE 'Post-MVP' "$f"
  grep -qE 'P0.*GDPR|GDPR.*P0' "$f"
}

@test "compliance-conflict fixture contains a P1 HIPAA story under a Phase 3 epic" {
  local f="$FIXTURES_DIR/readiness-compliance-conflict/epics-and-stories.md"
  grep -qE 'Phase 3' "$f"
  grep -qE 'P1.*HIPAA|HIPAA.*P1' "$f"
}

@test "compliance-mix fixture has 5 GDPR, 3 PCI-DSS, 2 HIPAA story rows" {
  local f="$FIXTURES_DIR/readiness-compliance-mix/epics-and-stories.md"
  local g p h
  g=$(grep -cE 'GDPR' "$f")
  # PCI-DSS variants: PCI-DSS or PCI DSS
  p=$(grep -cE 'PCI[- ]DSS' "$f")
  h=$(grep -cE 'HIPAA' "$f")
  [ "$g" -ge 5 ] || { echo "GDPR count = $g, expected >= 5"; return 1; }
  [ "$p" -ge 3 ] || { echo "PCI-DSS count = $p, expected >= 3"; return 1; }
  [ "$h" -ge 2 ] || { echo "HIPAA count = $h, expected >= 2"; return 1; }
}

@test "no-compliance fixture mentions zero GDPR/PCI-DSS/HIPAA tokens" {
  local f="$FIXTURES_DIR/readiness-no-compliance/epics-and-stories.md"
  ! grep -qE 'GDPR|PCI[- ]DSS|HIPAA' "$f"
}

@test "self-contradiction fixture has fully traced and no test coverage" {
  local f="$FIXTURES_DIR/readiness-self-contradiction/readiness-report.md"
  grep -qE 'FR-1.*fully traced' "$f"
  grep -qE 'FR-1.*no test coverage' "$f"
}

# ---------- SKILL.md step-count guard (vcp-cpt-09 parity) ----------

@test "SKILL.md still contains exactly 13 Step headings (vcp-cpt-09 parity)" {
  [ "$(_step_count)" = "13" ]
}

# ---------- AC1 / VCP-RC-03 / VCP-RC-04: priority-schedule sub-bullet ----------

@test "Step 7 documents the priority/schedule conflict scan (AC1, AC5)" {
  local block
  block="$(_extract_step_block 7)"
  echo "$block" | grep -qiE 'priority/schedule.*conflict|priority/schedule conflicts'
  echo "$block" | grep -qiE 'P0|P1'
  echo "$block" | grep -qiE 'GDPR'
  echo "$block" | grep -qiE 'HIPAA'
  echo "$block" | grep -qiE 'PCI[- ]DSS'
  echo "$block" | grep -qiE 'WARNING'
  echo "$block" | grep -qiE 'late.?phase|Post-MVP|Phase 2|Phase 3'
}

# ---------- AC2 / VCP-RC-05: compliance timeline estimation ----------

@test "Step 7 documents the compliance timeline estimation formula (AC2)" {
  local block
  block="$(_extract_step_block 7)"
  echo "$block" | grep -qiE 'compliance timeline'
  # Formula must be auditable inline.
  echo "$block" | grep -qE 'ceil\(.*story_count.*\*.*1\.5'
  echo "$block" | grep -qiE 'min.*1 week|minimum.*1.*week'
}

# ---------- AC4 / VCP-RC-06: silent on zero-compliance projects ----------

@test "Step 7 explicitly states that zero compliance stories suppresses the section (AC4)" {
  local block
  block="$(_extract_step_block 7)"
  echo "$block" | grep -qiE 'no.*compliance|zero.*compliance|omit'
}

# ---------- AC3 / VCP-RC-02: inline self-contradiction sweep at Step 10 ----------

@test "Step 10 documents the inline self-contradiction sweep (AC3)" {
  local block
  block="$(_extract_step_block 10)"
  echo "$block" | grep -qiE 'self-contradiction'
  echo "$block" | grep -qiE 'fully traced'
  echo "$block" | grep -qiE 'no test coverage'
}

@test "Step 10 documents enumeration of ALL contradiction pairs (AC6)" {
  local block
  block="$(_extract_step_block 10)"
  # Must mention enumerate/all and deterministic ordering.
  echo "$block" | grep -qiE 'enumerate|all.*pairs|every.*pair'
  echo "$block" | grep -qiE 'deterministic|alphabetical|stable'
}

# ---------- AC4 sub-promise (Subtask 4.1): three new frontmatter fields ----------

@test "Step 10 declares the three new YAML frontmatter fields (Subtask 4.1)" {
  local block
  block="$(_extract_step_block 10)"
  echo "$block" | grep -qE 'priority_schedule_conflicts_count'
  echo "$block" | grep -qE 'compliance_timeline_present'
  echo "$block" | grep -qE 'self_contradictions_count'
}

# ---------- AC4 sub-promise (Subtask 4.2): gate downgrade rule ----------

@test "Step 10 states self_contradictions_count > 0 prevents PASS verdict (Subtask 4.2)" {
  local block
  block="$(_extract_step_block 10)"
  # Must connect the count field to the PASS/CONDITIONAL downgrade.
  echo "$block" | grep -qiE 'self_contradictions_count.*>.*0|MUST NOT be PASS|CONDITIONAL'
}

# ---------- compliance-keyword scope guard (Dev Notes) ----------

@test "Step 7 enumerates the three compliance keywords (closed list intent)" {
  local block
  block="$(_extract_step_block 7)"
  # The closed compliance list MUST include GDPR, HIPAA, PCI-DSS.
  echo "$block" | grep -qiE 'GDPR'
  echo "$block" | grep -qiE 'HIPAA'
  echo "$block" | grep -qiE 'PCI[- ]DSS'
  # And MUST explicitly call the list closed — no silent extension.
  echo "$block" | grep -qiE 'closed list|do NOT extend|no others'
}

# ---------- traceability: FR-352 row references E46-S4 + VCP-RC-01..06 ----------

@test "traceability matrix row for references ..06" {
  local trace
  trace="$BATS_TEST_DIRNAME/../../../../docs/test-artifacts/traceability-matrix.md"
  if [ ! -f "$trace" ]; then
    skip "traceability-matrix.md not present in this checkout"
  fi
  grep -qE 'FR-352.*VCP-RC-01.*VCP-RC-06' "$trace" \
    || grep -qE 'FR-352.*VCP-RC-01\.\.VCP-RC-06' "$trace" \
    || grep -qE 'FR-352.*VCP-RC-01\.\.06' "$trace"
}

# ---------- test-plan: VCP-RC-02..06 status flipped from Planned ----------

@test "test plan ..06 rows no longer say 'Planned / Not Yet Written'" {
  local plan
  plan="$BATS_TEST_DIRNAME/../../../../docs/test-artifacts/test-plan.md"
  if [ ! -f "$plan" ]; then
    skip "test-plan.md not present in this checkout"
  fi
  local id
  for id in VCP-RC-02 VCP-RC-03 VCP-RC-04 VCP-RC-05 VCP-RC-06; do
    local row
    row=$(grep -E "^\| $id " "$plan" || true)
    [ -n "$row" ] || { echo "row for $id not found"; return 1; }
    if echo "$row" | grep -qE 'Planned / Not Yet Written'; then
      echo "$id still marked Planned / Not Yet Written: $row"
      return 1
    fi
  done
}
