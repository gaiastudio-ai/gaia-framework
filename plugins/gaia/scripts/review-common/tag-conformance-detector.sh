#!/usr/bin/env bash
# tag-conformance-detector.sh — GAIA review-common Phase 3A per-stack tag detector.
#
# Originally shipped with a per-invocation `--stack` contract. Extended with
# strict/suggestion mode (`test_tagging.strict`), a `--files <glob>` standalone
# CLI, per-file stack auto-detection (so a single invocation handles mixed
# monorepos), and severity routing (warning when strict, info — Suggestion —
# otherwise).
#
# Purpose
# -------
# Per-stack scanner that checks whether each test file declares at least one
# tag using the canonical mechanism for its stack. Stacks supported:
#
#   ts-dev       Vitest / Jest             — describe.each / it.each / .each / tagged it()
#   angular-dev  Karma / Jasmine / Jest    — same as ts-dev
#   java-dev     JUnit 5                   — @Tag annotation on class or method
#   python-dev   pytest                    — @pytest.mark.<name> decorator
#   go-dev       Go testing                — //go:build <tag> directive
#   flutter-dev  dart test                 — @Tags(['name'])
#   mobile-dev   Maestro / XCTest / Espresso — Maestro flow front-matter `tags:`
#                                            (defers to JUnit for Android, XCTest tagging
#                                            via @MainActor / @available currently
#                                            treated as missing — story scope)
#
# Output (stdout): a JSON fragment of the canonical Phase 3A check shape:
#
#   {
#     "name": "tag-conformance-detector",
#     "scope": "file",
#     "status": "passed|failed",
#     "findings": [
#       {"file":"<path>","line":<int>,"severity":"warning|info",
#        "rule":"missing-tag",
#        "message":"<text>","blocking":false,"category":"tag-conformance",
#        "stack":"<canonical-stack>"}
#     ]
#   }
#
# Status `failed` whenever ≥1 finding is emitted. Exit code is ALWAYS 0 on
# successful run (caller-error-only exit 1).
#
# Severity
# --------
# - Strict mode → severity `warning`. A finding contributes Warning-level
#   evidence to /gaia-review-test Phase 3A.
# - Non-strict (default) → severity `info` (Suggestion). Findings still surface
#   but do NOT escalate Phase 3A verdicts.
#
# Strict-mode resolution precedence:
#   1. CLI `--strict` flag (highest)
#   2. `GAIA_TEST_TAGGING_STRICT=1` env override
#   3. `test_tagging.strict: true` in `config/project-config.yaml`
#   4. default: false (non-strict / Suggestion)
#
# Invocation
# ----------
#   tag-conformance-detector.sh [--stack <stack>] [--strict] <path>...
#   tag-conformance-detector.sh [--stack <stack>] [--strict] --file-list <listfile>
#   tag-conformance-detector.sh [--stack <stack>] [--strict] --files <glob>
#   tag-conformance-detector.sh --help
#
# When `--stack` is omitted the detector auto-classifies each input file by
# extension to one of the canonical stacks; files that do not match any known
# extension are skipped silently. When `--stack` is provided the legacy
# single-stack discovery is preserved for backward compatibility with
# phase3a-test-review.sh callers.
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible (no 3-arg match, no associative arrays); no jq dependency.
#


set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="tag-conformance-detector.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3A per-stack tag-conformance detector.

Usage:
  $SCRIPT_NAME [--stack <stack>] [--strict] <path>...
  $SCRIPT_NAME [--stack <stack>] [--strict] --file-list <listfile>
  $SCRIPT_NAME [--stack <stack>] [--strict] --files <glob>
  $SCRIPT_NAME --help

<stack> is one of: ts-dev | angular-dev | java-dev | python-dev | go-dev |
                   flutter-dev | mobile-dev

When --stack is omitted, each file is classified by extension. Files that
do not match any known stack are skipped.

--strict  emit Warning-level findings; default is Suggestion-level (info).

Strict-mode resolution precedence (highest first):
  1. --strict flag
  2. GAIA_TEST_TAGGING_STRICT=1 env override
  3. test_tagging.strict: true in config/project-config.yaml
  4. default: false

Emits a single analysis-results.json checks[] fragment to stdout.
Exit 0 on successful scan.
EOF
}

# ---------- arg parsing ----------

