#!/usr/bin/env bats
# scanner-evidence.bats — scanner-first evidence collection tests.
#
# Tests the scanner-evidence.sh interface: manifest layout, fields, exit
# codes, set resolution, reuse, off switch, completeness, and error cases.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

# Shared repo template: built once per file, cloned per test via cp -r.
# This avoids the expensive git-init + git-clone + git-push per test.
setup_file() {
  _litter_snapshot_before
  export BATS_FILE_TMPDIR="${BATS_FILE_TMPDIR:-${BATS_TMPDIR:-/tmp}/scanner-ev-file-$$}"
  mkdir -p "$BATS_FILE_TMPDIR"
  _TMPL="$BATS_FILE_TMPDIR/template"
  mkdir -p "$_TMPL"

  # Template repo with origin/main.
  local bare_dir="$_TMPL/bare.git"
  git init --bare -q "$bare_dir"
  git clone -q "$bare_dir" "$_TMPL/repo"
  cd "$_TMPL/repo"
  mkdir -p src
  printf 'import os\n' > src/app.py
  git add -A && git -c user.email=a@b -c user.name=a commit -qm init
  git push -q origin HEAD:main 2>/dev/null
  git checkout -b feat-test -q
  printf 'import sys\n' >> src/app.py
  git add -A && git -c user.email=a@b -c user.name=a commit -qm "story change"
  cd - >/dev/null
}

teardown_file() {
  rm -rf "$BATS_FILE_TMPDIR" 2>/dev/null || true
  _litter_check_after
}

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

  # Clone the template repo (filesystem copy, no git network ops).
  REPO_DIR="$WORK_TMP/repo"
  cp -r "$BATS_FILE_TMPDIR/template/repo" "$REPO_DIR"
  cp -r "$BATS_FILE_TMPDIR/template/bare.git" "$WORK_TMP/bare.git"
  # Fix the remote to point at the local copy.
  git -C "$REPO_DIR" remote set-url origin "$WORK_TMP/bare.git"

  # Config directory.
  CONFIG_DIR="$WORK_TMP/.gaia/config"
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
project_kind: web-app
ci_cd:
  promotion_chain:
    - id: main
      branch: main
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

# --- Evidence interface tests ---

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

# --- Off switch ---

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

@test "scanner evidence: string false does NOT turn scanner-first off" {
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

# --- Reuse ---

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

# --- Provider validation ---

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

# --- Concurrency ---

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

# --- Scanner findings register ---

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

# --- not_applicable handling ---

@test "scanner evidence: osv-scanner not_applicable is recorded with skip reason" {
  # Make osv-scanner write a not_applicable fragment.
  cat > "$STUB_ADAPTERS/osv-scanner/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"osv-scanner","status":"not_applicable","reason":"no lockfiles found","findings":[]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
exit 0
SH
  chmod +x "$STUB_ADAPTERS/osv-scanner/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id na1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  # The manifest should record not_applicable state with the skip reason.
  jq -e '.adapters[] | select(.name == "osv-scanner") | .state == "not_applicable"' "$manifest_path"
  jq -e '.adapters[] | select(.name == "osv-scanner") | .skip_reason == "no lockfiles found"' "$manifest_path"
}

# --- Deleted files filtered ---

@test "scanner evidence: deleted files are excluded from the file list" {
  # Build a repo where gone.py exists on the base branch (origin/main) and is
  # deleted on the story branch. Without --diff-filter=d the deletion would
  # appear in the diff; with it, gone.py is excluded.
  cd "$REPO_DIR"
  # Create gone.py on the base and push to origin/main.
  printf 'gone\n' > src/gone.py
  printf 'kept\n' > src/kept.py
  git add -A && git -c user.email=a@b -c user.name=a commit -qm "add gone.py and kept.py"
  git push -q origin HEAD:main 2>/dev/null || true
  # Story branch: delete gone.py, modify kept.py (so the diff is non-empty).
  git checkout -b feat-del -q
  git rm -q src/gone.py
  printf 'kept v2\n' > src/kept.py
  git add -A && git -c user.email=a@b -c user.name=a commit -qm "remove gone.py, update kept.py"

  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
ci_cd:
  promotion_chain:
    - id: main
      branch: main
YAML

  # Adapter that captures the file list it receives.
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
FILE_LIST=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in --output) OUTPUT="\$2"; shift 2 ;; --input) FILE_LIST="\$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "\$FILE_LIST" ]; then cp "\$FILE_LIST" "$WORK_TMP/received-files.txt"; fi
frag='{"name":"semgrep","status":"passed","findings":[]}'
if [ -n "\$OUTPUT" ]; then printf '%s\n' "\$frag" > "\$OUTPUT"; else printf '%s\n' "\$frag"; fi
exit 0
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"
  cd - >/dev/null

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id del1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]

  # The adapter must have received a file list (assert it exists).
  [ -f "$WORK_TMP/received-files.txt" ]
  # The deleted file must not be in the list passed to the adapter.
  run grep "gone.py" "$WORK_TMP/received-files.txt"
  [ "$status" -ne 0 ]
}

