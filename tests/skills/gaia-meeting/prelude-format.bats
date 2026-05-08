#!/usr/bin/env bats
# prelude-format.bats — gaia-meeting prelude format helper (E76-S2, AC4)
#
# Covers AC4 / TC-MTG-RESEARCH-1 — fixed prelude format.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/lib/prelude-format.sh"
}

@test "Pre-flight: prelude-format.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC4: emits header line '[Prelude] {Name} ({Role}) — {tokens} tokens'" {
  run "$HELPER" --name Theo --role architect --tokens 1234 \
                --sources "docs/foo.md" \
                --bullets "I know X about Y"
  [ "$status" -eq 0 ]
  first_line=$(printf '%s\n' "$output" | sed -n '1p')
  [ "$first_line" = "[Prelude] Theo (architect) — 1234 tokens" ]
}

@test "AC4: emits 'Sources consulted:' block, one per line" {
  run "$HELPER" --name Theo --role architect --tokens 100 \
                --sources "docs/a.md
docs/b.md
https://example.com/x" \
                --bullets "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sources consulted:"* ]]
  [[ "$output" == *"docs/a.md"* ]]
  [[ "$output" == *"docs/b.md"* ]]
  [[ "$output" == *"https://example.com/x"* ]]
}

@test "AC4: emits 'What I know:' block, one bullet per line" {
  run "$HELPER" --name Derek --role pm --tokens 50 \
                --sources "_memory/Derek-sidecar/decisions/d.md" \
                --bullets "claim one
claim two"
  [ "$status" -eq 0 ]
  [[ "$output" == *"What I know:"* ]]
  [[ "$output" == *"- claim one"* ]]
  [[ "$output" == *"- claim two"* ]]
}

@test "AC4: rejects missing --name" {
  run "$HELPER" --role architect --tokens 100 --sources "x" --bullets "y"
  [ "$status" -ne 0 ]
}

@test "AC4: rejects missing --tokens" {
  run "$HELPER" --name Theo --role architect --sources "x" --bullets "y"
  [ "$status" -ne 0 ]
}

@test "AC4: tokens MUST be non-negative integer" {
  run "$HELPER" --name Theo --role architect --tokens -5 --sources "x" --bullets "y"
  [ "$status" -ne 0 ]
}

@test "AC4: header order — Header, Sources, What I know" {
  run "$HELPER" --name N --role R --tokens 10 \
                --sources "src1" --bullets "b1"
  [ "$status" -eq 0 ]
  hdr_line=$(printf '%s\n' "$output" | grep -n '^\[Prelude\]' | head -1 | cut -d: -f1)
  src_line=$(printf '%s\n' "$output" | grep -n '^Sources consulted:' | head -1 | cut -d: -f1)
  wik_line=$(printf '%s\n' "$output" | grep -n '^What I know:' | head -1 | cut -d: -f1)
  [ -n "$hdr_line" ]
  [ -n "$src_line" ]
  [ -n "$wik_line" ]
  [ "$hdr_line" -lt "$src_line" ]
  [ "$src_line" -lt "$wik_line" ]
}
