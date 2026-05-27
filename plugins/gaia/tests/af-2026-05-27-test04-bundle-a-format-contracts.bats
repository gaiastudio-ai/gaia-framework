#!/usr/bin/env bats
# AF-2026-05-27 — Test04 Bundle A: format-contract HIGHs.
#
# Producer/consumer format mismatches in the same lifecycle phase. The producer
# (gaia-create-epics) authors stories as `### Story E{N}-S{N}: Title` + plain
# `- Label: value` bullets; the consumers expected other shapes:
#
#   F-017: gaia-create-story/generate-frontmatter.sh::extract_bullet required
#          bold `- **Label:** value` — now tolerates plain `- Label: value` too.
#   F-014: gaia-atdd/discover-stories.sh parsed ONLY a pipe-table — now also
#          parses the canonical `### Story` + `- Risk:` bullet-block format.
#   F-011: gaia-create-ux/finalize.sh::heading_present rejected numbered H2s
#          (`## 1. Personas`) — back-ported the numeric-prefix tolerance the
#          sibling gaia-create-prd/finalize.sh got under AF-2026-05-22-3 Bug-3.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GF="$PLUGIN_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  DS="$PLUGIN_ROOT/skills/gaia-atdd/scripts/discover-stories.sh"
  UXF="$PLUGIN_ROOT/skills/gaia-create-ux/scripts/finalize.sh"
}

teardown() { common_teardown; }

# --- F-017: extract_bullet tolerates plain AND bold bullets ---

@test "F-017: extract_bullet reads plain '- Label: value' (canonical create-epics form)" {
  eval "$(awk '/^extract_bullet\(\) \{/,/^\}/' "$GF")"
  block="### Story E1-S1: Foo
- Epic: E1
- Priority: P0
- Risk: high"
  [ "$(extract_bullet Epic)" = "E1" ]
  [ "$(extract_bullet Priority)" = "P0" ]
  [ "$(extract_bullet Risk)" = "high" ]
}

@test "F-017: extract_bullet still reads bold '- **Label:** value' (legacy form)" {
  eval "$(awk '/^extract_bullet\(\) \{/,/^\}/' "$GF")"
  block="### Story E1-S1: Foo
- **Epic:** E1
- **Risk:** high"
  [ "$(extract_bullet Epic)" = "E1" ]
  [ "$(extract_bullet Risk)" = "high" ]
}

@test "F-017: extract_bullet emits empty for an absent label" {
  eval "$(awk '/^extract_bullet\(\) \{/,/^\}/' "$GF")"
  block="- Epic: E1"
  [ -z "$(extract_bullet Nonexistent)" ]
}

# --- F-014: discover-stories parses bullet-block AND pipe-table ---

@test "F-014: _parse_high_risk finds high-risk stories in the bullet-block format" {
  cat > "$TEST_TMP/epics.md" <<'MD'
## E1 — Core Brain Vault
### Story E1-S1: Build the vault
- Epic: E1
- Risk: high
### Story E1-S2: Low risk thing
- Epic: E1
- Risk: low
## E2 — Sync
### Story E2-S1: Risky sync
- Epic: E2
- Risk: high
MD
  _EPICS="$TEST_TMP/epics.md"
  eval "$(awk '/^_parse_high_risk\(\) \{/,/^\}/' "$DS")"
  run _parse_high_risk
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^E1-S1'
  printf '%s\n' "$output" | grep -qE '^E2-S1'
  # the low-risk story must NOT appear
  ! printf '%s\n' "$output" | grep -qE '^E1-S2'
}

@test "F-014: _parse_high_risk tolerates bold '- **Risk:** high' in a block" {
  cat > "$TEST_TMP/epics.md" <<'MD'
### Story E3-S1: Bold risk
- Epic: E3
- **Risk:** high
MD
  _EPICS="$TEST_TMP/epics.md"
  eval "$(awk '/^_parse_high_risk\(\) \{/,/^\}/' "$DS")"
  run _parse_high_risk
  printf '%s\n' "$output" | grep -qE '^E3-S1'
}

@test "F-014: _parse_high_risk still parses the legacy pipe-table format" {
  cat > "$TEST_TMP/epics.md" <<'MD'
| Key | Title | Size | Priority | Risk |
|-----|-------|------|----------|------|
| E1-S1 | Build vault | M | P0 | high |
| E1-S2 | Low thing | S | P2 | low |
| E3-S1 | Other risky | L | P1 | high |
MD
  _EPICS="$TEST_TMP/epics.md"
  eval "$(awk '/^_parse_high_risk\(\) \{/,/^\}/' "$DS")"
  run _parse_high_risk
  printf '%s\n' "$output" | grep -qE '^E1-S1'
  printf '%s\n' "$output" | grep -qE '^E3-S1'
  ! printf '%s\n' "$output" | grep -qE '^E1-S2'
}

@test "F-014: _parse_high_risk dedups a story matched by both formats" {
  cat > "$TEST_TMP/epics.md" <<'MD'
### Story E1-S1: Dup
- Risk: high
| E1-S1 | Dup | M | P0 | high |
MD
  _EPICS="$TEST_TMP/epics.md"
  eval "$(awk '/^_parse_high_risk\(\) \{/,/^\}/' "$DS")"
  run _parse_high_risk
  [ "$(printf '%s\n' "$output" | grep -cE '^E1-S1')" -eq 1 ]
}

# --- F-011: create-ux heading_present tolerates numbered + plain H2s ---

@test "F-011: create-ux heading_present passes a numbered H2 (## 1. Personas)" {
  eval "$(awk '/^heading_present\(\) \{/,/^\}/' "$UXF")"
  cat > "$TEST_TMP/ux.md" <<'MD'
## 1. Personas
content
## 10.1 Information Architecture
content
MD
  [ "$(heading_present "$TEST_TMP/ux.md" Personas)" = "pass" ]
  [ "$(heading_present "$TEST_TMP/ux.md" 'Information Architecture')" = "pass" ]
}

@test "F-011: create-ux heading_present still passes a plain H2 (## Personas)" {
  eval "$(awk '/^heading_present\(\) \{/,/^\}/' "$UXF")"
  cat > "$TEST_TMP/ux.md" <<'MD'
## Personas
content
MD
  [ "$(heading_present "$TEST_TMP/ux.md" Personas)" = "pass" ]
}

@test "F-011: create-ux heading_present fails for an absent heading" {
  eval "$(awk '/^heading_present\(\) \{/,/^\}/' "$UXF")"
  cat > "$TEST_TMP/ux.md" <<'MD'
## Personas
content
MD
  [ "$(heading_present "$TEST_TMP/ux.md" 'Nonexistent Section')" = "fail" ]
}

@test "F-011: create-ux regex matches the sibling create-prd numbered-prefix pattern" {
  # Both finalize scripts must carry the same numeric-outline tolerance.
  grep -qF '([0-9]+(\.[0-9]+)*\.?[[:space:]]+)?' "$UXF"
  grep -qF '([0-9]+(\.[0-9]+)*\.?[[:space:]]+)?' "$PLUGIN_ROOT/skills/gaia-create-prd/scripts/finalize.sh"
}

# --- F-018 producer side: create-epics SKILL.md template instructs the epic KEY ---

@test "F-018 (producer): create-epics story template uses the epic KEY, not the name" {
  grep -qF 'Epic: {epic KEY' "$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
  grep -qF 'Field-format contract (F-017/F-018' "$PLUGIN_ROOT/skills/gaia-create-epics/SKILL.md"
}
