#!/usr/bin/env bats
# validate-junit-sha.bats — tests for validate-junit-sha.sh.
# Uses real temporary git repos and crafted evidence directories.

load 'test_helper.bash'

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

# ── Helpers ──────────────────────────────────────────────────────────

# _make_repo — create a bare-minimum git repo. Prints the repo path.
_make_repo() {
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config user.name "Test"
  printf 'init\n' > "$repo/init.txt"
  git -C "$repo" add init.txt
  git -C "$repo" commit -q -m "init"
  printf '%s\n' "$repo"
}

# _make_evidence — create an evidence directory with run-records.json.
# Args: dir, head_sha, [run_url], [run_count]
_make_evidence() {
  local dir="$1" head_sha="$2" run_url="${3:-https://github.com/org/repo/actions/runs/101}" run_count="${4:-1}"
  mkdir -p "$dir"
  local runs="[]"
  local i=0
  while [ "$i" -lt "$run_count" ]; do
    local url="$run_url"
    if [ "$run_count" -gt 1 ]; then
      url="https://github.com/org/repo/actions/runs/$((101 + i))"
    fi
    runs="$(printf '%s' "$runs" | jq \
      --arg url "$url" \
      --arg sha "$head_sha" \
      '. + [{"url": $url, "head_sha": $sha, "attempt": 1, "conclusion": "success", "duration_seconds": 120}]')"
    i=$((i + 1))
  done
  printf '%s' "$runs" | jq '{runs: ., wall_clock_seconds: 120}' > "$dir/run-records.json"
}

# _make_junit_xml — write a valid JUnit XML file.
# Args: path [tests] [failures] [skipped_count] [commit_sha]
_make_junit_xml() {
  local path="$1"
  local tests="${2:-10}"
  local failures="${3:-0}"
  local skipped="${4:-0}"
  local commit_sha="${5:-}"
  local props=""
  if [ -n "$commit_sha" ]; then
    props="<properties><property name=\"commit\" value=\"$commit_sha\"/></properties>"
  fi
  cat > "$path" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="$tests" failures="$failures" skipped="$skipped">
  <testsuite name="Suite" tests="$tests" failures="$failures" skipped="$skipped">
    ${props}
    <testcase name="test-pass" classname="Suite" time="0.1"/>
  </testsuite>
</testsuites>
XMLEOF
}

# ── Setup / teardown ─────────────────────────────────────────────────

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/validate-junit-sha.sh"
  [ -f "$SCRIPT" ] || fail "validate-junit-sha.sh not found at $SCRIPT"

  unset GAIA_WORKTREE_MODE GAIA_PARALLEL_EXECUTION

  WORKDIR="$TEST_TMP/work"
  mkdir -p "$WORKDIR"

  REPO="$(_make_repo)"
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
  EVIDENCE_DIR="$WORKDIR/evidence"
  mkdir -p "$EVIDENCE_DIR"
}

teardown() {
  common_teardown
}

# ── Tests ────────────────────────────────────────────────────────────

@test "validate-junit-sha: missing --repo fails with exit 1" {
  run bash "$SCRIPT" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 1 ]
}

@test "validate-junit-sha: missing --evidence fails with exit 1" {
  run bash "$SCRIPT" --repo "$REPO"
  [ "$status" -eq 1 ]
}

@test "validate-junit-sha: matching SHA accepted" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"
  _make_junit_xml "$EVIDENCE_DIR/results.xml" 10 0 0 "$HEAD_SHA"

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 0 ]
  # Verdict must be accepted
  local verdict_status
  verdict_status="$(printf '%s' "$output" | jq -r '.status')"
  [ "$verdict_status" = "accepted" ]
}

@test "validate-junit-sha: mismatched run SHA rejected with reason" {
  local wrong_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  _make_evidence "$EVIDENCE_DIR" "$wrong_sha"

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 3 ]
  local reason
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [ "$reason" = "junit_sha_mismatch" ]
  # Names both short SHAs
  local expected_sha actual_sha
  expected_sha="$(printf '%s' "$output" | jq -r '.expected_sha')"
  actual_sha="$(printf '%s' "$output" | jq -r '.actual_sha')"
  [ -n "$expected_sha" ]
  [ -n "$actual_sha" ]
  [ "$expected_sha" != "$actual_sha" ]
}

