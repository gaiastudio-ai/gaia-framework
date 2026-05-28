#!/usr/bin/env bash
# dod-check.sh — gaia-dev-story Step 9 Definition of Done helper (E55-S8)
#
# Purpose:
#   Run a deterministic, dumb sequence of DoD checks and emit one YAML row
#   per check. Step 9 in SKILL.md parses this output to render a
#   human-readable summary. The script itself contains no LLM reasoning.
#
# Output:
#   YAML list, one row per check:
#     - { item: <name>, status: PASSED|FAILED|SKIPPED, output: <captured stdout/stderr> }
#
# Checks (in order):
#   1. build    — runs `build` if available; PASSED if exit 0, otherwise FAILED.
#   2. tests    — resolves a project-level test command and runs it. The
#                 deterministic precedence (E64-S1 AC1 / AC-EC1) is:
#                   (a) project-config.yaml `test_cmd:` (explicit user choice)
#                   (b) package.json `scripts.test` (via `npm test` if present)
#                   (c) bats discovery — `bats tests/*.bats` if `bats` and
#                       any `tests/*.bats` exist
#                 If none resolve, the row is SKIPPED with reason
#                 "no test runner detected" — never FAILED. The system POSIX
#                 `/bin/test` binary is explicitly never used.
#   3. lint     — runs `lint`  if available; PASSED if exit 0, otherwise FAILED.
#   4. secrets  — scans the staged diff and staged file basenames for env-like
#                 files / credentials / canonical secret patterns. Delegates
#                 to dev-story-security-invariants.sh::assert_no_secrets_staged
#                 when available; otherwise inline scan.
#   5. subtasks — counts unchecked subtask boxes in the story file (when
#                 STORY_FILE is provided via env). Always PASSED if STORY_FILE
#                 is unset (no story-file context available).
#
# Usage:
#   dod-check.sh
#
# Environment:
#   STORY_FILE  — optional. Absolute path to the story file for subtask check.
#   PROJECT_PATH — optional. Project root. Defaults to current working dir.
#
# Exit codes:
#   0 — all rows PASSED or SKIPPED
#   1 — at least one row FAILED
#   2 — usage error

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-dev-story/dod-check.sh"

log()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_LIB_DIR="$(cd "$SCRIPT_DIR/../../../scripts/lib" 2>/dev/null && pwd || echo "")"
INVARIANTS_LIB="$PLUGIN_LIB_DIR/dev-story-security-invariants.sh"

# Capture stdout+stderr; preserve exit code regardless of pipefail surprises.
_run_check() {
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  printf '%s\n%d\n' "$out" "$rc"
}

# Emit one YAML row.
_emit_row() {
  local item="$1" status="$2" out="$3"
  # Single-line `output` — collapse newlines, trim length to 200 chars to
  # keep the YAML compact. The Step 9 parser only needs status; output is
  # diagnostic.
  local one_line
  one_line="$(printf '%s' "$out" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-200)"
  # Escape double quotes in output.
  one_line="${one_line//\"/\\\"}"
  printf -- '- { item: %s, status: %s, output: "%s" }\n' "$item" "$status" "$one_line"
}

# Run a named check by trying the project's `<name>` command on PATH.
# If the command is not found (or only resolves to a shell builtin), the
# check is reported as PASSED with a "skipped" output — absence of a tool
# means there is nothing to verify here.
_check_command() {
  local item="$1" cmd="$2"
  local result rc out cmd_path
  # Use `type -P` which ONLY resolves PATH-listed files — bash builtins
  # and aliases are skipped. This matters for the `test` check, since
  # `command -v test` returns the builtin and never the project script.
  cmd_path="$(type -P "$cmd" 2>/dev/null || true)"
  if [ -z "$cmd_path" ] || [ ! -f "$cmd_path" ] || [ ! -x "$cmd_path" ]; then
    # E64-S2 AC1/AC2: SKIPPED is the canonical "nothing to verify" status.
    # Emitting PASSED here historically masked the absence of a real check.
    _emit_row "$item" "SKIPPED" "no '$cmd' command on PATH"
    return 0
  fi
  # Skip the system POSIX `test` binary (`/bin/test`, `/usr/bin/test`) —
  # running it with no args exits 1 and is never a project test runner.
  # Without this guard `_check_command "tests" "test"` would always FAIL
  # on macOS / Linux dev machines that lack a project-local `test` wrapper.
  # E64-S2 AC1: emit SKIPPED (not PASSED) so the row reflects "no test
  # runner detected" defensively, in case any caller routes the `tests`
  # check through `_check_command` instead of `_check_tests`.
  case "$cmd_path" in
    /bin/test|/usr/bin/test|/usr/local/bin/test)
      _emit_row "$item" "SKIPPED" "'$cmd' resolves to system POSIX builtin ($cmd_path) — no test runner detected"
      return 0
      ;;
  esac
  result="$(_run_check "$cmd_path")"
  rc="$(printf '%s' "$result" | tail -1)"
  out="$(printf '%s' "$result" | sed '$d')"
  if [ "$rc" -eq 0 ]; then
    _emit_row "$item" "PASSED" "$out"
    return 0
  fi
  _emit_row "$item" "FAILED" "$out"
  return 1
}

