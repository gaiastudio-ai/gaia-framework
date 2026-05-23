#!/usr/bin/env bats
# vcp-cpt-09-phase3-testing.bats — shared-helper exclusivity and wire-in
# assertions for Phase 3 testing skills (E43-S5).
#
# NFR-VCP-1 mandate: every checkpoint write MUST route through
# scripts/write-checkpoint.sh. This test extends VCP-CPT-09 coverage from
# Phase 1 (E43-S2), Phase 2 (E43-S3), and Phase 3 Solutioning (E43-S4) to
# the 8 Phase 3 testing skills. It also carries the VCP-CPT-11 cross-skill
# schema-consistency assertions: running one step of each of the 8 skills
# against a fixture, then validating the emitted checkpoint JSON against
# schema v1.
#
# Phase 3 testing skills and step counts (post E44-S6 wire-in; original
# E43-S5 counts noted in parens):
#   gaia-test-design         9 steps  (was 8; +1 Val Auto-Fix Loop step)
#   gaia-edit-test-plan      7 steps  (was 6; +1 Val Auto-Fix Loop step)
#   gaia-test-framework      5 steps
#   gaia-atdd                5 steps
#   gaia-trace               6 steps
#   gaia-ci-setup            9 steps
#   gaia-review-a11y         5 steps
#   gaia-val-validate        8 steps
#                      ---------- total: 54 invocations
#
# Refs: docs/implementation-artifacts/E43-S5-*.md,
#       docs/test-artifacts/test-plan.md §11.46.2,
#       docs/planning-artifacts/architecture.md §10.31.3 (ADR-059).

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/write-checkpoint.sh"
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export CHECKPOINT_ROOT="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_ROOT"
}
teardown() { common_teardown; }

# Canonical Phase 3 testing slugs and step counts (story E43-S5).
# Keep in sync with the SKILL.md files; mismatch = wire-in drift.
PHASE3_TEST_SLUGS=(
  gaia-test-design
  gaia-edit-test-plan
  gaia-test-framework
  gaia-atdd
  gaia-trace
  gaia-ci-setup
  gaia-review-a11y
  gaia-val-validate
)
PHASE3_TEST_STEPS=(9 7 5 5 6 9 5 8)

# Step-heading variants across the 8 skills:
#   - em-dash ("— "): gaia-edit-test-plan, gaia-test-framework, gaia-review-a11y
#   - double-hyphen ("-- "): gaia-test-design, gaia-atdd, gaia-trace,
#     gaia-ci-setup, gaia-val-validate
# Tests accept either variant via the `(--|—)` alternation.

# ---------- AC1/AC2/AC4: canonical invocation line present per step ----------

@test "AC1/AC2/AC4: each Phase 3 testing SKILL.md has one canonical invocation per declared step" {
  local i=0
  for slug in "${PHASE3_TEST_SLUGS[@]}"; do
    local expected="${PHASE3_TEST_STEPS[$i]}"
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || { echo "missing SKILL.md: $file"; return 1; }

    # Count `### Step N —` or `### Step N --` headings.
    local step_headings
    step_headings=$(grep -cE '^### Step [0-9]+ (--|—)' "$file" || true)
    [ "$step_headings" = "$expected" ] || {
      echo "$slug: expected $expected step headings, got $step_headings"
      return 1
    }

    # Count canonical write-checkpoint.sh invocation lines targeting this slug.
    local cp_lines
    cp_lines=$(grep -cE "^> \`!(\\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh ${slug} [0-9]+" "$file" || true)
    [ "$cp_lines" = "$expected" ] || {
      echo "$slug: expected $expected checkpoint invocations, got $cp_lines"
      return 1
    }

    # Each step N from 1..expected must have exactly one invocation line.
    local n
    for n in $(seq 1 "$expected"); do
      local hits
      hits=$(grep -cE "^> \`!(\\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh ${slug} ${n}( |\`)" "$file" || true)
      [ "$hits" = "1" ] || {
        echo "$slug step $n: expected 1 invocation, got $hits"
        return 1
      }
    done

    i=$((i+1))
  done
}

# ---------- AC5: per-skill key_variables surface ----------

@test "AC5: each Phase 3 testing SKILL.md declares required per-skill key_variables" {
  # Minimum one skill-specific key_variable per SKILL.md. The story requires
  # a non-empty subset of skill-own context.
  local spec
  for spec in \
    "gaia-test-design|story_key test_plan_path" \
    "gaia-edit-test-plan|test_plan_path edit_mode" \
    "gaia-test-framework|detected_stack framework_config_path" \
    "gaia-atdd|story_key test_file_path" \
    "gaia-trace|trace_matrix_path coverage_metrics" \
    "gaia-ci-setup|ci_provider ci_config_path" \
    "gaia-review-a11y|a11y_scope report_path" \
    "gaia-val-validate|artifact_path iteration_number"; do
    local slug="${spec%%|*}"
    local keys="${spec#*|}"
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || { echo "missing SKILL.md: $file"; return 1; }
    local key
    for key in $keys; do
      grep -qE "^> \`!(\\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh ${slug} [0-9]+ .*${key}=" "$file" || {
        echo "$slug: key_variable '$key' missing from all invocation lines"
        return 1
      }
    done
  done
}

