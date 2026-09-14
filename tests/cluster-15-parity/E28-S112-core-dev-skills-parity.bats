#!/usr/bin/env bats
# E28-S112-core-dev-skills-parity.bats
#
# Parity + structure tests for E28-S112 — Convert 8 core dev skills to SKILL.md format.
#
# Validates:
#   AC1: Each of the 8 core dev SKILL.md files exists under plugins/gaia/skills/
#        with valid YAML frontmatter (name, description, allowed-tools) and
#        passes the frontmatter linter with zero errors.
#   AC2: Every legacy "<!-- SECTION: xxx -->" marker from _gaia/dev/skills/_skill-index.yaml
#        is preserved verbatim in the converted SKILL.md (same IDs, same order).
#   AC3: ADR-041 citation present in each SKILL.md body (native execution).
#   AC4: No legacy frontmatter fields leak into the active frontmatter surface —
#        applicable_agents, test_scenarios, and version MUST NOT appear in the
#        SKILL.md frontmatter (they are either dropped or migrated into the body).
#   AC5: No name collisions across the 8 new skills.
#
# Refs: E28-S112, FR-323, NFR-048, NFR-053, ADR-041, ADR-042, ADR-046, ADR-048
#
# Usage:
#   bats tests/cluster-15-parity/E28-S112-core-dev-skills-parity.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  LINT_SCRIPT="$REPO_ROOT/.github/scripts/lint-skill-frontmatter.sh"

  # The 8 core dev skills in this story (legacy-name -> native-name).
  SKILLS=(
    "gaia-git-workflow"
    "gaia-api-design"
    "gaia-database-design"
    "gaia-docker-workflow"
    "gaia-testing-patterns"
    "gaia-code-review-standards"
    "gaia-documentation-standards"
    "gaia-security-basics"
  )
}

# Helper: extract YAML frontmatter (lines between first two `---` delimiters).
_frontmatter() {
  local file="$1"
  awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (seen == 0) { in_fm = 1; seen = 1; next }
      else if (in_fm == 1) { in_fm = 0; exit }
    }
    in_fm == 1 { print }
  ' "$file"
}

# ---------- AC1: SKILL.md existence + valid frontmatter per skill ----------

@test "E28-S112: gaia-git-workflow/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-git-workflow/SKILL.md" ]
}

@test "E28-S112: gaia-api-design/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-api-design/SKILL.md" ]
}

@test "E28-S112: gaia-database-design/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-database-design/SKILL.md" ]
}

@test "E28-S112: gaia-docker-workflow/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-docker-workflow/SKILL.md" ]
}

@test "E28-S112: gaia-testing-patterns/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-testing-patterns/SKILL.md" ]
}

@test "E28-S112: gaia-code-review-standards/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-code-review-standards/SKILL.md" ]
}

@test "E28-S112: gaia-documentation-standards/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-documentation-standards/SKILL.md" ]
}

@test "E28-S112: gaia-security-basics/SKILL.md exists" {
  [ -f "$SKILLS_DIR/gaia-security-basics/SKILL.md" ]
}

@test "E28-S112: each SKILL.md has YAML frontmatter delimiters" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    head -1 "$f" | grep -q "^---$" || { echo "missing opening --- in $f"; return 1; }
    awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$f" || { echo "missing closing --- in $f"; return 1; }
  done
}

@test "E28-S112: each SKILL.md has name: gaia-<skill> matching directory" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    head -30 "$f" | grep -q "^name: $skill\$" || { echo "name mismatch in $f"; return 1; }
  done
}

@test "E28-S112: each SKILL.md has a non-empty description" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    head -30 "$f" | grep -qE '^description: .+' || { echo "missing description in $f"; return 1; }
  done
}

@test "E28-S112: each SKILL.md declares an allowed-tools field" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    head -30 "$f" | grep -qE '^allowed-tools:' || { echo "missing allowed-tools in $f"; return 1; }
  done
}

