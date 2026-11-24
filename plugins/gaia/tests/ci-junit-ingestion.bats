#!/usr/bin/env bats
# ci-junit-ingestion.bats — tests for ci-junit-fetch.sh.
# Uses a stubbed gh CLI and real temporary git repos.

load 'test_helper.bash'

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

# ── Helpers ──────────────────────────────────────────────────────────

# _make_repo — create a bare-minimum git repo with a commit.
# Prints the repo path.
_make_repo() {
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config user.name "Test"
  printf 'init\n' > "$repo/init.txt"
  git -C "$repo" add init.txt
  git -C "$repo" commit -q -m "init"
  git -C "$repo" remote add origin "https://github.com/testorg/testrepo.git" 2>/dev/null || true
  printf '%s\n' "$repo"
}

# _make_junit_xml — write a valid JUnit XML file.
# Args: path [tests] [failures] [skipped_count]
_make_junit_xml() {
  local path="$1"
  local tests="${2:-10}"
  local failures="${3:-0}"
  local skipped="${4:-0}"
  cat > "$path" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="$tests" failures="$failures" skipped="$skipped">
  <testsuite name="Suite" tests="$tests" failures="$failures" skipped="$skipped">
    <testcase name="test-pass" classname="Suite" time="0.1"/>
    <system-out>some stdout TOKEN=secret123</system-out>
    <system-err>some stderr</system-err>
  </testsuite>
</testsuites>
XMLEOF
}

# _write_gh_stub — write a gh CLI stub script.
# Args: stub_path, mode, head_sha, junit_data_dir
# mode: ok | no-runs | incomplete | no-artifacts | no-junit |
#       multi-run | reattempt | mixed-case | no-auth
_write_gh_stub() {
  local stub_path="$1" mode="$2" head_sha="$3" junit_dir="$4"
  local log_dir="${5:-}"
  cat > "$stub_path" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail
STUBEOF

  # Embed the mode, SHA and junit path as variables
  printf 'STUB_MODE="%s"\n' "$mode" >> "$stub_path"
  printf 'STUB_SHA="%s"\n' "$head_sha" >> "$stub_path"
  printf 'STUB_JUNIT_DIR="%s"\n' "$junit_dir" >> "$stub_path"
  printf 'STUB_LOG_DIR="%s"\n' "$log_dir" >> "$stub_path"

  cat >> "$stub_path" <<'STUBEOF'

# Log all calls if log dir is set
if [ -n "$STUB_LOG_DIR" ]; then
  printf '%s\n' "$*" >> "$STUB_LOG_DIR/gh-calls.log"
fi

# auth status
if [ "$1" = "auth" ] && [ "${2:-}" = "status" ]; then
  if [ "$STUB_MODE" = "no-auth" ]; then exit 1; fi
  exit 0
fi

# run list
if [ "$1" = "run" ] && [ "$2" = "list" ]; then
  if [ "$STUB_MODE" = "no-runs" ]; then
    printf '[]\n'; exit 0
  fi
  local_status="completed"
  if [ "$STUB_MODE" = "incomplete" ]; then local_status="in_progress"; fi
  local_attempt=1
  if [ "$STUB_MODE" = "reattempt" ]; then local_attempt=2; fi

  if [ "$STUB_MODE" = "multi-run" ]; then
    printf '[{"databaseId":101,"url":"https://github.com/testorg/testrepo/actions/runs/101","headSha":"%s","status":"%s","conclusion":"success","attempt":1,"startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:01:00Z"},{"databaseId":102,"url":"https://github.com/testorg/testrepo/actions/runs/102","headSha":"%s","status":"%s","conclusion":"success","attempt":1,"startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:02:00Z"}]\n' "$STUB_SHA" "$local_status" "$STUB_SHA" "$local_status"
  else
    printf '[{"databaseId":101,"url":"https://github.com/testorg/testrepo/actions/runs/101","headSha":"%s","status":"%s","conclusion":"success","attempt":%d,"startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:02:00Z"}]\n' "$STUB_SHA" "$local_status" "$local_attempt"
  fi
  exit 0
fi

# api (artifact listing)
if [ "$1" = "api" ]; then
  case "$STUB_MODE" in
    no-artifacts) printf '[]' ;;
    no-junit)     printf '[{"name":"coverage-report"}]' ;;
    mixed-case)   printf '[{"name":"JUnit-Results"}]' ;;
    custom-pattern) printf '[{"name":"junit-report"},{"name":"shard-1-timing"}]' ;;
    glob-pattern)   printf '[{"name":"v2.shard-report"},{"name":"v2Xshard-report"}]' ;;
    non-junit-content) printf '[{"name":"junit-report"},{"name":"junit-error-report"}]' ;;
    many-artifacts)
      printf '['
      _ctr=1
      while [ "$_ctr" -le 55 ]; do
        [ "$_ctr" -gt 1 ] && printf ','
        printf '{"name":"junit-shard-%d"}' "$_ctr"
        _ctr=$((_ctr + 1))
      done
      printf ']'
      ;;
    small-many-artifacts)
      printf '['
      _ctr=1
      while [ "$_ctr" -le 10 ]; do
        [ "$_ctr" -gt 1 ] && printf ','
        printf '{"name":"junit-part-%d"}' "$_ctr"
        _ctr=$((_ctr + 1))
      done
      printf ']'
      ;;
    backslash-artifacts) printf '[{"name":"junit-report"},{"name":"bk\\\\slash-results"}]' ;;
    fail-downloads)
      printf '['
      _ctr=1
      while [ "$_ctr" -le 10 ]; do
        [ "$_ctr" -gt 1 ] && printf ','
        printf '{"name":"junit-part-%d"}' "$_ctr"
        _ctr=$((_ctr + 1))
      done
      printf ']'
      ;;
    *)            printf '[{"name":"junit-report"}]' ;;
  esac
  exit 0
