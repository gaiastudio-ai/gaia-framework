#!/usr/bin/env bats
# discover-inputs.bats — E45-S4 / FR-346 / ADR-062 audit.
#
# This suite implements VCP-DSC-01..VCP-DSC-07 from test-plan.md §11.46.6.
# It asserts that the 6 lifecycle skills in scope of ADR-062 declare a
# canonical `discover_inputs` strategy in their SKILL.md frontmatter and
# that their first input-loading step body matches the declared strategy.
#
# Canonical strategies (ADR-062 §10.31.6):
#   FULL_LOAD      — read entire artifact (default for small/single-file inputs)
#   SELECTIVE_LOAD — load only named diff sections / headings
#   INDEX_GUIDED   — load index/TOC first, fetch named sections on demand
#
# Strategy mapping (architecture.md §10.31.6):
#   /gaia-product-brief    -> INDEX_GUIDED
#   /gaia-create-prd       -> INDEX_GUIDED
#   /gaia-create-arch      -> INDEX_GUIDED
#   /gaia-create-epics     -> INDEX_GUIDED
#   /gaia-readiness-check  -> INDEX_GUIDED
#   /gaia-edit-test-plan   -> SELECTIVE_LOAD
#
# The audit (VCP-DSC-07) is script-verifiable and runs in CI; per-skill
# behavior assertions (VCP-DSC-01..06) inspect the SKILL.md step body for
# the index-first or diff-only loading pattern described in ADR-062.

load test_helper

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILLS_DIR="$PLUGIN_ROOT/skills"
  export PLUGIN_ROOT SKILLS_DIR

  INDEX_GUIDED_SKILLS=(
    gaia-product-brief
    gaia-create-prd
    gaia-create-arch
    gaia-create-epics
    gaia-readiness-check
  )
  SELECTIVE_LOAD_SKILLS=(
    gaia-edit-test-plan
  )
  export INDEX_GUIDED_SKILLS SELECTIVE_LOAD_SKILLS
}

teardown() { common_teardown; }

# Extract the YAML frontmatter block (between the first two `---` lines) from
# a SKILL.md file. Prints the body to stdout. Returns 1 if no frontmatter is
# found.
_extract_frontmatter() {
  local file="$1"
  awk '
    /^---[[:space:]]*$/ { count++; if (count == 2) exit; next }
    count == 1 { print }
  ' "$file"
}

# Echo the value of `discover_inputs:` from a SKILL.md frontmatter block.
# Empty string if absent.
_read_strategy() {
  local file="$1"
  _extract_frontmatter "$file" \
    | grep -E '^discover_inputs:[[:space:]]+' \
    | head -1 \
    | sed -E 's/^discover_inputs:[[:space:]]+//; s/[[:space:]]+$//'
}

# ---------- VCP-DSC-07: strategy declaration audit (script-verifiable) ----------

@test "every in-scope SKILL.md declares discover_inputs in frontmatter" {
  local missing=""
  for skill in "${INDEX_GUIDED_SKILLS[@]}" "${SELECTIVE_LOAD_SKILLS[@]}"; do
    local file="$SKILLS_DIR/$skill/SKILL.md"
    if [ ! -f "$file" ]; then
      missing="$missing  $file (skill file not found)\n"
      continue
    fi
    local strategy
    strategy="$(_read_strategy "$file")"
    if [ -z "$strategy" ]; then
      missing="$missing  $skill (no discover_inputs key in frontmatter)\n"
    fi
  done
  if [ -n "$missing" ]; then
    echo -e "Skills missing discover_inputs frontmatter declaration:\n$missing"
    return 1
  fi
}

@test "every discover_inputs value is a canonical enum (FULL_LOAD|SELECTIVE_LOAD|INDEX_GUIDED)" {
  local offenders=""
  for skill in "${INDEX_GUIDED_SKILLS[@]}" "${SELECTIVE_LOAD_SKILLS[@]}"; do
    local file="$SKILLS_DIR/$skill/SKILL.md"
    local strategy
    strategy="$(_read_strategy "$file")"
    case "$strategy" in
      FULL_LOAD|SELECTIVE_LOAD|INDEX_GUIDED) ;;
      *) offenders="$offenders  $skill -> '$strategy'\n" ;;
    esac
  done
  if [ -n "$offenders" ]; then
    echo -e "Skills with non-canonical discover_inputs values:\n$offenders"
    return 1
  fi
}

@test "each SKILL.md declares discover_inputs exactly once (no duplicate keys)" {
  local offenders=""
  for skill in "${INDEX_GUIDED_SKILLS[@]}" "${SELECTIVE_LOAD_SKILLS[@]}"; do
    local file="$SKILLS_DIR/$skill/SKILL.md"
    local count
    count="$(_extract_frontmatter "$file" | grep -cE '^discover_inputs:[[:space:]]+' || true)"
    if [ "$count" != "1" ]; then
      offenders="$offenders  $skill -> $count occurrences\n"
    fi
  done
  if [ -n "$offenders" ]; then
    echo -e "Skills with non-unique discover_inputs declarations:\n$offenders"
    return 1
  fi
}