STACK=""
PATHS=()
FILE_LIST=""
FILES_GLOB=""
STRICT_FLAG=0  # 1 when --strict explicitly passed; otherwise resolve per precedence
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --stack)
      [ $# -ge 2 ] || die "--stack requires a value"
      STACK="$2"; shift 2 ;;
    --file-list)
      [ $# -ge 2 ] || die "--file-list requires a path"
      FILE_LIST="$2"; shift 2 ;;
    --files)
      [ $# -ge 2 ] || die "--files requires a glob"
      FILES_GLOB="$2"; shift 2 ;;
    --strict) STRICT_FLAG=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

# Validate explicit --stack value (auto-detect when omitted).
if [ -n "$STACK" ]; then
  case "$STACK" in
    ts-dev|angular-dev|java-dev|python-dev|go-dev|flutter-dev|mobile-dev) ;;
    *) die "unknown stack: '$STACK' (expected ts-dev|angular-dev|java-dev|python-dev|go-dev|flutter-dev|mobile-dev)" ;;
  esac
fi

# ---------- strict-mode resolution ----------

resolve_strict_mode() {
  # Precedence: --strict > GAIA_TEST_TAGGING_STRICT > project-config.yaml > false.
  if [ "$STRICT_FLAG" = "1" ]; then
    printf '1\n'; return 0
  fi
  case "${GAIA_TEST_TAGGING_STRICT:-}" in
    1|true|TRUE|True|yes|YES|on|ON) printf '1\n'; return 0 ;;
  esac
  # Look up test_tagging.strict from project-config.yaml. resolve-config.sh
  # does not surface this key via --field yet, so a tiny grep fallback keeps
  # the detector self-contained. The grep is anchored, single-line, and
  # tolerates surrounding whitespace and quoted booleans.
  local cfg=""
  # Prefer .gaia/config/project-config.yaml over legacy config/
  for c in \
    "${CLAUDE_PROJECT_ROOT:-}/.gaia/config/project-config.yaml" \
    "${CLAUDE_PROJECT_ROOT:-}/config/project-config.yaml" \
    "${PWD}/.gaia/config/project-config.yaml" \
    "${PWD}/config/project-config.yaml" \
    "${CLAUDE_SKILL_DIR:-}/.gaia/config/project-config.yaml" \
    "${CLAUDE_SKILL_DIR:-}/config/project-config.yaml"; do
    if [ -n "$c" ] && [ -f "$c" ]; then cfg="$c"; break; fi
  done
  if [ -n "$cfg" ]; then
    # Match e.g. `  strict: true` directly under a `test_tagging:` block.
    awk '
      BEGIN { intag=0 }
      /^test_tagging:[[:space:]]*$/ { intag=1; next }
      intag && /^[A-Za-z_]/ { intag=0 }
      intag && /^[[:space:]]+strict:[[:space:]]*(true|"true"|'\''true'\'')[[:space:]]*$/ { print "1"; exit }
    ' "$cfg" | head -n 1
    return 0
  fi
  printf ''
}

STRICT_RESOLVED="$(resolve_strict_mode)"
if [ "$STRICT_RESOLVED" = "1" ]; then
  SEVERITY="warning"
else
  SEVERITY="info"
fi

# ---------- file extension → canonical stack auto-classifier ----------

classify_file_to_stack() {
  local f="$1"
  case "$f" in
    *.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx)
      printf 'ts-dev\n' ;;
    *Test.java|*Tests.java|*IT.java)
      printf 'java-dev\n' ;;
    test_*.py|*_test.py)
      # Match by basename — directory prefix may not start with `test_`.
      printf 'python-dev\n' ;;
    *_test.go)
      printf 'go-dev\n' ;;
    *_test.dart|*.test.dart)
      printf 'flutter-dev\n' ;;
    *.yaml|*.yml)
      printf 'mobile-dev\n' ;;
    *Test.kt|*Tests.kt)
      printf 'mobile-dev\n' ;;
    *) printf '\n' ;;
  esac
}

# Basename-aware classification — patterns like `test_*.py` only match the
# basename, not the full path.
classify_path_to_stack() {
  local p="$1"
  local b
  b="$(basename -- "$p")"
  # Try basename first (handles test_*.py / *_test.py / *Test.java).
  local s
  s="$(classify_file_to_stack "$b")"
  if [ -z "$s" ]; then
    s="$(classify_file_to_stack "$p")"
  fi
  printf '%s\n' "$s"
}

# ---------- discover input files ----------