fi

# run download
if [ "$1" = "run" ] && [ "$2" = "download" ]; then
  local_dir=""
  local_name=""
  shift 3  # past 'run download <id>'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)  local_dir="$2"; shift 2 ;;
      --name) local_name="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done
  if [ -n "$local_dir" ]; then
    mkdir -p "$local_dir"
    if [ "$STUB_MODE" = "non-junit-content" ] && [ -n "$local_name" ]; then
      case "$local_name" in
        *error*)
          printf '<html><body>Error page</body></html>\n' > "$local_dir/results.xml"
          ;;
        *)
          cp "$STUB_JUNIT_DIR/results.xml" "$local_dir/results.xml"
          ;;
      esac
    else
      cp "$STUB_JUNIT_DIR/results.xml" "$local_dir/results.xml"
    fi
  fi
  if [ "$STUB_MODE" = "fail-downloads" ]; then
    exit 1
  fi
  exit 0
fi

printf 'gh stub: unhandled: %s\n' "$*" >&2
exit 1
STUBEOF

  chmod +x "$stub_path"
}

# _make_config — create a minimal project-config.yaml with ci_platform.
# Args: config_dir [provider] [junit_artifact_pattern]
_make_config() {
  local config_dir="$1" provider="${2:-github-actions}" pattern="${3:-}"
  mkdir -p "$config_dir"
  cat > "$config_dir/project-config.yaml" <<CFGEOF
project:
  name: test-project
ci_platform:
  provider: $provider
CFGEOF
  if [ -n "$pattern" ]; then
    cat >> "$config_dir/project-config.yaml" <<CFGEOF
ci_cd:
  junit_artifact_pattern: "$pattern"
CFGEOF
  fi
}

# _ensure_junit_data — create the shared JUnit fixture directory once.
# Returns the path.  Idempotent within a test.
_ensure_junit_data() {
  local junit_dir="$TEST_TMP/junit-data"
  if [ ! -f "$junit_dir/results.xml" ]; then
    mkdir -p "$junit_dir"
    _make_junit_xml "$junit_dir/results.xml"
  fi
  printf '%s' "$junit_dir"
}

# _setup_stub — set up a gh stub in a temp bin directory.
# Args: mode
# Sets: STUB_BIN_DIR
_setup_stub() {
  local mode="${1:-ok}"
  local junit_dir
  junit_dir="$(_ensure_junit_data)"

  STUB_BIN_DIR="$TEST_TMP/bin-$mode"
  mkdir -p "$STUB_BIN_DIR"
  _write_gh_stub "$STUB_BIN_DIR/gh" "$mode" "$HEAD_SHA" "$junit_dir"
}

