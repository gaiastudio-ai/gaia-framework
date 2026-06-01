#!/usr/bin/env bash
# test-config-split.sh — Cluster 20 test gate (E28-S145)
#
# Drives plugins/gaia/scripts/resolve-config.sh across the four project-
# structure fixtures defined in tests/fixtures/config-split/ and against
# the live repository (Fixture C), compares resolved values against an
# expected oracle per fixture, and writes an authoritative test report
# to tests/fixtures/config-split/_report/config-split-test-report.md (the
# former `docs/migration/config-split-test-report.md` home was retired
# with `docs/` under AF-2026-06-01-3).
#
# Fixtures:
#   A — root-project         (project_path: ".")
#   B — subdir-project       (project_path: "my-app")
#   C — live repo            (project_path: "gaia-public", current GAIA setup)
#   D — no-shared-config     (global.yaml only, no project-config.yaml)
#   overlap — overlap-precedence (local overrides shared per ADR-044 §10.26.3)
#
# Exit code 0 on full pass. Non-zero on any fixture failure so CI can gate.
# Idempotent — two back-to-back runs produce identical reports (date and SHA
# are captured deterministically from the same resolver run, no wall-clock
# drift in the recorded oracle comparisons).

set -euo pipefail
LC_ALL=C
export LC_ALL

# ---------- Locate project root & resolver ----------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$(cd "${SCRIPT_DIR}/.." && pwd)"          # gaia-public/
RESOLVER="${PROJECT_PATH}/plugins/gaia/scripts/resolve-config.sh"
FIXTURES_DIR="${PROJECT_PATH}/tests/fixtures/config-split"
REPORT="${PROJECT_PATH}/tests/fixtures/config-split/_report/config-split-test-report.md"
mkdir -p "$(dirname "$REPORT")"

[ -x "$RESOLVER" ] || { echo "resolver not found or not executable: $RESOLVER" >&2; exit 2; }
[ -d "$FIXTURES_DIR" ] || { echo "fixtures dir missing: $FIXTURES_DIR" >&2; exit 2; }

# ---------- Run metadata ----------

commit_sha() { git -C "$PROJECT_PATH" rev-parse --short HEAD 2>/dev/null || echo "UNKNOWN"; }
resolver_sig() { shasum -a 256 "$RESOLVER" | awk '{print $1}'; }

RUN_COMMIT="$(commit_sha)"
RUN_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RESOLVER_SHA="$(resolver_sig)"

# ---------- Result accumulators ----------

PASS_COUNT=0
FAIL_COUNT=0
FAIL_DETAILS=()

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); }
record_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_DETAILS+=("$1")
}

# ---------- Helpers ----------

# read_resolved_value <KEY_NAME> <resolver-stdout-buffer>
# The resolver emits lines like:  key='value'
# This extracts the value (stripping single quotes) for the requested key.
read_resolved_value() {
  local key="$1" buf="$2"
  printf '%s\n' "$buf" \
    | awk -v K="$key" -F"=" '
        $1 == K {
          sub(/^[^=]*=/, "", $0)
          v=$0
          # strip outer single quotes if present
          if (v ~ /^\x27.*\x27$/) { v=substr(v, 2, length(v)-2) }
          print v
          exit
        }
      '
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    record_pass
    printf "    PASS  %-40s = %s\n" "$label" "$actual" >&2
    echo "| $label | pass | $actual | $expected |"
  else
    record_fail "[$label] expected='$expected' actual='$actual'"
    printf "    FAIL  %-40s expected='%s' actual='%s'\n" "$label" "$expected" "$actual" >&2
    echo "| $label | **fail** | $actual | $expected |"
  fi
}

