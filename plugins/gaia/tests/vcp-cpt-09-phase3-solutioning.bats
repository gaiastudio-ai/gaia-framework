#!/usr/bin/env bats
# vcp-cpt-09-phase3-solutioning.bats — shared-helper exclusivity and wire-in
# assertions for Phase 3 solutioning skills (E43-S4).
#
# NFR-VCP-1 mandate: every checkpoint write MUST route through
# scripts/write-checkpoint.sh. This test extends VCP-CPT-09 coverage from
# Phase 1 (E43-S2) and Phase 2 (E43-S3) to the 8 Phase 3 solutioning
# skills. It also carries the VCP-CPT-11 cross-skill schema-consistency
# assertions: running one step of each of the 8 skills against a fixture,
# then validating the emitted checkpoint JSON against schema v1.
#
# Phase 3 solutioning skills and step counts (post E44-S5 wire-in):
#   gaia-create-arch        13 steps  (was 12; +1 Val Auto-Fix Loop step at 10)
#   gaia-edit-arch           9 steps  (was 7;  +1 Val Auto-Fix Loop at 7; +1 Re-shard at 9 from E53-S244)
#   gaia-review-api          6 steps  (was 5;  +1 Val Auto-Fix Loop step at 6)
#   gaia-adversarial         4 steps
#   gaia-create-epics       12 steps  (was 11; +1 Val Auto-Fix Loop step at 9)
#   gaia-threat-model        8 steps  (was 7;  +1 Val Auto-Fix Loop step at 8)
#   gaia-infra-design        7 steps  (was 6;  +1 Val Auto-Fix Loop step at 7)
#   gaia-readiness-check    13 steps  (was 12; +1 Val Auto-Fix Loop step at 11 per E44-S6)
#                      ---------- total: 71 invocations
#
# Refs: docs/implementation-artifacts/E43-S4-*.md,
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

# Canonical Phase 3 solutioning slugs and step counts (story E43-S4).
# Keep in sync with the SKILL.md files; mismatch = wire-in drift.
PHASE3_SOL_SLUGS=(
  gaia-create-arch
  gaia-edit-arch
  gaia-review-api
  gaia-adversarial
  gaia-create-epics
  gaia-threat-model
  gaia-infra-design
  gaia-readiness-check
)
PHASE3_SOL_STEPS=(13 9 6 4 12 8 7 13)

# ---------- AC1/AC2/AC4: canonical invocation line present per step ----------