# _setup_stub_logged — set up a gh stub with call logging.
# Args: mode
# Sets: STUB_BIN_DIR, STUB_LOG_DIR
_setup_stub_logged() {
  local mode="${1:-ok}"
  local junit_dir
  junit_dir="$(_ensure_junit_data)"

  STUB_LOG_DIR="$TEST_TMP/stub-logs"
  mkdir -p "$STUB_LOG_DIR"

  STUB_BIN_DIR="$TEST_TMP/bin-$mode"
  mkdir -p "$STUB_BIN_DIR"
  _write_gh_stub "$STUB_BIN_DIR/gh" "$mode" "$HEAD_SHA" "$junit_dir" "$STUB_LOG_DIR"
}

# _run_fetch_with_stderr — run ci-junit-fetch.sh capturing stderr to a file.
# Args: stderr_file [extra_env_assignments...]
# Uses: STUB_BIN_DIR, CONFIG_ROOT (or override via env), REPO, OUT_DIR, SCRIPT.
# The function sets up the standard env and runs the script through bash -c so
# both stdout and stderr routing are reliable under bats `run`.
_run_fetch_with_stderr() {
  local stderr_file="$1"; shift
  local extra_env=""
  while [ "$#" -gt 0 ]; do
    extra_env="${extra_env} $1"; shift
  done
  run bash -c "
    export PATH=\"${STUB_BIN_DIR}:\$PATH\"
    export PROJECT_ROOT=\"${PROJECT_ROOT_OVERRIDE:-${CONFIG_ROOT}}\"
    export CLAUDE_PROJECT_ROOT=\"${CLAUDE_PROJECT_ROOT_OVERRIDE:-${CONFIG_ROOT}}\"
    ${extra_env}
    bash \"${SCRIPT}\" --repo \"${REPO}\" --out \"${OUT_DIR}\" 2>\"${stderr_file}\"
  "
}

# ── Setup / teardown ─────────────────────────────────────────────────

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/ci-junit-fetch.sh"
  [ -f "$SCRIPT" ] || fail "ci-junit-fetch.sh not found at $SCRIPT"

  unset GAIA_WORKTREE_MODE GAIA_PARALLEL_EXECUTION

  WORKDIR="$TEST_TMP/work"
  mkdir -p "$WORKDIR"

  REPO="$(_make_repo)"
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
  OUT_DIR="$WORKDIR/evidence"
  mkdir -p "$OUT_DIR"

  # Config root with github-actions
  CONFIG_ROOT="$WORKDIR/cfg"
  _make_config "$CONFIG_ROOT/.gaia/config" "github-actions"
}

teardown() {
  common_teardown
}

# ── Tests ────────────────────────────────────────────────────────────

@test "ci-junit-fetch: missing --repo fails with exit 1" {
  run bash "$SCRIPT" --out "$OUT_DIR"
  [ "$status" -eq 1 ]
}

@test "ci-junit-fetch: missing --out fails with exit 1" {
  run bash "$SCRIPT" --repo "$REPO"
  [ "$status" -eq 1 ]
}

@test "ci-junit-fetch: no ci_platform configured exits 2 with reason" {
  local no_cfg="$WORKDIR/no-config"
  mkdir -p "$no_cfg"
  _setup_stub ok

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$no_cfg" CLAUDE_PROJECT_ROOT="$no_cfg" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no ci_platform configured"* ]]
}

@test "ci-junit-fetch: unsupported provider exits 2" {
  local gl_cfg="$WORKDIR/gl-config"
  _make_config "$gl_cfg/.gaia/config" "gitlab-ci"
  _setup_stub ok

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$gl_cfg" CLAUDE_PROJECT_ROOT="$gl_cfg" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"provider not supported"* ]]
}

@test "ci-junit-fetch: gh not installed exits 2" {
  # When gh is on the same directory as essential tools (common on CI),
  # PATH narrowing would break the script. Instead, verify the contract:
  # the _cjf_unavailable path returns exit 2 with the reason on stdout.
  # The "gh not installed" branch is tested by confirming the script's
  # own guard: if we skip the provider resolution and go straight to
  # the github-actions path, command -v gh is the next gate.
  if command -v gh >/dev/null 2>&1; then
    # gh is installed — test the contract indirectly: remove auth.
    # A stub gh that passes command -v but fails auth exits 2 too.
    _setup_stub no-auth

    run env PATH="$STUB_BIN_DIR:$PATH" \
      PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
      bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not authenticated"* ]]
  else
    # gh not installed — test the real code path directly.
    run env PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
      bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"gh CLI not installed"* ]]
  fi
}