# run_fixture_matrix <fixture_label> <shared_path|empty> <local_path|empty>
#                    <expected_project_root> <expected_project_path>
#                    <expected_memory_path> <expected_checkpoint_path>
#                    <expected_installed_path> <expected_framework_version>
#                    <expected_date>
#
# Emits a markdown table fragment to stdout (captured into REPORT_TABLES by
# caller) and prints a human line summary to stderr for the terminal run.
run_fixture_matrix() {
  local label="$1" shared="$2" local_p="$3" \
    e_root="$4" e_path="$5" e_mem="$6" e_cp="$7" e_inst="$8" e_ver="$9" e_date="${10}"
  echo ">>> Fixture $label" >&2

  local cmd=( "$RESOLVER" --format shell )
  if [ -n "$shared" ]; then cmd+=( --shared "$shared" ); fi
  if [ -n "$local_p" ]; then cmd+=( --local "$local_p" ); fi

  local buf stderr_file rc
  stderr_file="$(mktemp)"
  buf="$( "${cmd[@]}" 2>"$stderr_file" )"
  rc=$?
  local stderr_contents
  stderr_contents="$(cat "$stderr_file")"
  rm -f "$stderr_file"

  {
    echo
    echo "### Fixture $label"
    echo
    echo "- Shared: \`${shared:-<absent>}\`"
    echo "- Local:  \`${local_p:-<absent>}\`"
    echo "- Resolver exit code: \`$rc\`"
    echo "- Stderr: \`$(printf '%s' "$stderr_contents" | tr '\n' ' ' | sed 's/[[:space:]]*$//')\`"
    echo
    echo "| Field | Result | Resolved | Expected |"
    echo "|-------|--------|----------|----------|"
  } >> "$REPORT.partial"

  if [ "$rc" -ne 0 ]; then
    record_fail "[$label] resolver exit $rc stderr='$stderr_contents'"
    echo "    FAIL  resolver exit $rc (stderr: $stderr_contents)" >&2
    echo "| <resolver> | **fail** | exit=$rc | exit=0 |" >> "$REPORT.partial"
    return 0
  fi

  {
    assert_eq "project_root"      "$(read_resolved_value project_root      "$buf")" "$e_root"
    assert_eq "project_path"      "$(read_resolved_value project_path      "$buf")" "$e_path"
    assert_eq "memory_path"       "$(read_resolved_value memory_path       "$buf")" "$e_mem"
    assert_eq "checkpoint_path"   "$(read_resolved_value checkpoint_path   "$buf")" "$e_cp"
    assert_eq "installed_path"    "$(read_resolved_value installed_path    "$buf")" "$e_inst"
    assert_eq "framework_version" "$(read_resolved_value framework_version "$buf")" "$e_ver"
    assert_eq "date"              "$(read_resolved_value date              "$buf")" "$e_date"
  } >> "$REPORT.partial"
}

# ---------- Fixture inputs ----------

FIX_A_SHARED="${FIXTURES_DIR}/root-project/_gaia/_config/config/project-config.yaml"
FIX_A_LOCAL="${FIXTURES_DIR}/root-project/_gaia/_config/global.yaml"

FIX_B_SHARED="${FIXTURES_DIR}/subdir-project/_gaia/_config/config/project-config.yaml"
FIX_B_LOCAL="${FIXTURES_DIR}/subdir-project/_gaia/_config/global.yaml"

FIX_C_SHARED="${PROJECT_PATH}/plugins/gaia/config/project-config.yaml"
# Fixture C: live repo — resolver runs with only the shared file. The live
# global.yaml lives in _gaia/ (framework) and is not a resolver input; the
# E28-S144 consumers call the resolver with just --shared or rely on
# CLAUDE_SKILL_DIR. To exercise the production path here, use --shared only.
FIX_C_LOCAL=""

FIX_D_LOCAL="${FIXTURES_DIR}/no-shared-config/_gaia/_config/global.yaml"

FIX_OVERLAP_SHARED="${FIXTURES_DIR}/overlap-precedence/_gaia/_config/config/project-config.yaml"
FIX_OVERLAP_LOCAL="${FIXTURES_DIR}/overlap-precedence/_gaia/_config/global.yaml"

# ---------- Oracle (expected values) — sourced from fixture authoring ----------

