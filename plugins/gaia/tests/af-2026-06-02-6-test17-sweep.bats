#!/usr/bin/env bats
# AF-2026-06-02-6 — Test17 brownfield manual-test sweep regression coverage.
#
# Each test asserts one of the 18 fixes lands and stays landed. The bats are
# pinned to specific in-tree scripts/SKILLs/schemas so a regression of any
# fixed finding fails CI deterministically.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ===========================================================================
# F-H02 — sprint-state.sh dep-resolver Tier-1 top-level + Tier-2 dual-glob
# ===========================================================================

@test "AF-33-6 F-H02: sprint-state.sh dep-resolver Tier-1 queries top-level .stories[]" {
  # Per Val V-01: source escapes the dep key as \"${_dep}\" inside the
  # yq query (the yq string is shell-double-quoted). Match the literal
  # as written on disk.
  grep -qF '.stories[] | select(.key == \"${_dep}\")' "$PLUGIN/scripts/sprint-state.sh"
}

@test "AF-33-6 F-H02: sprint-state.sh dep-resolver Tier-2 includes canonical per-story-dir glob" {
  # The dual-glob fallback MUST list epic-*/${_dep}-*/story.md alongside
  # the legacy epic-*/stories/${_dep}-*.md.
  grep -qF 'epic-*/"${_dep}-"*/story.md' "$PLUGIN/scripts/sprint-state.sh"
}

@test "AF-33-6 F-H02: sprint-state.sh dep-resolver Tier-1 fallback to legacy .sprints[].stories[]" {
  # Defense in depth: the canonical query above runs first, but if it returns
  # null the script falls back to the legacy roll-up shape so vestigial
  # multi-sprint yamls still resolve. Match the on-disk escape per Val V-01.
  grep -qF '.sprints[].stories[] | select(.key == \"${_dep}\")' "$PLUGIN/scripts/sprint-state.sh"
}

@test "AF-33-6 F-H02: sprint-state.sh wrapper at gaia-dev-story is byte-identical to canonical" {
  diff "$PLUGIN/scripts/sprint-state.sh" "$PLUGIN/skills/gaia-dev-story/scripts/sprint-state.sh"
}

# ===========================================================================
# F-M01 — sarif-merge SKILL comment no longer claims provenance survives
# ===========================================================================

@test "AF-33-6 F-M01: sarif-merge.sh comment no longer claims clean-scan provenance is preserved" {
  # The prior incorrect claim said "...so a zero-finding clean scan still
  # emits a per-tool run". After the fix that wording is gone and the
  # comment explicitly states real findings survive while clean-scan
  # provenance is lost.
  ! grep -F 'a zero-finding clean scan still emits' "$PLUGIN/scripts/adapters/brownfield/sarif-merge.sh"
  grep -qF 'REAL findings' "$PLUGIN/scripts/adapters/brownfield/sarif-merge.sh"
}

# ===========================================================================
# F-M02 — generate-pipeline.sh comment has no literal "exit 1"
# ===========================================================================

@test "AF-33-6 F-M02: generate-pipeline.sh header comment does not contain literal 'exit 1'" {
  # The prior literal `the prior \`exit 1\` stub` matched naive
  # `grep "exit 1"` checks on the generated workflow comment. The fix
  # replaces the wording so the comment can't trigger that false positive.
  ! grep -nE 'the prior .exit 1. stub /gaia-init seeds' "$PLUGIN/skills/gaia-ci-setup/scripts/generate-pipeline.sh"
  grep -qF 'the prior no-op placeholder' "$PLUGIN/skills/gaia-ci-setup/scripts/generate-pipeline.sh"
}

# ===========================================================================
# F-M03 — generate-frontmatter.sh normalizes risk to lowercase
# ===========================================================================

@test "AF-33-6 F-M03: generate-frontmatter.sh lowercases risk before emit" {
  grep -qF "risk=\"\$(printf '%s' \"\$risk\" | tr '[:upper:]' '[:lower:]')\"" \
    "$PLUGIN/skills/gaia-create-story/scripts/generate-frontmatter.sh"
}

# ===========================================================================
# F-M04 — materialize-sprint-stories.sh bulk path populates required fields
# ===========================================================================

@test "AF-33-6 F-M04: materialize-sprint-stories.sh frontmatter includes date author depends_on blocks traces_to delivered" {
  # All fields the validator requires must appear in the printf format.
  grep -qE 'date: "%s"' "$PLUGIN/scripts/materialize-sprint-stories.sh"
  grep -qE 'author: "gaia-create-story"' "$PLUGIN/scripts/materialize-sprint-stories.sh"
  grep -qF 'depends_on: []' "$PLUGIN/scripts/materialize-sprint-stories.sh"
  grep -qF 'blocks: []' "$PLUGIN/scripts/materialize-sprint-stories.sh"
  grep -qF 'traces_to: []' "$PLUGIN/scripts/materialize-sprint-stories.sh"
  grep -qF 'delivered: false' "$PLUGIN/scripts/materialize-sprint-stories.sh"
  grep -qF 'deferred_implementation: false' "$PLUGIN/scripts/materialize-sprint-stories.sh"
}

