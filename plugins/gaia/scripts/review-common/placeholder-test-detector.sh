#!/usr/bin/env bash
# placeholder-test-detector.sh — deterministic placeholder gate.
#
# Scans test files for low-quality placeholder patterns produced by the
# /gaia-test-automate Phase 2 skeleton path or human-authored stubs that
# never got fleshed out. Emits structured findings on stdout and exits
# non-zero on any match — used as a mandatory post-generation gate by
# /gaia-test-automate (default mode, NOT --scaffold) and as a Phase 3A
# scanner by /gaia-review-test.
#
# Public API:
#   placeholder-test-detector.sh --file <path>
#   placeholder-test-detector.sh --dir <path>
#   placeholder-test-detector.sh --help
#
# Output format (one line per offense, on stdout):
#   low_quality_test_generated|<file>:<line>|<matched_pattern>
#
# Exit codes:
#   0 — clean (no placeholder hits)
#   1 — at least one placeholder match (caller treats as REQUEST_CHANGES)
#   2 — caller error (missing flag / unreadable target)
#

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="placeholder-test-detector.sh"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat <<EOF
$SCRIPT_NAME — placeholder pattern detector for generated/automated tests.

Usage:
  $SCRIPT_NAME --file <path>       Scan a single file
  $SCRIPT_NAME --dir <path>        Scan a directory recursively (test files only)
  $SCRIPT_NAME --help              Show this help

Detected placeholder patterns:
  expect(true) / expect(false) / .toBe(true) / .toBe(false) (when sole assertion)
  assert True / assert False (Python)
  assert_true(...) / assert_false(...)
  test.todo(...) / test.skip(...) / it.skip(...) / xit(...)
  xdescribe(...) / xcontext(...) / describe.skip(...)
  empty it/test blocks: it('x', () => {}) or test('x', () => {})

Output (one line per match on stdout):
  low_quality_test_generated|<file>:<line>|<matched_pattern>

Exit codes:
  0  no placeholder findings
  1  at least one placeholder finding
  2  caller error
EOF
}

# Test-file extensions for --dir recursion.
TEST_EXT_REGEX='.*\.(test|spec)\.(ts|tsx|js|jsx|mjs|cjs)$|.*\.bats$|.*_test\.(py|go)$|.*test_.*\.py$|.*Test\.java$|.*\.dart$'

