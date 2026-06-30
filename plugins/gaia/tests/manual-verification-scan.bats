#!/usr/bin/env bats
# manual-verification-scan.bats — unit coverage for the read-only
# manual_verification frontmatter scan helper. Sources the library and drives
# each public function directly (mverify_read / mverify_enabled /
# mverify_annotate / mverify_scan_keys), so the public-function coverage gate
# recognizes them and the fail-safe contract is asserted at the function level.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="$REPO_ROOT/plugins/gaia/scripts/manual-verification-scan.sh"
  TMP="$(mktemp -d)"
  # Source the library to expose its public functions in this shell.
  # shellcheck source=/dev/null
  source "$LIB"
}

teardown() { rm -rf "$TMP"; }

_story() {
  # _story <path> <manual_verification-value-or-empty>
  local path="$1" val="$2"
  mkdir -p "$(dirname "$path")"
  if [ -n "$val" ]; then
    printf -- '---\nkey: "X"\nmanual_verification: %s\n---\n# Story\n' "$val" > "$path"
  else
    printf -- '---\nkey: "X"\n---\n# Story\n' > "$path"
  fi
}

# ---------- mverify_read ----------

@test "mverify_read returns the verbatim flag value" {
  _story "$TMP/t.md" "true"
  run mverify_read "$TMP/t.md"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "mverify_read returns empty for an absent flag" {
  _story "$TMP/t.md" ""
  run mverify_read "$TMP/t.md"
  [ -z "$output" ]
}

@test "mverify_read strips an unquoted trailing comment on the value" {
  _story "$TMP/t.md" "true  # user-facing"
  run mverify_read "$TMP/t.md"
  [ "$output" = "true" ]
}

# ---------- mverify_enabled (fail-safe) ----------

@test "mverify_enabled is true only for the literal true" {
  _story "$TMP/t.md" "true"
  run mverify_enabled "$TMP/t.md"
  [ "$status" -eq 0 ]
}

@test "mverify_enabled is false for false / absent / non-literal-true (fail-safe)" {
  _story "$TMP/f.md" "false";  run mverify_enabled "$TMP/f.md";  [ "$status" -ne 0 ]
  _story "$TMP/a.md" "";       run mverify_enabled "$TMP/a.md";  [ "$status" -ne 0 ]
  _story "$TMP/u.md" "TRUE";   run mverify_enabled "$TMP/u.md";  [ "$status" -ne 0 ]
  _story "$TMP/o.md" "1";      run mverify_enabled "$TMP/o.md";  [ "$status" -ne 0 ]
}

# ---------- mverify_annotate ----------

@test "mverify_annotate prints the annotation only when enabled" {
  _story "$TMP/t.md" "true"
  run mverify_annotate "$TMP/t.md"
  [ "$output" = "[manual_verification]" ]

  _story "$TMP/f.md" "false"
  run mverify_annotate "$TMP/f.md"
  [ -z "$output" ]
}

# ---------- mverify_scan_keys ----------

@test "mverify_scan_keys lists only the keys whose story carries the flag" {
  mkdir -p "$TMP/impl/epic-E1-x/E1-S1-a" "$TMP/impl/epic-E1-x/E1-S2-b" "$TMP/impl/epic-E1-x/E1-S3-c"
  _story "$TMP/impl/epic-E1-x/E1-S1-a/story.md" "true"
  _story "$TMP/impl/epic-E1-x/E1-S2-b/story.md" "false"
  _story "$TMP/impl/epic-E1-x/E1-S3-c/story.md" ""
  run mverify_scan_keys "$TMP/impl" E1-S1 E1-S2 E1-S3
  [ "$status" -eq 0 ]
  [[ "$output" == *"E1-S1"* ]]
  [[ "$output" != *"E1-S2"* ]]
  [[ "$output" != *"E1-S3"* ]]
}

@test "mverify_scan_keys skips keys with no resolvable story file" {
  mkdir -p "$TMP/impl"
  run mverify_scan_keys "$TMP/impl" E9-S9
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
