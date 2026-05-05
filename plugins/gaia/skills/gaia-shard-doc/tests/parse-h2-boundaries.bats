#!/usr/bin/env bats
# E53-S236 — Code-block-aware H2 boundary detection in gaia-shard-doc.
#
# Verifies AC1, AC2, AC3, AC4: parse-h2-boundaries.sh toggles a fenced-code
# state when it encounters a ``` line and ignores `## ` lines while inside,
# producing exactly 5 boundaries on the 5-real / 5-code-block synthetic fixture.

setup() {
  SKILL_DIR="${BATS_TEST_DIRNAME}/.."
  SCRIPT="${SKILL_DIR}/scripts/parse-h2-boundaries.sh"
  FIXTURE="${BATS_TEST_DIRNAME}/fixtures/mixed-h2-fixture.md"
}

@test "parse-h2-boundaries.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "synthetic fixture exists at expected path" {
  [ -f "$FIXTURE" ]
}

@test "AC2: produces exactly 5 boundaries on the 5-real / 5-code-block fixture" {
  run "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
  # Each boundary is a single line of "<lineno>:<heading text>".
  count=$(printf '%s\n' "$output" | grep -c '^[0-9][0-9]*:')
  [ "$count" -eq 5 ]
}

@test "AC1: ignores H2-shaped lines inside fenced code blocks" {
  run "$SCRIPT" "$FIXTURE"
  [ "$status" -eq 0 ]
  # None of the headings should mention "Fake Heading"; all five real
  # sections are titled "Real Section <N>".
  ! printf '%s\n' "$output" | grep -q "Fake Heading"
  printf '%s\n' "$output" | grep -q "Real Section One"
  printf '%s\n' "$output" | grep -q "Real Section Two"
  printf '%s\n' "$output" | grep -q "Real Section Three"
  printf '%s\n' "$output" | grep -q "Real Section Four"
  printf '%s\n' "$output" | grep -q "Real Section Five"
}

@test "AC3: matches E53-S222 reference algorithm — naked '## ' on toggled state" {
  # Ad-hoc 4-line fixture: code-block boundary toggled by ``` only — a
  # nested ``` inside a block reverts to outside-state, mirroring the
  # E53-S222 Python implementation's simple alternating toggle.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
## Outside One
```
## Inside (ignored)
```
## Outside Two
EOF
  run "$SCRIPT" "$tmp"
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -c '^[0-9][0-9]*:')
  [ "$count" -eq 2 ]
  printf '%s\n' "$output" | grep -q "Outside One"
  printf '%s\n' "$output" | grep -q "Outside Two"
  ! printf '%s\n' "$output" | grep -q "Inside"
  rm -f "$tmp"
}

@test "AC4: zero boundaries on a doc whose only H2s are all inside fences" {
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Top
Some prose.
```markdown
## Hidden A
## Hidden B
```
More prose.
EOF
  run "$SCRIPT" "$tmp"
  [ "$status" -eq 0 ]
  # grep -c returns exit 1 when no matches; tolerate that with `|| true`.
  count=$(printf '%s\n' "$output" | grep -c '^[0-9][0-9]*:' || true)
  [ "$count" -eq 0 ]
  rm -f "$tmp"
}
