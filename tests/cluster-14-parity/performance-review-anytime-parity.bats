#!/usr/bin/env bats
# performance-review-anytime-parity.bats — E28-S108 parity + structure tests
#
# Validates the conversion of _gaia/lifecycle/workflows/anytime/performance-review/
# to a native SKILL.md at plugins/gaia/skills/gaia-performance-review/SKILL.md.
#
# This skill is the ANYTIME bottleneck analysis — distinct from the
# PR-gate Review Gate skill at plugins/gaia/skills/gaia-review-perf/
# (shipped in E28-S71 / Cluster 9).
#
#   AC1: SKILL.md exists at the native-conversion target path with valid
#        frontmatter (name, description, allowed-tools) and passes the
#        frontmatter linter with zero errors.
#   AC2: Name disambiguation — gaia-performance-review and gaia-review-perf
#        coexist with distinct directories and non-overlapping descriptions.
#   AC3: Legacy 9-step instruction body is preserved as prose sections —
#        story load, status gate, auto-pass classification, N+1/DB analysis,
#        memory/bundle analysis, caching/complexity review, verdict,
#        generate output, update review gate.
#   AC4: Header note explicitly distinguishes this skill from gaia-review-perf.
#   AC5: Auto-pass classification fast path preserved (classify-files.sh).
#   AC6: Percentile-based reporting (P50/P95/P99) mandate preserved.
#   AC7: Machine-readable verdict (PASSED / FAILED) preserved.
#   AC8: Zero orphaned engine-specific XML tags (<action>, <template-output>,
#        <invoke-workflow>, <check>, <ask>, <step>, <workflow>).
#   AC9: No memory-loader.sh invocation — performance review does NOT
#        consult agent memory sidecars.
#
# Refs: E28-S108, FR-323, NFR-048, NFR-053, ADR-041, ADR-042, ADR-048
#
# Usage:
#   bats tests/cluster-14-parity/performance-review-anytime-parity.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"

  SKILL="gaia-performance-review"
  SKILL_DIR="$SKILLS_DIR/$SKILL"
  SKILL_FILE="$SKILL_DIR/SKILL.md"

  SIBLING_SKILL="gaia-review-perf"
  SIBLING_DIR="$SKILLS_DIR/$SIBLING_SKILL"
}

# ---------- AC1: SKILL.md exists and has valid frontmatter ----------

@test "E28-S108: gaia-performance-review SKILL.md exists" {
  [ -f "$SKILL_FILE" ]
}

@test "E28-S108: gaia-performance-review SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review SKILL.md has name: gaia-perf-deepdive (renamed per E69-S1)" {
  head -30 "$SKILL_FILE" | grep -q '^name: gaia-perf-deepdive$'
}

@test "E28-S108: gaia-performance-review SKILL.md has a non-empty description" {
  head -30 "$SKILL_FILE" | grep -qE '^description: .+'
}

@test "E28-S108: gaia-performance-review SKILL.md has allowed-tools Read" {
  head -30 "$SKILL_FILE" | grep -qE '^allowed-tools:.*Read'
}

@test "E28-S108: gaia-performance-review SKILL.md has allowed-tools Bash" {
  head -30 "$SKILL_FILE" | grep -qE '^allowed-tools:.*Bash'
}

@test "E28-S108: gaia-performance-review SKILL.md passes frontmatter linter" {
  cd "$REPO_ROOT" && bash "$REPO_ROOT/.github/scripts/lint-skill-frontmatter.sh"
}

# ---------- AC2: Name disambiguation with gaia-review-perf ----------

@test "E28-S108: gaia-performance-review and gaia-review-perf are distinct directories" {
  [ -d "$SKILL_DIR" ]
  [ -d "$SIBLING_DIR" ]
  [ "$SKILL_DIR" != "$SIBLING_DIR" ]
}

@test "E28-S108: descriptions are distinct between gaia-performance-review and gaia-review-perf" {
  local anytime_desc pr_desc
  anytime_desc=$(head -30 "$SKILL_FILE" | grep -E '^description: ' | head -1)
  pr_desc=$(head -30 "$SIBLING_DIR/SKILL.md" | grep -E '^description: ' | head -1)
  [ "$anytime_desc" != "$pr_desc" ]
}

# ---------- AC3: Legacy 9-step instruction body preserved as prose ----------

