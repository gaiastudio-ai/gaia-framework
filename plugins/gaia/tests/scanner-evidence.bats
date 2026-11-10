#!/usr/bin/env bats
# scanner-evidence.bats — scanner-first evidence collection tests.
#
# Tests the scanner-evidence.sh interface: manifest layout, fields, exit
# codes, set resolution, reuse, off switch, completeness, and error cases.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/scanner-ev-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP"

  BATS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_DIR="$(cd "$BATS_DIR/.." && pwd)"
  SCANNER_EVIDENCE="$PLUGIN_DIR/scripts/review-common/security/scanner-evidence.sh"

  # Build a minimal story directory.
  STORY_DIR="$WORK_TMP/.gaia/artifacts/implementation-artifacts/epic-test/E999-S1-test-story"
  mkdir -p "$STORY_DIR"
  cat > "$STORY_DIR/story.md" <<'MD'
---
key: "E999-S1"
title: "test story"
status: in-progress
---
# test story
MD

  # Build a minimal repo tree.
  REPO_DIR="$WORK_TMP/repo"
  mkdir -p "$REPO_DIR/src"
  cd "$REPO_DIR" && git init -q && printf 'import os\n' > src/app.py && git add -A && git -c user.email=a@b -c user.name=a commit -qm init && cd - >/dev/null

  # Config directory.
  CONFIG_DIR="$WORK_TMP/.gaia/config"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
project_kind: web-app
YAML

  # Create stub adapter directory with adapters that exit 0.
  STUB_ADAPTERS="$WORK_TMP/adapters"
  _make_stub() {
    local name="$1" category="$2"
    local dir="$STUB_ADAPTERS/$name"
    mkdir -p "$dir"
    printf '{"provider":"%s","category":"%s","runtime-profile":"subprocess","default-timeout-seconds":10,"file-extensions":[],"scope":"project","description":"stub"}\n' \
      "$name" "$category" > "$dir/adapter.json"
    cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"stub","status":"passed","findings":[]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
exit 0
SH
    chmod +x "$dir/run.sh"
    # Fake binary.
    mkdir -p "$WORK_TMP/fakebin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_TMP/fakebin/$name"
    chmod +x "$WORK_TMP/fakebin/$name"
  }

  _make_stub semgrep sast
  _make_stub osv-scanner dep-audit

  export PROJECT_ROOT="$WORK_TMP"
  export PROJECT_PATH="$WORK_TMP"
  export CLAUDE_PROJECT_ROOT="$WORK_TMP"
  export PROJECT_CONFIG="$CONFIG_DIR/project-config.yaml"
  export BUILTIN_ADAPTERS_DIR="$STUB_ADAPTERS"
}

teardown() {
  rm -rf "$WORK_TMP" 2>/dev/null || true
}

# --- Evidence interface tests (AC2) ---

@test "scanner evidence: manifest written with all required fields" {
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id r1 --repo "$REPO_DIR"

  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  [ -f "$manifest_path" ]

  jq -e '.version == 1' "$manifest_path"
  jq -e '.story == "E999-S1"' "$manifest_path"
  jq -e '.run_id == "r1"' "$manifest_path"
  jq -e '.enabled == true' "$manifest_path"
  jq -e '.complete == true' "$manifest_path"
  jq -e '.adapters | length > 0' "$manifest_path"
  jq -e '.adapters[0] | has("name", "category", "state", "failure_kind", "skip_reason", "fragment", "sha256")' "$manifest_path"
}

@test "scanner evidence: fragment file present and hash matches" {
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id r2 --repo "$REPO_DIR"

  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  local evidence_dir; evidence_dir="$(dirname "$manifest_path")"

  local frag_name frag_sha256
  while IFS=$'\t' read -r frag_name frag_sha256; do
    [ -n "$frag_name" ] || continue
    [ -f "$evidence_dir/$frag_name" ]
    local actual_sha; actual_sha="$(shasum -a 256 "$evidence_dir/$frag_name" | awk '{print $1}')"
    [ "$actual_sha" = "$frag_sha256" ]
  done < <(jq -r '.adapters[] | select(.fragment != null) | [.fragment, .sha256] | @tsv' "$manifest_path")
}

@test "scanner evidence: exit 0 on complete evidence" {
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id r3 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
}

