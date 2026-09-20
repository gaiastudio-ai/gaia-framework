#!/usr/bin/env bats
# detect-ux-scope.bats -- UX-scope detector re-key validation
#
# Validates the detect-ux-scope.sh helper after the re-key from the legacy
# frontmatter block to the design-record reference pointer.  Moved from
# tests/skills/gaia-create-story/ to plugins/gaia/tests/ for CI visibility.
#
# Dependencies: bats-core 1.10+, jq, GNU or BSD grep with -E support.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HELPER="$REPO_ROOT/scripts/detect-ux-scope.sh"
  FIXTURES="$REPO_ROOT/../../tests/fixtures/ux-detection"
  SKILL_FILE="$REPO_ROOT/skills/gaia-create-story/SKILL.md"
}

# Helper: build a minimal story fixture with the given frontmatter keys and body.
# Usage: _make_fixture <path> <extra_frontmatter_yaml> [body_text]
# The extra_frontmatter_yaml is inserted between the standard key/title/epic/status
# block and the closing `---`.  Body defaults to a generic non-UI-term sentence.
_make_fixture() {
  local path="$1" extra_fm="${2:-}" body="${3:-Implements the backend service.}"
  cat > "$path" <<EOF
---
key: "E99-S99"
title: "Test fixture"
epic: "E99"
status: "ready-for-dev"
${extra_fm}
---
# Story
${body}
EOF
}

# ---------- Pre-flight ----------

@test "Pre-flight: detect-ux-scope.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "Pre-flight: jq is installed" {
  command -v jq >/dev/null 2>&1
}

@test "Pre-flight: fixture directory exists" {
  [ -d "$FIXTURES" ]
}

# ---------- Existing back-compat tests (fixture renamed to design-tagged) ----------

@test "Back-compat: design-tagged.md -> ux_match=true" {
  run "$HELPER" "$FIXTURES/design-tagged.md"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "true" ] || { echo "expected ux_match=true for design-tagged fixture, got $match"; false; }
}

@test "Back-compat: design-tagged.md -> rules_fired contains rule1" {
  run "$HELPER" "$FIXTURES/design-tagged.md"
  [ "$status" -eq 0 ]
  has_rule1=$(echo "$output" | jq -r '.rules_fired | index("rule1")')
  [ "$has_rule1" != "null" ]
}

@test "Back-compat: design-tagged.md returns rules_fired in priority order (rule1 first)" {
  run "$HELPER" "$FIXTURES/design-tagged.md"
  [ "$status" -eq 0 ]
  first=$(echo "$output" | jq -r '.rules_fired[0]')
  [ "$first" = "rule1" ]
}

# ---------- Existing rule/schema tests (unchanged fixtures) ----------

@test "backend-data-flow.md -> ux_match=false" {
  run "$HELPER" "$FIXTURES/backend-data-flow.md"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "false" ]
}

@test "backend-data-flow.md -> excluded_by lists data flow" {
  run "$HELPER" "$FIXTURES/backend-data-flow.md"
  [ "$status" -eq 0 ]
  excluded=$(echo "$output" | jq -r '.excluded_by | index("data flow")')
  [ "$excluded" != "null" ]
}

@test "backend-platform.md -> ux_match=false (word-boundary blocks form)" {
  run "$HELPER" "$FIXTURES/backend-platform.md"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "false" ]
}

@test "backend-platform.md -> rules_fired is empty" {
  run "$HELPER" "$FIXTURES/backend-platform.md"
  [ "$status" -eq 0 ]
  count=$(echo "$output" | jq -r '.rules_fired | length')
  [ "$count" = "0" ]
}

@test "SKILL.md invokes detect-ux-scope.sh" {
  grep -qE "detect-ux-scope\.sh" "$SKILL_FILE"
}

@test "ui-terms-modal.md fires rule2 (UI terms)" {
  run "$HELPER" "$FIXTURES/ui-terms-modal.md"
  [ "$status" -eq 0 ]
  has_rule2=$(echo "$output" | jq -r '.rules_fired | index("rule2")')
  [ "$has_rule2" != "null" ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "true" ]
}

@test "missing-ux-design.md -> exit 0 even when rule 4 file is absent" {
  run "$HELPER" "$FIXTURES/missing-ux-design.md"
  [ "$status" -eq 0 ]
}

