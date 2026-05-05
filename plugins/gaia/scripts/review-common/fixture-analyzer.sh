#!/usr/bin/env bash
# fixture-analyzer.sh — GAIA review-common Phase 3A fixture analyzer (E67-S1, ADR-077).
#
# Purpose
# -------
# Deterministic scanner that flags three fixture-quality issues:
#
#   - oversized-fixture        : fixture file exceeds --max-lines (default 500).
#   - mutation-during-run      : fixture file path appears as a write target
#                                (`fs.writeFile`, `open(..., 'w')`, `Files.write`)
#                                inside a test file.
#   - fixture-cycle            : circular fixture-dependency graph detected.
#                                Pytest fixtures (`@pytest.fixture` + `def name(other_fixture)`)
#                                are the primary case; JS test-helper imports
#                                participate via `import x from "./fixtures/y"`
#                                in fixture files.
#
# Output (stdout): a JSON fragment of the canonical Phase 3A check shape:
#
#   {
#     "name": "fixture-analyzer",
#     "scope": "file",
#     "status": "passed|failed",
#     "findings": [
#       {"file":"<path>","line":<int>,"severity":"warning",
#        "rule":"oversized-fixture|mutation-during-run|fixture-cycle",
#        "message":"<text>","blocking":false,"category":"fixture-quality"}
#     ]
#   }
#
# Status `failed` whenever ≥1 finding is emitted. Exit code is ALWAYS 0 on
# successful run (caller-error-only exit 1).
#
# Invocation
# ----------
#   fixture-analyzer.sh [--max-lines N] <path>...
#   fixture-analyzer.sh --file-list <listfile> [--max-lines N]
#   fixture-analyzer.sh --help
#
# `<path>` may be a fixture file, a test file, or a directory. Directories are
# walked for fixture files (under `fixtures/`, `__fixtures__/`, `test-data/`,
# `testdata/`) and test files (the same patterns as smell-detector).
#
# POSIX discipline: bash + set -euo pipefail + LC_ALL=C; macOS bash 3.2 + BSD
# awk compatible (no 3-arg match, no associative arrays); no jq dependency.
#
# Refs: AC3, AC6, AC7, FR-RSV2-1, FR-RSV2-2, NFR-RSV2-1, ADR-075, ADR-077.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="fixture-analyzer.sh"

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — Phase 3A fixture analyzer (ADR-077).

Usage:
  $SCRIPT_NAME [--max-lines N] <path>...
  $SCRIPT_NAME [--max-lines N] --file-list <listfile>
  $SCRIPT_NAME --help

Detects oversized fixtures (--max-lines, default 500), fixture mutation during
test runs, and fixture dependency cycles.

Emits a single analysis-results.json checks[] fragment to stdout.
Exit 0 on successful scan.
EOF
}

# ---------- arg parsing ----------

PATHS=()
FILE_LIST=""
MAX_LINES=500
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --max-lines)
      [ $# -ge 2 ] || die "--max-lines requires a number"
      MAX_LINES="$2"; shift 2
      case "$MAX_LINES" in
        ''|*[!0-9]*) die "--max-lines must be a positive integer (got: $MAX_LINES)" ;;
      esac ;;
    --file-list)
      [ $# -ge 2 ] || die "--file-list requires a path"
      FILE_LIST="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do PATHS+=("$1"); shift; done ;;
    -*) die "unknown flag: $1" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

# ---------- discover input files ----------