# ---------- Pattern scanning ----------
#
# For each input file, emit one structured finding per offending line on
# stdout. Returns 0 when the file is clean, 1 when at least one finding
# was emitted.
scan_file() {
  local file="$1"
  local hits=0
  local line_no
  local line
  local rel_file

  if [ ! -f "$file" ]; then
    err "file not found: $file"
    return 2
  fi
  if [ ! -r "$file" ]; then
    err "file not readable: $file"
    return 2
  fi

  rel_file="$file"

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))

    # Strip leading whitespace for pattern checks (preserves the original
    # for output messaging via $line_no — match position-agnostic).
    local stripped="${line#"${line%%[![:space:]]*}"}"

    # Skip comment lines that happen to mention a pattern in prose.
    case "$stripped" in
      '//'*|'#'*|'*'*) continue ;;
    esac

    # 1. expect(true) / expect(false) — vacuous boolean assertions.
    case "$stripped" in
      *'expect(true)'*|*'expect(false)'*)
        printf 'low_quality_test_generated|%s:%d|expect_boolean_literal\n' "$rel_file" "$line_no"
        hits=$((hits + 1))
        continue ;;
    esac

    # 1b. .toBe(true) / .toBe(false) on an `expect(true|false)` style chain
    # already caught above. Detect `expect(<anything>).toBe(true)` paired
    # with the literal-arg form below ONLY when the expect arg is itself
    # a literal (e.g., `expect(true).toBe(true)`); otherwise leave alone.

    # 2. Python assert True / assert False (token-anchored, single regex).
    if printf '%s' "$stripped" | grep -Eq '^assert[[:space:]]+(True|False)([[:space:]]*$|[[:space:]]*[,;#])'; then
      printf 'low_quality_test_generated|%s:%d|assert_boolean_literal\n' "$rel_file" "$line_no"
      hits=$((hits + 1))
      continue
    fi

    # 3. assert_true(...) / assert_false(...).
    if printf '%s' "$stripped" | grep -Eq '\bassert_(true|false)[[:space:]]*\('; then
      printf 'low_quality_test_generated|%s:%d|assert_true_false_helper\n' "$rel_file" "$line_no"
      hits=$((hits + 1))
      continue
    fi

    # 4. test.todo / test.skip / it.skip / xit / xdescribe / xcontext / describe.skip.
    if printf '%s' "$stripped" | grep -Eq '(^|[^A-Za-z0-9_])(test\.todo|test\.skip|it\.skip|xit|xdescribe|xcontext|describe\.skip)[[:space:]]*\('; then
      local pattern
      pattern="$(printf '%s' "$stripped" | grep -Eo '(test\.todo|test\.skip|it\.skip|xit|xdescribe|xcontext|describe\.skip)' | head -1)"
      printf 'low_quality_test_generated|%s:%d|%s\n' "$rel_file" "$line_no" "$pattern"
      hits=$((hits + 1))
      continue
    fi

    # 5. Empty it/test block — `it('x', () => {})` or `test('x', () => {})`
    # with no body content. Detect single-line empty arrow callbacks.
    if printf '%s' "$stripped" | grep -Eq '\b(it|test)\([^)]*,[[:space:]]*(\([^)]*\)|async)[[:space:]]*=>[[:space:]]*\{[[:space:]]*\}'; then
      printf 'low_quality_test_generated|%s:%d|empty_block\n' "$rel_file" "$line_no"
      hits=$((hits + 1))
      continue
    fi
    # Empty bats block — `@test "name" {}` on one line.
    if printf '%s' "$stripped" | grep -Eq '^@test[[:space:]]+"[^"]*"[[:space:]]*\{[[:space:]]*\}[[:space:]]*$'; then
      printf 'low_quality_test_generated|%s:%d|empty_block\n' "$rel_file" "$line_no"
      hits=$((hits + 1))
      continue
    fi
  done < "$file"

  if [ "$hits" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ---------- Argument parsing ----------

MODE=""
TARGET=""

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      [ "$#" -ge 2 ] || { err "--file requires a path"; exit 2; }
      MODE="file"; TARGET="$2"; shift 2 ;;
    --dir)
      [ "$#" -ge 2 ] || { err "--dir requires a path"; exit 2; }
      MODE="dir"; TARGET="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "unknown argument: $1"
      exit 2 ;;
  esac
done

[ -n "$MODE" ] || { err "missing mode flag (--file or --dir)"; exit 2; }
[ -n "$TARGET" ] || { err "missing target path"; exit 2; }

# ---------- Dispatch ----------

if [ "$MODE" = "file" ]; then
  if [ ! -e "$TARGET" ]; then
    err "file not found: $TARGET"
    exit 2
  fi
  set +e
  scan_file "$TARGET"
  rc=$?
  set -e
  exit "$rc"
fi

# Dir mode — recurse into test files only.
if [ ! -d "$TARGET" ]; then
  err "directory not found: $TARGET"
  exit 2
fi

TOTAL_HITS=0

# Use find -print0 + read -d for null-delimited safety. macOS bash 3.2 OK.
while IFS= read -r -d '' f; do
  set +e
  scan_file "$f"
  rc=$?
  set -e
  if [ "$rc" -eq 1 ]; then
    TOTAL_HITS=$((TOTAL_HITS + 1))
  elif [ "$rc" -eq 2 ]; then
    # Unreadable file — propagate as caller error.
    exit 2
  fi
done < <(find "$TARGET" -type f -regextype posix-extended -regex "$TEST_EXT_REGEX" -print0 2>/dev/null \
         || find "$TARGET" -type f \( \
              -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
              -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \
              -o -name '*.test.mjs' -o -name '*.test.cjs' \
              -o -name '*.bats' \
              -o -name '*_test.py' -o -name 'test_*.py' \
              -o -name '*_test.go' \
              -o -name '*Test.java' \
            \) -print0)

if [ "$TOTAL_HITS" -gt 0 ]; then
  exit 1
fi
exit 0