# --- Test-command resolution (E64-S1 AC1 / AC-EC1 / AC-EC2) ---------------
#
# Determine the project test command using a deterministic precedence:
#   1. .gaia/config/project-config.yaml `test_cmd:`   (explicit user choice;
#      legacy config/project-config.yaml is also accepted as fallback)
#   2. package.json `scripts.test`                    (resolved via `npm test`)
#   3. bats discovery on `tests/*.bats`               (if `bats` binary on PATH)
# When nothing resolves, return non-zero — caller emits SKIPPED.
#
# Outputs the resolved command on stdout (single token or quoted argv string)
# in a form that survives `bash -c "$cmd"`.
_resolve_test_cmd() {
  # 1. project-config.yaml test_cmd — E96-S1 / ADR-111: prefer .gaia/config/,
  # fall back to legacy config/.
  local _cfg=""
  if [ -f ".gaia/config/project-config.yaml" ]; then
    _cfg=".gaia/config/project-config.yaml"
  elif [ -f "config/project-config.yaml" ]; then
    _cfg="config/project-config.yaml"
  fi
  if [ -n "$_cfg" ]; then
    local cmd
    # Match a top-level `test_cmd: <value>` line. Strip surrounding quotes
    # and trailing whitespace; ignore comments after the value.
    cmd="$(awk '
      /^[[:space:]]*test_cmd[[:space:]]*:/ {
        sub(/^[^:]*:[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        sub(/[[:space:]]+$/, "")
        n = length($0)
        if (n >= 2 && substr($0, 1, 1) == "\"" && substr($0, n, 1) == "\"") {
          print substr($0, 2, n - 2); exit
        }
        if (n >= 2 && substr($0, 1, 1) == "'"'"'" && substr($0, n, 1) == "'"'"'") {
          print substr($0, 2, n - 2); exit
        }
        print; exit
      }
    ' "$_cfg")"
    if [ -n "$cmd" ]; then
      printf '%s\n' "$cmd"
      return 0
    fi
    # 1b. AF-2026-05-24-14 / Test02 F-10: also check the canonical
    # test_execution.tier_1.command (added by AF-2026-05-22-6 Bug-6).
    # The legacy single `test_cmd:` key is preferred for backward compat,
    # but post-AF-22-6 projects only use the nested form. Use yq when
    # available; fall back to awk.
    if command -v yq >/dev/null 2>&1; then
      cmd="$(yq eval '.test_execution.tier_1.command // ""' "$_cfg" 2>/dev/null || echo "")"
      if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
        printf '%s\n' "$cmd"
        return 0
      fi
    fi
  fi
  # 1c. AF-2026-05-24-14 / Test02 F-10: pytest fallback. If pytest is on
  # PATH AND there's a tests/ directory with at least one test_*.py file,
  # use pytest. This catches the common pytest+greenfield case where
  # neither test_cmd nor test_execution is hydrated but the operator
  # clearly has a working pytest setup.
  if command -v pytest >/dev/null 2>&1; then
    if find tests -maxdepth 3 -type f -name 'test_*.py' -print -quit 2>/dev/null | grep -q .; then
      printf 'pytest tests/\n'
      return 0
    fi
  fi
  # 2. package.json scripts.test (only if `npm` is on PATH)
  if [ -f "package.json" ] && command -v npm >/dev/null 2>&1; then
    if grep -Eq '"test"[[:space:]]*:' package.json; then
      printf 'npm test\n'
      return 0
    fi
  fi
  # 3. bats discovery on tests/*.bats
  if command -v bats >/dev/null 2>&1; then
    # Use a glob expansion guarded by nullglob so the test for `[ -e $file ]`
    # works even when no match is found.
    local first_match
    first_match="$(find tests -maxdepth 2 -name '*.bats' -print -quit 2>/dev/null || true)"
    if [ -n "$first_match" ]; then
      printf 'bats tests\n'
      return 0
    fi
  fi
  return 1
}

# Run the resolved test command. Emits PASSED / FAILED / SKIPPED YAML row.
_check_tests() {
  local cmd out rc
  if ! cmd="$(_resolve_test_cmd)"; then
    _emit_row "tests" "SKIPPED" "no test runner detected"
    return 0
  fi
  set +e
  out="$(bash -c "$cmd" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    _emit_row "tests" "PASSED" "$out"
    return 0
  fi
  _emit_row "tests" "FAILED" "$out"
  return 1
}

# --- Build / lint command resolution (AF-2026-05-27-8 / Test06 F-013) -------
#
# Previously build + lint resolved ONLY via `type -P <name>` (a PATH binary
# literally named "build" / "lint"), while tests used the rich _resolve_test_cmd
# precedence. The split meant a project with `npm run build` + `npm run lint`
# scripts (the overwhelmingly common case) reported build/lint as SKIPPED while
# tests PASSED — an inconsistent, confusing DoD result. _resolve_script_cmd
# brings build + lint to parity with tests:
#   1. .gaia/config/project-config.yaml `<name>_cmd:` (then legacy config/)
#   2. package.json `scripts.<name>` → `npm run <name>`
#   3. a PATH binary literally named <name>
# Returns the resolved command on stdout (exit 0), or non-zero when nothing
# resolves (caller emits SKIPPED).
_resolve_script_cmd() {
  local name="$1"
  # 1. project-config.yaml <name>_cmd
  local _cfg=""
  if [ -f ".gaia/config/project-config.yaml" ]; then
    _cfg=".gaia/config/project-config.yaml"
  elif [ -f "config/project-config.yaml" ]; then
    _cfg="config/project-config.yaml"
  fi
  if [ -n "$_cfg" ]; then
    local cmd
    cmd="$(awk -v key="${name}_cmd" '
      $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
        sub(/^[^:]*:[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        sub(/[[:space:]]+$/, "")
        n = length($0)
        if (n >= 2 && substr($0,1,1) == "\"" && substr($0,n,1) == "\"") { print substr($0,2,n-2); exit }
        if (n >= 2 && substr($0,1,1) == "'"'"'" && substr($0,n,1) == "'"'"'") { print substr($0,2,n-2); exit }
        print; exit
      }
    ' "$_cfg")"
    if [ -n "$cmd" ]; then
      printf '%s\n' "$cmd"
      return 0
    fi
  fi
  # 2. package.json scripts.<name> (only if npm on PATH)
  if [ -f "package.json" ] && command -v npm >/dev/null 2>&1; then
    if grep -Eq "\"${name}\"[[:space:]]*:" package.json; then
      printf 'npm run %s\n' "$name"
      return 0
    fi
  fi
  # 3. a PATH binary literally named <name>
  local cmd_path
  cmd_path="$(type -P "$name" 2>/dev/null || true)"
  if [ -n "$cmd_path" ] && [ -x "$cmd_path" ]; then
    printf '%s\n' "$cmd_path"
    return 0
  fi
  return 1
}

# _check_script <item> <name> — run the resolved build/lint command, emit a row.
# Mirrors _check_tests so build / lint / tests now share one resolution model.
_check_script() {
  local item="$1" name="$2" cmd out rc
  if ! cmd="$(_resolve_script_cmd "$name")"; then
    _emit_row "$item" "SKIPPED" "no '$name' command (project-config ${name}_cmd, package.json scripts.${name}, or PATH binary)"
    return 0
  fi
  set +e
  out="$(bash -c "$cmd" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    _emit_row "$item" "PASSED" "$out"
    return 0
  fi
  _emit_row "$item" "FAILED" "$out"
  return 1
}

# Inline secrets scan fallback (when the lib is not available).
_inline_secrets_scan() {
  local files diff base pat patterns
  files="$(git diff --cached --name-only 2>/dev/null || true)"
  if [ -n "$files" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      base="$(basename "$f")"
      if printf '%s' "$base" | grep -Eq '^\.env(\..+)?$'; then
        echo "secrets: staged env-like file: $f"
        return 1
      fi
      if printf '%s' "$base" | grep -qiE 'credentials'; then
        echo "secrets: staged credentials-like file: $f"
        return 1
      fi
    done <<<"$files"
  fi
  diff="$(git diff --cached 2>/dev/null || true)"
  if [ -n "$diff" ]; then
    patterns=(
      'AKIA[0-9A-Z]{16}'
      'gh[ps]_[A-Za-z0-9]{36,}'
      'Bearer[[:space:]]+[A-Za-z0-9._-]+'
      'xox[baprs]-[A-Za-z0-9-]{10,}'
    )
    for pat in "${patterns[@]}"; do
      if printf '%s' "$diff" | grep -Eq "$pat"; then
        echo "secrets: staged content matches pattern: $pat"
        return 1
      fi
    done
  fi
  return 0
}

_check_secrets() {
  local out rc
  if [ -f "$INVARIANTS_LIB" ]; then
    # shellcheck disable=SC1090
    set +e
    out="$(bash -c "source '$INVARIANTS_LIB' && assert_no_secrets_staged" 2>&1)"
    rc=$?
    set -e
  else
    set +e
    out="$(_inline_secrets_scan 2>&1)"
    rc=$?
    set -e
  fi
  if [ "$rc" -eq 0 ]; then
    _emit_row "secrets" "PASSED" "no secrets in staged diff"
    return 0
  fi
  _emit_row "secrets" "FAILED" "$out"
  return 1
}

_check_subtasks() {
  if [ -z "${STORY_FILE:-}" ] || [ ! -f "${STORY_FILE:-/dev/null}" ]; then
    _emit_row "subtasks" "PASSED" "skipped: STORY_FILE unset"
    return 0
  fi
  # E64-S1 AC2 / E64-S2 AC3: only count `- [ ]` items inside the
  # `## Tasks / Subtasks` section. Unchecked items in `## Definition of
  # Done` (e.g., "PR merged to staging" pre-merge) and `## Acceptance
  # Criteria` are intentionally excluded — they are not subtasks and
  # reflect intentional pre-merge state.
  #
  # Heading match is anchored: literal `## ` prefix + the words
  # "tasks / subtasks" with arbitrary case and tolerant of trailing
  # whitespace. Lowercase-normalize the line, strip trailing whitespace,
  # then compare for exact equality with `## tasks / subtasks`. Any other
  # `^## ` line closes the section. Avoids the legacy fuzzy / case-
  # sensitive `==` comparison that silently dropped sections like
  # `## tasks / subtasks` or `## Tasks / Subtasks   ` (story scenario 4).
  local unchecked
  unchecked="$(awk '
    BEGIN { in_section = 0; count = 0 }
    {
      line = $0
      sub(/[[:space:]]+$/, "", line)
      lower = tolower(line)
      if (lower == "## tasks / subtasks") { in_section = 1; next }
      if (in_section && line ~ /^## /) { in_section = 0 }
      if (in_section && line ~ /^[[:space:]]*-[[:space:]]+\[ \]/) count++
    }
    END { print count }
  ' "$STORY_FILE")"
  if [ "$unchecked" -gt 0 ]; then
    _emit_row "subtasks" "FAILED" "unchecked subtask count: $unchecked"
    return 1
  fi
  _emit_row "subtasks" "PASSED" "all subtasks checked"
  return 0
}

# ---------- Main ----------
overall=0
# AF-2026-05-27-8 / Test06 F-013: build + lint now use _check_script (same
# config → package.json scripts → PATH precedence as tests) instead of the
# PATH-binary-only _check_command, so `npm run build` / `npm run lint` projects
# no longer get a spurious SKIPPED while tests PASS.
_check_script "build" "build" || overall=1
_check_tests                  || overall=1
_check_script "lint"  "lint"  || overall=1
_check_secrets                 || overall=1
_check_subtasks                || overall=1

exit "$overall"