@test "AF-33-6 F-M03/F-M04 bulk path: materialize lowercases risk too" {
  grep -qF "risk=\"\$(printf '%s' \"\$risk\" | tr '[:upper:]' '[:lower:]')\"" \
    "$PLUGIN/scripts/materialize-sprint-stories.sh"
}

# ===========================================================================
# F-M05 — compose-verdict.sh accepts PASS (and CRITICAL) synonyms
# ===========================================================================

@test "AF-33-6 F-M05: compose-verdict.sh accepts PASS as PASSED synonym" {
  run bash "$PLUGIN/skills/gaia-sprint-review/scripts/compose-verdict.sh" --track-a PASS --track-b PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "PASSED" ]
}

@test "AF-33-6 F-M05: compose-verdict.sh accepts CRITICAL as FAILED synonym" {
  run bash "$PLUGIN/skills/gaia-sprint-review/scripts/compose-verdict.sh" --track-a CRITICAL --track-b PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "FAILED" ]
}

@test "AF-33-6 F-M05: compose-verdict.sh still accepts WARNING" {
  run bash "$PLUGIN/skills/gaia-sprint-review/scripts/compose-verdict.sh" --track-a WARNING --track-b PASSED
  [ "$status" -eq 0 ]
  [ "$output" = "PASSED" ]
}

# ===========================================================================
# D-9 — close.sh usage doc points at canonical .gaia/ path
# ===========================================================================

@test "AF-33-6 D-9: close.sh usage documents retro at .gaia/ path" {
  grep -qF '.gaia/artifacts/implementation-artifacts/retrospective/retrospective-{sprint_id}-' \
    "$PLUGIN/skills/gaia-sprint-close/scripts/close.sh"
  ! grep -nE 'retro doc must exist at docs/implementation-artifacts/retrospective-' \
    "$PLUGIN/skills/gaia-sprint-close/scripts/close.sh"
}

# ===========================================================================
# L-02 — render-test-quality.sh sets 0644 on the report
# ===========================================================================

@test "AF-33-6 L-02: render-test-quality.sh chmod 644 the report after mv" {
  grep -qF 'chmod 644 "$REPORT"' "$PLUGIN/scripts/adapters/dead-code/render-test-quality.sh"
}

# ===========================================================================
# L-04 — devops persona splits design vs deployment by artifact KIND
# ===========================================================================

@test "AF-33-6 L-04: devops persona explicitly splits design vs deployment routing" {
  grep -qF 'planning artifact' "$PLUGIN/agents/devops.md"
  grep -qF 'implementation artifacts' "$PLUGIN/agents/devops.md"
  grep -qF 'Do NOT route an infra DESIGN into' "$PLUGIN/agents/devops.md"
}

# ===========================================================================
# L-05 — scaffold-story.sh emits section-distinct placeholders
# ===========================================================================

@test "AF-33-6 L-05: scaffold-story.sh has per-section placeholder helper" {
  grep -qF '{USER_STORY_PLACEHOLDER}' "$PLUGIN/skills/gaia-create-story/scripts/scaffold-story.sh"
  grep -qF '{ACCEPTANCE_CRITERIA_PLACEHOLDER}' "$PLUGIN/skills/gaia-create-story/scripts/scaffold-story.sh"
  grep -qF '{TASKS_PLACEHOLDER}' "$PLUGIN/skills/gaia-create-story/scripts/scaffold-story.sh"
  grep -qF '{DEV_NOTES_PLACEHOLDER}' "$PLUGIN/skills/gaia-create-story/scripts/scaffold-story.sh"
  grep -qF '{TECHNICAL_NOTES_PLACEHOLDER}' "$PLUGIN/skills/gaia-create-story/scripts/scaffold-story.sh"
  grep -qF '{DEPENDENCIES_PLACEHOLDER}' "$PLUGIN/skills/gaia-create-story/scripts/scaffold-story.sh"
  grep -qF '{TEST_SCENARIOS_PLACEHOLDER}' "$PLUGIN/skills/gaia-create-story/scripts/scaffold-story.sh"
}

# ===========================================================================
# L-07 — resolve-epic-slug.sh accepts ASCII-double-hyphen Epic-prefix heading
# ===========================================================================

@test "AF-33-6 L-07: resolve-epic-slug.sh accepts '## Epic E5 -- Title' (ASCII --) heading" {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
## Epic E5 -- Test Heading For L-07

- content
EOF
  source "$PLUGIN/scripts/lib/resolve-epic-slug.sh"
  run resolve_epic_slug "E5" "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E5-test-heading-for-l-07"* ]]
  rm -f "$tmp"
}