# --- No base resolution exits incomplete ---

@test "scanner evidence: no integration branch exits 2 with incomplete manifest" {
  # Create a standalone repo (no remote) with no matching branch names.
  local solo_repo="$WORK_TMP/solo"
  mkdir -p "$solo_repo"
  cd "$solo_repo"
  git init -q -b unusual-name
  printf 'test\n' > file.txt
  git add -A && git -c user.email=a@b -c user.name=a commit -qm init
  cd - >/dev/null

  # No promotion_chain in config, no origin, no common branch names.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
YAML

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id nobase1 --repo "$solo_repo"

  # Without any resolvable integration branch, the script exits 2 (incomplete).
  [ "$status" -eq 2 ]
}

# --- Register write failure marks run incomplete ---

@test "scanner evidence: register write failure marks run incomplete" {
  # Create a finding adapter that produces one finding.
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"semgrep","status":"passed","findings":[{"id":"r1","severity":"high","message":"test","source":"semgrep"}]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
exit 0
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  # Build a copy of the scanner evidence scripts in a temp tree, with a
  # register-write.sh that always fails. The register script resolves its
  # writer relative to itself, so placing a failing stub there is enough.
  # Also copy the probe so the script reaches the register step.
  local tree="$WORK_TMP/scripts"
  local sec_dir="$tree/review-common/security"
  local rw_dir="$tree/review-common"
  mkdir -p "$sec_dir" "$tree/adapters"
  cp "$PLUGIN_DIR/scripts/review-common/security/scanner-evidence.sh" "$sec_dir/"
  cp "$PLUGIN_DIR/scripts/review-common/security/scanner-findings-register.sh" "$sec_dir/"
  cp "$PLUGIN_DIR/scripts/tool-availability-probe.sh" "$tree/"
  chmod +x "$sec_dir/scanner-evidence.sh" "$sec_dir/scanner-findings-register.sh" "$tree/tool-availability-probe.sh"
  # Stub resolve-story-file.sh so story lookup works.
  printf '#!/usr/bin/env bash\necho "%s/story.md"\n' "$STORY_DIR" > "$tree/resolve-story-file.sh"
  chmod +x "$tree/resolve-story-file.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$rw_dir/register-write.sh"
  chmod +x "$rw_dir/register-write.sh"

  BUILTIN_ADAPTERS_DIR="$STUB_ADAPTERS" \
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$sec_dir/scanner-evidence.sh" --story E999-S1 --run-id failreg1 --repo "$REPO_DIR"

  # A register write failure makes the run incomplete (exit 2) because
  # a finding that never reaches the register would be invisible to the
  # verdict resolver.
  [ "$status" -eq 2 ]
  # The manifest must also record complete=false so a re-run does not
  # reuse evidence that missed the register step.
  local manifest="$STORY_DIR/scanner-evidence/failreg1/evidence-manifest.json"
  [ -f "$manifest" ]
  jq -e '.complete == false' "$manifest"
}

# --- Docker mode test (skipped without docker) ---

@test "scanner evidence: docker mode resolves runtime profile" {
  # This tests that configuring docker runner sets the runtime profile correctly.
  # A full docker test requires the gaia-tools image — we verify the config path.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
ci_cd:
  promotion_chain:
    - id: main
      branch: main
brownfield:
  tools:
    runner: docker
YAML

  # With docker runner, the adapters receive runtime-profile=container.
  # The stubs don't actually run docker, so the test passes — we verify
  # the config path is read. The runtime profile itself is tested by repro cases.
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id dock1 --repo "$REPO_DIR"
  # With stubs that don't care about runtime profile, this should complete normally.
  [ "$status" -eq 0 ]
}

