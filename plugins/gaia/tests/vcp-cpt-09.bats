#!/usr/bin/env bats
# vcp-cpt-09.bats — shared-helper exclusivity for Phase 1 skills (E43-S2).
#
# NFR-VCP-1 mandate: every checkpoint write MUST route through
# scripts/write-checkpoint.sh. No SKILL.md and no co-located script under
# the 6 Phase 1 skill directories may write JSON directly into
# _memory/checkpoints/ via printf/echo/cat/tee/redirect.
#
# VCP-CPT-09 is the regression guard that enforces NFR-VCP-1 on a per-PR
# basis — any future change that re-introduces inline checkpoint-writing
# logic trips the assertions below.
#
# Refs: docs/implementation-artifacts/E43-S2-*.md,
#       docs/test-artifacts/test-plan.md §11.46.2,
#       docs/planning-artifacts/architecture.md §10.31.3 (ADR-059).

load 'test_helper.bash'

setup() {
  common_setup
  SKILLS_DIR="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
}
teardown() { common_teardown; }

PHASE1_SLUGS=(
  gaia-brainstorm
  gaia-market-research
  gaia-domain-research
  gaia-tech-research
  gaia-advanced-elicitation
  gaia-product-brief
)

# ---------- AC7/AC-EC2: no inline checkpoint writes in SKILL.md ----------

@test "no Phase 1 SKILL.md contains inline _memory/checkpoints writes" {
  # Three signatures the grep must never match:
  #   printf ... > _memory/checkpoints...
  #   cat ... > _memory/checkpoints/...
  #   echo ... > _memory/checkpoints/...
  # We allow references inside prose (e.g., a narrative description) by
  # requiring the pattern to include a redirect-into-checkpoints phrase.
  local offenders=""
  for slug in "${PHASE1_SLUGS[@]}"; do
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || continue
    # Match any `> _memory/checkpoints` redirect. Real shell redirects
    # (in a bash block) would hit this; markdown blockquote lines like
    # `> \`!(\$\{CLAUDE_PLUGIN_ROOT\}/)?scripts/write-checkpoint.sh ...\`` would not because the > is
    # followed by a space and a backtick, not a path.
    local hit
    hit=$(grep -nE '>\s*_memory/checkpoints' "$file" || true)
    if [ -n "$hit" ]; then
      offenders+="$file: $hit"$'\n'
    fi
    # Catch `printf ... > "${CHECKPOINT_ROOT:-_memory/checkpoints}/..."`.
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

# ---------- AC7: no inline writes in co-located skill scripts ----------

@test "Phase 1 co-located scripts do not write to _memory/checkpoints" {
  local offenders=""
  for slug in "${PHASE1_SLUGS[@]}"; do
    local scripts_dir="$SKILLS_DIR/$slug/scripts"
    [ -d "$scripts_dir" ] || continue
    # Scan every file under scripts/ for checkpoint-directed writes.
    local hit
    hit=$(grep -rnE '(printf|echo|cat|tee|>)[^|]*_memory/checkpoints/[^ ]*\.json' "$scripts_dir" 2>/dev/null || true)
    if [ -n "$hit" ]; then
      offenders+="$scripts_dir: $hit"$'\n'
    fi
    # Also flag direct write-checkpoint.sh replicas: a co-located helper
    # that imitates the shared writer is a NFR-VCP-1 violation.
    hit=$(grep -rln 'schema_version' "$scripts_dir" 2>/dev/null || true)
    if [ -n "$hit" ]; then
      offenders+="$scripts_dir (schema_version echo): $hit"$'\n'
    fi
  done
  if [ -n "$offenders" ]; then
    echo "inline checkpoint writes detected in co-located scripts:"
    echo "$offenders"
    return 1
  fi
}

# ---------- AC7: canonical helper line is the ONLY checkpoint writer ----------

@test "every checkpoint-related line in Phase 1 SKILL.md routes through write-checkpoint.sh" {
  # For each SKILL.md: any line mentioning _memory/checkpoints or
  # `step-` JSON filenames must be either (a) a blockquote that invokes
  # write-checkpoint.sh, or (b) a narrative reference in Dev/Critical
  # Rules prose that does NOT include a shell redirect.
  for slug in "${PHASE1_SLUGS[@]}"; do
    local file="$SKILLS_DIR/$slug/SKILL.md"
    [ -f "$file" ] || continue
    # The only acceptable checkpoints-writing construct: the canonical line.
    local any_writer
    any_writer=$(grep -nE '_memory/checkpoints.*(>|<<)' "$file" || true)
    [ -z "$any_writer" ] || {
      echo "$slug: non-canonical checkpoint write detected: $any_writer"
      return 1
    }
  done
}
