#!/usr/bin/env bats
# dead-code-jvm.bats — E70-S8 JVM SpotBugs adapter.
#
# Story: E70-S8. FR-545 / NFR-87 / ADR-078.
#
# adapter.sh wraps SpotBugs `-xml -output <tmp>`, filters BugInstance elements to
# priority=1 AND rank<=4 ("proven-dead-equivalent" conservative default), and emits:
#   - flat JSON to <out>/dead-code/jvm-spotbugs.json (AC3/AC4)
#   - SARIF to <out>/sarif/jvm-spotbugs.sarif (.properties.symbol, dedup ladder)
# qualifier = "<FQCN>.<method>(<signature>)".
# The priority-2/rank-14 BugInstance in the fixture MUST be filtered out.
#
# Test seams:
#   JVM_PROJECT_ROOT     repo to scan
#   JVM_OUT_DIR          output root
#   JVM_SPOTBUGS_FIXTURE pre-captured SpotBugs -xml output the shim emits

load '../test_helper.bash'

setup() {
  common_setup
  ADAPTER="$(cd "$BATS_TEST_DIRNAME/../../scripts/adapters/dead-code/jvm-spotbugs" && pwd 2>/dev/null || echo "$BATS_TEST_DIRNAME/../../scripts/adapters/dead-code/jvm-spotbugs")/adapter.sh"
  FX="$BATS_TEST_DIRNAME/../fixtures/dead-code-jvm"
  export ADAPTER FX
  FAKE_BIN="$TEST_TMP/bin"; mkdir -p "$FAKE_BIN"; export FAKE_BIN
  OUT="$TEST_TMP/audit"; mkdir -p "$OUT"; export OUT
  # SpotBugs writes XML to the path after `-output`; the shim copies the fixture there.
  cat > "$FAKE_BIN/spotbugs" <<EOF
#!/usr/bin/env bash
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -output) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$out" ] && cat "$FX/spotbugs-output.xml" > "\$out"
exit 0
EOF
  chmod +x "$FAKE_BIN/spotbugs"
}
teardown() { common_teardown; }

run_adapter() {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED=true \
    JVM_PROJECT_ROOT="$FX" JVM_OUT_DIR="$OUT" JVM_SPOTBUGS_FIXTURE="$FX/spotbugs-output.xml" run bash "$ADAPTER"
}

# --- AC3 / scenario 3 — priority=1 rank<=4 only; qualifier FQCN.method(sig) ---
@test "E70-S8 jvm (scenario 3): priority-1 finding → JSON file_path + qualifier FQCN.method(sig)" {
  run_adapter
  [ "$status" -eq 0 ]
  [ -f "$OUT/dead-code/jvm-spotbugs.json" ]
  run jq 'length' "$OUT/dead-code/jvm-spotbugs.json"
  [ "$output" = "1" ]   # priority-2/rank-14 BugInstance filtered out
  run jq -r '.[0].file_path' "$OUT/dead-code/jvm-spotbugs.json"
  [ "$output" = "com/example/Foo.java" ]
  run jq -r '.[0].qualifier' "$OUT/dead-code/jvm-spotbugs.json"
  [ "$output" = "com.example.Foo.bar(I)V" ]
  run jq -r '.[0].source_tool' "$OUT/dead-code/jvm-spotbugs.json"
  [ "$output" = "jvm-spotbugs" ]
}

# --- Val F1 fix — SARIF emission ---------------------------------------------
@test "E70-S8 jvm: emits SARIF with qualifier in .properties.symbol" {
  run_adapter
  [ "$status" -eq 0 ]
  [ -f "$OUT/sarif/jvm-spotbugs.sarif" ]
  run jq -r '.runs[0].results[0].properties.symbol' "$OUT/sarif/jvm-spotbugs.sarif"
  [ "$output" = "com.example.Foo.bar(I)V" ]
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$OUT/sarif/jvm-spotbugs.sarif"
  [ "$output" = "com/example/Foo.java" ]
}