@test "AC1/AC2/AC4: each Phase 3 solutioning SKILL.md has one canonical invocation per declared step" {
  local i=0
  for slug in "${PHASE3_SOL_SLUGS[@]}"; do
    local expected="${PHASE3_SOL_STEPS[$i]}"
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || { echo "missing SKILL.md: $file"; return 1; }

    # Count `### Step N —` headings.
    local step_headings
    step_headings=$(grep -cE '^### Step [0-9]+ —' "$file" || true)
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

@test "AC5: each Phase 3 solutioning SKILL.md declares required per-skill key_variables" {
  # Minimum one skill-specific key_variable per SKILL.md. The story requires
  # non-empty subset of skill-own context (project_name plus at least one
  # skill-local state variable).
  local spec
  for spec in \
    "gaia-create-arch|project_name arch_version" \
    "gaia-edit-arch|project_name edit_scope" \
    "gaia-review-api|api_spec_path review_scope" \
    "gaia-adversarial|target_artifact_path adversarial_angle" \
    "gaia-create-epics|prd_version epic_count" \
    "gaia-threat-model|threat_model_scope stride_stage" \
    "gaia-infra-design|target_environments iac_stack" \
    "gaia-readiness-check|gate_status artifacts_inspected_count"; do
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

# ---------- AC2 (VCP-CPT-09): no inline checkpoint writes in Phase 3 solutioning SKILL.md ----------

@test "AC2: no Phase 3 solutioning SKILL.md contains inline _memory/checkpoints writes" {
  local offenders=""
  for slug in "${PHASE3_SOL_SLUGS[@]}"; do
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

# ---------- AC2: no inline writes in Phase 3 solutioning co-located scripts ----------

@test "AC2: Phase 3 solutioning co-located scripts do not write to _memory/checkpoints" {
  local offenders=""
  for slug in "${PHASE3_SOL_SLUGS[@]}"; do
    local scripts_dir="$SKILLS_DIR/$slug/scripts"
    [ -d "$scripts_dir" ] || continue
    local hit
    hit=$(grep -rnE '(printf|echo|cat|tee)[^|]*>[^|]*_memory/checkpoints/[^ ]*\.json' "$scripts_dir" 2>/dev/null || true)
    if [ -n "$hit" ]; then
      offenders+="$scripts_dir: $hit"$'\n'
    fi
  done
  if [ -n "$offenders" ]; then
    echo "inline checkpoint writes detected in Phase 3 solutioning co-located scripts:"
    echo "$offenders"
    return 1
  fi
}

# ---------- AC2: canonical helper line is the only checkpoint writer ----------

@test "AC2: every checkpoint-related line in Phase 3 solutioning SKILL.md routes through write-checkpoint.sh" {
  for slug in "${PHASE3_SOL_SLUGS[@]}"; do
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
  for slug in "${PHASE3_SOL_SLUGS[@]}"; do
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

@test "VCP-CPT-11 AC1/AC6: simulating gaia-create-arch 13-step run writes 13 sequential checkpoints" {
  local slug="gaia-create-arch"
  local artifact="$TEST_TMP/architecture.md"
  printf '# arch\n' > "$artifact"
  local n
  for n in $(seq 1 13); do
    if [ "$n" = "9" ] || [ "$n" = "10" ] || [ "$n" = "13" ]; then
      "$SCRIPT" "$slug" "$n" project_name=acme arch_version=1.0.0 --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" project_name=acme arch_version=1.0.0
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "13" ]
  local numbers
  numbers=$(find "$dir" -name '*.json' -type f -exec jq -r '.step_number' {} \; | sort -n | tr '\n' ' ')
  [ "$numbers" = "1 2 3 4 5 6 7 8 9 10 11 12 13 " ]
}

@test "VCP-CPT-11 AC1/AC6: simulating gaia-edit-arch 9-step run writes 9 sequential checkpoints" {
  local slug="gaia-edit-arch"
  local artifact="$TEST_TMP/architecture.md"
  printf '# arch\n' > "$artifact"
  local n
  for n in $(seq 1 9); do
    if [ "$n" = "6" ] || [ "$n" = "7" ]; then
      "$SCRIPT" "$slug" "$n" project_name=acme edit_scope=section --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" project_name=acme edit_scope=section
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "9" ]
}

@test "VCP-CPT-11 AC1/AC6: simulating gaia-review-api 6-step run writes 6 sequential checkpoints" {
  local slug="gaia-review-api"
  local artifact="$TEST_TMP/api-review.md"
  printf '# api\n' > "$artifact"
  local n
  for n in $(seq 1 6); do
    if [ "$n" = "5" ] || [ "$n" = "6" ]; then
      "$SCRIPT" "$slug" "$n" api_spec_path=openapi.yaml review_scope=full --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" api_spec_path=openapi.yaml review_scope=full
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "6" ]
}

@test "VCP-CPT-11 AC1/AC6: simulating gaia-adversarial 4-step run writes 4 sequential checkpoints" {
  local slug="gaia-adversarial"
  local artifact="$TEST_TMP/adversarial.md"
  printf '# adv\n' > "$artifact"
  local n
  for n in $(seq 1 4); do
    if [ "$n" = "3" ]; then
      "$SCRIPT" "$slug" "$n" target_artifact_path=prd.md adversarial_angle=feasibility --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" target_artifact_path=prd.md adversarial_angle=feasibility
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "4" ]
}

