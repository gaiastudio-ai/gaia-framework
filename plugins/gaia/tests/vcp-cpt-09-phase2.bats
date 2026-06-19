#!/usr/bin/env bats
# vcp-cpt-09-phase2.bats — shared-helper exclusivity and wire-in assertions
# for Phase 2 planning skills (E43-S3).
#
# NFR-VCP-1 mandate: every checkpoint write MUST route through
# scripts/write-checkpoint.sh. This test extends VCP-CPT-09 coverage from
# Phase 1 (E43-S2) to the 2 Phase 2 planning skills: gaia-create-prd
# (13 steps) and gaia-create-ux (11 steps).
#
# This file also carries the VCP-CPT-02 wire-in sequence assertions for
# Phase 2 (AC1, AC2, AC4, AC6 of E43-S3):
#   - each `### Step N —` heading has exactly one canonical
#     `!scripts/write-checkpoint.sh` invocation line
#   - step_number 1..N is present exactly once per skill
#   - per-skill key_variables are declared on at least one invocation line
#
# Refs: docs/implementation-artifacts/E43-S3-*.md,
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

# Canonical Phase 2 skill slugs and step counts (story E43-S3).
# Keep in sync with the SKILL.md files; mismatch = wire-in drift.
PHASE2_SLUGS=(
  gaia-create-prd
  gaia-create-ux
)
PHASE2_STEPS=(14 12)

# ---------- AC1/AC2/AC3: canonical invocation line present per step ----------

@test "each Phase 2 SKILL.md has one canonical invocation per declared step" {
  local i=0
  for slug in "${PHASE2_SLUGS[@]}"; do
    local expected="${PHASE2_STEPS[$i]}"
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

# ---------- AC4: per-skill key_variables surface ----------

@test "each Phase 2 SKILL.md declares required per-skill key_variables" {
  # Per the story spec AC4:
  #   gaia-create-prd: project_name, prd_version, feature_slug
  #   gaia-create-ux:  project_name, ux_slug, prd_path
  local spec
  for spec in \
    "gaia-create-prd|project_name prd_version feature_slug" \
    "gaia-create-ux|project_name ux_slug prd_path"; do
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

# ---------- AC3/AC6 (VCP-CPT-09): no inline checkpoint writes in Phase 2 SKILL.md ----------

@test "no Phase 2 SKILL.md contains inline _memory/checkpoints writes" {
  local offenders=""
  for slug in "${PHASE2_SLUGS[@]}"; do
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

# ---------- AC3/AC6: no inline writes in Phase 2 co-located scripts ----------

@test "Phase 2 co-located scripts do not write to _memory/checkpoints" {
  local offenders=""
  for slug in "${PHASE2_SLUGS[@]}"; do
    local scripts_dir="$SKILLS_DIR/$slug/scripts"
    [ -d "$scripts_dir" ] || continue
    # Scan every file under scripts/ for checkpoint-directed writes that
    # bypass the shared helper. We allow references to the shared
    # scripts/checkpoint.sh (the V1 YAML writer) and to write-checkpoint.sh
    # itself — only inline JSON emission targeting _memory/checkpoints is
    # a violation.
    local hit
    hit=$(grep -rnE '(printf|echo|cat|tee)[^|]*>[^|]*_memory/checkpoints/[^ ]*\.json' "$scripts_dir" 2>/dev/null || true)
    if [ -n "$hit" ]; then
      offenders+="$scripts_dir: $hit"$'\n'
    fi
  done
  if [ -n "$offenders" ]; then
    echo "inline checkpoint writes detected in Phase 2 co-located scripts:"
    echo "$offenders"
    return 1
  fi
}

# ---------- AC3/AC6: canonical helper line is the only checkpoint writer ----------

@test "every checkpoint-related line in Phase 2 SKILL.md routes through write-checkpoint.sh" {
  for slug in "${PHASE2_SLUGS[@]}"; do
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

# ---------- AC1/AC5 (VCP-CPT-02 Phase 2): end-to-end checkpoint sequence ----------

@test "simulating gaia-create-prd 14-step run writes 14 sequential checkpoints" {
  local slug="gaia-create-prd"
  local artifact="$TEST_TMP/prd.md"
  printf '# prd\n' > "$artifact"

  local n
  for n in $(seq 1 14); do
    # Steps 11 (Generate Output), 12 (Val Auto-Fix Loop), and 14
    # (Incorporate Adversarial Findings) emit --paths to the prd artifact.
    if [ "$n" = "11" ] || [ "$n" = "12" ] || [ "$n" = "14" ]; then
      "$SCRIPT" "$slug" "$n" project_name=acme prd_version=1.0.0 feature_slug=checkpoint --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" project_name=acme prd_version=1.0.0 feature_slug=checkpoint
    fi
    sleep 0.002
  done

  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]

  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "14" ]

  local numbers
  numbers=$(find "$dir" -name '*.json' -type f -exec jq -r '.step_number' {} \; | sort -n | tr '\n' ' ')
  [ "$numbers" = "1 2 3 4 5 6 7 8 9 10 11 12 13 14 " ]
}

@test "simulating gaia-create-ux 12-step run writes 12 sequential checkpoints" {
  local slug="gaia-create-ux"
  local artifact="$TEST_TMP/ux.md"
  printf '# ux\n' > "$artifact"

  local n
  for n in $(seq 1 12); do
    # Steps 10 (Generate Output) and 11 (Val Auto-Fix Loop) emit --paths.
    if [ "$n" = "10" ] || [ "$n" = "11" ]; then
      "$SCRIPT" "$slug" "$n" project_name=acme ux_slug=web prd_path=docs/planning-artifacts/prd.md --paths "$artifact"
    else
      "$SCRIPT" "$slug" "$n" project_name=acme ux_slug=web prd_path=docs/planning-artifacts/prd.md
    fi
    sleep 0.002
  done

  local dir="$CHECKPOINT_ROOT/$slug"
  [ -d "$dir" ]

  local count
  count=$(find "$dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$count" = "12" ]

  local numbers
  numbers=$(find "$dir" -name '*.json' -type f -exec jq -r '.step_number' {} \; | sort -n | tr '\n' ' ')
  [ "$numbers" = "1 2 3 4 5 6 7 8 9 10 11 12 " ]
}