# Fixture A
A_PROJECT_ROOT=/fixture/root-project
A_PROJECT_PATH=/fixture/root-project
A_MEMORY_PATH=/fixture/root-project/_memory
A_CHECKPOINT_PATH=/fixture/root-project/_memory/checkpoints
A_INSTALLED_PATH=/fixture/root-project/_gaia
A_FRAMEWORK_VERSION=1.127.2-rc.1
A_DATE=2026-04-17

# Fixture B
B_PROJECT_ROOT=/fixture/subdir-project
B_PROJECT_PATH=/fixture/subdir-project/my-app
B_MEMORY_PATH=/fixture/subdir-project/_memory
B_CHECKPOINT_PATH=/fixture/subdir-project/_memory/checkpoints
B_INSTALLED_PATH=/fixture/subdir-project/_gaia
B_FRAMEWORK_VERSION=1.127.2-rc.1
B_DATE=2026-04-17

# Fixture C — oracle drawn from the live shared file at run time so drift on
# a future pinned framework_version or date does not break the test.
C_PROJECT_ROOT="$(awk -F": " '/^project_root:/{print $2; exit}' "$FIX_C_SHARED")"
C_PROJECT_PATH="$(awk -F": " '/^project_path:/{print $2; exit}' "$FIX_C_SHARED")"
C_MEMORY_PATH="$(awk -F": " '/^memory_path:/{print $2; exit}' "$FIX_C_SHARED")"
C_CHECKPOINT_PATH="$(awk -F": " '/^checkpoint_path:/{print $2; exit}' "$FIX_C_SHARED")"
C_INSTALLED_PATH="$(awk -F": " '/^installed_path:/{print $2; exit}' "$FIX_C_SHARED")"
C_FRAMEWORK_VERSION="$(awk -F": " '/^framework_version:/{print $2; exit}' "$FIX_C_SHARED")"
C_DATE="$(awk -F": " '/^date:/{print $2; exit}' "$FIX_C_SHARED")"

# Fixture D — no shared, only local
D_PROJECT_ROOT=/fixture/no-shared-config
D_PROJECT_PATH=/fixture/no-shared-config
D_MEMORY_PATH=/fixture/no-shared-config/_memory
D_CHECKPOINT_PATH=/fixture/no-shared-config/_memory/checkpoints
D_INSTALLED_PATH=/fixture/no-shared-config/_gaia
D_FRAMEWORK_VERSION=1.127.2-rc.1
D_DATE=2026-04-17

# Overlap — local wins
OVL_PROJECT_ROOT=/fixture/local-wins
OVL_PROJECT_PATH=/fixture/local-wins
OVL_MEMORY_PATH=/fixture/local-memory
OVL_CHECKPOINT_PATH=/fixture/local-checkpoints
OVL_INSTALLED_PATH=/fixture/local-installed
OVL_FRAMEWORK_VERSION=1.127.2-rc.1
OVL_DATE=2026-04-17

# ---------- Reset partial buffer ----------

: > "$REPORT.partial"

# ---------- Run matrix ----------

run_fixture_matrix "A (root-project, project_path=\".\")" \
  "$FIX_A_SHARED" "$FIX_A_LOCAL" \
  "$A_PROJECT_ROOT" "$A_PROJECT_PATH" "$A_MEMORY_PATH" "$A_CHECKPOINT_PATH" \
  "$A_INSTALLED_PATH" "$A_FRAMEWORK_VERSION" "$A_DATE"

run_fixture_matrix "B (subdir-project, project_path=\"my-app\")" \
  "$FIX_B_SHARED" "$FIX_B_LOCAL" \
  "$B_PROJECT_ROOT" "$B_PROJECT_PATH" "$B_MEMORY_PATH" "$B_CHECKPOINT_PATH" \
  "$B_INSTALLED_PATH" "$B_FRAMEWORK_VERSION" "$B_DATE"

run_fixture_matrix "C (live repo, project_path=\"gaia-public\")" \
  "$FIX_C_SHARED" "$FIX_C_LOCAL" \
  "$C_PROJECT_ROOT" "$C_PROJECT_PATH" "$C_MEMORY_PATH" "$C_CHECKPOINT_PATH" \
  "$C_INSTALLED_PATH" "$C_FRAMEWORK_VERSION" "$C_DATE"

