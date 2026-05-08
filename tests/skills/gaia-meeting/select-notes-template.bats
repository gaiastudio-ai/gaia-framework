#!/usr/bin/env bats
# select-notes-template.bats — bias→template mapper (E76-S5)
#
# T6 / AC15
#
# Verifies select-notes-template.sh maps each closing-artifact bias to the
# matching prompt template under the skill's knowledge/ subtree.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SELECTOR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/select-notes-template.sh"
  KNOWLEDGE_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/knowledge"
}

@test "Pre-flight: select-notes-template.sh exists and is executable" {
  [ -x "$SELECTOR" ]
}

@test "AC15: bias=architecture-decisions selects architecture-decisions template (NOT decision-record)" {
  run "$SELECTOR" --bias architecture-decisions
  [ "$status" -eq 0 ]
  [[ "$output" == *"notes-template-architecture-decisions.md" ]]
  [[ "$output" != *"decision-record"* ]]
}

@test "all eight new biases map to a template that exists on disk" {
  for bias in opportunity-map alignment-summary risk-register machine-readable-ac-list \
              brainstorming-document ux-design-notes architecture-decisions sprint-adjustments; do
    run "$SELECTOR" --bias "$bias"
    [ "$status" -eq 0 ]
    template="$KNOWLEDGE_DIR/$(basename "$output")"
    [ -f "$template" ]
  done
}

@test "AC15: each bias→template is one-to-one — distinct templates per bias" {
  outputs=()
  for bias in opportunity-map alignment-summary risk-register machine-readable-ac-list \
              brainstorming-document ux-design-notes architecture-decisions sprint-adjustments; do
    run "$SELECTOR" --bias "$bias"
    [ "$status" -eq 0 ]
    outputs+=("$output")
  done
  unique="$(printf '%s\n' "${outputs[@]}" | sort -u | wc -l | tr -d ' ')"
  [ "$unique" = "8" ]
}

@test "AC15: each template body contains the matching section header" {
  # bash 3 on macOS lacks associative arrays — use parallel arrays.
  biases=(opportunity-map alignment-summary risk-register machine-readable-ac-list brainstorming-document ux-design-notes architecture-decisions sprint-adjustments)
  headings=("Opportunity Map" "Alignment Summary" "Risk Register" "Acceptance Criteria" "Idea Clusters" "UX Design Notes" "Architecture Decisions" "Sprint Adjustments")
  for i in "${!biases[@]}"; do
    bias="${biases[$i]}"
    heading="${headings[$i]}"
    template="$KNOWLEDGE_DIR/notes-template-${bias}.md"
    [ -f "$template" ]
    grep -qE "^# ${heading}" "$template" \
      || grep -qE "^## ${heading}" "$template" \
      || (>&2 echo "missing heading '${heading}' in $template"; return 1)
  done
}

@test "Unknown bias is rejected with non-zero exit" {
  run "$SELECTOR" --bias unknown-bias
  [ "$status" -ne 0 ]
}