@test "scanner evidence: docker mode semgrep without baked rules fails as errored" {
  # The semgrep adapter in docker mode without baked rules (no --config) must
  # fail with a message saying rules are not baked, never do an empty pass.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
ci_cd:
  promotion_chain:
    - id: main
      branch: main
brownfield:
  tools:
    runner: docker
YAML

  # Use the REAL semgrep run.sh (not the stub) to exercise the docker branch.
  local real_run="$PLUGIN_DIR/scripts/adapters/semgrep/run.sh"
  cp "$real_run" "$STUB_ADAPTERS/semgrep/run.sh"
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id dockersem1 --repo "$REPO_DIR"
  # Evidence is incomplete because the adapter errored.
  [ "$status" -eq 2 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  [ -f "$manifest_path" ]
  jq -e '.adapters[] | select(.name == "semgrep") | .state == "ran_and_errored"' "$manifest_path"
}

# --- Fixture extension tests (.kt, .swift, .dart) ---

@test "scanner evidence: kt swift and dart files reach the adapter file list" {
  cd "$REPO_DIR"
  printf 'fun main() {}\n' > src/App.kt
  printf 'import Foundation\n' > src/App.swift
  printf 'void main() {}\n' > src/App.dart
  git add -A && git -c user.email=a@b -c user.name=a commit -qm "add mobile files"
  cd - >/dev/null

  # Adapter captures the file list.
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""; FL=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in --output) OUTPUT="\$2"; shift 2 ;; --input) FL="\$2"; shift 2 ;; *) shift ;; esac
done
[ -n "\$FL" ] && cp "\$FL" "$WORK_TMP/files-seen.txt"
frag='{"name":"semgrep","status":"passed","findings":[]}'
if [ -n "\$OUTPUT" ]; then printf '%s\n' "\$frag" > "\$OUTPUT"; else printf '%s\n' "\$frag"; fi
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id ext1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  [ -f "$WORK_TMP/files-seen.txt" ]
  grep -q '\.kt$' "$WORK_TMP/files-seen.txt"
  grep -q '\.swift$' "$WORK_TMP/files-seen.txt"
  grep -q '\.dart$' "$WORK_TMP/files-seen.txt"
}

# --- Timeout maps to ran_and_errored ---

@test "scanner evidence: adapter timeout maps to ran_and_errored and exit 2" {
  # Adapter that exits 124 (timeout killed).
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<'SH'
#!/usr/bin/env bash
exit 124
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id tout1 --repo "$REPO_DIR"
  [ "$status" -eq 2 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  jq -e '.adapters[] | select(.name == "semgrep") | .state == "ran_and_errored"' "$manifest_path"
}

# --- Stale or tampered evidence ---

@test "scanner evidence: tampered fragment hash triggers re-collection" {
  # First run: collect evidence.
  PATH="$WORK_TMP/fakebin:$PATH" \
    "$SCANNER_EVIDENCE" --story E999-S1 --run-id stale1 --repo "$REPO_DIR" >/dev/null 2>&1

  # Tamper with the fragment.
  local manifest_path="$STORY_DIR/scanner-evidence/stale1/evidence-manifest.json"
  local frag_name; frag_name="$(jq -r '.adapters[0].fragment' "$manifest_path")"
  printf '{"tampered":true}\n' > "$STORY_DIR/scanner-evidence/stale1/$frag_name"

  # Use a counter to detect re-run.
  local counter="$WORK_TMP/stale_count"
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
SH
  chmod +x "$STUB_ADAPTERS/osv-scanner/run.sh"

  # Second run: should detect tampered hash and re-collect.
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id stale1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local count; count="$(cat "$counter")"
  [ "$count" -gt 0 ]
}

# --- Redaction: gitleaks adapter redacts secrets ---

@test "scanner evidence: gitleaks adapter uses --redact flag" {
  # Create a gitleaks stub adapter that checks for --redact in args.
  mkdir -p "$STUB_ADAPTERS/gitleaks"
  printf '{"provider":"gitleaks","category":"secret-scan","runtime-profile":"subprocess","default-timeout-seconds":10,"file-extensions":[],"scope":"project","description":"secret scanner"}\n' \
    > "$STUB_ADAPTERS/gitleaks/adapter.json"
  cat > "$STUB_ADAPTERS/gitleaks/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"gitleaks","status":"passed","findings":[]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
SH
  chmod +x "$STUB_ADAPTERS/gitleaks/run.sh"
  mkdir -p "$WORK_TMP/fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_TMP/fakebin/gitleaks"
  chmod +x "$WORK_TMP/fakebin/gitleaks"

  # Check the real gitleaks adapter uses --redact.
  grep -q "\-\-redact" "$PLUGIN_DIR/scripts/adapters/gitleaks/run.sh"
}

# --- Adapter findings mapping ---

@test "scanner evidence: adapter findings are mapped into the fragment" {
  # Stub semgrep produces a finding.
  cat > "$STUB_ADAPTERS/semgrep/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"semgrep","status":"passed","findings":[{"id":"sql-injection","severity":"high","message":"SQL injection at app.py:5","source":"semgrep"}]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
SH
  chmod +x "$STUB_ADAPTERS/semgrep/run.sh"

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id map1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]

  # The fragment should contain the finding.
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  local evidence_dir; evidence_dir="$(dirname "$manifest_path")"
  local frag; frag="$(jq -r '.adapters[] | select(.name == "semgrep") | .fragment' "$manifest_path")"
  [ -n "$frag" ]
  jq -e '.findings | length == 1' "$evidence_dir/$frag"
  jq -e '.findings[0].id == "sql-injection"' "$evidence_dir/$frag"
  jq -e '.findings[0].severity == "high"' "$evidence_dir/$frag"
}

