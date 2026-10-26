#!/usr/bin/env bats
# dotted-path-handling.bats — regression tests for regex metacharacter
# handling in sarif-merge.sh path canonicalization and resolve-config.sh
# relative path resolution.
#
# Covers:
#   - sarif-merge.sh: literal path stripping (no regex) with dots, brackets,
#     parentheses in the repo root path.
#   - resolve-config.sh: relative memory_path / checkpoint_path / project_root
#     / artifact-dir values resolved to absolute paths anchored at the config
#     directory owner (not the caller's CWD).
#
# All fixtures use BATS_TEST_TMPDIR — nothing touches the real plugin tree.

load 'test_helper.bash'

setup() {
  common_setup
  MERGE="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/sarif-merge.sh"
  RESOLVE="$SCRIPTS_DIR/resolve-config.sh"
  export MERGE RESOLVE

  # Isolated sarif dirs.
  export SARIF_INPUT_DIR="$TEST_TMP/sarif-in"
  export SARIF_MERGED_OUT="$TEST_TMP/brownfield-sarif-merged.json"
  mkdir -p "$SARIF_INPUT_DIR"

  # Fake sarif CLI (same pattern as sarif-multitool-merge.bats).
  FAKE_BIN="$TEST_TMP/bin"
  mkdir -p "$FAKE_BIN"
  _mk_sarif_shim
  export FAKE_BIN
}
teardown() { common_teardown; }

# ---------- Helpers --------------------------------------------------------

_mk_sarif_shim() {
  cat > "$FAKE_BIN/sarif" <<'SHIMEOF'
#!/usr/bin/env bash
sub="$1"; shift || true
[ "$sub" = "merge" ] || { echo "fake-sarif: unsupported $sub" >&2; exit 2; }
OUTDIR="."; OUTFILE="merged.sarif"; inputs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-directory) OUTDIR="$2"; shift 2 ;;
    --output-file)      OUTFILE="$2"; shift 2 ;;
    *)                  inputs+=("$1"); shift ;;
  esac
done
runs="[]"
for f in "${inputs[@]}"; do
  [ -f "$f" ] || continue
  if ! jq -e '.version=="2.1.0" and (.runs|type=="array")' "$f" >/dev/null 2>&1; then
    echo "fake-sarif: non-conformant: $f" >&2; exit 3
  fi
  runs="$(jq -s '.[0] + .[1]' <(printf '%s' "$runs") <(jq '.runs' "$f"))"
done
mkdir -p "$OUTDIR"
jq -n --argjson runs "$runs" \
  '{"$schema":"https://json.schemastore.org/sarif-2.1.0.json","version":"2.1.0","runs":$runs}' \
  > "$OUTDIR/$OUTFILE"
SHIMEOF
  chmod +x "$FAKE_BIN/sarif"
}

_mk_sarif_input() {
  # $1=filename $2=tool $3=uri
  cat > "$SARIF_INPUT_DIR/$1" <<JSON
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"$2"}},"results":[{"ruleId":"R1","locations":[{"physicalLocation":{"artifactLocation":{"uri":"$3"}}}]}]}]}
JSON
}

# Build a canonical .gaia/config/project-config.yaml under $1.
# Remaining args are key=value lines appended verbatim.
_mk_config() {
  local dir="$1"; shift
  mkdir -p "$dir/.gaia/config"
  {
    for kv in "$@"; do
      printf '%s\n' "$kv"
    done
  } > "$dir/.gaia/config/project-config.yaml"
}

# ---------- sarif-merge.sh: dotted repo path (AC1) ------------------------

@test "sarif-merge canonicalizes URIs with dotted repo root" {
  local root="$TEST_TMP/my.app"
  _mk_sarif_input grype.sarif grype "$root/src/app.py"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  [ "$output" = "src/app.py" ] || false
}

@test "sarif-merge canonicalizes URIs with worktree-style dotted path" {
  local root="$TEST_TMP/.gaia-worktrees/e900-s1.fix"
  mkdir -p "$root"
  _mk_sarif_input semgrep.sarif semgrep "$root/lib/handler.js"
  _mk_sarif_input gitleaks.sarif gitleaks "config/settings.py"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '[.runs[].results[0].locations[0].physicalLocation.artifactLocation.uri] | sort | join(",")' "$SARIF_MERGED_OUT"
  [ "$output" = "config/settings.py,lib/handler.js" ] || false
}

@test "sarif-merge canonicalizes URIs with brackets in path" {
  local root="$TEST_TMP/proj[v2]"
  mkdir -p "$root"
  _mk_sarif_input grype.sarif grype "$root/src/main.go"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  [ "$output" = "src/main.go" ] || false
}

@test "sarif-merge canonicalizes URIs with parentheses in path" {
  local root="$TEST_TMP/proj(dev)"
  mkdir -p "$root"
  _mk_sarif_input grype.sarif grype "$root/index.ts"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  [ "$output" = "index.ts" ] || false
}

@test "sarif-merge canonicalizes file:// URIs with dotted path" {
  local root="$TEST_TMP/my.app"
  _mk_sarif_input semgrep.sarif semgrep "file://$root/views.py"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  [ "$output" = "views.py" ] || false
}