# --- Off switch (AC12) ---

@test "scanner evidence: off switch writes disabled manifest" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
review:
  scanner_first_enabled: false
YAML

  run "$SCANNER_EVIDENCE" --story E999-S1 --run-id off1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  [ -f "$manifest_path" ]
  jq -e '.enabled == false' "$manifest_path"
  jq -e '.complete == true' "$manifest_path"
  jq -e '.adapters | length == 0' "$manifest_path"
}

@test "scanner evidence: absent key means scanner-first is on" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
YAML

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id on1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  jq -e '.enabled == true' "$manifest_path"
}

@test "scanner evidence: string false does NOT turn scanner-first off (AC-EC9)" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
review:
  scanner_first_enabled: "false"
YAML

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id sf1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  jq -e '.enabled == true' "$manifest_path"
}

# --- Reuse (AC5) ---

@test "scanner evidence: reuses complete evidence with matching head" {
  # Use a counter file to detect how many times the adapter runs.
  local counter="$WORK_TMP/call_count"
  printf '0\n' > "$counter"
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in --output) OUTPUT="\$2"; shift 2 ;; *) shift ;; esac
done
c=\$(cat "$counter"); c=\$((c + 1)); printf '%s\n' "\$c" > "$counter"
frag='{"name":"semgrep","status":"passed","findings":[]}'
if [ -n "\$OUTPUT" ]; then printf '%s\n' "\$frag" > "\$OUTPUT"; else printf '%s\n' "\$frag"; fi
exit 0
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"
  cat > "$STUB_ADAPTERS/osv-scanner/run.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in --output) OUTPUT="\$2"; shift 2 ;; *) shift ;; esac
done
c=\$(cat "$counter"); c=\$((c + 1)); printf '%s\n' "\$c" > "$counter"
frag='{"name":"osv-scanner","status":"passed","findings":[]}'
if [ -n "\$OUTPUT" ]; then printf '%s\n' "\$frag" > "\$OUTPUT"; else printf '%s\n' "\$frag"; fi
exit 0
SH
  chmod +x "$STUB_ADAPTERS/osv-scanner/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id reuse1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local count_after_first; count_after_first="$(cat "$counter")"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id reuse1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local count_after_second; count_after_second="$(cat "$counter")"

  # The second call should not have run the adapters again.
  [ "$count_after_first" = "$count_after_second" ]
}

# --- Caller errors ---

@test "scanner evidence: exit 1 on missing --story" {
  run "$SCANNER_EVIDENCE" --run-id x --repo "$REPO_DIR"
  [ "$status" -eq 1 ]
}

@test "scanner evidence: exit 1 on invalid run-id with path separator" {
  run "$SCANNER_EVIDENCE" --story E999-S1 --run-id "a/b" --repo "$REPO_DIR"
  [ "$status" -eq 1 ]
}

@test "scanner evidence: exit 1 on run-id with dot-dot" {
  run "$SCANNER_EVIDENCE" --story E999-S1 --run-id "a..b" --repo "$REPO_DIR"
  [ "$status" -eq 1 ]
}

# --- Provider validation (AC3, AC-EC2) ---

@test "scanner evidence: exit 1 on provider with path separator in config" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
tools:
  sast:
    provider: "../x"
YAML

  run "$SCANNER_EVIDENCE" --story E999-S1 --run-id bad1 --repo "$REPO_DIR"
  [ "$status" -eq 1 ]
}

@test "scanner evidence: exit 1 on provider containing slash" {
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
tools:
  sast:
    provider: semgrep/test
YAML

  run "$SCANNER_EVIDENCE" --story E999-S1 --run-id bad2 --repo "$REPO_DIR"
  [ "$status" -eq 1 ]
}

@test "scanner evidence: non-scanner provider does not drop default set" {
  # A linter (non-scanner category) should not suppress the default scanners.
  mkdir -p "$STUB_ADAPTERS/radon"
  printf '{"provider":"radon","category":"complexity","runtime-profile":"subprocess","default-timeout-seconds":10,"file-extensions":[".py"],"scope":"file","description":"linter"}\n' \
    > "$STUB_ADAPTERS/radon/adapter.json"

  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
tools:
  lint:
    provider: radon
YAML

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id set1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  # Should still have the default set (semgrep + osv-scanner), not empty.
  local adapter_count; adapter_count="$(jq '.adapters | length' "$manifest_path")"
  [ "$adapter_count" -eq 2 ]
}