@test "ci-junit-fetch: gh not authenticated exits 2" {
  _setup_stub no-auth

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not authenticated"* ]]
}

@test "ci-junit-fetch: no runs for commit exits 2" {
  _setup_stub no-runs

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no CI runs found"* ]]
}

@test "ci-junit-fetch: incomplete runs exits 2 with reason" {
  _setup_stub incomplete

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CI not complete for head commit"* ]]
}

@test "ci-junit-fetch: no junit artifact on runs exits 2" {
  _setup_stub no-junit

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no JUnit artifacts found"* ]]
}

@test "ci-junit-fetch: successful fetch produces run-records.json and XML" {
  _setup_stub ok

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  [ -f "$OUT_DIR/run-records.json" ]

  local run_count
  run_count="$(jq '.runs | length' "$OUT_DIR/run-records.json")"
  [ "$run_count" -ge 1 ]

  local wcs
  wcs="$(jq '.wall_clock_seconds' "$OUT_DIR/run-records.json")"
  [ "$wcs" -ge 0 ]

  local xml_count
  xml_count="$(find "$OUT_DIR" -name '*.xml' | wc -l | tr -d ' ')"
  [ "$xml_count" -ge 1 ]
}

@test "ci-junit-fetch: multi-run merges and cites both links" {
  _setup_stub multi-run

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  local run_count
  run_count="$(jq '.runs | length' "$OUT_DIR/run-records.json")"
  [ "$run_count" -eq 2 ]

  # wall_clock_seconds is summed (60 + 120 = 180)
  local wcs
  wcs="$(jq '.wall_clock_seconds' "$OUT_DIR/run-records.json")"
  [ "$wcs" -eq 180 ]
}

@test "ci-junit-fetch: re-attempted run records attempt count" {
  _setup_stub reattempt

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  local attempt
  attempt="$(jq '.runs[0].attempt' "$OUT_DIR/run-records.json")"
  [ "$attempt" -eq 2 ]
}

@test "ci-junit-fetch: mixed-case artifact name downloaded" {
  _setup_stub mixed-case

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  local xml_count
  xml_count="$(find "$OUT_DIR" -name '*.xml' | wc -l | tr -d ' ')"
  [ "$xml_count" -ge 1 ]
}

@test "ci-junit-fetch: deterministic — same inputs twice yield same records" {
  _setup_stub ok

  local out1="$WORKDIR/out1" out2="$WORKDIR/out2"
  mkdir -p "$out1" "$out2"

  env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$out1"

  env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$out2"

  diff <(jq -S . "$out1/run-records.json") <(jq -S . "$out2/run-records.json")
}

# ── Repo flag, configurable pattern, content validation, bounds ──────

@test "ci-junit-fetch: gh run list passes repo flag derived from origin remote" {
  _setup_stub_logged ok

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  # gh run list must include --repo with the origin remote's owner/repo
  grep 'run list.*--repo testorg/testrepo' "$STUB_LOG_DIR/gh-calls.log"
}

@test "ci-junit-fetch: gh run download passes repo flag derived from origin remote" {
  _setup_stub_logged ok

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  # gh run download must include --repo with the origin remote's owner/repo
  grep 'run download.*--repo testorg/testrepo' "$STUB_LOG_DIR/gh-calls.log"
  # gh api must use the origin's owner/repo in the endpoint path
  grep 'api repos/testorg/testrepo/' "$STUB_LOG_DIR/gh-calls.log"
}

@test "ci-junit-fetch: custom artifact pattern matches configured name" {
  local custom_cfg="$WORKDIR/custom-cfg"
  _make_config "$custom_cfg/.gaia/config" "github-actions" "shard-*-timing"
  _setup_stub_logged custom-pattern

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$custom_cfg" CLAUDE_PROJECT_ROOT="$custom_cfg" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  # shard-1-timing must be downloaded (matches custom pattern)
  grep 'run download.*--name shard-1-timing' "$STUB_LOG_DIR/gh-calls.log"

  # junit-report must also be downloaded (additive: default + custom)
  grep 'run download.*--name junit-report' "$STUB_LOG_DIR/gh-calls.log"
}