# ---------- AC2 (VCP-CPT-09): no inline checkpoint writes in Phase 3 testing SKILL.md ----------

@test "AC2: no Phase 3 testing SKILL.md contains inline _memory/checkpoints writes" {
  local offenders=""
  for slug in "${PHASE3_TEST_SLUGS[@]}"; do
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || continue
    local hit
    hit=$(grep -nE '>\s*_memory/checkpoints' "$file" || true)
    if [ -n "$hit" ]; then
      offenders+="$file: $hit"$'\n'
    fi
    hit=$(grep -nE '(printf|echo|cat|tee)[^|]*>[^|]*checkpoints/.*\.json' "$file" || true)
    if [ -n "$hit" ]; then
      offenders+="$file: $hit"$'\n'
    fi
  done
  if [ -n "$offenders" ]; then
    echo "inline checkpoint writes detected:"
    echo "$offenders"
    return 1
  fi
}

# ---------- AC2: no inline writes in Phase 3 testing co-located scripts ----------

@test "AC2: Phase 3 testing co-located scripts do not write to _memory/checkpoints" {
  local offenders=""
  for slug in "${PHASE3_TEST_SLUGS[@]}"; do
    local scripts_dir="$SKILLS_DIR/$slug/scripts"
    [ -d "$scripts_dir" ] || continue
    local hit
    hit=$(grep -rnE '(printf|echo|cat|tee)[^|]*>[^|]*_memory/checkpoints/[^ ]*\.json' "$scripts_dir" 2>/dev/null || true)
    if [ -n "$hit" ]; then
      offenders+="$scripts_dir: $hit"$'\n'
    fi
  done
  if [ -n "$offenders" ]; then
    echo "inline checkpoint writes detected in Phase 3 testing co-located scripts:"
    echo "$offenders"
    return 1
  fi
}

# ---------- AC2: canonical helper line is the only checkpoint writer ----------

@test "AC2: every checkpoint-related line in Phase 3 testing SKILL.md routes through write-checkpoint.sh" {
  for slug in "${PHASE3_TEST_SLUGS[@]}"; do
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || continue
    local any_writer
    any_writer=$(grep -nE '_memory/checkpoints.*(>|<<)' "$file" || true)
    [ -z "$any_writer" ] || {
      echo "$slug: non-canonical checkpoint write detected: $any_writer"
      return 1
    }
  done
}

# ---------- AC4: skill_name discipline — literal slug, no slash ----------

@test "AC4: every invocation uses the literal skill slug as skill_name (no leading slash, no truncation)" {
  for slug in "${PHASE3_TEST_SLUGS[@]}"; do
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || continue
    # Reject any line that invokes write-checkpoint.sh with `/gaia-` prefix
    # or a non-matching slug.
    local bad
    bad=$(grep -nE '^> `!scripts/write-checkpoint\.sh /' "$file" || true)
    [ -z "$bad" ] || { echo "$slug: leading-slash skill_name found: $bad"; return 1; }
    bad=$(grep -nE "^> \`!(\\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint\.sh [a-z0-9-]+ " "$file" | grep -vE "write-checkpoint\.sh ${slug} " || true)
    [ -z "$bad" ] || { echo "$slug: wrong skill_name in invocation: $bad"; return 1; }
  done
}

# ---------- AC1/AC3/AC6 (VCP-CPT-11): schema consistency across all 8 skills ----------

# Per-skill step-count coverage consolidated into one data-driven test to keep
# the job inside the 2-minute bats CI budget. Runs one step of each
# non-multi-file skill with the step count drawn from PHASE3_TEST_STEPS, then
# asserts the resulting directory has exactly N JSON files with sequential
# step_numbers 1..N. gaia-ci-setup has its own @test below because it also
# validates the multi-file step (AC-EC8).