# --- HALT on errored adapter ---

@test "scanner evidence: exit 2 when adapter errors" {
  # Make semgrep adapter exit 2 (errored).
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<'SH'
#!/usr/bin/env bash
echo "fatal error" >&2
exit 2
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id halt1 --repo "$REPO_DIR"
  [ "$status" -eq 2 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  jq -e '.complete == false' "$manifest_path"
}

# --- Fragment validation ---

@test "scanner evidence: available adapter with no fragment is incomplete" {
  # Adapter runs but writes no output file.
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<'SH'
#!/usr/bin/env bash
# Intentionally writes nothing
exit 0
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id nofrag1 --repo "$REPO_DIR"
  [ "$status" -eq 2 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  jq -e '.complete == false' "$manifest_path"
}

# --- Concurrency (AC-EC7) ---

@test "scanner evidence: concurrent same-run-id calls do not clobber" {
  # Run 4 concurrent calls; none should exit 1 due to mv collision.
  local rc_file="$WORK_TMP/rc_results"
  : > "$rc_file"
  for j in 1 2 3 4; do
    (PATH="$WORK_TMP/fakebin:$PATH" \
      "$SCANNER_EVIDENCE" --story E999-S1 --run-id concurrent1 --repo "$REPO_DIR" >/dev/null 2>&1; echo $? >> "$rc_file") &
  done
  wait

  # All should succeed (exit 0), not fail due to temp file collision.
  local fail_count; fail_count="$(grep -c '^1$' "$rc_file" || true)"
  [ "$fail_count" -eq 0 ]
}

# --- Scanner findings register (RF-11) ---

@test "scanner evidence: findings from adapter fragment reach the register" {
  # Create a stub adapter that produces one high finding.
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"semgrep","status":"passed","findings":[{"id":"test-rule-1","severity":"high","message":"hardcoded secret at src/app.py:10","source":"semgrep"}]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
exit 0
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id reg1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]

  # Check the register has an entry.
  local reg_path="$STORY_DIR/reviews/findings-register-E999-S1.yaml"
  [ -f "$reg_path" ]
  local entry_count; entry_count="$(yq '.entries | length' "$reg_path" 2>/dev/null)"
  [ "$entry_count" -ge 1 ]
  # The entry should reference the scanner finding.
  yq -e '.entries[0].defect | test("hardcoded secret")' "$reg_path"
  yq -e '.entries[0].severity == "high"' "$reg_path"
}

@test "scanner evidence: re-run with same evidence does not duplicate register entries" {
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"semgrep","status":"passed","findings":[{"id":"dup-rule","severity":"medium","message":"potential issue","source":"semgrep"}]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
exit 0
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  # First run.
  PATH="$WORK_TMP/fakebin:$PATH" \
    "$SCANNER_EVIDENCE" --story E999-S1 --run-id dup1 --repo "$REPO_DIR" >/dev/null 2>&1

  local reg_path="$STORY_DIR/reviews/findings-register-E999-S1.yaml"
  local count1; count1="$(yq '.entries | length' "$reg_path" 2>/dev/null)"

  # Force a re-collection by removing the manifest (simulating new head).
  rm -f "$STORY_DIR/scanner-evidence/dup1/evidence-manifest.json"

  # Second run with same evidence.
  PATH="$WORK_TMP/fakebin:$PATH" \
    "$SCANNER_EVIDENCE" --story E999-S1 --run-id dup1 --repo "$REPO_DIR" >/dev/null 2>&1

  local count2; count2="$(yq '.entries | length' "$reg_path" 2>/dev/null)"
  # Entry count should not increase (dedup by run_id + sha + finding_id).
  [ "$count1" -eq "$count2" ]
}

@test "scanner evidence: clean scan adds no register entries" {
  # Default stubs produce zero findings.
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id clean1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]

  # Register should not exist or have zero entries.
  local reg_path="$STORY_DIR/reviews/findings-register-E999-S1.yaml"
  if [ -f "$reg_path" ]; then
    local count; count="$(yq '.entries | length' "$reg_path" 2>/dev/null)"
    [ "$count" -eq 0 ]
  fi
}
