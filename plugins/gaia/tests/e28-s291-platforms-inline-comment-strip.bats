#!/usr/bin/env bats
# e28-s291-platforms-inline-comment-strip.bats — the block-style platforms
# parser in surface-adapter.sh must strip an inline "# comment" so an annotated
# entry does not silently disable a surface.
#
# Defect: read_platforms() block-style branch stripped trailing whitespace but
# NOT a trailing "# comment", so "- server   # note" parsed to the literal
# "server   # note" and `--surface api` reported SKIPPED despite server being
# present. These tests exercise the REAL `--surface api` invocation (exit 0 =
# CONFIGURED, exit 2 = SKIPPED) plus the block/flow/mixed parse cases.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  ADAPTER="$REPO_ROOT/plugins/gaia/skills/gaia-test-manual/scripts/surface-adapter.sh"
  TEST_TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TEST_TMP"; }

_cfg() { printf '%s\n' "$1" > "$TEST_TMP/cfg.yaml"; }

# ---------- AC2: commented block entry → api surface CONFIGURED ----------

@test "api surface is CONFIGURED when server is listed with an inline comment (AC2)" {
  _cfg 'project_name: p
platforms:
  - web
  - server   # functional smoke target'
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/cfg.yaml"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIGURED"* ]]
}

# ---------- AC3: uncommented entry unchanged (zero-regression) ----------

@test "api surface still CONFIGURED for a plain (uncommented) server entry (AC3)" {
  _cfg 'project_name: p
platforms:
  - web
  - server'
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/cfg.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIGURED"* ]]
}

# ---------- AC3: flow-style unaffected ----------

@test "api surface CONFIGURED for flow-style platforms list (AC3)" {
  _cfg 'project_name: p
platforms: [web, server]'
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/cfg.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONFIGURED"* ]]
}

# ---------- a stack NOT present is still correctly SKIPPED ----------

@test "api surface SKIPPED when server is genuinely absent — no false CONFIGURED (AC3)" {
  _cfg 'project_name: p
platforms:
  - web'
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/cfg.yaml"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SKIPPED"* ]]
}

# ---------- the comment-strip does not let a commented-OUT entry count ----------

@test "a fully commented-out platform line is not parsed as a platform (AC1)" {
  # The line is a pure comment (no list value before the #) — must not yield a
  # bogus empty/garbage platform that accidentally matches.
  _cfg 'project_name: p
platforms:
  - web
  # - server'
  run bash "$ADAPTER" --surface api --config "$TEST_TMP/cfg.yaml"
  echo "status: $status"; echo "out: $output"
  # server is commented OUT entirely → api must be SKIPPED.
  [ "$status" -eq 2 ]
}

# ---------- direct parser check: commented entry yields the bare name ----------

@test "a dash line with only a comment does not yield an empty platform element (AC1, AC4)" {
  # "-   # note" after the dash + comment strip is empty; it must be skipped,
  # not appended as a bogus empty element producing a malformed "web,,server".
  CONFIG_PATH="$TEST_TMP/cfg.yaml"
  _cfg 'project_name: p
platforms:
  - web
  -   # just a comment
  - server'
  # shellcheck disable=SC1090
  source <(sed -n '/^read_platforms()/,/^}/p' "$ADAPTER")
  result="$(read_platforms)"
  echo "parsed: $result"
  [ "$result" = "web,server" ]
  [[ "$result" != *",,"* ]]
}

@test "read_platforms strips the inline comment, yielding the bare platform (AC1, AC4)" {
  CONFIG_PATH="$TEST_TMP/cfg.yaml"
  _cfg 'project_name: p
platforms:
  - web
  - server   # note
  - ios'
  # shellcheck disable=SC1090
  source <(sed -n '/^read_platforms()/,/^}/p' "$ADAPTER")
  result="$(read_platforms)"
  echo "parsed: $result"
  [ "$result" = "web,server,ios" ]
}