# ---------- AC1: Full-tree frontmatter linter passes ----------

@test "E28-S112: frontmatter linter passes on full plugins/gaia/skills tree" {
  cd "$REPO_ROOT" && bash "$LINT_SCRIPT"
}

# ---------- AC2: Sectioned-loading markers preserved verbatim ----------
# Section IDs per _gaia/dev/skills/_skill-index.yaml.

@test "E28-S112: gaia-git-workflow preserves 4 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-git-workflow/SKILL.md"
  grep -q '<!-- SECTION: branching -->' "$f"
  grep -q '<!-- SECTION: commits -->' "$f"
  grep -q '<!-- SECTION: pull-requests -->' "$f"
  grep -q '<!-- SECTION: conflict-resolution -->' "$f"
}

@test "E28-S112: gaia-api-design preserves 5 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-api-design/SKILL.md"
  grep -q '<!-- SECTION: rest-conventions -->' "$f"
  grep -q '<!-- SECTION: graphql -->' "$f"
  grep -q '<!-- SECTION: openapi -->' "$f"
  grep -q '<!-- SECTION: versioning -->' "$f"
  grep -q '<!-- SECTION: error-standards -->' "$f"
}

@test "E28-S112: gaia-database-design preserves 4 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-database-design/SKILL.md"
  grep -q '<!-- SECTION: schema-design -->' "$f"
  grep -q '<!-- SECTION: migrations -->' "$f"
  grep -q '<!-- SECTION: indexing -->' "$f"
  grep -q '<!-- SECTION: orm-patterns -->' "$f"
}

@test "E28-S112: gaia-docker-workflow preserves 3 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-docker-workflow/SKILL.md"
  grep -q '<!-- SECTION: multi-stage-builds -->' "$f"
  grep -q '<!-- SECTION: compose -->' "$f"
  grep -q '<!-- SECTION: security-scanning -->' "$f"
}

@test "E28-S112: gaia-testing-patterns preserves 4 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-testing-patterns/SKILL.md"
  grep -q '<!-- SECTION: tdd-cycle -->' "$f"
  grep -q '<!-- SECTION: unit-testing -->' "$f"
  grep -q '<!-- SECTION: integration-testing -->' "$f"
  grep -q '<!-- SECTION: test-doubles -->' "$f"
}

@test "E28-S112: gaia-code-review-standards preserves 4 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-code-review-standards/SKILL.md"
  grep -q '<!-- SECTION: review-checklist -->' "$f"
  grep -q '<!-- SECTION: solid-principles -->' "$f"
  grep -q '<!-- SECTION: complexity-metrics -->' "$f"
  grep -q '<!-- SECTION: review-gate-completion -->' "$f"
}

@test "E28-S112: gaia-documentation-standards preserves 4 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-documentation-standards/SKILL.md"
  grep -q '<!-- SECTION: readme-template -->' "$f"
  grep -q '<!-- SECTION: adr-format -->' "$f"
  grep -q '<!-- SECTION: inline-comments -->' "$f"
  grep -q '<!-- SECTION: api-docs -->' "$f"
}

@test "E28-S112: gaia-security-basics preserves 4 sectioned-loading markers" {
  local f="$SKILLS_DIR/gaia-security-basics/SKILL.md"
  grep -q '<!-- SECTION: owasp-top-10 -->' "$f"
  grep -q '<!-- SECTION: input-validation -->' "$f"
  grep -q '<!-- SECTION: secrets-management -->' "$f"
  grep -q '<!-- SECTION: cors-csrf -->' "$f"
}

# ---------- AC2: Sectioned-loading marker order preserved ----------

@test "E28-S112: gaia-git-workflow section markers appear in legacy order" {
  local f="$SKILLS_DIR/gaia-git-workflow/SKILL.md"
  local order
  order=$(grep -n '<!-- SECTION:' "$f" | awk -F'SECTION: ' '{print $2}' | awk -F' -->' '{print $1}')
  # The four legacy markers keep their original relative order; `worktrees` is
  # appended as a fifth loadable section, so the legacy selectors are unchanged.
  [ "$order" = "$(printf 'branching\ncommits\npull-requests\nconflict-resolution\nworktrees')" ]
}