@test "VCP-CPT-11 AC1/AC6/AC-EC8: simulating gaia-create-epics 12-step run writes 12 sequential checkpoints with multi-file step" {
  local slug="gaia-create-epics"
  local epics="$TEST_TMP/epics-and-stories.md"
  local arch="$TEST_TMP/architecture.md"
  printf '# epics\n' > "$epics"
  printf '# arch\n' > "$arch"
  local n
  for n in $(seq 1 12); do
    if [ "$n" = "8" ]; then
      # Multi-file step (AC-EC8 coverage).
      "$SCRIPT" "$slug" "$n" prd_version=1.0 epic_count=4 --paths "$epics" "$arch"
    elif [ "$n" = "9" ]; then
      # New Val auto-review step (single-file --paths).
      "$SCRIPT" "$slug" "$n" prd_version=1.0 epic_count=4 --paths "$epics"
    else
      "$SCRIPT" "$slug" "$n" prd_version=1.0 epic_count=4
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "12" ]
  # Step 8 must record both output paths.
  local step8_paths
  step8_paths=$(find "$dir" -name '*-step-8.json' -type f -exec jq -r '.output_paths | length' {} \;)
  [ "$step8_paths" = "2" ]
  local step8_checksums
  step8_checksums=$(find "$dir" -name '*-step-8.json' -type f -exec jq -r '.file_checksums | length' {} \;)
  [ "$step8_checksums" = "2" ]
}

@test "VCP-CPT-11 AC1/AC6: simulating gaia-threat-model 8-step run writes 8 sequential checkpoints" {
  local slug="gaia-threat-model"
  local artifact="$TEST_TMP/threat-model.md"
  printf '# tm\n' > "$artifact"
  local n
  for n in $(seq 1 8); do
    if [ "$n" = "7" ] || [ "$n" = "8" ]; then
      "$SCRIPT" "$slug" "$n" threat_model_scope=full stride_stage=elevation --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" threat_model_scope=full stride_stage=elevation
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "8" ]
}

@test "VCP-CPT-11 AC1/AC6: simulating gaia-infra-design 7-step run writes 7 sequential checkpoints" {
  local slug="gaia-infra-design"
  local artifact="$TEST_TMP/infra.md"
  printf '# infra\n' > "$artifact"
  local n
  for n in $(seq 1 7); do
    if [ "$n" = "6" ] || [ "$n" = "7" ]; then
      "$SCRIPT" "$slug" "$n" target_environments=staging,prod iac_stack=terraform --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" target_environments=staging,prod iac_stack=terraform
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "7" ]
}

@test "VCP-CPT-11 AC1/AC6: simulating gaia-readiness-check 13-step run writes 13 sequential checkpoints" {
  local slug="gaia-readiness-check"
  local artifact="$TEST_TMP/readiness.md"
  printf '# r\n' > "$artifact"
  local n
  for n in $(seq 1 13); do
    if [ "$n" = "10" ] || [ "$n" = "11" ] || [ "$n" = "13" ]; then
      "$SCRIPT" "$slug" "$n" gate_status=pass artifacts_inspected_count=7 --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" gate_status=pass artifacts_inspected_count=7
    fi
    sleep 0.002
  done
  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "13" ]
}

# ---------- VCP-CPT-11 AC6: schema consistency across all 8 skills ----------