@test "AF-33-6 L-07: resolve-epic-slug.sh accepts '## Epic E5 — Title' (em-dash with Epic prefix) heading" {
  local tmp
  tmp="$(mktemp)"
  printf '## Epic E5 \xe2\x80\x94 Em-Dash Variant\n\n- content\n' > "$tmp"
  source "$PLUGIN/scripts/lib/resolve-epic-slug.sh"
  run resolve_epic_slug "E5" "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"epic-E5-em-dash-variant"* ]]
  rm -f "$tmp"
}

# ===========================================================================
# L-08 — materialize-sprint-stories.sh invokes backfill-story-index.sh
# ===========================================================================

@test "AF-33-6 L-08: materialize-sprint-stories.sh invokes backfill-story-index.sh" {
  grep -qF 'backfill-story-index.sh' "$PLUGIN/scripts/materialize-sprint-stories.sh"
}

# ===========================================================================
# L-09 — test-environment-manifest.sh emits .yaml.example alongside
# ===========================================================================

@test "AF-33-6 L-09: test-environment-manifest.sh invokes install-test-environment-example.sh" {
  grep -qF 'install-test-environment-example.sh' "$PLUGIN/scripts/lib/test-environment-manifest.sh"
}

# ===========================================================================
# D-1 — brownfield-gap-entry.schema.json has claim_type + stale-claim
# ===========================================================================

@test "AF-33-6 D-1: brownfield-gap-entry schema has claim_type enum" {
  run jq -e '.properties.claim_type.enum | index("positive")' \
    "$PLUGIN/schemas/brownfield-gap-entry.schema.json"
  [ "$status" -eq 0 ]
  run jq -e '.properties.claim_type.enum | index("negative")' \
    "$PLUGIN/schemas/brownfield-gap-entry.schema.json"
  [ "$status" -eq 0 ]
}

@test "AF-33-6 D-1: brownfield-gap-entry schema category enum includes stale-claim" {
  run jq -e '.properties.category.enum | index("stale-claim")' \
    "$PLUGIN/schemas/brownfield-gap-entry.schema.json"
  [ "$status" -eq 0 ]
}

@test "AF-33-6 D-1: gaia-brownfield SKILL.md surfaces the gap-entry schema fragment" {
  grep -qF 'brownfield-gap-entry.schema.json' "$PLUGIN/skills/gaia-brownfield/SKILL.md"
  grep -qF 'gap-entry-schema-ref' "$PLUGIN/skills/gaia-brownfield/SKILL.md"
}

# ===========================================================================
# D-8 — test-architect persona splits planning vs test-tier routing
# ===========================================================================

@test "AF-33-6 D-8: test-architect persona references ADR-127 + splits routing" {
  grep -qF 'ADR-127' "$PLUGIN/agents/test-architect.md"
  grep -qF 'Planning-tier artifacts' "$PLUGIN/agents/test-architect.md"
  grep -qF 'Test-tier artifacts' "$PLUGIN/agents/test-architect.md"
}

# ===========================================================================
# D-4 — PRD template: 3-tier severity columns + Priority Matrix + stale-claim
# ===========================================================================

@test "AF-33-6 D-4: PRD template Gap Analysis Summary uses 3-tier CRITICAL/WARNING/INFO columns" {
  grep -qF '| Category | CRITICAL | WARNING | INFO | Total |' \
    "$PLUGIN/skills/gaia-create-prd/prd-template.md"
}

@test "AF-33-6 D-4: PRD template has Priority Matrix section" {
  grep -qF '## Priority Matrix (brownfield)' \
    "$PLUGIN/skills/gaia-create-prd/prd-template.md"
}

@test "AF-33-6 D-4: PRD template has Stale Claims category section" {
  grep -qF '### Stale Claims (`stale-claim`)' \
    "$PLUGIN/skills/gaia-create-prd/prd-template.md"
}

# ===========================================================================
# D-5 — adversarial SKILL description vs persona reconciliation
# ===========================================================================

@test "AF-33-6 D-5: gaia-adversarial SKILL description names Proposed refinement at artifact level" {
  grep -qF 'Proposed refinement' "$PLUGIN/skills/gaia-adversarial/SKILL.md"
  grep -qF 'NOT a downstream implementation fix' "$PLUGIN/skills/gaia-adversarial/SKILL.md"
}

# ===========================================================================
# D-7 — gaia-create-prd brownfield freshness re-check rule
# ===========================================================================

@test "AF-33-6 D-7: gaia-create-prd SKILL has brownfield freshness re-check Critical Rule" {
  grep -qF 'Brownfield freshness re-check' "$PLUGIN/skills/gaia-create-prd/SKILL.md"
  grep -qF 're-stat the `evidence_file`' "$PLUGIN/skills/gaia-create-prd/SKILL.md"
}