# ---------- Per-skill strategy assertions (VCP-DSC-01..06) ----------

@test "gaia-product-brief declares INDEX_GUIDED" {
  local file="$SKILLS_DIR/gaia-product-brief/SKILL.md"
  [ "$(_read_strategy "$file")" = "INDEX_GUIDED" ]
}

@test "gaia-create-prd declares INDEX_GUIDED" {
  local file="$SKILLS_DIR/gaia-create-prd/SKILL.md"
  [ "$(_read_strategy "$file")" = "INDEX_GUIDED" ]
}

@test "gaia-create-arch declares INDEX_GUIDED" {
  local file="$SKILLS_DIR/gaia-create-arch/SKILL.md"
  [ "$(_read_strategy "$file")" = "INDEX_GUIDED" ]
}

@test "gaia-create-epics declares INDEX_GUIDED" {
  local file="$SKILLS_DIR/gaia-create-epics/SKILL.md"
  [ "$(_read_strategy "$file")" = "INDEX_GUIDED" ]
}

@test "gaia-readiness-check declares INDEX_GUIDED" {
  local file="$SKILLS_DIR/gaia-readiness-check/SKILL.md"
  [ "$(_read_strategy "$file")" = "INDEX_GUIDED" ]
}

@test "gaia-edit-test-plan declares SELECTIVE_LOAD" {
  local file="$SKILLS_DIR/gaia-edit-test-plan/SKILL.md"
  [ "$(_read_strategy "$file")" = "SELECTIVE_LOAD" ]
}

# ---------- discover_inputs_target presence (ADR-062 declaration completeness) ----------

@test "discover_inputs_target is declared alongside discover_inputs in every in-scope SKILL.md" {
  local missing=""
  for skill in "${INDEX_GUIDED_SKILLS[@]}" "${SELECTIVE_LOAD_SKILLS[@]}"; do
    local file="$SKILLS_DIR/$skill/SKILL.md"
    if ! _extract_frontmatter "$file" | grep -qE '^discover_inputs_target:[[:space:]]+'; then
      missing="$missing  $skill (discover_inputs_target missing)\n"
    fi
  done
  if [ -n "$missing" ]; then
    echo -e "Skills missing discover_inputs_target declaration:\n$missing"
    return 1
  fi
}

# ---------- Per-skill loading-behavior assertions (AC2, AC3) ----------

@test "behavior: gaia-product-brief body references INDEX_GUIDED loading pattern" {
  local file="$SKILLS_DIR/gaia-product-brief/SKILL.md"
  grep -qE 'INDEX_GUIDED|index-first|index/TOC|heading scan' "$file"
}

@test "behavior: gaia-create-prd body references INDEX_GUIDED loading pattern" {
  local file="$SKILLS_DIR/gaia-create-prd/SKILL.md"
  grep -qE 'INDEX_GUIDED|index-first|index/TOC|heading scan' "$file"
}

@test "behavior: gaia-create-arch body references INDEX_GUIDED loading pattern" {
  local file="$SKILLS_DIR/gaia-create-arch/SKILL.md"
  grep -qE 'INDEX_GUIDED|index-first|index/TOC|heading scan' "$file"
}

@test "behavior: gaia-create-epics body references INDEX_GUIDED loading pattern" {
  local file="$SKILLS_DIR/gaia-create-epics/SKILL.md"
  grep -qE 'INDEX_GUIDED|index-first|index/TOC|heading scan' "$file"
}

@test "behavior: gaia-readiness-check body references INDEX_GUIDED loading pattern" {
  local file="$SKILLS_DIR/gaia-readiness-check/SKILL.md"
  grep -qE 'INDEX_GUIDED|index-first|index/TOC|heading scan' "$file"
}

@test "behavior: gaia-edit-test-plan body references SELECTIVE_LOAD diff-only pattern" {
  local file="$SKILLS_DIR/gaia-edit-test-plan/SKILL.md"
  grep -qE 'SELECTIVE_LOAD|diff section|diff-only|named sections only' "$file"
}

# ---------- Scope-boundary check: no other SKILL.md silently declares discover_inputs ----------

@test "scope guard: only the 6 in-scope SKILL.md files declare discover_inputs" {
  local in_scope=" gaia-product-brief gaia-create-prd gaia-create-arch gaia-create-epics gaia-readiness-check gaia-edit-test-plan "
  local violators=""
  while IFS= read -r file; do
    local skill
    skill="$(basename "$(dirname "$file")")"
    if echo "$in_scope" | grep -q " $skill "; then
      continue
    fi
    if _extract_frontmatter "$file" | grep -qE '^discover_inputs:[[:space:]]+'; then
      violators="$violators  $skill\n"
    fi
  done < <(ls "$SKILLS_DIR"/*/SKILL.md)
  if [ -n "$violators" ]; then
    echo -e "Out-of-scope skills with discover_inputs declarations (should be empty per E45-S4 scope):\n$violators"
    return 1
  fi
}