@test "sarif-merge leaves already-relative URIs unchanged with dotted root" {
  local root="$TEST_TMP/my.app"
  _mk_sarif_input gitleaks.sarif gitleaks "config/secrets.env"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  [ "$output" = "config/secrets.env" ] || false
}

@test "sarif-merge does not strip sibling path with dotted root" {
  # /x/my.app/ must not match /x/myXapp/f (literal, not regex)
  local root="$TEST_TMP/my.app"
  local sibling="$TEST_TMP/myXapp"
  mkdir -p "$sibling"
  _mk_sarif_input grype.sarif grype "$sibling/f.py"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  # URI must NOT be stripped to "f.py" — the root prefix does not match.
  # The canon function strips the leading / from unmatched absolute paths,
  # so the result is the path without the leading /.
  local expected="${sibling#/}/f.py"
  [ "$output" = "$expected" ] || false
}

@test "sarif-merge handles trailing slash in repo root" {
  local root="$TEST_TMP/trail"
  mkdir -p "$root"
  _mk_sarif_input grype.sarif grype "$root/src/a.py"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root/" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  [ "$output" = "src/a.py" ] || false
}

# ---------- resolve-config.sh: relative path resolution (AC2) -------------

@test "resolve-config resolves relative project_root and memory_path from subdir" {
  # Real-world shape: project_root: ".", memory_path: ".gaia/memory"
  # Run from a worktree-like subdir — should anchor to config owner, not CWD.
  local proj="$TEST_TMP/project-a"
  _mk_config "$proj" \
    "project_root: ." \
    "project_path: $proj/app" \
    "memory_path: .gaia/memory" \
    "checkpoint_path: .gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  # Run from a subdirectory (simulates worktree CWD)
  mkdir -p "$proj/sub/deep"
  cd "$proj/sub/deep"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  /usr/bin/grep -Fq "project_root='${proj}'" <<< "$output" || false
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
  /usr/bin/grep -Fq "checkpoint_path='${proj}/.gaia/memory/checkpoints'" <<< "$output" || false
}

@test "resolve-config keeps absolute paths unchanged" {
  local proj="$TEST_TMP/project-b"
  _mk_config "$proj" \
    "project_root: $proj" \
    "project_path: $proj/app" \
    "memory_path: $proj/.gaia/memory" \
    "checkpoint_path: $proj/.gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  /usr/bin/grep -Fq "project_root='${proj}'" <<< "$output" || false
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
}

@test "resolve-config resolves relative artifact paths to absolute" {
  local proj="$TEST_TMP/project-c"
  _mk_config "$proj" \
    "project_root: ." \
    "project_path: $proj/app" \
    "memory_path: .gaia/memory" \
    "checkpoint_path: .gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01" \
    "test_artifacts: docs/test-artifacts" \
    "planning_artifacts: docs/planning-artifacts" \
    "implementation_artifacts: docs/implementation-artifacts" \
    "creative_artifacts: docs/creative-artifacts"
  mkdir -p "$proj/other"
  cd "$proj/other"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  /usr/bin/grep -Fq "test_artifacts='${proj}/docs/test-artifacts'" <<< "$output" || false
  /usr/bin/grep -Fq "planning_artifacts='${proj}/docs/planning-artifacts'" <<< "$output" || false
  /usr/bin/grep -Fq "implementation_artifacts='${proj}/docs/implementation-artifacts'" <<< "$output" || false
  /usr/bin/grep -Fq "creative_artifacts='${proj}/docs/creative-artifacts'" <<< "$output" || false
}

@test "resolve-config output has no /. segments or trailing slash" {
  local proj="$TEST_TMP/project-d"
  _mk_config "$proj" \
    "project_root: ." \
    "project_path: $proj/app" \
    "memory_path: ./.gaia/memory" \
    "checkpoint_path: ./.gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  # No /. or trailing /
  if /usr/bin/grep -qE "'/[^']*(/\./|/\.')" <<< "$output"; then
    echo "output contains /. segment"; false
  fi
}

@test "resolve-config handles dotted path in project root" {
  local proj="$TEST_TMP/my.app"
  _mk_config "$proj" \
    "project_root: $proj" \
    "project_path: $proj/app" \
    "memory_path: .gaia/memory" \
    "checkpoint_path: .gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
}

@test "resolve-config handles brackets in project root path" {
  local proj="$TEST_TMP/proj[v2]"
  _mk_config "$proj" \
    "project_root: $proj" \
    "project_path: $proj/app" \
    "memory_path: .gaia/memory" \
    "checkpoint_path: .gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
}

@test "resolve-config handles parentheses in project root path" {
  local proj="$TEST_TMP/proj(dev)"
  _mk_config "$proj" \
    "project_root: $proj" \
    "project_path: $proj/app" \
    "memory_path: .gaia/memory" \
    "checkpoint_path: .gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
}

@test "resolve-config handles spaces in project root path" {
  local proj="$TEST_TMP/my project"
  _mk_config "$proj" \
    "project_root: $proj" \
    "project_path: $proj/app" \
    "memory_path: .gaia/memory" \
    "checkpoint_path: .gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
}

