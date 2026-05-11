#!/usr/bin/env bats
# check-sub-shard-conflict.bats — TC-MSS-SUBSHARD-6..9 + TC-MSS-SUBSHARD-NEW
# coverage for the /gaia-shard-doc sub-shard preservation guard (E53-S250).
#
# Story: E53-S250 (FR-453, AF-2026-05-10-5).
#
# The helper is a pre-emission gate: exit 0 = safe to write, exit 2 =
# preserve (refusal advisory), exit 1 = usage error. Per AC10 there is NO
# `--force-destroy` flag; refusal is absolute.
#
# Channels verified per AC11: stdout, stderr WARNING, summary-file line.
# Detection gate per AC12 counts CONTENT shards only (`[0-9][0-9]-*.md`);
# meta-file-only directories are treated as safe.

setup() {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/check-sub-shard-conflict.sh"
  TEST_TMP="$BATS_TEST_TMPDIR/check-sub-shard-conflict-$$"
  mkdir -p "$TEST_TMP"
}
teardown() {
  if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP" 2>/dev/null || true
  fi
}

# ---------- TC-MSS-SUBSHARD-6: sibling dir absent -> exit 0 (safe) ----------

@test "TC-MSS-SUBSHARD-6: sibling dir absent -> exit 0 (safe to write)" {
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 0 ]
  # No preserve signal on stdout.
  [ -z "$output" ]
}

# ---------- TC-MSS-SUBSHARD-7: sibling dir with content shards -> exit 2 -----

@test "TC-MSS-SUBSHARD-7: sibling dir with content shard fires preserve (exit 2)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  touch "$TEST_TMP/04-functional-requirements/04-01-fr-001.md"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 2 ]
  # AC11 channel 1: stdout preserve line.
  [[ "$output" == *"preserved: 04-functional-requirements"* ]]
  [[ "$output" == *"sub-shard directory"* ]]
}

@test "TC-MSS-SUBSHARD-7: stderr WARNING channel fires (AC11 channel 2)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  touch "$TEST_TMP/04-functional-requirements/04-01-fr-001.md"
  # `run --separate-stderr` populates $stderr separately.
  run --separate-stderr "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"WARNING: preserved: 04-functional-requirements"* ]]
}

@test "TC-MSS-SUBSHARD-7: --summary-file appends preserve line (AC11 channel 3)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  touch "$TEST_TMP/04-functional-requirements/04-01-fr-001.md"
  local sf="$TEST_TMP/summary.txt"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP" --summary-file "$sf"
  [ "$status" -eq 2 ]
  [ -f "$sf" ]
  run grep -F "Preserved sub-shards: 04-functional-requirements" "$sf"
  [ "$status" -eq 0 ]
}

# ---------- TC-MSS-SUBSHARD-8: byte-equality on sibling directory ----------

@test "TC-MSS-SUBSHARD-8: sibling directory is byte-identical pre/post run (AC4)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  echo "content of fr-001" > "$TEST_TMP/04-functional-requirements/04-01-fr-001.md"
  echo "content of fr-002" > "$TEST_TMP/04-functional-requirements/04-02-fr-002.md"
  echo "preamble" > "$TEST_TMP/04-functional-requirements/_preamble.md"
  # Snapshot recursive sha256 manifest BEFORE the run.
  pre="$(find "$TEST_TMP/04-functional-requirements" -type f -exec shasum -a 256 {} \; 2>/dev/null | sort)"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 2 ]
  # Snapshot after.
  post="$(find "$TEST_TMP/04-functional-requirements" -type f -exec shasum -a 256 {} \; 2>/dev/null | sort)"
  [ "$pre" = "$post" ]
}

# ---------- TC-MSS-SUBSHARD-9: flat layout (no sibling dirs) ---------------

@test "TC-MSS-SUBSHARD-9: no sibling dir for any slug -> exit 0 across slugs (AC6 flat-layout)" {
  # Multi-slug invocation regression-guard: a flat layout has no sibling
  # directories at all. Each slug check independently returns exit 0.
  for slug in 01-overview 02-goals 03-requirements 04-functional-requirements; do
    run "$SCRIPT" "$slug" "$TEST_TMP"
    [ "$status" -eq 0 ]
  done
}

# ---------- TC-MSS-SUBSHARD-NEW: AC12 — meta-only directory is safe -------

@test "TC-MSS-SUBSHARD-NEW(a): sibling with only index.md + _preamble.md -> exit 0 (safe)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  echo "index" > "$TEST_TMP/04-functional-requirements/index.md"
  echo "preamble" > "$TEST_TMP/04-functional-requirements/_preamble.md"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 0 ]
}

@test "TC-MSS-SUBSHARD-NEW(b): sibling with index + _preamble + 1 content shard -> exit 2 (refuse)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  echo "index" > "$TEST_TMP/04-functional-requirements/index.md"
  echo "preamble" > "$TEST_TMP/04-functional-requirements/_preamble.md"
  echo "fr-001" > "$TEST_TMP/04-functional-requirements/04-01-fr-001.md"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 2 ]
}

# ---------- AC10: refusal is absolute — no --force-destroy flag ------------

@test "AC10: --force-destroy flag is rejected as unknown (refusal is absolute)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  touch "$TEST_TMP/04-functional-requirements/04-01-fr-001.md"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP" --force-destroy
  [ "$status" -eq 1 ]
}

# ---------- Edge cases: empty sibling dir -> safe ---------------------------

@test "edge: empty sibling dir -> exit 0 (safe — no content shards)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 0 ]
}

# ---------- Edge cases: non-numeric-prefix file is ignored ----------------

@test "edge: sibling with only non-numeric-prefix .md files -> exit 0 (no canonical content)" {
  mkdir -p "$TEST_TMP/04-functional-requirements"
  echo "draft" > "$TEST_TMP/04-functional-requirements/draft-notes.md"
  echo "scratch" > "$TEST_TMP/04-functional-requirements/scratch.md"
  run "$SCRIPT" "04-functional-requirements" "$TEST_TMP"
  [ "$status" -eq 0 ]
}

# ---------- Usage errors --------------------------------------------------

@test "usage: missing slug arg -> exit 1" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "usage: missing out_dir arg -> exit 1" {
  run "$SCRIPT" "04-functional-requirements"
  [ "$status" -eq 1 ]
}

@test "usage: defensive — passing slug with .md extension is auto-stripped" {
  # Caller accidentally passes "04-functional-requirements.md" — helper
  # auto-strips and treats it as the bare slug.
  mkdir -p "$TEST_TMP/04-functional-requirements"
  touch "$TEST_TMP/04-functional-requirements/04-01-fr-001.md"
  run "$SCRIPT" "04-functional-requirements.md" "$TEST_TMP"
  [ "$status" -eq 2 ]
  [[ "$output" == *"preserved: 04-functional-requirements"* ]]
}