discover_files() {
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$p" ]; then
      find "$p" -type f \( \
        -path '*/fixtures/*' -o -path '*/__fixtures__/*' \
        -o -path '*/test-data/*' -o -path '*/testdata/*' \
        -o -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.test.js' -o -name '*.test.jsx' \
        -o -name '*.spec.ts' -o -name '*.spec.tsx' -o -name '*.spec.js' -o -name '*.spec.jsx' \
        -o -name 'test_*.py' -o -name '*_test.py' -o -name 'conftest.py' \
        -o -name '*Test.java' -o -name '*Tests.java' \
        -o -name '*_test.go' \
      \) 2>/dev/null
    fi
  done
}

INPUT_FILES=""
if [ -n "$FILE_LIST" ]; then
  [ -f "$FILE_LIST" ] || die "file list not found: $FILE_LIST"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    INPUT_FILES="${INPUT_FILES}${line}"$'\n'
  done < "$FILE_LIST"
fi
if [ "${#PATHS[@]}" -gt 0 ]; then
  INPUT_FILES="${INPUT_FILES}$(discover_files "${PATHS[@]}")"$'\n'
fi

SEEN_TMP="$(mktemp -t gaia-fix-seen.XXXXXX)"
FINDINGS_FILE="$(mktemp -t gaia-fix-findings.XXXXXX)"
DEDUPED_FILE="$(mktemp -t gaia-fix-deduped.XXXXXX)"
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
  local file="$1" line="$2" rule="$3" msg="$4"
  local file_esc msg_esc
  file_esc="$(printf '%s' "$file" | json_escape)"
  msg_esc="$(printf '%s' "$msg"  | json_escape)"
  if [ "$FINDING_COUNT" -gt 0 ]; then
    printf ',' >> "$FINDINGS_FILE"
  fi
  printf '{"file":"%s","line":%s,"severity":"warning","rule":"%s","message":"%s","blocking":false,"category":"fixture-quality"}' \
    "$file_esc" "$line" "$rule" "$msg_esc" >> "$FINDINGS_FILE"
  FINDING_COUNT=$((FINDING_COUNT + 1))
}

# ---------- detector: oversized-fixture ----------