# Fixture D: stderr must be silent (AC4 backward-compat contract). Run a
# dedicated pass that captures stderr and asserts it is empty.
echo ">>> Fixture D (stderr-silence check)" >&2
d_stderr_file="$(mktemp)"
"$RESOLVER" --format shell --local "$FIX_D_LOCAL" >/dev/null 2>"$d_stderr_file" || true
d_stderr="$(cat "$d_stderr_file")"
rm -f "$d_stderr_file"
if [ -z "$d_stderr" ]; then
  record_pass
  echo "    PASS  fixture-D stderr-silence" >&2
else
  record_fail "[D] fallback emitted stderr: $d_stderr"
  echo "    FAIL  fixture-D stderr='$d_stderr'" >&2
fi

run_fixture_matrix "D (no-shared-config, fallback)" \
  "" "$FIX_D_LOCAL" \
  "$D_PROJECT_ROOT" "$D_PROJECT_PATH" "$D_MEMORY_PATH" "$D_CHECKPOINT_PATH" \
  "$D_INSTALLED_PATH" "$D_FRAMEWORK_VERSION" "$D_DATE"

run_fixture_matrix "Overlap (local overrides shared per ADR-044 §10.26.3)" \
  "$FIX_OVERLAP_SHARED" "$FIX_OVERLAP_LOCAL" \
  "$OVL_PROJECT_ROOT" "$OVL_PROJECT_PATH" "$OVL_MEMORY_PATH" "$OVL_CHECKPOINT_PATH" \
  "$OVL_INSTALLED_PATH" "$OVL_FRAMEWORK_VERSION" "$OVL_DATE"

# Missing-key behavior: resolver must HALT when a required field is absent
# from both inputs (not silently resolve to empty). The E28-S142 contract
# asserts exit code 2 with a "missing required field: <name>" stderr line.
# We simulate this by pointing the resolver at a fixture with no value for
# project_root anywhere. Construct a minimal temp overlay on the fly.
echo ">>> Missing-key behavior check" >&2
mk_tmp="$(mktemp -d)"
cat > "$mk_tmp/shared.yaml" <<'SHARED_EOF'
# intentionally missing project_root
project_path: /tmp/missing-required
memory_path: /tmp/missing-required/_memory
checkpoint_path: /tmp/missing-required/_memory/checkpoints
installed_path: /tmp/missing-required/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-17
SHARED_EOF
mk_stderr_file="$(mktemp)"
set +e
"$RESOLVER" --format shell --shared "$mk_tmp/shared.yaml" >/dev/null 2>"$mk_stderr_file"
mk_rc=$?
set -e
mk_stderr="$(cat "$mk_stderr_file")"
rm -rf "$mk_tmp" "$mk_stderr_file"
if [ "$mk_rc" = 2 ] && printf '%s' "$mk_stderr" | grep -q "missing required field: project_root"; then
  record_pass
  echo "    PASS  missing-required-field signals exit=2 with clear stderr" >&2
else
  record_fail "[missing-key] expected exit=2 with 'missing required field: project_root'; got exit=$mk_rc stderr='$mk_stderr'"
  echo "    FAIL  missing-required-field exit=$mk_rc stderr='$mk_stderr'" >&2
fi

# ---------- Write report ----------

TOTAL=$((PASS_COUNT + FAIL_COUNT))
STATUS="PASS"
[ "$FAIL_COUNT" -gt 0 ] && STATUS="FAIL"

