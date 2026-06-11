#!/usr/bin/env bats
# meeting-notes-cost-breakdown-yaml.bats — TC-CBYAML-1..3.
#
# Regression coverage for the cost_breakdown YAML-emission bug in
# meeting-notes-writer.sh. The writer re-emits the payload's attendees mapping
# list into the saved-notes frontmatter as `cost_breakdown:`. A prior
# `sed 's/^[[:space:]]+/  /'` flattened ALL leading whitespace to 2 spaces,
# collapsing the per-list-item nesting: `role:`/`tokens:` lost their indent
# under `- name:` and parsed as broken sibling mappings, so the emitted
# frontmatter was invalid YAML for every meeting with attendees. The fix
# re-derives canonical 2-space-item / 4-space-field indent from line STRUCTURE,
# so the block round-trips through a YAML parser regardless of the payload's
# incoming indent depth.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WRITER="$PLUGIN/skills/gaia-meeting/scripts/meeting-notes-writer.sh"
  ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$ROOT/.gaia/artifacts/creative-artifacts"
  NOTES="$ROOT/.gaia/artifacts/creative-artifacts/meeting-notes/meeting-2026-06-11-cb.md"
}

# A YAML validity check that does not depend on yq being installed: prefer yq,
# fall back to python3. Mirrors the established _assert_valid_yaml idiom.
_yaml_ok() {
  local f="$1"
  if command -v yq >/dev/null 2>&1; then
    yq '.' "$f" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
  else
    return 99
  fi
}

# Echo a scalar from the parsed frontmatter (yq preferred, python3 fallback).
_yaml_get() {
  local f="$1" expr="$2" pyexpr="$3"
  if command -v yq >/dev/null 2>&1; then
    yq -r "$expr" "$f" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print($pyexpr)" "$f" 2>/dev/null
  else
    return 99
  fi
}

# Write a payload with two attendees and run the writer; isolates the
# frontmatter block to a temp file for parser checks.
_run_writer_and_extract_frontmatter() {
  local payload="$BATS_TEST_TMPDIR/payload.yaml"
  cat > "$payload" <<'EOF'
charter: "cost_breakdown round-trip test"
mode: clarify
total_tokens: 2360
attendees:
  - name: Derek
    role: Product Manager
    tokens: 1090
  - name: Theo
    role: System Architect
    tokens: 1270
summary: "test"
action_items: []
scratchpad_extractions: []
EOF
  run "$WRITER" --root "$ROOT" --payload "$payload" --date 2026-06-11 --slug cb
  [ "$status" -eq 0 ]
  [ -f "$NOTES" ]
  # Extract the YAML frontmatter (between the first two `---` fence lines).
  FM="$BATS_TEST_TMPDIR/frontmatter.yaml"
  awk '/^---$/{c++; next} c==1{print}' "$NOTES" > "$FM"
}

# TC-CBYAML-1 — the emitted frontmatter (incl. cost_breakdown) is valid YAML.
@test "TC-CBYAML-1: emitted cost_breakdown frontmatter parses as valid YAML" {
  _run_writer_and_extract_frontmatter
  _yaml_ok "$FM"
  rc=$?
  if [ "$rc" -eq 99 ]; then skip "no yq or python3 available to validate YAML"; fi
  [ "$rc" -eq 0 ]
}

# TC-CBYAML-2 — each attendee nests correctly: cost_breakdown is a list of
# mappings, and field access resolves the right values (not flattened siblings).
@test "TC-CBYAML-2: cost_breakdown attendees nest as proper mappings" {
  _run_writer_and_extract_frontmatter
  if ! command -v yq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    skip "no yq or python3 available to validate YAML"
  fi
  len="$(_yaml_get "$FM" '.cost_breakdown | length' 'len(d["cost_breakdown"])')"
  [ "$len" -eq 2 ]
  d0_name="$(_yaml_get "$FM" '.cost_breakdown[0].name' 'd["cost_breakdown"][0]["name"]')"
  [ "$d0_name" = "Derek" ]
  d1_tokens="$(_yaml_get "$FM" '.cost_breakdown[1].tokens' 'd["cost_breakdown"][1]["tokens"]')"
  [ "$d1_tokens" -eq 1270 ]
  d1_role="$(_yaml_get "$FM" '.cost_breakdown[1].role' 'd["cost_breakdown"][1]["role"]')"
  [ "$d1_role" = "System Architect" ]
}

# TC-CBYAML-3 — structural guard against the regression: continuation fields
# are emitted at 4-space indent under a 2-space list item. A flattening regression
# (both at 2 spaces) would put `role:` at the same indent as `- name:`.
@test "TC-CBYAML-3: continuation fields are emitted at 4-space indent (no flatten regression)" {
  _run_writer_and_extract_frontmatter
  # The list-item line is at exactly 2 spaces.
  grep -qE '^  - name: Derek$' "$NOTES"
  # The continuation fields are at exactly 4 spaces — NOT 2.
  grep -qE '^    role: Product Manager$' "$NOTES"
  grep -qE '^    tokens: 1090$' "$NOTES"
  # Regression signature: a 2-space `role:` (flattened sibling) must NOT appear.
  ! grep -qE '^  role: ' "$NOTES"
}