@test "E28-S108: gaia-performance-review references Load Story step" {
  grep -qiE 'load story|resolve story file|step 1' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review references Status Gate (review)" {
  grep -qiE 'status gate|review status|must be in .?review' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review references Auto-Pass Classification" {
  grep -qiE 'auto-pass|auto-passed|classification' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review references N+1 or database analysis" {
  grep -qiE 'N\+1|database analysis|unbounded quer' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review references memory or bundle analysis" {
  grep -qiE 'memory leak|bundle size|bundle analysis' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review references caching or complexity review" {
  grep -qiE 'caching|algorithm.*complex|O\(n.\)|O\(n\^2\)' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review references verdict PASSED/FAILED" {
  grep -q 'PASSED' "$SKILL_FILE"
  grep -q 'FAILED' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review writes report to {story_key}-performance-review.md" {
  grep -qE '\{story_key\}-performance-review\.md|story_key.*performance-review' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review updates Review Gate via review-gate.sh" {
  grep -q 'review-gate\.sh' "$SKILL_FILE"
}

# ---------- AC4: Header note distinguishes from gaia-review-perf ----------

@test "E28-S108: gaia-performance-review header note cross-links gaia-review-perf" {
  grep -q 'gaia-review-perf' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review notes anytime bottleneck analysis scope" {
  grep -qiE 'anytime|bottleneck' "$SKILL_FILE"
}

# ---------- AC5: Auto-pass fast path via classify-files.sh ----------

@test "E28-S108: gaia-performance-review classify-files.sh script exists" {
  [ -f "$SKILL_DIR/scripts/classify-files.sh" ]
  [ -x "$SKILL_DIR/scripts/classify-files.sh" ]
}

@test "E28-S108: gaia-performance-review references classify-files.sh" {
  grep -q 'classify-files\.sh' "$SKILL_FILE"
}

@test "E28-S108: classify-files.sh emits PASSED auto when no perf-relevant files" {
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
README.md
config.yaml
package.json.lock
EOF
  run "$SKILL_DIR/scripts/classify-files.sh" --file-list "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASSED"* ]] || [[ "$output" == *"auto"* ]]
  rm -f "$tmp"
}

@test "E28-S108: classify-files.sh does NOT auto-pass when .ts file present" {
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
src/api/users.ts
README.md
EOF
  run "$SKILL_DIR/scripts/classify-files.sh" --file-list "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PASSED (auto)"* ]]
  rm -f "$tmp"
}

# ---------- AC6: Percentile-based reporting preserved ----------

@test "E28-S108: gaia-performance-review cites P50/P95/P99 percentiles" {
  grep -qE 'P50.*P95.*P99|percentile' "$SKILL_FILE"
}

# ---------- AC7: Machine-readable verdict ----------

@test "E28-S108: gaia-performance-review has machine-readable verdict syntax" {
  grep -qE 'Verdict:.*PASSED|Verdict:.*FAILED|verdict.*PASSED|verdict.*FAILED' "$SKILL_FILE"
}

# ---------- AC8: Zero orphaned XML tags ----------

@test "E28-S108: gaia-performance-review has no orphaned <action> tags" {
  ! grep -qE '<action[> ]|</action>' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review has no orphaned <template-output> tags" {
  ! grep -qE '<template-output[> ]|</template-output>' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review has no orphaned <workflow> tags" {
  ! grep -qE '<workflow[> ]|</workflow>' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review has no orphaned <step> tags" {
  ! grep -qE '<step[> ]|</step>' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review has no orphaned <ask> tags" {
  ! grep -qE '<ask[> ]|</ask>' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review has no orphaned <check> tags" {
  ! grep -qE '<check[> ]|</check>' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review has no orphaned <invoke-workflow> tags" {
  ! grep -qE '<invoke-workflow[> ]|</invoke-workflow>' "$SKILL_FILE"
}

# ---------- AC9: Does NOT invoke memory-loader.sh ----------

@test "E28-S108: gaia-performance-review does NOT invoke memory-loader.sh" {
  ! grep -q 'memory-loader\.sh' "$SKILL_FILE"
}

# ---------- Scaffolding (shared pattern) ----------

@test "E28-S108: gaia-performance-review setup.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/setup.sh" ]
  [ -x "$SKILL_DIR/scripts/setup.sh" ]
}

@test "E28-S108: gaia-performance-review finalize.sh exists and is executable" {
  [ -f "$SKILL_DIR/scripts/finalize.sh" ]
  [ -x "$SKILL_DIR/scripts/finalize.sh" ]
}

@test "E28-S108: gaia-performance-review references setup.sh via bang-include" {
  grep -qE '!.*setup\.sh' "$SKILL_FILE"
}

@test "E28-S108: gaia-performance-review references finalize.sh via bang-include" {
  grep -qE '!.*finalize\.sh' "$SKILL_FILE"
}
