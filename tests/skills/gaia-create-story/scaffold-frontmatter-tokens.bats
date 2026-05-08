#!/usr/bin/env bats
# scaffold-frontmatter-tokens.bats — E80-S1 Cluster A (TC-CSF-1..TC-CSF-6)
#
# Validates that scaffold-story.sh substitutes all 14 caller-supplied
# frontmatter fields into story-template.md, producing a story file whose
# `origin`, `origin_ref`, `depends_on`, `blocks`, `traces_to` fields are
# populated (NOT defaults from the template) and whose `points` is an
# integer YAML scalar (NOT a quoted string).
#
# Test cases:
#   TC-CSF-1: --depends-on / --blocks survive scaffold (arrays land non-empty)
#   TC-CSF-2: --origin / --origin-ref survive scaffold (strings land non-null)
#   TC-CSF-3: omitted --origin preserves origin: null default
#   TC-CSF-4: points lands as integer YAML scalar (no quotes)
#   TC-CSF-5: re-run scaffold on existing story is byte-identical (ADR-074 C3)
#   TC-CSF-6: 5-parallel-fan-out: every sibling preserves all five fields
#
# Usage:
#   bats tests/skills/gaia-create-story/scaffold-frontmatter-tokens.bats
#
# Dependencies: bats-core 1.10+

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-create-story"
  SCAFFOLD="$SKILL_DIR/scripts/scaffold-story.sh"
  TEMPLATE="$SKILL_DIR/story-template.md"

  TEST_TMP="$BATS_TEST_TMPDIR/scaffold-tokens-$$"
  mkdir -p "$TEST_TMP/out"
}

# Build a frontmatter YAML block matching generate-frontmatter.sh's emitted
# format. Args: story_key title origin origin_ref depends_on blocks traces_to
build_frontmatter() {
  local key="$1" title="$2" origin="$3" origin_ref="$4"
  local depends="$5" blocks="$6" traces="$7"
  local origin_yaml="null" origin_ref_yaml="null"
  if [ "$origin" != "null" ]; then origin_yaml="\"$origin\""; fi
  if [ "$origin_ref" != "null" ]; then origin_ref_yaml="\"$origin_ref\""; fi
  cat <<EOF
---
template: 'story'
version: 1.4.0
used_by: ['create-story']
key: "$key"
title: "$title"
epic: "E99"
status: backlog
priority: "P1"
size: "M"
points: 5
risk: "medium"
sprint_id: null
priority_flag: null
origin: $origin_yaml
origin_ref: $origin_ref_yaml
depends_on: $depends
blocks: $blocks
traces_to: $traces
date: "2026-05-07"
author: "Test Author"
---
EOF
}

# ---------- Pre-flight ----------

@test "Pre-flight: scaffold-story.sh is executable" {
  [ -x "$SCAFFOLD" ]
}

@test "Pre-flight: story-template.md exists" {
  [ -f "$TEMPLATE" ]
}

# ---------- TC-CSF-1: depends_on / blocks survive scaffold ----------

@test "TC-CSF-1: --depends-on / --blocks survive scaffold (arrays land non-empty)" {
  fm="$(build_frontmatter "E99-S1" "Test story" "null" "null" \
        '["E79-S1"]' '["E79-S6", "E79-S7"]' '[]')"
  out="$TEST_TMP/out/E99-S1.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]
  [ -f "$out" ]

  # depends_on must be the non-empty flow array, not the literal default `[]`.
  run grep -E '^depends_on: \["E79-S1"\]' "$out"
  [ "$status" -eq 0 ]

  # blocks must contain both keys.
  run grep -E '^blocks: \["E79-S6", "E79-S7"\]' "$out"
  [ "$status" -eq 0 ]
}

# ---------- TC-CSF-2: origin / origin_ref survive scaffold ----------