@test "resolve-config cache returns same values from different CWDs" {
  local proj="$TEST_TMP/cache-test"
  _mk_config "$proj" \
    "project_root: ." \
    "project_path: $proj/app" \
    "memory_path: .gaia/memory" \
    "checkpoint_path: .gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  mkdir -p "$proj/dir-a" "$proj/dir-b"
  local sid="test-cache-$$"
  # Run from dir-a
  cd "$proj/dir-a"
  TMPDIR="$TEST_TMP" GAIA_NO_PROJECT_WALKUP=1 GAIA_SESSION_ID="$sid" \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml" --all --cache
  [ "$status" -eq 0 ] || false
  local out_a="$output"
  # Run from dir-b (should give same paths)
  cd "$proj/dir-b"
  TMPDIR="$TEST_TMP" GAIA_NO_PROJECT_WALKUP=1 GAIA_SESSION_ID="$sid" \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml" --all --cache
  [ "$status" -eq 0 ] || false
  local out_b="$output"
  [ "$out_a" = "$out_b" ] || { echo "CWD-dependent output"; echo "--- dir-a:"; echo "$out_a"; echo "--- dir-b:"; echo "$out_b"; false; }
  # Clean up cache files.
  rm -f "$TEST_TMP"/gaia-config-cache-"$sid"*.eval 2>/dev/null || true
}

# ---------- legacy config/ anchor -----------------------------------------

@test "resolve-config anchors relative project_root via legacy config/ layout" {
  # Legacy layout: config/project-config.yaml (not .gaia/config/)
  local proj="$TEST_TMP/legacy-proj"
  mkdir -p "$proj/config"
  cat > "$proj/config/project-config.yaml" <<YAML
project_root: .
project_path: $proj/app
memory_path: .gaia/memory
checkpoint_path: .gaia/memory/checkpoints
installed_path: $proj/_gaia
framework_version: 1.200.0
date: 1970-01-01
YAML
  mkdir -p "$proj/sub"
  cd "$proj/sub"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  # project_root should resolve to the legacy root (parent of config/)
  /usr/bin/grep -Fq "project_root='${proj}'" <<< "$output" || false
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
}

# ---------- --shared outside any config/ directory ------------------------

@test "resolve-config anchors to shared file dir when outside config/" {
  local proj="$TEST_TMP/freeform"
  mkdir -p "$proj/custom"
  cat > "$proj/custom/my-config.yaml" <<YAML
project_root: .
project_path: $proj/app
memory_path: .gaia/memory
checkpoint_path: .gaia/memory/checkpoints
installed_path: $proj/_gaia
framework_version: 1.200.0
date: 1970-01-01
YAML
  mkdir -p "$proj/other"
  cd "$proj/other"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/custom/my-config.yaml"
  [ "$status" -eq 0 ] || false
  # Should anchor to the shared file's directory, not CWD
  /usr/bin/grep -Fq "project_root='${proj}/custom'" <<< "$output" || false
}

# ---------- sarif path-boundary test --------------------------------------

@test "sarif-merge prefix-sibling not stripped without trailing slash boundary" {
  # root=/x/trail (no trailing /) must NOT match /x/trailblazer/f.py.
  # The script appends / to enforce a path-boundary match. Without it,
  # startswith("/x/trail") would match "/x/trailblazer/f.py".
  local root="$TEST_TMP/trail"
  local sibling="$TEST_TMP/trailblazer"
  mkdir -p "$root" "$sibling"
  _mk_sarif_input grype.sarif grype "$sibling/f.py"
  PATH="$FAKE_BIN:$PATH" \
    GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=true \
    GAIA_BROWNFIELD_SARIF_MERGE_ENABLED=true \
    GAIA_REPO_ROOT="$root" \
    run bash "$MERGE"
  [ "$status" -eq 0 ] || false
  run jq -r '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "$SARIF_MERGED_OUT"
  # Must NOT be stripped to "blazer/f.py" — the prefix /trail does not end at
  # a path boundary relative to /trailblazer. The full sibling path (minus
  # leading /) should survive.
  local expected="${sibling#/}/f.py"
  [ "$output" = "$expected" ] || false
}

# ---------- normalize collapses // ----------------------------------------

@test "resolve-config normalizes double slashes in paths" {
  local proj="$TEST_TMP/dblslash"
  _mk_config "$proj" \
    "project_root: $proj" \
    "project_path: $proj/app" \
    "memory_path: $proj//.gaia//memory" \
    "checkpoint_path: $proj/.gaia/memory/checkpoints" \
    "installed_path: $proj/_gaia" \
    "framework_version: 1.200.0" \
    "date: 1970-01-01"
  GAIA_NO_PROJECT_WALKUP=1 \
    run bash "$RESOLVE" --shared "$proj/.gaia/config/project-config.yaml"
  [ "$status" -eq 0 ] || false
  # Double slashes should be collapsed
  /usr/bin/grep -Fq "memory_path='${proj}/.gaia/memory'" <<< "$output" || false
}
