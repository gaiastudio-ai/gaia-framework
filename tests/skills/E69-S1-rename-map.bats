#!/usr/bin/env bats
# E69-S1-rename-map.bats — slash-command rename map validation
#
# Validates eight command renames per source-report §2.2:
#   gaia-code-review        -> gaia-review-code
#   gaia-qa-tests           -> gaia-review-qa
#   gaia-test-review        -> gaia-review-test
#   gaia-security-review    -> gaia-review-security (merge + retire)
#   gaia-a11y-testing       -> gaia-test-a11y
#   gaia-ci-setup           -> gaia-config-ci
#   gaia-performance-review -> gaia-perf-deepdive
#   gaia-run-all-reviews    -> gaia-review-all
#
# Surfaces:
#   - gaia-help.csv (6 in-place renames + 1 merge + 1 add)
#   - workflow-manifest.csv (8 renames)
#   - 8 SKILL.md files (7 name updates + 1 retirement)
#
# Usage: bats tests/skills/E69-S1-rename-map.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  KNOWLEDGE_DIR="$REPO_ROOT/plugins/gaia/knowledge"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  HELP_CSV="$KNOWLEDGE_DIR/gaia-help.csv"
  MANIFEST_CSV="$KNOWLEDGE_DIR/workflow-manifest.csv"
}

# Helper: returns 0 if exact field value appears in any column of CSV
csv_field_present() {
  local file="$1" field="$2"
  grep -Fq "\"$field\"" "$file"
}

# ---------- AC1: gaia-help.csv ----------

@test "AC1: gaia-help.csv has gaia-review-code as command (renamed from gaia-code-review)" {
  csv_field_present "$HELP_CSV" "gaia-review-code"
}

@test "AC1: gaia-help.csv no longer has gaia-code-review as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-code-review"'
}

@test "AC1: gaia-help.csv has gaia-review-qa as command" {
  csv_field_present "$HELP_CSV" "gaia-review-qa"
}

@test "AC1: gaia-help.csv no longer has gaia-qa-tests as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-qa-tests"'
}

@test "AC1: gaia-help.csv has gaia-review-test as command" {
  csv_field_present "$HELP_CSV" "gaia-review-test"
}

@test "AC1: gaia-help.csv no longer has gaia-test-review as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-test-review"'
}

@test "AC1: gaia-help.csv has gaia-test-a11y as command" {
  csv_field_present "$HELP_CSV" "gaia-test-a11y"
}

@test "AC1: gaia-help.csv no longer has gaia-a11y-testing as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-a11y-testing"'
}

@test "AC1: gaia-help.csv has gaia-config-ci as command" {
  csv_field_present "$HELP_CSV" "gaia-config-ci"
}

@test "AC1: gaia-help.csv no longer has gaia-ci-setup as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-ci-setup"'
}

@test "AC1: gaia-help.csv has gaia-perf-deepdive as command" {
  csv_field_present "$HELP_CSV" "gaia-perf-deepdive"
}

@test "AC1: gaia-help.csv no longer has gaia-performance-review as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-performance-review"'
}

@test "AC1: gaia-help.csv security-review row merged — only one gaia-review-security row" {
  local count
  count=$(awk -F',' '{print $5}' "$HELP_CSV" | grep -c '"gaia-review-security"')
  [ "$count" -eq 1 ]
}

@test "AC1: gaia-help.csv no longer has gaia-security-review as primary command" {
  ! awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-security-review"'
}

@test "AC1: gaia-help.csv has new gaia-review-all row" {
  awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-review-all"'
}

# ---------- AC2: workflow-manifest.csv ----------

@test "AC2: workflow-manifest.csv has gaia-review-code" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-review-code"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-code-review as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-code-review"'
}

@test "AC2: workflow-manifest.csv has gaia-review-qa" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-review-qa"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-qa-tests as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-qa-tests"'
}

@test "AC2: workflow-manifest.csv has gaia-review-test" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-review-test"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-test-review as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-test-review"'
}

@test "AC2: workflow-manifest.csv has gaia-review-security" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-review-security"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-security-review as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-security-review"'
}

@test "AC2: workflow-manifest.csv has gaia-test-a11y" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-test-a11y"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-a11y-testing as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-a11y-testing"'
}

@test "AC2: workflow-manifest.csv has gaia-config-ci" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-config-ci"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-ci-setup as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-ci-setup"'
}