@test "E28-S112: gaia-api-design section markers appear in legacy order" {
  local f="$SKILLS_DIR/gaia-api-design/SKILL.md"
  local order
  order=$(grep -n '<!-- SECTION:' "$f" | awk -F'SECTION: ' '{print $2}' | awk -F' -->' '{print $1}')
  [ "$order" = "$(printf 'rest-conventions\ngraphql\nopenapi\nversioning\nerror-standards')" ]
}

# ---------- AC3: ADR-041 citation ----------

@test "E28-S112: each SKILL.md cites ADR-041 (native execution)" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    grep -q 'ADR-041' "$f" || { echo "missing ADR-041 citation in $f"; return 1; }
  done
}

# ---------- AC4: Legacy frontmatter fields MUST NOT leak ----------

@test "E28-S112: no SKILL.md has applicable_agents in active frontmatter" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    local fm
    fm=$(_frontmatter "$f")
    ! echo "$fm" | grep -qE '^applicable_agents:' || { echo "applicable_agents leaked into frontmatter of $f"; return 1; }
  done
}

@test "E28-S112: no SKILL.md has test_scenarios in active frontmatter" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    local fm
    fm=$(_frontmatter "$f")
    ! echo "$fm" | grep -qE '^test_scenarios:' || { echo "test_scenarios leaked into frontmatter of $f"; return 1; }
  done
}

@test "E28-S112: no SKILL.md has version field in active frontmatter" {
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    local fm
    fm=$(_frontmatter "$f")
    ! echo "$fm" | grep -qE '^version:' || { echo "version leaked into frontmatter of $f"; return 1; }
  done
}

# ---------- AC5: No name collisions among new skills ----------

@test "E28-S112: the 8 new skills have unique name frontmatter values" {
  local names=""
  for skill in "${SKILLS[@]}"; do
    local f="$SKILLS_DIR/$skill/SKILL.md"
    local name
    name=$(_frontmatter "$f" | awk -F': ' '/^name:/ {print $2; exit}')
    names="$names"$'\n'"$name"
  done
  local unique
  unique=$(echo "$names" | grep -v '^$' | sort -u | wc -l | tr -d ' ')
  [ "$unique" = "8" ]
}

# ---------- Functional parity spot-checks (NFR-053) ----------

@test "E28-S112: gaia-git-workflow#commits preserves Conventional Commits table header" {
  local f="$SKILLS_DIR/gaia-git-workflow/SKILL.md"
  grep -q 'Conventional Commits' "$f"
  grep -q '| Type | Use When |' "$f"
}

@test "E28-S112: gaia-testing-patterns#tdd-cycle preserves Red-Green-Refactor ordering" {
  local f="$SKILLS_DIR/gaia-testing-patterns/SKILL.md"
  grep -q 'Red-Green-Refactor' "$f"
  grep -qF '**Red**' "$f"
  grep -qF '**Green**' "$f"
  grep -qF '**Refactor**' "$f"
}

@test "E28-S112: gaia-security-basics#owasp-top-10 preserves A01/A02/A03 headers" {
  local f="$SKILLS_DIR/gaia-security-basics/SKILL.md"
  grep -q 'A01: Broken Access Control' "$f"
  grep -q 'A02: Cryptographic Failures' "$f"
  grep -q 'A03: Injection' "$f"
}

@test "E28-S112: gaia-code-review-standards#review-gate-completion preserves hard-gate wording" {
  local f="$SKILLS_DIR/gaia-code-review-standards/SKILL.md"
  grep -q 'Review Gate Completion' "$f"
  grep -q 'review-summary.md' "$f"
  grep -q 'hard gate' "$f"
}
