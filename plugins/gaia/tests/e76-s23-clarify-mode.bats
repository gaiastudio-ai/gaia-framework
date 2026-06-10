#!/usr/bin/env bats
# e76-s23-clarify-mode.bats — coverage for the `clarify` meeting mode.
#
# TC-MTG-CLARIFY-1..7: registry resolution, alias canonicalization,
# collision-freedom, bias-to-template mapping, template presence, and the
# not-a-decision / not-a-brainstorm structural constraints on the template.

setup() {
  # Derive the gaia plugin root from this test file's location so the suite is
  # resilient to repo-rename / checkout-dir flips (the dir name is not assumed).
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MEETING="$PLUGIN/skills/gaia-meeting"
  MODES="$MEETING/knowledge/modes.yaml"
  REGISTRY_LIB="$MEETING/scripts/lib/load-mode-registry.sh"
  RESOLVE_MODE="$MEETING/scripts/resolve-mode.sh"
  SELECT_TEMPLATE="$MEETING/scripts/select-notes-template.sh"
  TEMPLATE="$MEETING/knowledge/notes-template-clarification-notes.md"
}

# TC-MTG-CLARIFY-1 — clarify mode resolves from the registry.
@test "TC-MTG-CLARIFY-1: clarify mode resolves from the registry" {
  run bash -c ". '$REGISTRY_LIB'; mode_registry_canonical clarify"
  [ "$status" -eq 0 ]
  [ "$output" = "clarify" ]
}

# TC-MTG-CLARIFY-2 — aliases clarification + questions canonicalize to clarify.
@test "TC-MTG-CLARIFY-2: aliases clarification and questions canonicalize to clarify" {
  run bash -c ". '$REGISTRY_LIB'; mode_registry_canonical clarification"
  [ "$status" -eq 0 ]
  [ "$output" = "clarify" ]

  run bash -c ". '$REGISTRY_LIB'; mode_registry_canonical questions"
  [ "$status" -eq 0 ]
  [ "$output" = "clarify" ]
}

# TC-MTG-CLARIFY-3 — clarify name + aliases do not collide with any existing
# mode name or alias.
@test "TC-MTG-CLARIFY-3: clarify name and aliases do not collide" {
  # Collect every name + alias token across the registry; assert each of
  # clarify / clarification / questions appears exactly once.
  tokens="$(grep -E '^\s*(- name:|aliases:)' "$MODES" \
    | sed -E 's/.*name:\s*//; s/.*aliases:\s*//; s/[][,]/ /g')"
  for tok in clarify clarification questions; do
    count="$(printf '%s\n' $tokens | grep -cxF "$tok" || true)"
    [ "$count" -eq 1 ]
  done
}

# TC-MTG-CLARIFY-4 — select-notes-template.sh --bias clarification-notes
# exits 0 and outputs a path ending in notes-template-clarification-notes.md.
@test "TC-MTG-CLARIFY-4: select-notes-template resolves clarification-notes bias" {
  run "$SELECT_TEMPLATE" --bias clarification-notes
  [ "$status" -eq 0 ]
  [[ "$output" == *"notes-template-clarification-notes.md" ]]
}

# TC-MTG-CLARIFY-5 — template file exists on disk under knowledge/.
@test "TC-MTG-CLARIFY-5: clarification-notes template exists" {
  [ -f "$TEMPLATE" ]
  [ -s "$TEMPLATE" ]
}

# TC-MTG-CLARIFY-6 — template does NOT contain decision-record headings.
@test "TC-MTG-CLARIFY-6: template has no decision-record headings" {
  [ -f "$TEMPLATE" ]   # guard: a missing file would make the grep vacuously pass
  run grep -Ei '^\s*#+\s*(Decision|Options chosen|Alternatives considered)\b' "$TEMPLATE"
  [ "$status" -ne 0 ]
}

# TC-MTG-CLARIFY-7 — template does NOT contain brainstorming-document headings.
@test "TC-MTG-CLARIFY-7: template has no brainstorming-document headings" {
  [ -f "$TEMPLATE" ]   # guard: a missing file would make the grep vacuously pass
  run grep -Ei '^\s*#+\s*(Idea clusters|Ranked options)\b' "$TEMPLATE"
  [ "$status" -ne 0 ]
}
