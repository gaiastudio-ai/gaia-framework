#!/usr/bin/env bats
# scanner-evidence.bats — scanner-first evidence collection tests.
#
# Tests the scanner-evidence.sh interface: manifest layout, fields, exit
# codes, set resolution, reuse, off switch, and completeness checks.

bats_require_minimum_version 1.5.0

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
  mkdir -p "$REPO_DIR"
  printf 'hello\n' > "$REPO_DIR/main.py"

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

# --- Reuse (AC5) ---

@test "scanner evidence: reuses complete evidence with matching head" {
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id reuse1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id reuse1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
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

# --- Bad provider (EC2) ---

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