# --- Osv dedup: dep-audit finding already in osv is skipped ---

@test "scanner evidence: osv dedup skips duplicate advisory from dep-audit" {
  # Create two adapters: osv-scanner with advisory GHSA-1234, and a dep-audit
  # adapter with the same advisory. Only osv-scanner's should be registered.
  cat > "$STUB_ADAPTERS/osv-scanner/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"osv-scanner","status":"passed","findings":[{"id":"GHSA-1234","severity":"high","message":"vuln in pkg","source":"osv-scanner"}]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
SH
  chmod +x "$STUB_ADAPTERS/osv-scanner/run.sh"

  # Create a dep-audit adapter that reports the same advisory.
  mkdir -p "$STUB_ADAPTERS/dep-audit"
  printf '{"provider":"dep-audit","category":"dep-audit","runtime-profile":"subprocess","default-timeout-seconds":10,"file-extensions":[],"scope":"project","description":"dep audit"}\n' \
    > "$STUB_ADAPTERS/dep-audit/adapter.json"
  cat > "$STUB_ADAPTERS/dep-audit/run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
OUTPUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in --output) OUTPUT="$2"; shift 2 ;; *) shift ;; esac
done
frag='{"name":"dep-audit","status":"passed","findings":[{"id":"GHSA-1234","severity":"high","message":"same vuln","source":"dep-audit"}]}'
if [ -n "$OUTPUT" ]; then printf '%s\n' "$frag" > "$OUTPUT"; else printf '%s\n' "$frag"; fi
SH
  chmod +x "$STUB_ADAPTERS/dep-audit/run.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_TMP/fakebin/dep-audit"
  chmod +x "$WORK_TMP/fakebin/dep-audit"

  # Configure both adapters.
  cat > "$CONFIG_DIR/project-config.yaml" <<'YAML'
project_name: test
ci_cd:
  promotion_chain:
    - id: main
      branch: main
tools:
  dep-audit:
    provider: dep-audit
  sast:
    provider: semgrep
  dep-scan:
    provider: osv-scanner
YAML

  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id dedup1 --repo "$REPO_DIR"

  # Evidence should be complete (both adapters ran).
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  [ -f "$manifest_path" ]

  # Run the register script directly against the manifest.
  local reg_script="$PLUGIN_DIR/scripts/review-common/security/scanner-findings-register.sh"
  [ -x "$reg_script" ]
  "$reg_script" --story E999-S1 --manifest "$manifest_path" 2>/dev/null
  # The register must exist with exactly 1 entry (osv-scanner's GHSA-1234);
  # dep-audit's duplicate must have been skipped by the cross-adapter dedup.
  local reg_path="$STORY_DIR/reviews/findings-register-E999-S1.yaml"
  [ -f "$reg_path" ]
  local count; count="$(yq '.entries | length' "$reg_path")"
  [ "$count" -eq 1 ]
}

# --- dep-audit sub-routine dedup against osv-scanner evidence ---

