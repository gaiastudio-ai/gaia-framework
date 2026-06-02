#!/usr/bin/env bats
# create-story-canonical-path.bats — E79-S2
#
# Verifies that gaia-framework/plugins/gaia/skills/gaia-create-story/SKILL.md
# Step 4 has been updated to:
#   - delegate epic-slug derivation to scripts/lib/resolve-epic-slug.sh
#     (no inline awk/sed for epic-slug derivation),
#   - emit `mkdir -p` of the per-epic stories/ directory BEFORE the
#     scaffold-story.sh invocation, and
#   - write the scaffold output to the canonical nested path
#     `${IMPLEMENTATION_ARTIFACTS}/epic-${EPIC_SLUG}/stories/<key>-${SLUG}.md`,
#   - REFUSE to write the nested sibling when a legacy flat-path file
#     `${IMPLEMENTATION_ARTIFACTS}/<key>-*.md` already exists for the same key,
#     emitting a single stderr WARNING line that names BOTH paths and points
#     the operator at E79-S6 migration.
#
# Test scenarios trace back to the story's Test Scenarios table:
#   TC-CSP-1 — Single-shot canonical write (AC1, AC4, AC7)
#   TC-CSP-3 — Legacy-flat refusal (AC3)
#
# Pattern: cluster-7 SKILL.md prose-anchor pattern (see
# create-story-artifact-paths.bats). The story changes SKILL.md prose only
# — no script source under .../scripts/ is modified — so the assertions
# inspect SKILL.md content rather than invoking /gaia-create-story end-to-end.

load 'test_helper.bash'