@test "VCP-CPT-11 AC6: checkpoints from all 8 skills share identical schema shape" {
  # Run one step of each of the 8 skills, then assert every emitted JSON
  # has the same top-level keys in the same order.
  local artifact="$TEST_TMP/out.md"
  printf '# x\n' > "$artifact"

  "$SCRIPT" gaia-create-arch     1 project_name=a arch_version=1.0 --paths "$artifact"
  "$SCRIPT" gaia-edit-arch       1 project_name=a edit_scope=s     --paths "$artifact"
  "$SCRIPT" gaia-review-api      1 api_spec_path=a review_scope=s  --paths "$artifact"
  "$SCRIPT" gaia-adversarial     1 target_artifact_path=a adversarial_angle=s --paths "$artifact"
  "$SCRIPT" gaia-create-epics    1 prd_version=1 epic_count=1      --paths "$artifact"
  "$SCRIPT" gaia-threat-model    1 threat_model_scope=a stride_stage=s        --paths "$artifact"
  "$SCRIPT" gaia-infra-design    1 target_environments=a iac_stack=s          --paths "$artifact"
  "$SCRIPT" gaia-readiness-check 1 gate_status=pass artifacts_inspected_count=1 --paths "$artifact"

  # Each skill's checkpoint JSON must have the same top-level key set.
  local expected="schema_version step_number skill_name timestamp key_variables output_paths file_checksums"
  local slug
  for slug in gaia-create-arch gaia-edit-arch gaia-review-api gaia-adversarial \
              gaia-create-epics gaia-threat-model gaia-infra-design gaia-readiness-check; do
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
  # Simulate the helper being absent by pointing at a non-existent path.
  # The SKILL.md uses the literal `scripts/write-checkpoint.sh`; if the
  # helper is removed from the installed framework, the step fails.
  run -127 bash -c '/nonexistent/scripts/write-checkpoint.sh gaia-adversarial 1 x=y 2>&1'
  [ "$status" -ne 0 ]
}

# ---------- AC-EC1: step with empty --paths still writes a valid checkpoint ----------

@test "AC-EC1: Phase 3 solutioning step with zero output paths still writes a valid checkpoint" {
  local slug="gaia-adversarial"
  "$SCRIPT" "$slug" 2 target_artifact_path=prd.md adversarial_angle=feasibility
  local f
  f=$(find "$CHECKPOINT_ROOT/$slug" -name '*-step-2.json' -type f | head -1)
  [ -n "$f" ]
  [ "$(jq -r '.output_paths | length' "$f")" = "0" ]
  [ "$(jq -r '.file_checksums | length' "$f")" = "0" ]
}

# ---------- AC-EC6: metacharacters in key_variable value preserved verbatim ----------

@test "AC-EC6: metacharacters in key_variable are preserved without command injection" {
  local slug="gaia-infra-design"
  "$SCRIPT" "$slug" 1 target_environments='prod;rm -rf /' iac_stack='$(whoami)'
  local f
  f=$(find "$CHECKPOINT_ROOT/$slug" -name '*-step-1.json' -type f | head -1)
  [ -n "$f" ]
  # Values must round-trip through jq and equal the literal strings.
  local v1 v2
  v1=$(jq -r '.key_variables.target_environments' "$f")
  v2=$(jq -r '.key_variables.iac_stack' "$f")
  [ "$v1" = 'prod;rm -rf /' ]
  [ "$v2" = '$(whoami)' ]
}

# ---------- AC-EC4: two skills running concurrently write to distinct dirs ----------

@test "AC-EC4: two Phase 3 solutioning skills write checkpoints to distinct per-skill dirs" {
  local art="$TEST_TMP/art.md"
  printf 'x\n' > "$art"
  "$SCRIPT" gaia-create-arch  3 project_name=a arch_version=1.0 --paths "$art" &
  "$SCRIPT" gaia-infra-design 3 target_environments=a iac_stack=b --paths "$art" &
  wait
  [ -d "$CHECKPOINT_ROOT/gaia-create-arch" ]
  [ -d "$CHECKPOINT_ROOT/gaia-infra-design" ]
  local c1 c2
  c1=$(find "$CHECKPOINT_ROOT/gaia-create-arch"  -name '*.json' | wc -l | tr -d ' ')
  c2=$(find "$CHECKPOINT_ROOT/gaia-infra-design" -name '*.json' | wc -l | tr -d ' ')
  [ "$c1" = "1" ]
  [ "$c2" = "1" ]
}