@test "AC2: workflow-manifest.csv has gaia-perf-deepdive" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-perf-deepdive"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-performance-review as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-performance-review"'
}

@test "AC2: workflow-manifest.csv has gaia-review-all" {
  awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-review-all"'
}

@test "AC2: workflow-manifest.csv no longer has gaia-run-all-reviews as command" {
  ! awk -F',' '{print $7}' "$MANIFEST_CSV" | grep -q '"gaia-run-all-reviews"'
}

# ---------- AC3: SKILL.md frontmatter name: ----------

@test "AC3: gaia-code-review/SKILL.md has name: gaia-review-code" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-code-review/SKILL.md" | grep -q "^name: gaia-review-code$"
}

@test "AC3: gaia-qa-tests/SKILL.md has name: gaia-review-qa" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-qa-tests/SKILL.md" | grep -q "^name: gaia-review-qa$"
}

@test "AC3: gaia-test-review/SKILL.md has name: gaia-review-test" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-test-review/SKILL.md" | grep -q "^name: gaia-review-test$"
}

@test "AC3: gaia-a11y-testing/SKILL.md has name: gaia-test-a11y" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-a11y-testing/SKILL.md" | grep -q "^name: gaia-test-a11y$"
}

@test "AC3: gaia-ci-setup/SKILL.md has name: gaia-config-ci" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-ci-setup/SKILL.md" | grep -q "^name: gaia-config-ci$"
}

@test "AC3: gaia-performance-review/SKILL.md has name: gaia-perf-deepdive" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-performance-review/SKILL.md" | grep -q "^name: gaia-perf-deepdive$"
}

@test "AC3: gaia-run-all-reviews/SKILL.md has name: gaia-review-all" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-run-all-reviews/SKILL.md" | grep -q "^name: gaia-review-all$"
}

@test "AC3: gaia-security-review/SKILL.md is RETIRED — name is NOT gaia-review-security" {
  ! awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-security-review/SKILL.md" | grep -q "^name: gaia-review-security$"
}

@test "AC3: gaia-security-review/SKILL.md has deprecated_aliases pointing to gaia-review-security" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-security-review/SKILL.md" | grep -q "gaia-review-security"
}

@test "AC3: gaia-review-security/SKILL.md still has name: gaia-review-security (canonical)" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-review-security/SKILL.md" | grep -q "^name: gaia-review-security$"
}

# ---------- AC4 & AC5: deprecation_aliases + deprecated_since ----------

@test "AC5: gaia-code-review/SKILL.md has deprecated_aliases for old name" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-code-review/SKILL.md" | grep -q "gaia-code-review"
}

@test "AC5: gaia-code-review/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-code-review/SKILL.md" | grep -q "^deprecated_since:"
}

@test "AC5: gaia-qa-tests/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-qa-tests/SKILL.md" | grep -q "^deprecated_since:"
}

@test "AC5: gaia-test-review/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-test-review/SKILL.md" | grep -q "^deprecated_since:"
}

@test "AC5: gaia-a11y-testing/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-a11y-testing/SKILL.md" | grep -q "^deprecated_since:"
}

@test "AC5: gaia-ci-setup/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-ci-setup/SKILL.md" | grep -q "^deprecated_since:"
}

@test "AC5: gaia-performance-review/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-performance-review/SKILL.md" | grep -q "^deprecated_since:"
}

@test "AC5: gaia-run-all-reviews/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-run-all-reviews/SKILL.md" | grep -q "^deprecated_since:"
}

@test "AC5: gaia-security-review/SKILL.md has deprecated_since field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-security-review/SKILL.md" | grep -q "^deprecated_since:"
}

# ---------- AC6: gaia-review-perf untouched ----------

@test "AC6: gaia-review-perf/SKILL.md still has name: gaia-review-perf" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-review-perf/SKILL.md" | grep -q "^name: gaia-review-perf$"
}

@test "AC6: gaia-review-perf/SKILL.md has NO deprecated_aliases (it is conformant)" {
  ! awk '/^---$/{n++; next} n==1{print}' "$SKILLS_DIR/gaia-review-perf/SKILL.md" | grep -q "^deprecated_aliases:"
}

@test "AC6: gaia-help.csv gaia-review-perf row unchanged (still present)" {
  awk -F',' '{print $5}' "$HELP_CSV" | grep -q '"gaia-review-perf"'
}