@test "ci-junit-fetch: glob dot in artifact pattern matches literal dot only" {
  local glob_cfg="$WORKDIR/glob-cfg"
  _make_config "$glob_cfg/.gaia/config" "github-actions" "v2.shard"
  _setup_stub_logged glob-pattern

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$glob_cfg" CLAUDE_PROJECT_ROOT="$glob_cfg" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  # v2.shard-report must be downloaded (literal dot matches custom pattern)
  grep 'run download.*--name v2\.shard-report' "$STUB_LOG_DIR/gh-calls.log"

  # v2Xshard-report must NOT be downloaded (dot is literal, not regex any-char)
  local match_count
  match_count="$(grep -c 'run download.*--name v2Xshard-report' "$STUB_LOG_DIR/gh-calls.log" || true)"
  [ "$match_count" -eq 0 ]
}

@test "ci-junit-fetch: absent artifact pattern defaults to junit match" {
  # No junit_artifact_pattern in config — CONFIG_ROOT has no ci_cd block.
  # This is green by design: backward-compatible default.
  _setup_stub ok

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 0 ]

  # Default junit pattern matches the standard artifact
  local xml_count
  xml_count="$(find "$OUT_DIR" -name '*.xml' | wc -l | tr -d ' ')"
  [ "$xml_count" -ge 1 ]
}

@test "ci-junit-fetch: non-junit file discarded with stderr warning" {
  _setup_stub_logged non-junit-content

  local stderr_file="$TEST_TMP/discard-stderr.log"
  _run_fetch_with_stderr "$stderr_file"
  [ "$status" -eq 0 ]

  grep -q 'discarded non-JUnit file' "$stderr_file"

  # The valid JUnit artifact must be present in the output directory.
  local junit_xml_count
  junit_xml_count="$(find "$OUT_DIR" -name '*.xml' -type f | wc -l | tr -d ' ')"
  [ "$junit_xml_count" -ge 1 ] || {
    printf 'expected at least 1 valid JUnit XML in output, got 0\n' >&2
    return 1
  }

  # The discarded non-JUnit content must NOT be present — verify no file
  # under the output directory contains the HTML marker from the stub.
  if grep -rql '<html>' "$OUT_DIR" 2>/dev/null; then
    printf 'expected 0 non-JUnit HTML files in output, but found match\n' >&2
    return 1
  fi
}

@test "ci-junit-fetch: artifact count exceeding bound truncates with warning" {
  _setup_stub_logged many-artifacts

  local stderr_file="$TEST_TMP/bound-stderr.log"
  _run_fetch_with_stderr "$stderr_file"
  [ "$status" -eq 0 ]

  local download_count
  download_count="$(grep -c 'run download' "$STUB_LOG_DIR/gh-calls.log")"
  [ "$download_count" -eq 50 ] || {
    printf 'expected exactly 50 downloads, got %s\n' "$download_count" >&2
    return 1
  }

  grep -q 'artifact bound reached' "$stderr_file"
}

@test "ci-junit-fetch: custom max artifacts env var bounds download count" {
  _setup_stub_logged small-many-artifacts

  local stderr_file="$TEST_TMP/custom-bound-stderr.log"
  _run_fetch_with_stderr "$stderr_file" "export CJF_MAX_ARTIFACTS=3"
  [ "$status" -eq 0 ]

  local download_count
  download_count="$(grep -c 'run download' "$STUB_LOG_DIR/gh-calls.log")"
  [ "$download_count" -eq 3 ] || {
    printf 'expected exactly 3 downloads, got %s\n' "$download_count" >&2
    return 1
  }

  grep -q 'artifact bound reached' "$stderr_file"
}

@test "ci-junit-fetch: exact bound produces all downloads with no truncation warning" {
  _setup_stub_logged small-many-artifacts

  local stderr_file="$TEST_TMP/exact-bound-stderr.log"
  _run_fetch_with_stderr "$stderr_file" "export CJF_MAX_ARTIFACTS=10"
  [ "$status" -eq 0 ]

  local download_count
  download_count="$(grep -c 'run download' "$STUB_LOG_DIR/gh-calls.log")"
  [ "$download_count" -eq 10 ] || {
    printf 'expected 10 downloads, got %s\n' "$download_count" >&2
    return 1
  }

  local warn_count
  warn_count="$(grep -c 'artifact bound reached' "$stderr_file" || true)"
  [ "$warn_count" -eq 0 ]
}

# ── Path helper fallback ───────────────────────────────────────────