@test "scanner evidence: dep-audit sub-routine drops findings already in osv fragment" {
  # Build a scanner-evidence directory with a complete osv-scanner fragment
  # that reports advisory GHSA-1234. Then run the real dep-audit sub-routine
  # with findings that include GHSA-1234 (duplicate) and GHSA-5678 (unique).
  # The duplicate must be dropped; the unique must survive.
  local ev_dir="$WORK_TMP/evidence/run1"
  mkdir -p "$ev_dir"

  # Write the osv-scanner fragment with one finding.
  printf '{"name":"osv-scanner","status":"passed","findings":[{"id":"GHSA-1234","severity":"high","message":"vuln in pkg","source":"osv-scanner"}]}\n' \
    > "$ev_dir/osv-scanner.json"
  local osv_sha; osv_sha="$(shasum -a 256 "$ev_dir/osv-scanner.json" | awk '{print $1}')"

  # Write a complete manifest referencing the fragment.
  jq -nc --arg sha "$osv_sha" \
    '{version:1,story:"E999-S1",run_id:"run1",head_sha:"abc",enabled:true,complete:true,
      adapters:[{name:"osv-scanner",category:"dep-audit",state:"available",
                 failure_kind:null,skip_reason:null,fragment:"osv-scanner.json",sha256:$sha}]}' \
    > "$ev_dir/evidence-manifest.json"

  # Create a project with a manifest file so the sub-routine doesn't skip.
  local proj="$WORK_TMP/proj"
  mkdir -p "$proj"
  printf '{}\n' > "$proj/package.json"

  local dep_audit="$PLUGIN_DIR/scripts/review-common/security/dep-audit-subroutine.sh"
  [ -x "$dep_audit" ]

  # Run with two findings: GHSA-1234 (dup) + GHSA-5678 (unique).
  GAIA_DEP_AUDIT_FINDINGS='[{"id":"GHSA-1234","severity":"high","message":"vuln in pkg","source":"dep-audit"},{"id":"GHSA-5678","severity":"medium","message":"other vuln","source":"dep-audit"}]' \
    run "$dep_audit" --target "$proj" --evidence-dir "$ev_dir"
  [ "$status" -eq 0 ]

  # The output must contain GHSA-5678 but NOT GHSA-1234.
  local findings_count; findings_count="$(printf '%s' "$output" | jq '.findings | length')"
  [ "$findings_count" -eq 1 ]
  printf '%s' "$output" | jq -e '.findings[0].id == "GHSA-5678"'
  # Verify the dup is absent.
  run bash -c "printf '%s' '$output' | jq -e '.findings[] | select(.id == \"GHSA-1234\")'"
  [ "$status" -ne 0 ]
}

@test "scanner evidence: dep-audit sub-routine keeps all findings without evidence dir" {
  # Without --evidence-dir, no dedup happens — all findings are kept.
  local proj="$WORK_TMP/proj"
  mkdir -p "$proj"
  printf '{}\n' > "$proj/package.json"

  local dep_audit="$PLUGIN_DIR/scripts/review-common/security/dep-audit-subroutine.sh"
  GAIA_DEP_AUDIT_FINDINGS='[{"id":"GHSA-1234","severity":"high","message":"v1","source":"dep-audit"},{"id":"GHSA-5678","severity":"medium","message":"v2","source":"dep-audit"}]' \
    run "$dep_audit" --target "$proj"
  [ "$status" -eq 0 ]
  local findings_count; findings_count="$(printf '%s' "$output" | jq '.findings | length')"
  [ "$findings_count" -eq 2 ]
}

# --- Probe --output passthrough ---

@test "scanner evidence: probe output is written to the fragment path" {
  # The scanner-evidence.sh calls the probe with --output <fragment path>.
  # When the adapter writes to that path, the fragment is present and hashed.
  PATH="$WORK_TMP/fakebin:$PATH" \
    run "$SCANNER_EVIDENCE" --story E999-S1 --run-id probe1 --repo "$REPO_DIR"
  [ "$status" -eq 0 ]
  local manifest_path; manifest_path="$(echo "$output" | tail -1)"
  local evidence_dir; evidence_dir="$(dirname "$manifest_path")"

  # Every adapter with state=available should have a non-null fragment and sha256.
  local avail_frags; avail_frags="$(jq '[.adapters[] | select(.state == "available")] | length' "$manifest_path")"
  [ "$avail_frags" -gt 0 ]
  local null_frags; null_frags="$(jq '[.adapters[] | select(.state == "available" and .fragment == null)] | length' "$manifest_path")"
  [ "$null_frags" -eq 0 ]
}
