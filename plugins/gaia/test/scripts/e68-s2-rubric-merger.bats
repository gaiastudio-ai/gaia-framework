#!/usr/bin/env bats
# e68-s2-rubric-merger.bats — RFC 7396 JSON-merge-patch tests for rubric-merger.sh
#
# Story: E68-S2 — Layered rubric loader + rubric-merger.sh + rubric.schema.json
#                 + /gaia-validate-rubric + /gaia-config-validate
#
# Covers AC2 (RFC 7396 semantics) + AC3 (script presence) + AC4 (determinism).

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
MERGER="$SCRIPTS_DIR/rubric-merger.sh"

setup() {
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# ---------- AC3: rubric-merger.sh exists at canonical path ----------

@test "AC3: rubric-merger.sh exists at canonical path" {
  [ -f "$MERGER" ]
}

@test "AC3: rubric-merger.sh is executable" {
  [ -x "$MERGER" ]
}

@test "AC3: rubric-merger.sh uses set -euo pipefail" {
  run grep -c "set -euo pipefail" "$MERGER"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ---------- AC2: RFC 7396 null-delete ----------

@test "AC2 / TC-RSV2-MERGE-01: null deletes a key from merged output" {
  cat >"$TMP_DIR/base.json" <<'EOF'
{"rules": {"r1": {"severity": "High"}, "r2": {"severity": "Low"}}}
EOF
  cat >"$TMP_DIR/layer.json" <<'EOF'
{"rules": {"r1": null}}
EOF
  run "$MERGER" "$TMP_DIR/base.json" "$TMP_DIR/layer.json"
  [ "$status" -eq 0 ]
  # r1 should be deleted, r2 should remain
  run bash -c "$MERGER '$TMP_DIR/base.json' '$TMP_DIR/layer.json' | jq -e '.rules | has(\"r1\") | not'"
  [ "$status" -eq 0 ]
  run bash -c "$MERGER '$TMP_DIR/base.json' '$TMP_DIR/layer.json' | jq -e '.rules.r2.severity == \"Low\"'"
  [ "$status" -eq 0 ]
}

# ---------- AC2: RFC 7396 object-recursive-merge ----------

@test "AC2 / TC-RSV2-MERGE-02: objects merge recursively" {
  cat >"$TMP_DIR/base.json" <<'EOF'
{"a": {"b": 1, "c": 2}}
EOF
  cat >"$TMP_DIR/layer.json" <<'EOF'
{"a": {"c": 3, "d": 4}}
EOF
  run bash -c "$MERGER '$TMP_DIR/base.json' '$TMP_DIR/layer.json' | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":{"b":1,"c":3,"d":4}}' ]
}

# ---------- AC2: RFC 7396 array-replace ----------

@test "AC2 / TC-RSV2-MERGE-03: arrays are replaced (not concatenated)" {
  cat >"$TMP_DIR/base.json" <<'EOF'
{"items": [1, 2, 3]}
EOF
  cat >"$TMP_DIR/layer.json" <<'EOF'
{"items": [4, 5]}
EOF
  run bash -c "$MERGER '$TMP_DIR/base.json' '$TMP_DIR/layer.json' | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"items":[4,5]}' ]
}

# ---------- AC4: determinism (byte-identical output) ----------

@test "AC4 / TC-RSV2-MERGE-05: two runs on same inputs produce byte-identical output" {
  cat >"$TMP_DIR/a.json" <<'EOF'
{"z": 1, "a": {"y": 2, "b": 3}, "m": [1,2,3]}
EOF
  cat >"$TMP_DIR/b.json" <<'EOF'
{"a": {"y": 99}, "n": "added"}
EOF
  run "$MERGER" "$TMP_DIR/a.json" "$TMP_DIR/b.json"
  [ "$status" -eq 0 ]
  local h1 h2
  h1=$("$MERGER" "$TMP_DIR/a.json" "$TMP_DIR/b.json" | shasum -a 256 | awk '{print $1}')
  h2=$("$MERGER" "$TMP_DIR/a.json" "$TMP_DIR/b.json" | shasum -a 256 | awk '{print $1}')
  [ "$h1" = "$h2" ]
}

# ---------- input validation ----------

@test "TC-RSV2-MERGE-04: missing input file exits non-zero" {
  cat >"$TMP_DIR/exists.json" <<'EOF'
{"a": 1}
EOF
  run "$MERGER" "$TMP_DIR/exists.json" "$TMP_DIR/missing.json"
  [ "$status" -ne 0 ]
}

@test "TC-RSV2-MERGE-04: invalid JSON input exits non-zero" {
  cat >"$TMP_DIR/exists.json" <<'EOF'
{"a": 1}
EOF
  cat >"$TMP_DIR/bad.json" <<'EOF'
{not valid json
EOF
  run "$MERGER" "$TMP_DIR/exists.json" "$TMP_DIR/bad.json"
  [ "$status" -ne 0 ]
}

@test "single-layer identity: merger with one input emits that input verbatim (sort-keys normalised)" {
  cat >"$TMP_DIR/only.json" <<'EOF'
{"b": 2, "a": 1}
EOF
  run bash -c "$MERGER '$TMP_DIR/only.json' | jq -c ."
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":1,"b":2}' ]
}