is_fixture_path() {
  case "$1" in
    */fixtures/*|*/__fixtures__/*|*/test-data/*|*/testdata/*) return 0 ;;
    *) return 1 ;;
  esac
}

detect_oversized() {
  local file="$1"
  is_fixture_path "$file" || return 0
  local lines
  lines="$(awk 'END{print NR}' "$file" 2>/dev/null || printf 0)"
  if [ "$lines" -gt "$MAX_LINES" ]; then
    emit_finding "$file" 1 "oversized-fixture" \
      "fixture has $lines lines (threshold: $MAX_LINES)"
  fi
}

# ---------- detector: mutation-during-run ----------
# Inside a test file, look for write-API calls whose first arg refers to a
# fixture path.

detect_mutation() {
  local file="$1"
  case "$file" in
    *.test.*|*.spec.*|test_*.py|*_test.py|*Test.java|*Tests.java|*_test.go|*conftest.py)
      ;;
    *)
      return 0 ;;
  esac
  awk -v file="$file" '
    {
      ln = NR
      if ($0 ~ /(fs\.writeFile|fs\.writeFileSync|fs\.appendFile|writeFileSync|fs\.unlink|fs\.rm)[[:space:]]*\(/ ||
          $0 ~ /open[[:space:]]*\([^)]*["\x27][^"\x27]*\/(fixtures|test-data|testdata|__fixtures__)\//) {
        if ($0 ~ /(fixtures|test-data|testdata|__fixtures__)/) {
          # Trim leading whitespace for message clarity.
          s = $0
          sub(/^[[:space:]]+/, "", s)
          if (length(s) > 120) s = substr(s, 1, 117) "..."
          gsub(/\t/, " ", s)
          printf "%s\t%d\tmutation-during-run\twrite-API call targets fixture path: %s\n", file, ln, s
        }
      }
      # Java
      if ($0 ~ /(Files\.write|Files\.delete|FileOutputStream)[[:space:]]*\(/ &&
          $0 ~ /(fixtures|testdata)/) {
        s = $0
        sub(/^[[:space:]]+/, "", s)
        if (length(s) > 120) s = substr(s, 1, 117) "..."
        gsub(/\t/, " ", s)
        printf "%s\t%d\tmutation-during-run\tJava write-API targets fixture path: %s\n", file, ln, s
      }
      # Python with open(... "w") within a test file
      if ($0 ~ /open[[:space:]]*\([^)]*["\x27](w|a|wb|ab)["\x27]/ &&
          $0 ~ /(fixtures|testdata|test-data|__fixtures__)/) {
        s = $0
        sub(/^[[:space:]]+/, "", s)
        if (length(s) > 120) s = substr(s, 1, 117) "..."
        gsub(/\t/, " ", s)
        printf "%s\t%d\tmutation-during-run\tPython open(w/a) targets fixture path: %s\n", file, ln, s
      }
    }
  ' "$file" 2>/dev/null || return 0
}

# ---------- detector: fixture-cycle ----------
# pytest: collect (fixture-name -> [param-fixture-names]) and detect a cycle
# via DFS. We honor only files actually scanned (DEDUPED_FILE).

build_pytest_graph() {
  local out="$1"
  : > "$out"
  while IFS= read -r f || [ -n "$f" ]; do
    [ -z "$f" ] && continue
    case "$f" in
      *conftest.py|*test_*.py|*_test.py) ;;
      *) continue ;;
    esac
    awk '
      /@pytest\.fixture/ {
        next_def_is_fixture = 1
        next
      }
      /^[[:space:]]*def[[:space:]]+/ {
        if (next_def_is_fixture) {
          # Extract name and parameters.
          line = $0
          sub(/^[[:space:]]*def[[:space:]]+/, "", line)
          # name up to "("
          paren = index(line, "(")
          if (paren > 0) {
            name = substr(line, 1, paren - 1)
            rest = substr(line, paren + 1)
            close_idx = index(rest, ")")
            params = (close_idx > 0) ? substr(rest, 1, close_idx - 1) : rest
            # Split params by comma; for each, take identifier (strip type/default).
            n = split(params, arr, ",")
            for (i = 1; i <= n; i++) {
              p = arr[i]
              gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
              # Strip "type: ..." and "= default"
              sub(/=.*$/, "", p)
              sub(/:.*$/, "", p)
              gsub(/[[:space:]]+/, "", p)
              if (p != "" && p != "self" && p != "cls") {
                printf "%s\t%s\n", name, p
              }
            }
            # Always emit a node line for the fixture (parent: empty).
            printf "%s\t\n", name
          }
          next_def_is_fixture = 0
        }
      }
      /^[[:space:]]*[a-zA-Z]/ && !/@pytest\.fixture/ && next_def_is_fixture {
        # Decorator was followed by something that is not a def; reset.
        next_def_is_fixture = 0
      }
    ' "$f" 2>/dev/null >> "$out"
  done < "$DEDUPED_FILE"
}

detect_fixture_cycles_pytest() {
  local graph="$1"
  [ -s "$graph" ] || return 0

  awk '
    BEGIN { node_count = 0 }
    {
      n = $1
      p = $2
      # Track unique nodes.
      if (!(n in seen_node)) {
        seen_node[n] = 1
        node_count++
        nodes[node_count] = n
      }
      if (p != "") {
        edges[n, ++ec[n]] = p
      }
    }
    function dfs(u,    i, c) {
      if (color[u] == 1) {
        # Found a back-edge: cycle.
        cycle_found = u
        return 1
      }
      if (color[u] == 2) return 0
      color[u] = 1
      for (i = 1; i <= ec[u]; i++) {
        c = edges[u, i]
        if (dfs(c)) {
          path = u " -> " path
          return 1
        }
      }
      color[u] = 2
      return 0
    }
    END {
      for (i = 1; i <= node_count; i++) {
        path = ""
        if (dfs(nodes[i])) {
          printf "fixture-cycle\tcycle detected involving fixture %s\n", cycle_found
          break
        }
      }
    }
  ' "$graph" 2>/dev/null || true
}

# ---------- main scan ----------

# 1. Per-file detectors: oversized + mutation
while IFS= read -r f || [ -n "$f" ]; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  detect_oversized "$f"
  while IFS=$'\t' read -r ff fl rr mm; do
    [ -z "$ff" ] && continue
    emit_finding "$ff" "$fl" "$rr" "$mm"
  done < <(detect_mutation "$f")
done < "$DEDUPED_FILE"

# 2. Cross-file detector: fixture cycles (pytest)
GRAPH_FILE="$(mktemp -t gaia-fix-graph.XXXXXX)"
trap 'rm -f "$SEEN_TMP" "$FINDINGS_FILE" "$DEDUPED_FILE" "$GRAPH_FILE"' EXIT
build_pytest_graph "$GRAPH_FILE"
while IFS=$'\t' read -r rule msg; do
  [ -z "$rule" ] && continue
  # Use first conftest.py / test file as the location anchor.
  anchor="$(head -n 1 "$DEDUPED_FILE" 2>/dev/null || printf 'unknown')"
  emit_finding "$anchor" 1 "$rule" "$msg"
done < <(detect_fixture_cycles_pytest "$GRAPH_FILE")

# ---------- emit check fragment ----------

if [ "$FINDING_COUNT" -gt 0 ]; then
  STATUS="failed"
else
  STATUS="passed"
fi

printf '{"name":"fixture-analyzer","scope":"file","status":"%s","findings":[' "$STATUS"
cat "$FINDINGS_FILE"
printf ']}\n'

exit 0
