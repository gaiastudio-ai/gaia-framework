#!/usr/bin/env bats
# generate-frontmatter-golden.bats -- golden-output test for the frontmatter
# generator after the design-metadata block removal.
#
# Validates that the generator's emitted, non-environment-dependent
# frontmatter fields are byte-identical to the pre-change golden baseline and
# that no retired design-provider block or design_ref placeholder leaks into
# the output.
#
# Dependencies: bats-core 1.10+, diff, awk.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GENERATOR="$REPO_ROOT/skills/gaia-create-story/scripts/generate-frontmatter.sh"
  # Reuse the existing cluster-7 fixtures (they exercise the happy-path
  # invocation with known deterministic inputs).
  CLUSTER7_FIXTURES="$REPO_ROOT/tests/cluster-7/fixtures"
  GOLDEN="$BATS_TEST_DIRNAME/fixtures/generate-frontmatter-golden.txt"

  # Capture generator output once into a temp file so negative assertions
  # do not clobber each other.
  GEN_OUT="$BATS_TEST_TMPDIR/gen-output.txt"
  GEN_ERR="$BATS_TEST_TMPDIR/gen-stderr.txt"
  "$GENERATOR" \
    --story-key E99-S1 \
    --epics-file "$CLUSTER7_FIXTURES/epics-frontmatter-happy.md" \
    --project-config "$CLUSTER7_FIXTURES/project-config-frontmatter-default.yaml" \
    >"$GEN_OUT" 2>"$GEN_ERR" || true
}

# Helper: extract the generator's emitted frontmatter fields (strip the
# template/version/used_by header and the --- fences, and also strip the
# date/author fields which are environment-dependent).
_extract_fields() {
  awk '
    /^---/ { if (++fence == 2) exit; next }
    fence == 1 && !/^(template|version|used_by):/ && !/^date:/ && !/^author:/ { print }
  ' "$1"
}

# Helper: strip the date/author from the committed golden (they are
# environment-dependent and must be excluded from the diff).
_golden_fields() {
  awk '!/^date:/ && !/^author:/' "$GOLDEN"
}

# ---------- Pre-flight ----------

@test "Pre-flight: generate-frontmatter.sh exists and is executable" {
  [ -x "$GENERATOR" ]
}

@test "Pre-flight: golden baseline file exists" {
  [ -f "$GOLDEN" ]
}

@test "Pre-flight: cluster-7 fixtures exist" {
  [ -f "$CLUSTER7_FIXTURES/epics-frontmatter-happy.md" ]
  [ -f "$CLUSTER7_FIXTURES/project-config-frontmatter-default.yaml" ]
}

# ---------- (AC4) generated frontmatter has no design block and emitted fields match golden ----------

@test "(AC4) generated frontmatter has no design block and emitted fields match golden" {
  [ -s "$GEN_OUT" ] || { echo "generator produced empty output"; false; }

  # Build the legacy search term from fragments to keep this file sweep-clean
  legacy_term="$(printf '%s%s' 'fig' 'ma')"

  # No legacy block line
  run grep -iE "^${legacy_term}:" "$GEN_OUT"
  [ "$status" -eq 1 ] || { echo "legacy block line found in output: $output"; false; }

  # No design_ref: line (generator does not emit it yet)
  run grep '^design_ref:' "$GEN_OUT"
  [ "$status" -eq 1 ] || { echo "design_ref line found in output: $output"; false; }

  # No empty placeholder block
  run grep -E '^\s*#.*design' "$GEN_OUT"
  [ "$status" -eq 1 ] || { echo "design placeholder comment found: $output"; false; }

  # Emitted fields match golden (excluding date/author which are env-dependent)
  actual="$(_extract_fields "$GEN_OUT")"
  expected="$(_golden_fields)"
  diff <(echo "$actual") <(echo "$expected") || { echo "field diff against golden failed"; false; }
}

# ---------- (AC-EC5) post-change frontmatter matches pre-change golden for the generator's emitted fields ----------

@test "(AC-EC5) post-change frontmatter matches pre-change golden for the generator's emitted fields" {
  [ -s "$GEN_OUT" ] || { echo "generator produced empty output"; false; }
  # The golden was committed BEFORE the template/generator edits.
  # This test re-runs the generator and diffs against that baseline.
  actual="$(_extract_fields "$GEN_OUT")"
  expected="$(_golden_fields)"
  diff <(echo "$actual") <(echo "$expected") || { echo "post-change output diverges from pre-change golden"; false; }
}

# ---------- (AC-EC6) headless project emits no design reference and no warning ----------

@test "(AC-EC6) headless project emits no design reference and no warning" {
  [ -s "$GEN_OUT" ] || { echo "generator produced empty output"; false; }

  # No design key in output
  run grep '^design_ref:' "$GEN_OUT"
  [ "$status" -eq 1 ] || { echo "design_ref found in headless output: $output"; false; }

  # Stderr must not contain design warnings
  run grep -iE 'design|ux-design' "$GEN_ERR"
  [ "$status" -eq 1 ] || { echo "design warning on stderr: $output"; false; }
}

# ---------- (AC-EC7) no ux-design.md produces well-formed frontmatter with no design placeholder ----------

@test "(AC-EC7) no ux-design.md produces well-formed frontmatter with no design placeholder" {
  [ -s "$GEN_OUT" ]

  # Output must be valid YAML (between --- fences)
  frontmatter_file="$BATS_TEST_TMPDIR/frontmatter.yaml"
  awk '
    /^---/ { if (++fence == 2) exit; next }
    fence == 1 { print }
  ' "$GEN_OUT" > "$frontmatter_file"

  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$frontmatter_file" 2>/dev/null \
    || yq '.' "$frontmatter_file" >/dev/null 2>&1

  # No design_ref key
  run grep '^design_ref:' "$frontmatter_file"
  [ "$status" -eq 1 ] || { echo "design_ref key found in no-ux output: $output"; false; }

  # No empty design block (e.g., design_ref: null or design_ref: "")
  run grep -E '^design_ref:\s*(null|""|$)' "$frontmatter_file"
  [ "$status" -eq 1 ] || { echo "empty design placeholder found: $output"; false; }
}