discover_test_files_for_stack() {
  local p stack="$1"; shift
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$p" ]; then
      case "$stack" in
        ts-dev|angular-dev)
          find "$p" -type f \( \
            -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
            -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \
          \) 2>/dev/null ;;
        java-dev)
          find "$p" -type f \( -name '*Test.java' -o -name '*Tests.java' -o -name '*IT.java' \) 2>/dev/null ;;
        python-dev)
          find "$p" -type f \( -name 'test_*.py' -o -name '*_test.py' \) 2>/dev/null ;;
        go-dev)
          find "$p" -type f -name '*_test.go' 2>/dev/null ;;
        flutter-dev)
          find "$p" -type f \( -name '*_test.dart' -o -name '*.test.dart' \) 2>/dev/null ;;
        mobile-dev)
          find "$p" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*Test.kt' -o -name '*Tests.kt' -o -name '*Test.java' -o -name '*Tests.java' \) 2>/dev/null ;;
      esac
    fi
  done
}

# Auto-detect mode discovery: walk a directory and emit ANY recognized test file.
discover_test_files_auto() {
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$p" ]; then
      find "$p" -type f \( \
        -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
        -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \
        -o -name '*Test.java' -o -name '*Tests.java' -o -name '*IT.java' \
        -o -name 'test_*.py' -o -name '*_test.py' \
        -o -name '*_test.go' \
        -o -name '*_test.dart' -o -name '*.test.dart' \
        -o -name '*.yaml' -o -name '*.yml' \
        -o -name '*Test.kt' -o -name '*Tests.kt' \
      \) 2>/dev/null
    fi
  done
}

# Expand a glob pattern into a newline-separated path list. Uses bash
# pathname expansion in a controlled subshell so tests/no-match doesn't
# bleed into PATHS.
expand_glob() {
  local g="$1"
  # shellcheck disable=SC2086
  ( shopt -s nullglob 2>/dev/null || true; eval "for x in $g; do printf '%s\n' \"\$x\"; done" )
}

INPUT_FILES=""
if [ -n "$FILE_LIST" ]; then
  [ -f "$FILE_LIST" ] || die "file list not found: $FILE_LIST"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    INPUT_FILES="${INPUT_FILES}${line}"$'\n'
  done < "$FILE_LIST"
fi
if [ -n "$FILES_GLOB" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    INPUT_FILES="${INPUT_FILES}${line}"$'\n'
  done <<EOF_GLOB
$(expand_glob "$FILES_GLOB")
EOF_GLOB
fi
if [ "${#PATHS[@]}" -gt 0 ]; then
  if [ -n "$STACK" ]; then
    INPUT_FILES="${INPUT_FILES}$(discover_test_files_for_stack "$STACK" "${PATHS[@]}")"$'\n'
  else
    INPUT_FILES="${INPUT_FILES}$(discover_test_files_auto "${PATHS[@]}")"$'\n'
  fi
fi

SEEN_TMP="$(mktemp -t gaia-tag-seen.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-tag-findings.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-tag-deduped.XXXXXX)"
trap 'rm -f "$SEEN_TMP" "$FINDINGS_FILE" "$DEDUPED_FILE"' EXIT

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  if ! grep -Fxq "$f" "$SEEN_TMP" 2>/dev/null; then
    printf '%s\n' "$f" >> "$SEEN_TMP"
    printf '%s\n' "$f" >> "$DEDUPED_FILE"
  fi
done <<EOF
${INPUT_FILES}
EOF

# Deterministic file order — sort the deduped list (LC_ALL=C pinned for
# byte-stable diffs in CI).
sort -o "$DEDUPED_FILE" "$DEDUPED_FILE"

# ---------- finding emitter ----------

json_escape() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/, "\\\\");
    gsub(/"/,  "\\\"");
    gsub(/\t/, "\\t");
    gsub(/\r/, "\\r");
    if (NR>1) printf "\\n";
    printf "%s", $0;
  }'
}