setup() {
  common_setup
  SKILL_DIR="$SKILLS_DIR/gaia-create-story"
  SKILL_MD="$SKILL_DIR/SKILL.md"
  RESOLVER="$SCRIPTS_DIR/lib/resolve-epic-slug.sh"
  VALIDATE_CANON="$SKILL_DIR/scripts/validate-canonical-filename.sh"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Preconditions — E79-S1 deliverables present.
# ---------------------------------------------------------------------------

@test "TC-CSP-1: SKILL.md exists for gaia-create-story" {
  [ -f "$SKILL_MD" ]
}

@test "TC-CSP-1: resolve-epic-slug.sh from E79-S1 is present and executable" {
  [ -x "$RESOLVER" ]
}

# ---------------------------------------------------------------------------
# TC-CSP-1 / AC1, AC4 — Single-shot canonical write: SKILL.md Step 4 emits
# the canonical nested output path and delegates to the resolver.
# ---------------------------------------------------------------------------

@test "TC-CSP-1: SKILL.md Step 4 references resolve-epic-slug.sh (AC4)" {
  run grep -nF "resolve-epic-slug.sh" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 calls the resolver with --epic-key (AC4)" {
  # The invocation may span multiple lines (continuation backslash); grep with
  # -A2 picks up the --epic-key flag on the line following the resolver call.
  run bash -c 'grep -nE -A2 "resolve-epic-slug\\.sh" "$1" | grep -qE -- "--epic-key"' _ "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 writes to canonical nested path (AC1)" {
  # The output= line must reference epic-${EPIC_SLUG}/stories/<key>-${SLUG}.md
  run grep -nE 'output[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/epic-\$\{?EPIC_SLUG\}?/stories/' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 has zero residual flat-path output assignments (AC1)" {
  # The legacy flat output expression `--output "${IMPLEMENTATION_ARTIFACTS}/<story_key>-${SLUG}.md"`
  # MUST NOT remain in SKILL.md once Step 4 has been migrated to the nested path.
  run grep -nE -- '--output[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/<story_key>-\$\{?SLUG\}?\.md"' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 emits mkdir -p of per-epic stories dir (AC2)" {
  run grep -nE 'mkdir -p[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/epic-\$\{?EPIC_SLUG\}?/stories"' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 mkdir -p line PRECEDES scaffold-story.sh invocation (AC2)" {
  # Match the actual scaffold-story.sh INVOCATION line (begins with `$(!scripts/...`),
  # not the prose comment. The invocation form has `$(!` and `scaffold-story.sh \`.
  mkdir_line="$(grep -nE 'mkdir -p[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/epic-\$\{?EPIC_SLUG\}?/stories"' "$SKILL_MD" | head -1 | cut -d: -f1)"
  scaffold_line="$(grep -nE '!scripts/scaffold-story\.sh' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$mkdir_line" ]
  [ -n "$scaffold_line" ]
  [ "$mkdir_line" -lt "$scaffold_line" ]
}

@test "TC-CSP-1: SKILL.md Step 4 has zero residual inline awk/sed epic-slug derivation (AC4)" {
  # Inline `awk` or `sed` referencing `epic:` / `epic-slug` would mean SKILL.md
  # is re-implementing the resolver logic in prose — forbidden by ADR-074
  # deterministic-script-lift principle.
  run grep -nE 'awk[[:space:]]+.*epic:|sed[[:space:]]+.*epic-slug' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 prose names ADR-074 deterministic-script-lift (AC4)" {
  run grep -nE 'ADR-074' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 HALTs on resolver non-zero exit (AC4)" {
  # The Step 4 prose must say HALT (or equivalent) on resolver failure — no
  # silent fallback to a hardcoded slug.
  run grep -niE 'resolver.*(HALT|non-zero)|HALT.*resolver' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# TC-CSP-3 / AC3 — Legacy-flat refusal: SKILL.md Step 4 carries an explicit
# guard with all required tokens.
# ---------------------------------------------------------------------------

@test "TC-CSP-3: SKILL.md Step 4 probes for legacy flat sibling via compgen -G (AC3)" {
  run grep -nE 'compgen -G[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/\$\{?STORY_KEY\}?-\*\.md"' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-3: SKILL.md Step 4 emits REFUSED stderr WARNING (AC3)" {
  run grep -nF "REFUSED" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-3: SKILL.md Step 4 refusal message names E79-S6 migration (AC3)" {
  run grep -nF "E79-S6" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-3: SKILL.md Step 4 refusal message names BOTH the flat path and the nested path (AC3)" {
  # Refusal prose must mention both `flat` and `nested` so the operator gets
  # both paths in a single stderr line.
  run grep -niE 'flat.*nested|nested.*flat' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-3: SKILL.md Step 4 refusal HALTs non-zero (AC3)" {
  # Refusal must be a workflow-level halt (exit 1), not a finding.
  run grep -niE 'exit 1|HALT' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC7 — validate-canonical-filename.sh inspects basename only and accepts
# nested basenames unchanged. We assert the script source has not grown a
# parent-directory check that would reject the nested layout.
# ---------------------------------------------------------------------------

@test "AC7: validate-canonical-filename.sh exists" {
  [ -x "$VALIDATE_CANON" ]
}

@test "AC7: validate-canonical-filename.sh accepts a nested-path basename" {
  # Build a temp file whose basename is canonical for E79-S2 and whose parent
  # is the per-epic stories/ directory. The validator should exit 0 — it
  # inspects basename only (E63-S4 contract).
  story_key="E79-S2"
  slug="gaia-create-story-write-to-canonical-nested-path-add-legacy-flat-refusal"
  story_title='`/gaia-create-story` — write to canonical nested path; add legacy-flat refusal'
  nested_dir="$TEST_TMP/docs/implementation-artifacts/epic-E79-canonical-per-epic-story-file-layout/stories"
  mkdir -p "$nested_dir"
  nested_file="$nested_dir/${story_key}-${slug}.md"
  cat > "$nested_file" <<YAML
---
key: "$story_key"
title: "$story_title"
size: "M"
risk: "high"
sprint_id: "sprint-40"
priority_flag: null
origin: null
origin_ref: null
depends_on: ["E79-S1"]
blocks: []
traces_to: []
date: "2026-05-07"
author: "Julien Louage"
points: "5"
---
YAML

  run "$VALIDATE_CANON" --file "$nested_file"
  [ "$status" -eq 0 ]
}
