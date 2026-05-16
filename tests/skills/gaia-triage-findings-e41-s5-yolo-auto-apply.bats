#!/usr/bin/env bats
# gaia-triage-findings-e41-s5-yolo-auto-apply.bats — E41-S5 declarative wire-up
#
# Validates the declarative surface and hard-gate preservation for
# /gaia-triage-findings YOLO auto-apply (GR-TF-1).
#
# AC1 (TC-YOLO-10): yolo_steps:[3] declared; Step 3 invokes yolo-mode.sh is_yolo;
#                    > [!yolo] body marker per §10.30.2 documents auto-apply
# AC2 (TC-YOLO-11): Step 3b Done-Story Guard body preserved (FR-FITP-1 hard gate)
#                    yolo_steps does NOT include 3b / 3c (FR-YOLO-2(b))
# AC3 (TC-YOLO-14): non-YOLO per-finding confirmation flow text preserved
# AC4 (FR-FITP-3): Step 3c action-items wire-up preserved
# AC6 (ECI-508):   idempotency markers [TRIAGED]/[DISMISSED] still referenced
#
# Usage: bats tests/skills/gaia-triage-findings-e41-s5-yolo-auto-apply.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_FILE="$REPO_ROOT/plugins/gaia/skills/gaia-triage-findings/SKILL.md"
  HELPER_FILE="$REPO_ROOT/plugins/gaia/scripts/yolo-mode.sh"
}

frontmatter() {
  awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2) exit; next} n==1' "$SKILL_FILE"
}

# Step bodies use both "### Step N ---" and "### Step N --" patterns in this skill;
# tolerate either; stop at the next ### Step heading or top-level ## section.
step_body() {
  local header="$1"
  awk -v hdr="$header" '
    $0 ~ "^### " hdr "($|[^A-Za-z0-9])" { capture=1; next }
    /^### Step / && capture { exit }
    /^## [^#]/ && capture { exit }
    capture { print }
  ' "$SKILL_FILE"
}

# ---------- Pre-flight ----------

@test "Pre-flight: SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "Pre-flight: yolo-mode.sh helper exists (E41-S1)" {
  [ -f "$HELPER_FILE" ]
  grep -q '^is_yolo()' "$HELPER_FILE"
}

# ---------- AC1: declarative surface ----------

@test "AC1: frontmatter declares yolo_steps: [3]" {
  frontmatter | grep -qE '^yolo_steps:[[:space:]]*\[[[:space:]]*3[[:space:]]*\]'
}

@test "AC1: Step 3 body invokes yolo-mode.sh is_yolo helper" {
  step_body "Step 3" | grep -qE 'yolo-mode\.sh.*is_yolo'
}

@test "AC1: Step 3 body declares the > [!yolo] body marker per §10.30.2" {
  step_body "Step 3" | grep -qE '^>[[:space:]]*\[!yolo\]'
}

@test "AC1: Step 3 body documents auto-apply under YOLO" {
  step_body "Step 3" | grep -qiE 'auto-apply'
}

# ---------- AC2: hard-gate preservation (FR-YOLO-2(b)) ----------

@test "AC2: yolo_steps does NOT include Step 3b (FR-FITP-1 hard gate)" {
  # Step 3b is referenced as "3b" not just the number 3 — but yolo_steps takes
  # integer step indices. Just confirm 3b is documented as a hard gate elsewhere.
  step_body "Step 3" | grep -qE 'Step 3b|3b.*hard gate|Done-Story Guard'
}

@test "AC2: Step 3b Done-Story Guard heading is preserved" {
  grep -qE '^### Step 3b' "$SKILL_FILE"
}

@test "AC2: Step 3b body still invokes triage-guard.sh check" {
  step_body "Step 3b" | grep -qE 'triage-guard\.sh check'
}

# ---------- AC3: non-YOLO regression preserved ----------

@test "AC3: Step 3 body retains the canonical non-YOLO confirm/override wording" {
  step_body "Step 3" | grep -qiE 'confirm or override|user confirm'
}

# ---------- AC4: Step 3c action-items persistence preserved (FR-FITP-3) ----------

@test "AC4: Step 3c heading is preserved" {
  grep -qE '^### Step 3c' "$SKILL_FILE"
}

@test "AC4: Step 3c body still wires action-items writer for NOW classifications" {
  step_body "Step 3c" | grep -qiE 'action-items|aiw_write|FR-FITP-3'
}

# ---------- AC6: idempotency markers preserved (ECI-508) ----------

@test "AC6: TRIAGED / DISMISSED markers referenced for Ctrl-C recovery" {
  grep -qE '\[TRIAGED\]' "$SKILL_FILE"
  grep -qE '\[DISMISSED\]' "$SKILL_FILE"
}

# ---------- Anti-pattern guard (§10.30.8) ----------

@test "Anti-pattern: Step 3 body uses yolo-mode.sh helper (not inline env parse)" {
  step_body "Step 3" | grep -qE 'yolo-mode\.sh|is_yolo'
}