# --- AC5 / scenario 5 — spotbugs absent → degrade ----------------------------
@test "E70-S8 jvm (scenario 5): spotbugs absent → WARNING + exit 0" {
  rm -f "$FAKE_BIN/spotbugs"
  # The jvm adapter runs its no-source-file guard (find for *.java/*.kt/*.class)
  # BEFORE the spotbugs-absence check, so this test must keep find+grep on PATH
  # (an empty PATH would mis-trigger the no-source branch and emit INFO, not
  # WARNING). Use the system bin dirs WITHOUT FAKE_BIN — `spotbugs` is not a
  # standard tool, so it is genuinely absent on local and CI runners alike, and
  # the fixture's Foo.java lets execution reach the spotbugs-absence WARNING.
  run env PATH="/usr/bin:/bin" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED=true \
    JVM_PROJECT_ROOT="$FX" JVM_OUT_DIR="$OUT" bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"spotbugs"* ]]
}

@test "jvm adapter degrade emits a language-aware install hint" {
  rm -f "$FAKE_BIN/spotbugs"
  run env PATH="/usr/bin:/bin" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED=true \
    JVM_PROJECT_ROOT="$FX" JVM_OUT_DIR="$OUT" bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"install via"* ]]
  [[ "$output" == *"spotbugs"* ]]
}

# --- AC5 — no java/class files → no-op ---------------------------------------
@test "E70-S8 jvm: no .java/.class files → idempotent no-op, exit 0" {
  emptyroot="$TEST_TMP/empty"; mkdir -p "$emptyroot"
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED=true \
    JVM_PROJECT_ROOT="$emptyroot" JVM_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/dead-code/jvm-spotbugs.json" ] || [ "$(jq 'length' "$OUT/dead-code/jvm-spotbugs.json")" = "0" ]
}

# --- issue-1390 — no-JVM-source guard precedes the docker dispatch -----------
# On a non-JVM project the adapter must short-circuit BEFORE any spotbugs
# dispatch (docker or native), and must NOT leave a 0-byte spotbugs.sarif in
# the SARIF input dir (that empty file crashes the downstream merge — #1389).
@test "issue-1390: no JVM source under docker runner mode → exit 0, no spotbugs.sarif written" {
  emptyroot="$TEST_TMP/empty-docker"; mkdir -p "$emptyroot"
  # Force docker runner mode; with no real docker daemon docker_runner_available
  # is false, but the source-file guard must fire FIRST regardless.
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED=true \
    GAIA_TOOLS_RUNNER=docker \
    JVM_PROJECT_ROOT="$emptyroot" JVM_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  # The empty SARIF that triggers #1389 must NOT exist.
  [ ! -f "$OUT/sarif/spotbugs.sarif" ]
  [ ! -f "$OUT/sarif/jvm-spotbugs.sarif" ]
  # The skip must be attributed to the missing source files.
  [[ "$output" == *"no "*".java"* ]] || [[ "$output" == *"no-op"* ]]
}

# --- AC-X1 / scenario 6 — per-tool flag-off ----------------------------------
@test "E70-S8 jvm (scenario 6): deadcode_jvm_enabled=false → skip" {
  PATH="$FAKE_BIN:$PATH" GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true GAIA_BROWNFIELD_DEADCODE_JVM_ENABLED=false \
    JVM_PROJECT_ROOT="$FX" JVM_OUT_DIR="$OUT" run bash "$ADAPTER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || [[ "$output" == *"INFO"* ]]
  [ ! -f "$OUT/dead-code/jvm-spotbugs.json" ]
}

# --- Hygiene -----------------------------------------------------------------
@test "E70-S8 jvm: adapter.sh + adapter.json exist; bash -n clean" {
  [ -x "$ADAPTER" ]
  [ -f "$(dirname "$ADAPTER")/adapter.json" ]
  run bash -n "$ADAPTER"
  [ "$status" -eq 0 ]
  run jq -e '.provider' "$(dirname "$ADAPTER")/adapter.json"
  [ "$status" -eq 0 ]
}
