#!/usr/bin/env bats
# create-story-canonical-path.bats — E79-S2
#
# Verifies that gaia-public/plugins/gaia/skills/gaia-create-story/SKILL.md
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

@test "TC-CSP-1: SKILL.md Step 4 writes to the canonical per-story path (AC1)" {
  # The output= line must reference the per-story directory form
  # ${STORY_DIR}/story.md, where STORY_DIR = ${IMPLEMENTATION_ARTIFACTS}/${EPIC_DIR}/<story_key>-${SLUG}.
  # The `stories/` middle level was dropped: the per-story dir carries the key
  # and the basename is the literal story.md.
  run grep -nE -- '--output[[:space:]]+"\$\{?STORY_DIR\}?/story\.md"' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # And STORY_DIR is defined as the per-story nested path under EPIC_DIR.
  run grep -nE 'STORY_DIR="\$\{?IMPLEMENTATION_ARTIFACTS\}?/\$\{?EPIC_DIR\}?/' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 has zero residual flat-path output assignments (AC1)" {
  # The legacy flat output expression `--output "${IMPLEMENTATION_ARTIFACTS}/<story_key>-${SLUG}.md"`
  # MUST NOT remain in SKILL.md once Step 4 has been migrated to the per-story path.
  run grep -nE -- '--output[[:space:]]+"\$\{?IMPLEMENTATION_ARTIFACTS\}?/<story_key>-\$\{?SLUG\}?\.md"' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 has zero residual stories/-middle-level output assignments (AC1)" {
  # The superseded nested form with a `stories/` middle level
  # (epic-${EPIC_SLUG}/stories/<key>-${SLUG}.md) MUST NOT remain as a NEW write
  # target now that the per-story-dir layout replaced it (it survives only as a
  # read-only fallback, never an --output target).
  run grep -nE -- '--output[[:space:]]+"[^"]*/stories/' "$SKILL_MD"
  [ "$status" -ne 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 emits mkdir -p of the per-story dir + reviews subdir (AC2)" {
  run grep -nE 'mkdir -p[[:space:]]+"\$\{?STORY_DIR\}?/reviews"' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-1: SKILL.md Step 4 mkdir -p line PRECEDES scaffold-story.sh invocation (AC2)" {
  # The per-story-dir mkdir must precede the scaffold invocation so the output
  # directory exists before the skeleton is written.
  mkdir_line="$(grep -nE 'mkdir -p[[:space:]]+"\$\{?STORY_DIR\}?/reviews"' "$SKILL_MD" | head -1 | cut -d: -f1)"
  # Anchor to the actual scaffold INVOCATION (a `!`-prefixed run line), not a
  # prose comment that merely names the script.
  scaffold_line="$(grep -nE '!.*scaffold-story\.sh' "$SKILL_MD" | head -1 | cut -d: -f1)"
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

@test "TC-CSP-1: SKILL.md Step 4 delegates scaffolding to the deterministic script (AC4)" {
  # Assert the deterministic-script-lift behavior, not an internal identifier
  # (scrubbed from published source).
  run grep -niE 'scaffold-story\.sh|deterministic skeleton|delegated to' "$SKILL_MD"
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

@test "TC-CSP-3: SKILL.md Step 4 probes for a legacy flat sibling by the story-key glob (AC3)" {
  # The probe globs for ${IMPLEMENTATION_ARTIFACTS}/${STORY_KEY}-*.md (the legacy
  # flat sibling). The mechanism is a positional-param glob expansion
  # (`set -- "${IMPLEMENTATION_ARTIFACTS}/${STORY_KEY}-"*.md`), which is the
  # portable form; accept either that or a compgen -G probe of the same glob.
  run grep -nE '(set -- |compgen -G[[:space:]]+)"\$\{?IMPLEMENTATION_ARTIFACTS\}?/\$\{?STORY_KEY\}?-"?\*\.md' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-3: SKILL.md Step 4 emits REFUSED stderr WARNING (AC3)" {
  run grep -nF "REFUSED" "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "TC-CSP-3: SKILL.md Step 4 refusal message points to the layout migration (AC3)" {
  # Assert the refusal directs the operator to run the migration, not an
  # internal story key (scrubbed from published source).
  run grep -niE 'REFUSED.*migration|layout migration|migration first' "$SKILL_MD"
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
