#!/usr/bin/env bats
# dead-code-join.bats — E70-S8 multi-stack universal file_path JOIN + unified render.
#
# Story: E70-S8 / AC4 / AC6 / scenario 4, 9. FR-545 / NFR-87.
#
# Integration: a single polyglot repo (Go + Python + Java) is scanned by all
# three dead-code adapters into ONE shared output dir. This test proves:
#   1. all three adapters fire and each writes its per-tool JSON + SARIF;
#   2. the universal `file_path` JOIN key works across stacks (every finding
#      carries a repo-root-relative file_path);
#   3. the merged SARIF inputs carry qualifier in .properties.symbol so the
#      E104-S1 dedup precision ladder applies (Val F1 fix);
#   4. the render helper emits ONE "Test Quality" section with THREE per-stack
#      sub-sections (Go / Python / JVM), each showing the stack-native qualifier
#      — NOT one flat list with a synthesized cross-stack confidence (scenario 9
#      anti-pattern guard).

load 'test_helper.bash'

setup() {
  common_setup
  AROOT="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/dead-code" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../scripts/adapters/dead-code")"
  GO_ADAPTER="$AROOT/go-deadcode/adapter.sh"
  PY_ADAPTER="$AROOT/python-vulture/adapter.sh"
  JVM_ADAPTER="$AROOT/jvm-spotbugs/adapter.sh"
  RENDER="$AROOT/render-test-quality.sh"
  FX="$BATS_TEST_DIRNAME/fixtures/dead-code-multi-stack"
  export AROOT GO_ADAPTER PY_ADAPTER JVM_ADAPTER RENDER FX
  FAKE_BIN="$TEST_TMP/bin"; mkdir -p "$FAKE_BIN"; export FAKE_BIN
  OUT="$TEST_TMP/audit"; mkdir -p "$OUT"; export OUT
  cat > "$FAKE_BIN/deadcode" <<EOF
#!/usr/bin/env bash
cat "$FX/deadcode-output.json"
EOF
  cat > "$FAKE_BIN/go" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$FAKE_BIN/vulture" <<EOF
#!/usr/bin/env bash
cat "$FX/vulture-output.txt"
EOF
  cat > "$FAKE_BIN/spotbugs" <<EOF
#!/usr/bin/env bash
out=""
while [ \$# -gt 0 ]; do case "\$1" in -output) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && cat "$FX/spotbugs-output.xml" > "\$out"
exit 0
EOF
  chmod +x "$FAKE_BIN/deadcode" "$FAKE_BIN/go" "$FAKE_BIN/vulture" "$FAKE_BIN/spotbugs"
}
teardown() { common_teardown; }

run_all_three() {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_DEADCODE_GO_ENABLED=true DEADCODE_PROJECT_ROOT="$FX" DEADCODE_OUT_DIR="$OUT" \
    DEADCODE_JSON_FIXTURE="$FX/deadcode-output.json" bash "$GO_ADAPTER"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_DEADCODE_PYTHON_ENABLED=true PY_PROJECT_ROOT="$FX" PY_OUT_DIR="$OUT" \
    PY_VULTURE_FIXTURE="$FX/vulture-output.txt" bash "$PY_ADAPTER"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED=true JVM_PROJECT_ROOT="$FX" JVM_OUT_DIR="$OUT" \
    JVM_SPOTBUGS_FIXTURE="$FX/spotbugs-output.xml" bash "$JVM_ADAPTER"
}

# --- scenario 4 — all three fire; per-tool JSON present ----------------------
@test "join (scenario 4): all three adapters write per-tool JSON" {
  run_all_three
  [ -f "$OUT/dead-code/go-deadcode.json" ]
  [ -f "$OUT/dead-code/python-vulture.json" ]
  [ -f "$OUT/dead-code/jvm-spotbugs.json" ]
}

# --- universal file_path JOIN — every finding carries repo-relative file_path -
@test "join: universal file_path JOIN key present across all stacks" {
  run_all_three
  # Concatenate all findings; every entry must have a non-empty file_path.
  total="$(jq -s 'add | length' "$OUT/dead-code/go-deadcode.json" "$OUT/dead-code/python-vulture.json" "$OUT/dead-code/jvm-spotbugs.json")"
  [ "$total" = "3" ]
  missing="$(jq -s 'add | map(select((.file_path // "") == "")) | length' \
    "$OUT/dead-code/go-deadcode.json" "$OUT/dead-code/python-vulture.json" "$OUT/dead-code/jvm-spotbugs.json")"
  [ "$missing" = "0" ]
  # Each stack's file_path matches its fixture source file.
  run jq -r '.[0].file_path' "$OUT/dead-code/go-deadcode.json";     [ "$output" = "unused_pkg/lib.go" ]
  run jq -r '.[0].file_path' "$OUT/dead-code/python-vulture.json";  [ "$output" = "svc.py" ]
  run jq -r '.[0].file_path' "$OUT/dead-code/jvm-spotbugs.json";    [ "$output" = "com/example/Svc.java" ]
}

# --- Val F1 fix — all three SARIF inputs land in sarif/ for the dedup ladder --
@test "join: three SARIF inputs with .properties.symbol for dedup" {
  run_all_three
  for t in go-deadcode python-vulture jvm-spotbugs; do
    [ -f "$OUT/sarif/$t.sarif" ]
    run jq -r '.runs[0].results[0].properties.symbol' "$OUT/sarif/$t.sarif"
    [ -n "$output" ] && [ "$output" != "null" ]
  done
}

# --- AC4 / scenario 9 — ONE section, THREE per-stack sub-sections ------------
@test "join (/scenario 9): render emits ONE Test Quality section, THREE per-stack sub-sections" {
  run_all_three
  report="$TEST_TMP/consolidated-gaps.md"
  cat > "$report" <<'MD'
---
title: brownfield consolidated gaps
---
# Consolidated Gaps
MD
  run bash "$RENDER" --out-dir "$OUT" --report "$report"
  [ "$status" -eq 0 ]
  # Exactly one Test Quality H2 section.
  [ "$(grep -cE '^## Test Quality' "$report")" = "1" ]
  # Three per-stack H3 sub-sections.
  grep -qE '^### (Go|Go / go-deadcode)' "$report"
  grep -qE '^### (Python|Python / vulture)' "$report"
  grep -qE '^### (JVM|JVM / SpotBugs)' "$report"
  # Stack-native qualifiers present verbatim.
  grep -q 'unused_pkg.DeadGoFunc' "$report"
  grep -q 'dead_py_func@95' "$report"
  grep -q 'com.example.Svc.run(I)V' "$report"
  # Anti-pattern guard: no synthesized cross-stack confidence column.
  ! grep -qiE 'unified.confidence|synthesized.confidence|cross.stack.confidence' "$report"
}

# --- render helper hygiene ---------------------------------------------------
@test "join: render-test-quality.sh exists, executable, bash -n clean" {
  [ -x "$RENDER" ]
  run bash -n "$RENDER"
  [ "$status" -eq 0 ]
}