@test "TC-CSF-2: --origin / --origin-ref survive scaffold (strings land non-null)" {
  fm="$(build_frontmatter "E99-S2" "Test story" \
        "AF-2026-05-07-3" "Work Item 4.2" '[]' '[]' '[]')"
  out="$TEST_TMP/out/E99-S2.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]

  run grep -E '^origin: "AF-2026-05-07-3"' "$out"
  [ "$status" -eq 0 ]

  run grep -E '^origin_ref: "Work Item 4.2"' "$out"
  [ "$status" -eq 0 ]
}

# ---------- TC-CSF-3: origin: null default preserved ----------

@test "TC-CSF-3: omitted --origin preserves origin: null default" {
  fm="$(build_frontmatter "E99-S3" "Test story" "null" "null" '[]' '[]' '[]')"
  out="$TEST_TMP/out/E99-S3.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]

  run grep -E '^origin: null$' "$out"
  [ "$status" -eq 0 ]

  run grep -E '^origin_ref: null$' "$out"
  [ "$status" -eq 0 ]
}

# ---------- TC-CSF-4: points integer scalar ----------

@test "TC-CSF-4: points lands as integer YAML scalar (no quotes)" {
  fm="$(build_frontmatter "E99-S4" "Test story" "null" "null" '[]' '[]' '[]')"
  out="$TEST_TMP/out/E99-S4.md"
  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]

  # points: 5 (integer) — exact match, no quotes around the value.
  run grep -E '^points: 5$' "$out"
  [ "$status" -eq 0 ]

  # Negative assertion: must NOT match the quoted form.
  run grep -E '^points: "5"$' "$out"
  [ "$status" -ne 0 ]
}

# ---------- TC-CSF-5: idempotency (ADR-074 C3) ----------

@test "TC-CSF-5: re-run scaffold on existing story is byte-identical" {
  fm="$(build_frontmatter "E99-S5" "Test story" \
        "AF-2026-05-07-5" "Work Item 5" \
        '["E99-S1"]' '["E99-S2"]' '["TC-1", "TC-2"]')"
  out="$TEST_TMP/out/E99-S5.md"

  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]
  hash1="$(shasum -a 256 "$out" | awk '{print $1}')"

  run "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm"
  [ "$status" -eq 0 ]
  hash2="$(shasum -a 256 "$out" | awk '{print $1}')"

  [ "$hash1" = "$hash2" ]
}

# ---------- TC-CSF-6: 5-parallel-fan-out preserves all fields ----------

@test "TC-CSF-6: 5-parallel-fan-out: every sibling preserves all five fields" {
  # Spawn 5 parallel scaffold invocations, each with distinct depends_on,
  # blocks, traces_to, origin, origin_ref. After all complete, every output
  # MUST contain its own slot's values (no cross-contamination, no field loss).
  pids=()
  for i in 1 2 3 4 5; do
    fm="$(build_frontmatter "E99-S$i" "Sibling $i" \
          "AF-2026-05-07-$i" "Work Item $i" \
          "[\"E99-D$i\"]" "[\"E99-B$i\"]" "[\"TC-X$i\"]")"
    out="$TEST_TMP/out/E99-S$i.md"
    "$SCAFFOLD" --template "$TEMPLATE" --output "$out" --frontmatter "$fm" \
      >"$TEST_TMP/out/E99-S$i.stdout" 2>"$TEST_TMP/out/E99-S$i.stderr" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  for i in 1 2 3 4 5; do
    out="$TEST_TMP/out/E99-S$i.md"
    [ -f "$out" ]
    run grep -E "^origin: \"AF-2026-05-07-$i\"" "$out"
    [ "$status" -eq 0 ]
    run grep -E "^origin_ref: \"Work Item $i\"" "$out"
    [ "$status" -eq 0 ]
    run grep -E "^depends_on: \\[\"E99-D$i\"\\]" "$out"
    [ "$status" -eq 0 ]
    run grep -E "^blocks: \\[\"E99-B$i\"\\]" "$out"
    [ "$status" -eq 0 ]
    run grep -E "^traces_to: \\[\"TC-X$i\"\\]" "$out"
    [ "$status" -eq 0 ]
  done
}