FINDING_COUNT=0
emit_finding() {
  local file="$1" line="$2" rule="$3" msg="$4" stack="$5"
  local file_esc msg_esc
  file_esc="$(printf '%s' "$file" | json_escape)"
  msg_esc="$(printf '%s' "$msg"  | json_escape)"
  if [ "$FINDING_COUNT" -gt 0 ]; then
    printf ',' >> "$FINDINGS_FILE"
  fi
  printf '{"file":"%s","line":%s,"severity":"%s","rule":"%s","message":"%s","blocking":false,"category":"tag-conformance","stack":"%s"}' \
    "$file_esc" "$line" "$SEVERITY" "$rule" "$msg_esc" "$stack" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- per-stack tag presence checks ----------

has_tag_ts() {
  local f="$1"
  grep -Eq '(describe|it|test)\.each|@[A-Za-z][A-Za-z0-9_-]*[[:space:]]*$|tags:[[:space:]]*\[' "$f" 2>/dev/null
}

has_tag_java() {
  local f="$1"
  grep -Eq '@Tag[[:space:]]*\(' "$f" 2>/dev/null
}

has_tag_python() {
  local f="$1"
  # Also recognize module-level `pytestmark = pytest.mark.unit` and the list
  # form `pytestmark = [pytest.mark.unit, pytest.mark.smoke]`. The original
  # check only matched per-test decorators (@pytest.mark.X), missing the
  # equally-canonical module-level form.
  grep -Eq '@pytest\.mark\.[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null && return 0
  grep -Eq '^[[:space:]]*pytestmark[[:space:]]*=[[:space:]]*(\[[[:space:]]*)?pytest\.mark\.' "$f" 2>/dev/null && return 0
  return 1
}

has_tag_go() {
  local f="$1"
  head -n 10 "$f" 2>/dev/null | grep -Eq '^//go:build[[:space:]]+'
}

has_tag_flutter() {
  local f="$1"
  grep -Eq "@Tags\(\[" "$f" 2>/dev/null
}

has_tag_mobile() {
  local f="$1"
  case "$f" in
    *.yaml|*.yml)
      head -n 30 "$f" 2>/dev/null | grep -Eq '^[[:space:]]*tags:[[:space:]]*' ;;
    *.kt|*.java)
      grep -Eq '@Tag[[:space:]]*\(' "$f" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# Resolve the stack to use for a given file: explicit --stack wins; else auto.
resolve_stack_for_file() {
  local f="$1"
  if [ -n "$STACK" ]; then
    # Even when --stack is explicit, only apply the per-stack tag check to
    # files that LOOK like test files for that stack. Otherwise source files
    # (e.g. `core/budget/tracker.py`) get checked for @pytest.mark and
    # reported as missing-tag — a false-positive on source code that has no
    # business carrying test tags.
    #
    # We cross-check by calling auto-classify: if the file's extension/name
    # matches the explicit stack's test pattern, accept; otherwise skip
    # silently. This preserves the legacy single-stack contract for actual
    # test files while filtering source-file noise.
    local auto
    auto="$(classify_path_to_stack "$f")"
    if [ "$auto" = "$STACK" ]; then
      printf '%s\n' "$STACK"
    else
      printf '\n'  # skip — not a test file for the explicit stack
    fi
  else
    classify_path_to_stack "$f"
  fi
}

# ---------- main scan ----------

while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  s="$(resolve_stack_for_file "$f")"
  [ -z "$s" ] && continue  # auto-detect skip: unrecognized file
  ok=1
  case "$s" in
    ts-dev|angular-dev) has_tag_ts "$f" || ok=0 ;;
    java-dev)           has_tag_java "$f" || ok=0 ;;
    python-dev)         has_tag_python "$f" || ok=0 ;;
    go-dev)             has_tag_go "$f" || ok=0 ;;
    flutter-dev)        has_tag_flutter "$f" || ok=0 ;;
    mobile-dev)         has_tag_mobile "$f" || ok=0 ;;
    *) continue ;;
  esac
  if [ "$ok" = "0" ]; then
    case "$s" in
      ts-dev|angular-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no Vitest/Jest tag mechanism (describe.each / it.each / tagged it()) found in test file" "$s" ;;
      java-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no JUnit @Tag annotation found in test file" "$s" ;;
      python-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no @pytest.mark.<name> decorator found in test file" "$s" ;;
      go-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no //go:build directive found in first 10 lines of test file" "$s" ;;
      flutter-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no @Tags(['…']) annotation found in test file" "$s" ;;
      mobile-dev)
        emit_finding "$f" 1 "missing-tag" \
          "no Maestro front-matter tags: field (or JUnit @Tag) found in test file" "$s" ;;
    esac
  fi
done < "$DEDUPED_FILE"

# ---------- emit check fragment ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"tag-conformance-detector","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
