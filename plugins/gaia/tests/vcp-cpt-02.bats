#!/usr/bin/env bats
# vcp-cpt-02.bats — Phase 1 skill checkpoint wire-in assertions (E43-S2).
#
# Covers VCP-CPT-02: sequential, well-formed checkpoint writes for the 6
# Phase 1 skills. The Phase 1 skills are authored in markdown (SKILL.md),
# so this file cannot run the skills end-to-end under bats — instead it
# verifies the contract at two layers:
#   (1) Every `### Step N —` heading in each of the 6 SKILL.md files has
#       exactly one canonical `!scripts/write-checkpoint.sh` invocation
#       line paired to it (AC1, AC4, AC6).
#   (2) Simulating the sequence of invocations declared in SKILL.md
#       against a real write-checkpoint.sh run (N=1..step_count) lands
#       exactly N checkpoint files with sequential step_number values and
#       filenames matching the {timestamp}-step-{N}.json pattern (AC1,
#       AC2, AC6).
#
# Refs: docs/implementation-artifacts/E43-S2-*.md,
#       docs/test-artifacts/test-plan.md §11.46.2,
#       docs/planning-artifacts/architecture.md §10.31.3 (ADR-059).

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/write-checkpoint.sh"
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export CHECKPOINT_ROOT="$TEST_TMP/_memory/checkpoints"
  mkdir -p "$CHECKPOINT_ROOT"
}
teardown() { common_teardown; }

# Canonical Phase 1 skill slugs and step counts (story E43-S2).
# Keep in sync with the SKILL.md files; mismatch = wire-in drift.
PHASE1_SLUGS=(
  gaia-brainstorm
  gaia-market-research
  gaia-domain-research
  gaia-tech-research
  gaia-advanced-elicitation
  gaia-product-brief
)
PHASE1_STEPS=(6 7 6 6 5 9)

# ---------- AC3/AC7: canonical invocation line present per step ----------

@test "AC3/AC4/AC7: each Phase 1 SKILL.md has one canonical invocation per declared step" {
  local i=0
  for slug in "${PHASE1_SLUGS[@]}"; do
    local expected="${PHASE1_STEPS[$i]}"
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

# ---------- AC1/AC2/AC6: end-to-end checkpoint sequence for brainstorm ----------

@test "AC1/AC6: simulating gaia-brainstorm 5-step run writes 5 sequential checkpoints" {
  local slug="gaia-brainstorm"
  local artifact="$TEST_TMP/brainstorm-acme.md"
  printf '# brainstorm\n' > "$artifact"

  # Simulate the 5 invocation lines the SKILL.md now emits. Each run is
  # separated by a 2ms sleep so the microsecond timestamps in filenames
  # are strictly increasing (AC-EC5 / E43-S1 AC-EC4 guarantee).
  local n
  for n in 1 2 3 4 5; do
    "$SCRIPT" "$slug" "$n" slug=acme technique=divergent --paths "$artifact"
    sleep 0.002
  done

  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]

  # Exactly 5 json files landed.
  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "5" ]

  # step_numbers are 1..5, strictly sequential.
  local numbers
  numbers=$(find "$dir" -name '*.json' -type f -exec jq -r '.step_number' {} \; | sort -n | tr '\n' ' ')
  [ "$numbers" = "1 2 3 4 5 " ]

  # Filenames match {timestamp}-step-{N}.json.
  local f
  for f in "$dir"/*.json; do
    [[ "$(basename "$f")" =~ ^[0-9TZ:.-]+-step-[0-9]+\.json$ ]]
  done

  # Every output_paths entry references a file that exists (AC2).
  for f in "$dir"/*.json; do
    local path
    path=$(jq -r '.output_paths[0]' "$f")
    [ -f "$path" ] || { echo "missing: $path"; return 1; }
    # file_checksums present and matches actual sha256 (AC2).
    local expected
    expected=$(shasum -a 256 "$path" | awk '{print $1}')
    local recorded
    recorded=$(jq -r --arg p "$path" '.file_checksums[$p]' "$f")
    [ "$recorded" = "sha256:$expected" ]
  done
}

# ---------- AC5: per-skill key_variables surface ----------

@test "AC5: each Phase 1 SKILL.md declares the required per-skill key_variables on at least one invocation" {
  # Paired list: slug|space-separated key names. Avoids bash 4 assoc arrays
  # whose declare -A interacts badly with bats' set -u harness.
  local spec
  for spec in \
    "gaia-brainstorm|slug technique" \
    "gaia-market-research|research_topic competitor_set" \
    "gaia-domain-research|domain research_scope" \
    "gaia-tech-research|technology evaluation_criteria" \
    "gaia-advanced-elicitation|elicitation_topic technique" \
    "gaia-product-brief|product_name target_user"; do
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

# ---------- AC-EC1: zero-artifact steps use --paths omission ----------

@test "AC-EC1: skill steps that produce no artifact emit checkpoints without --paths" {
  # At least one Phase 1 skill step (e.g., gaia-market-research Step 2
  # Web Access Check) produces no artifact. Simulate: invocation without
  # --paths must yield output_paths=[] and file_checksums={}.
  "$SCRIPT" gaia-market-research 2 research_topic=fintech competitor_set=list
  local dir="$CHECKPOINT_ROOT/gaia-market-research"
  local json
  json=$(find "$dir" -name '*.json' -type f)
  run jq -r '.output_paths | length' "$json"
  [ "$output" = "0" ]
  run jq -r '.file_checksums | length' "$json"
  [ "$output" = "0" ]
}
