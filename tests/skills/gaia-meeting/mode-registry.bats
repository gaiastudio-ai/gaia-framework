#!/usr/bin/env bats
# mode-registry.bats — gaia-meeting mode registry (E76-S5)
#
# T1 / AC1-AC8 / AC15 / AC16 / FR-MTG-17
#
# Verifies the canonical mode-registry data structure ships at
# plugins/gaia/skills/gaia-meeting/knowledge/modes.yaml with one entry per
# mode (nine total — `decide` from E76-S1 plus the eight added in E76-S5),
# each carrying name, optional aliases, default_invitees, closing_artifact_bias,
# and notes_template_ref. The registry is a read-only knowledge file under
# the skill plugin tree (not project-level config).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REGISTRY="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/knowledge/modes.yaml"
  KNOWLEDGE_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/knowledge"
}

# State-machine block extractor (avoids the awk range-bug — gaia-shell-idioms).
# Prints lines from `- name: <target>` (inclusive) up to the next `- name:`
# header (exclusive), or to EOF if `<target>` is the last entry.
_block() {
  local target="$1"
  awk -v target="$target" '
    BEGIN { p = 0 }
    /^  - name:/ {
      if (p == 1) exit
      if ($0 == "  - name: " target) { p = 1; print; next }
    }
    p == 1 { print }
  ' "$REGISTRY"
}

@test "Pre-flight: modes.yaml registry exists" {
  [ -f "$REGISTRY" ]
}

@test "registry contains all nine modes" {
  for m in decide explore align red-team ac brainstorm design architecture sprint; do
    grep -qE "^  - name: $m\$" "$REGISTRY"
  done
}

@test "registry: explore has empty default_invitees and opportunity-map bias" {
  block="$(_block explore)"
  echo "$block" | grep -qE "closing_artifact_bias: opportunity-map"
  echo "$block" | grep -qE "default_invitees:[[:space:]]*\[\]"
}

@test "registry: align has Derek and Nate as default_invitees and alignment-summary bias" {
  block="$(_block align)"
  echo "$block" | grep -qE "closing_artifact_bias: alignment-summary"
  echo "$block" | grep -qE "Derek"
  echo "$block" | grep -qE "Nate"
}

@test "registry: red-team has Zara, Sable, Nova and risk-register bias" {
  block="$(_block red-team)"
  echo "$block" | grep -qE "closing_artifact_bias: risk-register"
  for n in Zara Sable Nova; do
    echo "$block" | grep -qE "$n"
  done
}

@test "registry: ac has Vera, Sable and machine-readable-ac-list bias" {
  block="$(_block ac)"
  echo "$block" | grep -qE "closing_artifact_bias: machine-readable-ac-list"
  echo "$block" | grep -qE "Vera"
  echo "$block" | grep -qE "Sable"
}

@test "registry: brainstorm has all five (Rex, Orion, Lyra, Elara, Vermeer) and brainstorming-document bias" {
  block="$(_block brainstorm)"
  echo "$block" | grep -qE "closing_artifact_bias: brainstorming-document"
  for n in Rex Orion Lyra Elara Vermeer; do
    echo "$block" | grep -qE "$n"
  done
}

@test "registry: design has all eight (Christy, Suki, Layla, Talia, Tariq, Lena, Cleo, Freya), ux-design-notes bias, and ux alias" {
  block="$(_block design)"
  echo "$block" | grep -qE "closing_artifact_bias: ux-design-notes"
  for n in Christy Suki Layla Talia Tariq Lena Cleo Freya; do
    echo "$block" | grep -qE "$n"
  done
  echo "$block" | grep -qE "aliases:.*ux"
}

@test "registry: architecture has all six (Theo, Soren, Milo, Juno, Omar, Priya) and architecture-decisions bias" {
  block="$(_block architecture)"
  echo "$block" | grep -qE "closing_artifact_bias: architecture-decisions"
  for n in Theo Soren Milo Juno Omar Priya; do
    echo "$block" | grep -qE "$n"
  done
}

@test "registry: sprint has Nate, Derek, Rafael and sprint-adjustments bias" {
  block="$(_block sprint)"
  echo "$block" | grep -qE "closing_artifact_bias: sprint-adjustments"
  for n in Nate Derek Rafael; do
    echo "$block" | grep -qE "$n"
  done
}

@test "registry: every mode has notes_template_ref pointing to a real template file" {
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    template="$KNOWLEDGE_DIR/$ref"
    [ -f "$template" ] || { echo "missing template: $template" >&2; return 1; }
  done < <(awk -F': *' '/^    notes_template_ref:/ { print $2 }' "$REGISTRY")
}

@test "registry: design entry declares ux as alias" {
  block="$(_block design)"
  echo "$block" | grep -qE "aliases:.*ux"
}

@test "registry: closing_artifact_bias values are unique across modes (one-to-one mapping)" {
  biases="$(awk -F': *' '/closing_artifact_bias:/ { print $2 }' "$REGISTRY")"
  unique="$(echo "$biases" | sort -u | wc -l | tr -d ' ')"
  total="$(echo "$biases" | wc -l | tr -d ' ')"
  [ "$unique" = "$total" ]
}