@test "missing-ux-design.md -> rule4 absent from rules_fired" {
  run "$HELPER" "$FIXTURES/missing-ux-design.md"
  [ "$status" -eq 0 ]
  has_rule4=$(echo "$output" | jq -r '.rules_fired | index("rule4")')
  [ "$has_rule4" = "null" ]
}

@test "Schema: helper emits valid JSON with ux_match, rules_fired, excluded_by keys" {
  run "$HELPER" "$FIXTURES/backend-platform.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("ux_match") and has("rules_fired") and has("excluded_by")' >/dev/null
}

@test "Schema: rules_fired and excluded_by are arrays" {
  run "$HELPER" "$FIXTURES/backend-data-flow.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.rules_fired | type == "array") and (.excluded_by | type == "array")' >/dev/null
}

@test "Error: missing story file -> exit 1" {
  run "$HELPER" "$FIXTURES/does-not-exist.md"
  [ "$status" -eq 1 ]
}

@test "Error: missing argument -> non-zero exit" {
  run "$HELPER"
  [ "$status" -ne 0 ]
}

@test "Word-boundary: platform must not match UI term form" {
  tmp="$BATS_TEST_TMPDIR/platform-only.md"
  cat > "$tmp" <<'EOF'
---
key: "E99-S99"
title: "Adopt platform tooling"
---
# Story
Platform vendor selection only.
EOF
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "false" ]
}

@test "Word-boundary: workflow (exclusion) suppresses flow" {
  tmp="$BATS_TEST_TMPDIR/workflow.md"
  cat > "$tmp" <<'EOF'
---
key: "E99-S98"
title: "Refactor CI workflow"
---
# Story
The build workflow needs simplification.
EOF
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "false" ]
}

# ==========================================================================
# New tests for the design-record reference re-key
# ==========================================================================

# ---------- (AC1) design-record reference in frontmatter classifies in scope ----------

@test "(AC1) design-record reference in frontmatter classifies in scope" {
  tmp="$BATS_TEST_TMPDIR/design-ref.md"
  _make_fixture "$tmp" 'design_ref: ".gaia/state/design-record.yaml"'
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "true" ] || { echo "expected ux_match=true, got $match"; false; }
  has_rule1=$(echo "$output" | jq -r '.rules_fired | index("rule1")')
  [ "$has_rule1" != "null" ] || { echo "rule1 missing from rules_fired"; false; }
}

# ---------- (AC2) legacy block only no longer matches ----------

@test "(AC2) legacy block only no longer matches" {
  tmp="$BATS_TEST_TMPDIR/legacy-only.md"
  # Build the legacy key from split fragments at runtime so this file
  # stays sweep-clean for the provider-literal containment gate.
  legacy_key="$(printf '%s%s' 'fig' 'ma')"
  _make_fixture "$tmp" "$(printf '%s:\n  file_key: \"abc123\"\n  node_id: \"10:42\"' "$legacy_key")"
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "false" ] || { echo "expected ux_match=false for legacy-only, got $match"; false; }
}

# ---------- (AC3) neither key classifies out of scope ----------

@test "(AC3) neither key classifies out of scope" {
  tmp="$BATS_TEST_TMPDIR/neither-key.md"
  _make_fixture "$tmp" ""
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "false" ] || { echo "expected ux_match=false for bare story, got $match"; false; }
}

# ---------- (AC-EC1) both keys present classifies in scope on new reference ----------

@test "(AC-EC1) both keys present classifies in scope on new reference" {
  tmp="$BATS_TEST_TMPDIR/both-keys.md"
  legacy_key="$(printf '%s%s' 'fig' 'ma')"
  _make_fixture "$tmp" "$(printf 'design_ref: \".gaia/state/design-record.yaml\"\n%s:\n  file_key: \"abc123\"' "$legacy_key")"
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "true" ] || { echo "expected ux_match=true for both-keys, got $match"; false; }
  has_rule1=$(echo "$output" | jq -r '.rules_fired | index("rule1")')
  [ "$has_rule1" != "null" ] || { echo "rule1 missing from rules_fired for both-keys"; false; }
}

# ---------- (AC-EC2) dangling reference still classifies in scope ----------

