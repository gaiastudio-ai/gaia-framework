#!/usr/bin/env bats
# AF-2026-05-27-2 — val-sidecar-write.sh routes on PROJECT LAYOUT, not on whether
# the .gaia/memory/ subdir already exists (Test04 follow-up: a project-root
# _memory/validator-sidecar/decision-log.md leaked because the first sidecar
# write of a run fired before .gaia/memory/ was mkdir'd, so the existence-probe
# fell through to the legacy _memory/ tree on a .gaia/-layout project).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WRITER="$PLUGIN_ROOT/scripts/val-sidecar-write.sh"
}

teardown() { common_teardown; }

_write() {
  # $1 = --root dir, $2 = input-id
  bash "$WRITER" \
    --command-name "/gaia-triage-findings" \
    --input-id "$2" \
    --sprint-id "sprint-1" \
    --decision-payload '{"verdict":"recorded","findings":[],"artifact_path":".gaia/artifacts/x.md"}' \
    --root "$1"
}

@test ".gaia/ tree present but memory subdir absent → writes to .gaia/memory/ (NOT _memory/)" {
  local root="$TEST_TMP/p1"
  mkdir -p "$root/.gaia/config"   # .gaia layout, but NO .gaia/memory/ yet
  run _write "$root" "t-001"
  [ "$status" -eq 0 ]
  [ -f "$root/.gaia/memory/validator-sidecar/decision-log.md" ]
  # The exact Test04 bug: a stray legacy-tree file must NOT be created.
  [ ! -f "$root/_memory/validator-sidecar/decision-log.md" ]
}

@test "bare root (no .gaia/, no _memory/) → defaults to canonical .gaia/memory/" {
  local root="$TEST_TMP/p2"
  mkdir -p "$root"
  run _write "$root" "t-002"
  [ "$status" -eq 0 ]
  [ -f "$root/.gaia/memory/validator-sidecar/decision-log.md" ]
  [ ! -f "$root/_memory/validator-sidecar/decision-log.md" ]
}

@test "even a pre-existing _memory/ is IGNORED; writer uses .gaia/memory/" {
  # The legacy _memory/ arm was removed (ADR-111, .gaia/ is the only tree). Even
  # when a stray _memory/ tree exists, the writer targets .gaia/memory/ and does
  # NOT append to the legacy file.
  local root="$TEST_TMP/p3"
  mkdir -p "$root/_memory/validator-sidecar"
  printf '# Val Validator — Decision Log\n\n' > "$root/_memory/validator-sidecar/decision-log.md"
  run _write "$root" "t-003"
  [ "$status" -eq 0 ]
  grep -q 't-003' "$root/.gaia/memory/validator-sidecar/decision-log.md"
  ! grep -q 't-003' "$root/_memory/validator-sidecar/decision-log.md"
}

@test ".gaia/ AND legacy _memory/ both present → writes .gaia/memory/ only" {
  local root="$TEST_TMP/p4"
  mkdir -p "$root/.gaia/config" "$root/_memory/validator-sidecar"
  printf '# Val Validator — Decision Log\n\n' > "$root/_memory/validator-sidecar/decision-log.md"
  run _write "$root" "t-004"
  [ "$status" -eq 0 ]
  grep -q 't-004' "$root/.gaia/memory/validator-sidecar/decision-log.md"
  # the legacy file must NOT receive the new entry.
  ! grep -q 't-004' "$root/_memory/validator-sidecar/decision-log.md"
}

@test "writer routes to .gaia/memory unconditionally (no _memory arm, no subdir probe)" {
  # AF-2026-05-27-3: the transitional layout probe AND the legacy _memory arm are
  # both gone — the writer hardcodes the canonical .gaia/memory/ target.
  ! grep -qF 'if [ -d "$REAL_ROOT/.gaia/memory" ]; then' "$WRITER"
  ! grep -qE 'DECISION_LOG="\$REAL_ROOT/_memory' "$WRITER"
  grep -qF 'DECISION_LOG="$REAL_ROOT/.gaia/memory/validator-sidecar/decision-log.md"' "$WRITER"
}

# --- cross-writer hygiene detector in memory-loader.sh ---

@test "memory-loader warns when a stray _memory/ coexists with .gaia/memory/" {
  local ml="$PLUGIN_ROOT/scripts/memory-loader.sh"
  local root="$TEST_TMP/hy1"
  mkdir -p "$root/.gaia/memory" "$root/_memory"
  run env MEMORY_PATH="$root/.gaia/memory" bash -c '
    eval "$(awk "/^_gaia_stray_legacy_memory_warn\\(\\) \\{/,/^}/" "'"$ml"'")"
    _gaia_stray_legacy_memory_warn 2>&1'
  printf '%s\n' "$output" | grep -qF 'a project-root _memory/ tree coexists with the canonical .gaia/memory/'
}

@test "memory-loader is silent on a clean .gaia project (no stray _memory/)" {
  local ml="$PLUGIN_ROOT/scripts/memory-loader.sh"
  local root="$TEST_TMP/hy2"
  mkdir -p "$root/.gaia/memory"
  run env MEMORY_PATH="$root/.gaia/memory" bash -c '
    eval "$(awk "/^_gaia_stray_legacy_memory_warn\\(\\) \\{/,/^}/" "'"$ml"'")"
    _gaia_stray_legacy_memory_warn 2>&1'
  [ -z "$output" ]
}