# _make_fake_script_tree — create a copy of ci-junit-fetch.sh with a minimal
# resolve-config.sh stub (returns github-actions provider) and a controllable
# lib/gaia-paths.sh.  Args: dest_dir, paths_lib_mode (missing|broken|ok).
_make_fake_script_tree() {
  local dest="$1" mode="$2"
  mkdir -p "$dest/lib"
  cp "$SCRIPT" "$dest/ci-junit-fetch.sh"

  # Minimal resolve-config.sh stub — only supports --field ci_platform.provider
  cat > "$dest/resolve-config.sh" <<'RCEOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--field" ] && [ "${2:-}" = "ci_platform.provider" ]; then
  printf 'github-actions\n'
  exit 0
fi
exit 1
RCEOF
  chmod +x "$dest/resolve-config.sh"

  case "$mode" in
    missing) ;; # no lib/gaia-paths.sh at all
    broken)
      printf '#!/usr/bin/env bash\nreturn 1 2>/dev/null || exit 1\n' \
        > "$dest/lib/gaia-paths.sh"
      ;;
    ok)
      cp "$SCRIPTS_DIR/lib/gaia-paths.sh" "$dest/lib/gaia-paths.sh"
      ;;
  esac
}

@test "ci-junit-fetch: missing gaia-paths.sh warns and falls back to default pattern" {
  _setup_stub ok

  local fake_scripts="$TEST_TMP/fake-scripts"
  _make_fake_script_tree "$fake_scripts" missing

  local stderr_file="$TEST_TMP/paths-warn-stderr.log"
  run bash -c "
    export PATH=\"${STUB_BIN_DIR}:\$PATH\"
    export PROJECT_ROOT=\"${CONFIG_ROOT}\"
    export CLAUDE_PROJECT_ROOT=\"${CONFIG_ROOT}\"
    bash \"${fake_scripts}/ci-junit-fetch.sh\" --repo \"${REPO}\" --out \"${OUT_DIR}\" 2>\"${stderr_file}\"
  "
  # Script still succeeds — falls back to default junit pattern
  [ "$status" -eq 0 ]

  # Warning about missing gaia-paths.sh must appear on stderr
  grep -q 'gaia-paths.sh not found' "$stderr_file"
}

@test "ci-junit-fetch: broken gaia-paths.sh warns and falls back to default pattern" {
  _setup_stub ok

  local fake_scripts="$TEST_TMP/fake-scripts-broken"
  _make_fake_script_tree "$fake_scripts" broken

  local stderr_file="$TEST_TMP/paths-broken-stderr.log"
  run bash -c "
    export PATH=\"${STUB_BIN_DIR}:\$PATH\"
    export PROJECT_ROOT=\"${CONFIG_ROOT}\"
    export CLAUDE_PROJECT_ROOT=\"${CONFIG_ROOT}\"
    bash \"${fake_scripts}/ci-junit-fetch.sh\" --repo \"${REPO}\" --out \"${OUT_DIR}\" 2>\"${stderr_file}\"
  "
  # Script still succeeds — falls back to default junit pattern
  [ "$status" -eq 0 ]

  # Warning about gaia-paths.sh failure must appear on stderr
  grep -q 'gaia-paths.sh failed to source' "$stderr_file"
}

# ── Code-review fixes ──────────────────────────────────────────────

@test "ci-junit-fetch: no origin remote exits 2 as unavailable" {
  _setup_stub ok

  # Remove origin so owner/repo derivation cannot succeed
  git -C "$REPO" remote remove origin

  run env PATH="$STUB_BIN_DIR:$PATH" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not determine owner/repo"* ]]
}

@test "ci-junit-fetch: backslash in glob pattern properly escapes for regex" {
  _setup_stub_logged backslash-artifacts

  local bk_cfg="$WORKDIR/bk-cfg"
  mkdir -p "$bk_cfg/.gaia/config"
  cat > "$bk_cfg/.gaia/config/project-config.yaml" <<'CFGEOF'
project:
  name: test-project
ci_platform:
  provider: github-actions
ci_cd:
  junit_artifact_pattern: 'bk\slash*'
CFGEOF

  local stderr_file="$TEST_TMP/bk-stderr.log"
  PROJECT_ROOT_OVERRIDE="$bk_cfg" CLAUDE_PROJECT_ROOT_OVERRIDE="$bk_cfg" \
    _run_fetch_with_stderr "$stderr_file"
  [ "$status" -eq 0 ]

  # Backslash artifact must be downloaded (escaped backslash matches literal)
  grep -F 'bk\slash-results' "$STUB_LOG_DIR/gh-calls.log" || {
    printf 'expected download of bk\\slash-results artifact\n' >&2
    return 1
  }

  # Default junit artifact must also be downloaded (additive)
  grep 'run download.*--name junit-report' "$STUB_LOG_DIR/gh-calls.log"

  # No jq Regex failure must leak to stderr
  local regex_err_count
  regex_err_count="$(grep -ci 'regex failure' "$stderr_file" || true)"
  [ "$regex_err_count" -eq 0 ]
}

