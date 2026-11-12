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
  cat > "$stub_path" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail
STUBEOF

  # Embed the mode, SHA and junit path as variables
  printf 'STUB_MODE="%s"\n' "$mode" >> "$stub_path"
  printf 'STUB_SHA="%s"\n' "$head_sha" >> "$stub_path"
  printf 'STUB_JUNIT_DIR="%s"\n' "$junit_dir" >> "$stub_path"

  cat >> "$stub_path" <<'STUBEOF'

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
    *)            printf '[{"name":"junit-report"}]' ;;
  esac
  exit 0
fi

# run download
if [ "$1" = "run" ] && [ "$2" = "download" ]; then
  local_dir=""
  shift 3  # past 'run download <id>'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)  local_dir="$2"; shift 2 ;;
      --name) shift 2 ;;
      *)      shift ;;
    esac
  done
  if [ -n "$local_dir" ]; then
    mkdir -p "$local_dir"
    cp "$STUB_JUNIT_DIR/results.xml" "$local_dir/results.xml"
  fi
  exit 0
fi

printf 'gh stub: unhandled: %s\n' "$*" >&2
exit 1
STUBEOF

  chmod +x "$stub_path"
}

# _make_config — create a minimal project-config.yaml with ci_platform.
_make_config() {
  local config_dir="$1" provider="${2:-github-actions}"
  mkdir -p "$config_dir"
  cat > "$config_dir/project-config.yaml" <<CFGEOF
project:
  name: test-project
ci_platform:
  provider: $provider
CFGEOF
}

# _setup_stub — set up a gh stub in a temp bin directory.
# Args: mode
# Sets: STUB_BIN_DIR
_setup_stub() {
  local mode="${1:-ok}"
  local junit_dir="$TEST_TMP/junit-data"
  mkdir -p "$junit_dir"
  _make_junit_xml "$junit_dir/results.xml"

  STUB_BIN_DIR="$TEST_TMP/bin-$mode"
  mkdir -p "$STUB_BIN_DIR"
  _write_gh_stub "$STUB_BIN_DIR/gh" "$mode" "$HEAD_SHA" "$junit_dir"
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
  run env PATH="/usr/bin:/bin" \
    PROJECT_ROOT="$CONFIG_ROOT" CLAUDE_PROJECT_ROOT="$CONFIG_ROOT" \
    bash "$SCRIPT" --repo "$REPO" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"gh CLI not installed"* ]]
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