@test "VCP-CPT-11 AC1/AC6: per-skill step-count coverage (single-file skills)" {
  # slug|expected|key_var_1|val_1|key_var_2|val_2
  local spec
  for spec in \
    "gaia-test-design|9|story_key|E1-S1|test_plan_path|docs/test-artifacts/test-plan.md" \
    "gaia-edit-test-plan|7|test_plan_path|docs/test-artifacts/test-plan.md|edit_mode|add" \
    "gaia-test-framework|5|detected_stack|typescript|framework_config_path|jest.config.ts" \
    "gaia-atdd|5|story_key|E1-S1|test_file_path|docs/test-artifacts/atdd-E1-S1.md" \
    "gaia-trace|6|trace_matrix_path|docs/test-artifacts/traceability-matrix.md|coverage_metrics|full" \
    "gaia-review-a11y|5|a11y_scope|component|report_path|docs/test-artifacts/a11y.md" \
    "gaia-val-validate|8|artifact_path|docs/planning-artifacts/prd.md|iteration_number|1"; do
    local slug expected k1 v1 k2 v2
    IFS='|' read -r slug expected k1 v1 k2 v2 <<<"$spec"
    local artifact="$TEST_TMP/$slug.md"
    printf '# x\n' > "$artifact"
    local n
    for n in $(seq 1 "$expected"); do
      "$SCRIPT" "$slug" "$n" "$k1=$v1" "$k2=$v2" --paths "$artifact"
    done
    local dir="$CHECKPOINT_ROOT/$slug"
    [ -d "$dir" ] || { echo "$slug: checkpoint dir missing"; return 1; }
    local count
    count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
    [ "$count" = "$expected" ] || { echo "$slug: expected $expected checkpoints, got $count"; return 1; }
    local numbers expected_seq
    numbers=$(find "$dir" -name '*.json' -type f -exec jq -r '.step_number' {} \; | sort -n | tr '\n' ' ')
    expected_seq=$(seq 1 "$expected" | tr '\n' ' ')
    [ "$numbers" = "$expected_seq" ] || {
      echo "$slug: expected sequence '$expected_seq', got '$numbers'"; return 1
    }
  done
}

@test "VCP-CPT-11 AC1/AC6/AC-EC8: simulating gaia-ci-setup 9-step run writes 9 sequential checkpoints with multi-file step" {
  local slug="gaia-ci-setup"
  local f1="$TEST_TMP/.github/workflows/ci.yml"
  local f2="$TEST_TMP/.github/workflows/release.yml"
  mkdir -p "$(dirname "$f1")"
  printf 'on: push\n' > "$f1"
  printf 'on: tag\n' > "$f2"
  local n
  for n in $(seq 1 9); do
    if [ "$n" = "8" ]; then
      # Multi-file step (AC-EC8 coverage).
      "$SCRIPT" "$slug" "$n" ci_provider=github_actions ci_config_path="$f1" --paths "$f1" "$f2"
    else
      "$SCRIPT" "$slug" "$n" ci_provider=github_actions ci_config_path="$f1"
    fi
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "9" ]
  # Step 8 must record both output paths.
  local step8_paths
  step8_paths=$(find "$dir" -name '*-step-8.json' -type f -exec jq -r '.output_paths | length' {} \;)
  [ "$step8_paths" = "2" ]
  local step8_checksums
  step8_checksums=$(find "$dir" -name '*-step-8.json' -type f -exec jq -r '.file_checksums | length' {} \;)
  [ "$step8_checksums" = "2" ]
}

# ---------- VCP-CPT-11 AC6: schema consistency across all 8 skills ----------

@test "VCP-CPT-11 AC6: checkpoints from all 8 skills share identical schema shape" {
  # Run one step of each of the 8 skills, then assert every emitted JSON
  # has the same top-level keys in the same order.
  local artifact="$TEST_TMP/out.md"
  printf '# x\n' > "$artifact"

  "$SCRIPT" gaia-test-design    1 story_key=E1-S1 test_plan_path=a --paths "$artifact"
  "$SCRIPT" gaia-edit-test-plan 1 test_plan_path=a edit_mode=add   --paths "$artifact"
  "$SCRIPT" gaia-test-framework 1 detected_stack=ts framework_config_path=a --paths "$artifact"
  "$SCRIPT" gaia-atdd           1 story_key=E1-S1 test_file_path=a  --paths "$artifact"
  "$SCRIPT" gaia-trace          1 trace_matrix_path=a coverage_metrics=full --paths "$artifact"
  "$SCRIPT" gaia-ci-setup       1 ci_provider=gh ci_config_path=a   --paths "$artifact"
  "$SCRIPT" gaia-review-a11y    1 a11y_scope=component report_path=a --paths "$artifact"
  "$SCRIPT" gaia-val-validate   1 artifact_path=a iteration_number=1 --paths "$artifact"

  # Each skill's checkpoint JSON must have the same top-level key set.
  local expected="schema_version step_number skill_name timestamp key_variables output_paths file_checksums"
  local slug
  for slug in gaia-test-design gaia-edit-test-plan gaia-test-framework gaia-atdd \
              gaia-trace gaia-ci-setup gaia-review-a11y gaia-val-validate; do
    local f
    f=$(find "$CHECKPOINT_ROOT/$slug" -name '*-step-1.json' -type f | head -1)
    [ -n "$f" ] || { echo "$slug: no checkpoint JSON found"; return 1; }
    local keys
    keys=$(jq -r 'keys_unsorted | join(" ")' "$f")
    [ "$keys" = "$expected" ] || {
      echo "$slug: expected keys '$expected', got '$keys'"
      return 1
    }
    # Every file_checksums value matches the sha256:<hex> pattern (AC3).
    local bad
    bad=$(jq -r '[.file_checksums[] | select(test("^sha256:[0-9a-f]{64}$") | not)] | length' "$f")
    [ "$bad" = "0" ] || {
      echo "$slug: bad checksum values: $bad"
      return 1
    }
    # schema_version must be 1.
    local ver
    ver=$(jq -r '.schema_version' "$f")
    [ "$ver" = "1" ] || { echo "$slug: schema_version=$ver (expected 1)"; return 1; }
    # skill_name must equal the slug (AC4).
    local got_slug
    got_slug=$(jq -r '.skill_name' "$f")
    [ "$got_slug" = "$slug" ] || { echo "$slug: skill_name in JSON is '$got_slug'"; return 1; }
  done
}