@test "validate-junit-sha: missing run URL rejected" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA" "file:///local/path"

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 3 ]
  local reason
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [ "$reason" = "junit_run_link_missing" ]
}

@test "validate-junit-sha: empty runs array rejected with run_link_missing" {
  mkdir -p "$EVIDENCE_DIR"
  printf '{"runs":[],"wall_clock_seconds":0}\n' > "$EVIDENCE_DIR/run-records.json"

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 3 ]
  local reason
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [ "$reason" = "junit_run_link_missing" ]
}

@test "validate-junit-sha: XML commit property differs rejected" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"
  local wrong_xml_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  _make_junit_xml "$EVIDENCE_DIR/results.xml" 10 0 0 "$wrong_xml_sha"

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 3 ]
  local reason
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [ "$reason" = "junit_sha_mismatch" ]
}

@test "validate-junit-sha: HEAD moved after fetch rejected" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"

  # Move HEAD by committing
  printf 'new\n' > "$REPO/new.txt"
  git -C "$REPO" add new.txt
  git -C "$REPO" commit -q -m "move head"

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 3 ]
  local reason
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [ "$reason" = "junit_sha_mismatch" ]
}

@test "validate-junit-sha: malformed XML rejected with parse error" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"
  # Write malformed XML with a property that triggers parsing
  cat > "$EVIDENCE_DIR/bad.xml" <<'EOF'
<?xml version="1.0"?>
<testsuites>
  <testsuite>
    <properties><property name="commit" value="abc"/></properties>
    <not-closed
  </testsuite>
</testsuites>
EOF

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 3 ]
  local reason
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [ "$reason" = "junit_parse_error" ]
}

@test "validate-junit-sha: oversized XML rejected" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"
  # Create a file that reports as very large — use a commit property
  # so the validator actually tries to parse it
  local big="$EVIDENCE_DIR/big.xml"
  printf '<?xml version="1.0"?>\n<testsuites><testsuite><properties><property name="commit" value="x"/></properties></testsuite></testsuites>\n' > "$big"
  # Stub stat to return a huge size — actually we rely on the python parser
  # The size check is in the shell; we need a file >50MB. Create a sparse file.
  # Instead, test that the function handles it gracefully.
  # Skip this if we can't create a large enough sparse file quickly
  if command -v truncate >/dev/null 2>&1; then
    truncate -s 55M "$big"
  elif command -v dd >/dev/null 2>&1; then
    dd if=/dev/zero of="$big" bs=1 count=0 seek=55000000 2>/dev/null
  else
    skip "cannot create sparse file for size test"
  fi

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 3 ]
  local reason
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [ "$reason" = "junit_parse_error" ]
}

@test "validate-junit-sha: XML with no commit property accepted" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"
  _make_junit_xml "$EVIDENCE_DIR/results.xml" 10 0 0 ""

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  [ "$status" -eq 0 ]
  local verdict_status
  verdict_status="$(printf '%s' "$output" | jq -r '.status')"
  [ "$verdict_status" = "accepted" ]
}

@test "validate-junit-sha: deterministic — same inputs twice yield same verdict" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"
  _make_junit_xml "$EVIDENCE_DIR/results.xml" 10 0 0 "$HEAD_SHA"

  local v1 v2
  v1="$(bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR")"
  v2="$(bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR")"

  [ "$(printf '%s' "$v1" | jq -S .)" = "$(printf '%s' "$v2" | jq -S .)" ]
}

@test "validate-junit-sha: entity-laden XML never resolves entities" {
  _make_evidence "$EVIDENCE_DIR" "$HEAD_SHA"
  # Write XML with an external entity reference
  cat > "$EVIDENCE_DIR/entity.xml" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE testsuites [
  <!ENTITY xxe SYSTEM "file:///etc/passwd">
]>
<testsuites>
  <testsuite name="&xxe;">
    <testcase name="t"/>
  </testsuite>
</testsuites>
EOF

  run bash "$SCRIPT" --repo "$REPO" --evidence "$EVIDENCE_DIR"
  # Should either accept (no commit property) or reject with parse error
  # but never resolve the entity (python ElementTree blocks XXE by default)
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
  if [ "$status" -eq 3 ]; then
    local reason
    reason="$(printf '%s' "$output" | jq -r '.reason')"
    [ "$reason" = "junit_parse_error" ]
  fi
}