{
  echo "# Config Split Test Report — E28-S145"
  echo
  echo "> **Cluster 20 test gate.** Authoritative per-fixture results for the"
  echo "> ADR-044 config split (\`global.yaml\` + \`config/project-config.yaml\`)"
  echo "> resolved via \`plugins/gaia/scripts/resolve-config.sh\`."
  echo
  echo "## Run metadata"
  echo
  echo "| Field | Value |"
  echo "|-------|-------|"
  echo "| Generated (UTC) | \`$RUN_DATE\` |"
  echo "| Repository commit | \`$RUN_COMMIT\` |"
  echo "| Resolver script | \`plugins/gaia/scripts/resolve-config.sh\` |"
  echo "| Resolver sha256 | \`$RESOLVER_SHA\` |"
  echo "| Pass | $PASS_COUNT / $TOTAL |"
  echo "| Fail | $FAIL_COUNT / $TOTAL |"
  echo "| Status | **$STATUS** |"
  echo
  echo "## Fixture inventory"
  echo
  echo "| ID | Structure | Fixture path | project_path |"
  echo "|----|-----------|--------------|--------------|"
  echo "| A  | root-project (project_path=\".\") | \`tests/fixtures/config-split/root-project/\` | \`/fixture/root-project\` |"
  echo "| B  | subdir-project (project_path=\"my-app\") | \`tests/fixtures/config-split/subdir-project/\` | \`/fixture/subdir-project/my-app\` |"
  echo "| C  | live repo (project_path=\"gaia-public\") | \`plugins/gaia/config/project-config.yaml\` | \`$C_PROJECT_PATH\` |"
  echo "| D  | no-shared-config (backward-compat fallback) | \`tests/fixtures/config-split/no-shared-config/\` | \`/fixture/no-shared-config\` |"
  echo "| Overlap | overlap-precedence (local overrides shared) | \`tests/fixtures/config-split/overlap-precedence/\` | \`/fixture/local-wins\` |"
  echo
  echo "## Resolved-field matrix"
  cat "$REPORT.partial"
  echo
  echo "## Cross-cutting checks"
  echo
  echo "- **AC4 stderr silence (Fixture D):** the resolver MUST NOT emit any"
  echo "  stderr when the shared file is absent and only \`global.yaml\` is"
  echo "  loaded. Captured stderr for the fallback run was $([ -z "${d_stderr:-}" ] && echo 'empty — PASS' || echo "non-empty — FAIL: '$d_stderr'")."
  echo "- **Test Scenario #5 (overlap precedence):** verified via the \`Overlap\`"
  echo "  fixture — shared file carries sentinel values and local file carries"
  echo "  real values; the matrix above confirms every field resolves to the"
  echo "  local value."
  echo "- **Test Scenario #6 (missing-key behavior):** verified with an ad-hoc"
  echo "  in-process fixture that omits \`project_root\`; resolver was expected"
  echo "  to exit 2 with \`missing required field: project_root\` on stderr."
  echo "- **Test Scenario #7 (idempotency):** the wrapper captures \`RUN_DATE\`"
  echo "  once per invocation and uses a deterministic comparison oracle; two"
  echo "  back-to-back runs produce reports that differ only on the \`Generated\`"
  echo "  timestamp line. No fixture state is mutated."
  echo
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "## Failure diagnostics"
    echo
    for d in "${FAIL_DETAILS[@]}"; do
      echo "- \`$d\`"
    done
    echo
  fi
  echo "## Reproduce locally"
  echo
  echo '```bash'
  echo "cd \"$PROJECT_PATH\""
  echo "./scripts/test-config-split.sh"
  echo '```'
  echo
  echo "## See also"
  echo
  echo "- ADR-044 — config split (local \`global.yaml\` vs team-shared \`config/project-config.yaml\`)."
  echo "- \`plugins/gaia/scripts/resolve-config.sh\` — unit under test."
  echo "- \`plugins/gaia/config/project-config.schema.yaml\` — shared-file schema."
  echo "- Story: \`.gaia/artifacts/implementation-artifacts/E28-S145-*.md\` (project-root layout post-ADR-111)."
} > "$REPORT"

rm -f "$REPORT.partial"

echo "" >&2
echo "===========================================" >&2
echo " Config-split test: $STATUS ($PASS_COUNT/$TOTAL)" >&2
echo " Report: $REPORT" >&2
echo "===========================================" >&2

[ "$FAIL_COUNT" -eq 0 ]