# ---------- AC-EC7: missing helper trips a loud error ----------

@test "AC-EC7: invoking a renamed helper fails loudly (missing write-checkpoint.sh path)" {
  run -127 bash -c '/nonexistent/scripts/write-checkpoint.sh gaia-val-validate 1 x=y 2>&1'
  [ "$status" -ne 0 ]
}

# ---------- AC-EC1 + AC-EC5: empty --paths and metacharacter preservation ----------

@test "AC-EC1 + AC-EC5: empty --paths writes valid checkpoint; metacharacters preserved verbatim" {
  # AC-EC1: zero-output step.
  "$SCRIPT" gaia-val-validate 2 artifact_path=prd.md iteration_number=1
  local f
  f=$(find "$CHECKPOINT_ROOT/gaia-val-validate" -name '*-step-2.json' -type f | head -1)
  [ -n "$f" ]
  [ "$(jq -r '.output_paths | length' "$f")" = "0" ]
  [ "$(jq -r '.file_checksums | length' "$f")" = "0" ]
  # AC-EC5: shell metacharacter preservation.
  "$SCRIPT" gaia-review-a11y 1 a11y_scope='prod;rm -rf /' report_path='$(whoami)'
  f=$(find "$CHECKPOINT_ROOT/gaia-review-a11y" -name '*-step-1.json' -type f | head -1)
  [ -n "$f" ]
  [ "$(jq -r '.key_variables.a11y_scope' "$f")" = 'prod;rm -rf /' ]
  [ "$(jq -r '.key_variables.report_path' "$f")" = '$(whoami)' ]
}

# ---------- AC-EC3/AC-EC4/AC-EC9: per-skill directory isolation (concurrent + nested) ----------

@test "AC-EC3/AC-EC4/AC-EC9: Phase 3 testing skills write checkpoints to distinct per-skill dirs (concurrent + nested)" {
  local art="$TEST_TMP/art.md"
  printf 'x\n' > "$art"
  # Concurrent writes (AC-EC4) + two-skill isolation (AC-EC3).
  "$SCRIPT" gaia-test-design  3 story_key=E1-S1 test_plan_path=a --paths "$art" &
  "$SCRIPT" gaia-val-validate 3 artifact_path=a iteration_number=1 --paths "$art" &
  wait
  # Nested caller-subflow isolation (AC-EC9) — each skill passes its own slug.
  "$SCRIPT" gaia-atdd         3 story_key=E1-S1 test_file_path=a --paths "$art"
  "$SCRIPT" gaia-val-validate 4 artifact_path=a iteration_number=2 --paths "$art"
  [ -d "$CHECKPOINT_ROOT/gaia-test-design" ]
  [ -d "$CHECKPOINT_ROOT/gaia-val-validate" ]
  [ -d "$CHECKPOINT_ROOT/gaia-atdd" ]
  local c1 c2 c3
  c1=$(find "$CHECKPOINT_ROOT/gaia-test-design" -name '*.json' | wc -l | tr -d ' ')
  c2=$(find "$CHECKPOINT_ROOT/gaia-val-validate" -name '*.json' | wc -l | tr -d ' ')
  c3=$(find "$CHECKPOINT_ROOT/gaia-atdd" -name '*.json' | wc -l | tr -d ' ')
  [ "$c1" = "1" ]
  [ "$c2" = "2" ]
  [ "$c3" = "1" ]
  # No cross-namespace leakage.
  local cross
  cross=$(find "$CHECKPOINT_ROOT/gaia-atdd" -name '*-step-4.json' | wc -l | tr -d ' ')
  [ "$cross" = "0" ]
  cross=$(find "$CHECKPOINT_ROOT/gaia-test-design" -name '*-step-4.json' | wc -l | tr -d ' ')
  [ "$cross" = "0" ]
}