@test "ci-junit-fetch: jq regex error falls back to default junit match" {
  # When the configured pattern produces a jq regex error, the script warns
  # and retries with the default "junit" match.  Trigger this via a jq
  # wrapper that fails with "Regex failure" on non-default regex arguments.
  _setup_stub_logged ok

  local jq_wrapper_dir="$TEST_TMP/jq-wrap-bin"
  mkdir -p "$jq_wrapper_dir"

  local real_jq
  real_jq="$(command -v jq)"

  cat > "$jq_wrapper_dir/jq" <<JQWRAP
#!/usr/bin/env bash
# Delegate to the real jq, but simulate a regex failure when the --arg re
# value is not exactly "junit" (i.e. a combined/custom pattern).
for _a; do
  case "\$_a" in
    junit|junit\\|*) ;;  # default-only or combined — let combined fail
    *)
      # Check if this invocation passes --arg re with a combined pattern
      _has_re=false _re_val=""
      _prev=""
      for _b; do
        if [ "\$_prev" = "re" ] && [ "\$_pprev" = "--arg" ]; then
          _has_re=true; _re_val="\$_b"; break
        fi
        _pprev="\$_prev"; _prev="\$_b"
      done
      if \$_has_re && [ "\$_re_val" != "junit" ]; then
        printf 'jq: error (compile): Regex failure\\n' >&2
        exit 5
      fi
      ;;
  esac
  break  # only inspect first arg shape, then fall through
done
exec "$real_jq" "\$@"
JQWRAP
  chmod +x "$jq_wrapper_dir/jq"

  # Use a config with a custom pattern so the script builds a combined regex.
  local regex_cfg="$WORKDIR/regex-fb-cfg"
  _make_config "$regex_cfg/.gaia/config" "github-actions" "custom-*-report"

  local stderr_file="$TEST_TMP/regex-fb-stderr.log"
  PROJECT_ROOT_OVERRIDE="$regex_cfg" CLAUDE_PROJECT_ROOT_OVERRIDE="$regex_cfg" \
    run bash -c "
      export PATH=\"${jq_wrapper_dir}:${STUB_BIN_DIR}:\$PATH\"
      export PROJECT_ROOT=\"${regex_cfg}\"
      export CLAUDE_PROJECT_ROOT=\"${regex_cfg}\"
      bash \"${SCRIPT}\" --repo \"${REPO}\" --out \"${OUT_DIR}\" 2>\"${stderr_file}\"
    "
  [ "$status" -eq 0 ]

  # The warning about the regex error must appear on stderr.
  grep -q 'regex error for configured pattern' "$stderr_file"

  # Despite the regex error, the default junit match must still download.
  local xml_count
  xml_count="$(find "$OUT_DIR" -name '*.xml' -type f | wc -l | tr -d ' ')"
  [ "$xml_count" -ge 1 ] || {
    printf 'expected at least 1 JUnit XML after fallback, got 0\n' >&2
    return 1
  }
}

@test "ci-junit-fetch: download bound counts attempts not just successes" {
  _setup_stub_logged fail-downloads

  local stderr_file="$TEST_TMP/fail-dl-stderr.log"
  _run_fetch_with_stderr "$stderr_file" "export CJF_MAX_ARTIFACTS=4"
  # Exit status may be 2 (no junit found when every download fails) — not
  # the subject of this test.  We test only the download-attempt count.

  local download_count
  download_count="$(grep -c 'run download' "$STUB_LOG_DIR/gh-calls.log")"
  [ "$download_count" -eq 4 ] || {
    printf 'expected exactly 4 download attempts, got %s\n' "$download_count" >&2
    return 1
  }
}