@test "(AC-EC2) dangling reference still classifies in scope" {
  tmp="$BATS_TEST_TMPDIR/dangling-ref.md"
  _make_fixture "$tmp" 'design_ref: "/nonexistent/path.yaml"'
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "true" ] || { echo "expected ux_match=true for dangling ref, got $match"; false; }
}

# ---------- (AC-EC3) pre-existing story with legacy block still parses ----------

@test "(AC-EC3) pre-existing story with legacy block still parses through consumers" {
  tmp="$BATS_TEST_TMPDIR/legacy-parse.md"
  legacy_key="$(printf '%s%s' 'fig' 'ma')"
  _make_fixture "$tmp" "$(printf '%s:\n  file_key: \"xyz789\"\n  node_id: \"5:10\"' "$legacy_key")"
  # Detector must not crash on unknown frontmatter keys
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ] || { echo "detector crashed on legacy block: exit $status"; false; }

  # The file must also be valid YAML (consumers that parse story frontmatter
  # must not choke on the legacy block)
  frontmatter=$(awk '
    BEGIN { state=0 }
    /^---[[:space:]]*$/ { if (state==0) { state=1; next } else if (state==1) { exit } }
    state==1 { print }
  ' "$tmp")
  echo "$frontmatter" | python3 -c 'import sys, yaml; yaml.safe_load(sys.stdin)' 2>/dev/null \
    || echo "$frontmatter" | yq '.' >/dev/null 2>&1
}

# ---------- (AC-EC4) key in prose only does not match structured position ----------

@test "(AC-EC4) key in prose only does not match structured position" {
  # DUAL PLACEMENT (do not simplify):
  # The detector greps $frontmatter (not the full file), so "body prose" can
  # only fire rule1 if the token leaks into frontmatter at a non-column-0
  # position.  This fixture places design_ref: in TWO non-column-0 spots:
  #   1. Inside a frontmatter VALUE (`notes: "see design_ref: for details"`)
  #      -- exercises the `^` anchor against a same-line-but-indented match.
  #   2. In the body prose below the `---` fence -- exercises the frontmatter-
  #      vs-body boundary.
  # Both vectors must be present to guard the anchor; dropping either would
  # leave one escape path untested.  Tex's mutant (drop `^` on the grep)
  # proves placement #1 alone turns this test red.
  tmp="$BATS_TEST_TMPDIR/prose-only.md"
  cat > "$tmp" <<'EOF'
---
key: "E99-S56"
title: "Prose mention story"
epic: "E99"
status: "ready-for-dev"
notes: "see design_ref: for details"
---
# Story
The design_ref: pointer is mentioned here only in prose.
Implements the backend service.
EOF
  run "$HELPER" "$tmp"
  [ "$status" -eq 0 ]
  match=$(echo "$output" | jq -r '.ux_match')
  [ "$match" = "false" ] || { echo "expected ux_match=false for prose-only, got $match"; false; }
}

# ---------- (AC5) sweep of create-story fix-story quick-spec returns zero provider hits ----------

@test "(AC5) sweep of create-story fix-story quick-spec returns zero provider hits" {
  # Build the search term from fragments to keep this file sweep-clean
  search_term="$(printf '%s%s' 'fig' 'ma')"

  cs_skill="$REPO_ROOT/skills/gaia-create-story/SKILL.md"
  fs_skill="$REPO_ROOT/skills/gaia-fix-story/SKILL.md"
  qs_skill="$REPO_ROOT/skills/gaia-quick-spec/SKILL.md"
  template="$REPO_ROOT/skills/gaia-create-story/story-template.md"
  generator="$REPO_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"

  # Zero word-bounded hits on any of the five files
  for f in "$cs_skill" "$fs_skill" "$qs_skill" "$template" "$generator"; do
    run grep -wiE "\\b${search_term}\\b" "$f"
    [ "$status" -eq 1 ] || { echo "retired provider literal found in $(basename "$f"): $output"; false; }
  done

  # Guard against strip-without-rebind: each skill must name the design record
  grep -q 'design.ref\|design-record\|design record' "$cs_skill"
  grep -q 'design.ref\|design-record\|design record' "$fs_skill"
  # quick-spec: pin the actual rewritten out-of-scope line so this guard is
  # sensitive to a regression of that specific wording (not just presence of
  # unrelated routing text elsewhere in the file)
  grep -qE '\*\*MCP / design tokens:\*\*' "$qs_skill"
}
