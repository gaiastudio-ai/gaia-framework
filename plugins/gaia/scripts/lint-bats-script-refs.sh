#!/usr/bin/env bash
# lint-bats-script-refs.sh — sweep linter for stale script references
# in bats test files across BOTH gaia-framework/tests/ and
# gaia-framework/plugins/gaia/tests/ trees.
#
# Cross-tree discoverability: when a script under plugins/gaia/scripts/ or
# plugins/gaia/skills/*/scripts/ is deleted, dangling .bats references in
# either tree should fail CI.
#
# Behaviour:
#   - Scans every *.bats under {root}/tests/ and {root}/plugins/gaia/tests/.
#   - For each non-comment line, extracts script references that look like
#       plugins/gaia/scripts/<name>.sh
#       plugins/gaia/skills/<skill>/scripts/<name>.sh
#       scripts/<name>.sh                (resolved against repo root)
#   - For each extracted reference, checks the script file exists at
#     {root}/<reference>. If not, emits one structured line on stdout:
#       STALE: <bats-file>:<line> -> <script-path>
#   - Lines starting with # (any leading whitespace) are skipped.
#   - --ignore-pattern <regex> suppresses any extracted reference whose
#     script-path matches the regex (basic ERE). Multiple flags allowed.
#
# Usage:
#   lint-bats-script-refs.sh --root <repo-root> [--ignore-pattern <regex>]...
#   lint-bats-script-refs.sh --help
#
# Exit codes:
#   0 — every reference resolves to an existing script
#   1 — at least one stale reference found
#   2 — usage error (bad flag, missing root)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="lint-bats-script-refs.sh"

usage() {
  cat <<'EOF'
Usage:
  lint-bats-script-refs.sh --root <repo-root> [--ignore-pattern <regex>]...
  lint-bats-script-refs.sh --help

Options:
  --root PATH             Absolute path to the repo root (must contain
                          tests/ or plugins/gaia/tests/).
  --ignore-pattern REGEX  Suppress any reference whose script-path matches
                          REGEX. May be passed multiple times.
  --help                  Print this help and exit.

Exit codes:
  0  All references resolve to existing scripts.
  1  At least one stale reference found.
  2  Usage error.
EOF
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-2}"; }

ROOT=""
IGNORE_PATTERNS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || die "missing argument for --root"
      ROOT="$2"
      shift 2
      ;;
    --ignore-pattern)
      [ $# -ge 2 ] || die "missing argument for --ignore-pattern"
      IGNORE_PATTERNS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$ROOT" ] || { usage >&2; die "missing required --root"; }
[ -d "$ROOT" ] || die "root not a directory: $ROOT"

# is_ignored <script-path>
# Returns 0 if any --ignore-pattern matches the script-path.
is_ignored() {
  local path="$1"
  local pat
  for pat in "${IGNORE_PATTERNS[@]:-}"; do
    [ -n "$pat" ] || continue
    if printf '%s' "$path" | grep -Eq "$pat"; then
      return 0
    fi
  done
  return 1
}

# extract_script_refs <bats-file>
# Emit one line per script reference: "<line-number>\t<script-path>".
# Skips:
#   - comment lines (leading whitespace + #)
#   - lines inside heredoc blocks (cat > ... <<MARKER ... MARKER), since
#     those carry fixture content rather than live test invocations.
extract_script_refs() {
  local bats_file="$1"
  # State machine:
  #   in_heredoc=0 outside, =1 inside.
  #   heredoc_marker is the closing token (literal MARKER line, optionally
  #   indented when <<-MARKER is used; we accept any leading whitespace).
  awk '
    BEGIN { in_heredoc = 0; marker = "" }
    {
      line = $0
      if (in_heredoc) {
        # Closing token: line whose trimmed content equals the marker.
        trimmed = line
        sub(/^[[:space:]]+/, "", trimmed)
        sub(/[[:space:]]+$/, "", trimmed)
        if (trimmed == marker) {
          in_heredoc = 0
          marker = ""
        }
        next
      }
      # Detect heredoc opener:  ... <<[-]MARKER  or  <<[-]"MARKER"  or <<[-]'"'"'MARKER'"'"'.
      if (match(line, /<<-?[[:space:]]*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?/)) {
        token = substr(line, RSTART, RLENGTH)
        # Strip the leading << and optional - and surrounding quotes.
        sub(/^<<-?[[:space:]]*/, "", token)
        gsub(/['\''"]/, "", token)
        marker = token
        in_heredoc = 1
        next
      }
      # Strip leading whitespace before checking comment marker.
      tmp = line
      sub(/^[[:space:]]+/, "", tmp)
      if (substr(tmp, 1, 1) == "#") next
      # Iterate every match on the line.
      while (match(line, /(plugins\/gaia\/scripts\/[A-Za-z0-9_.+-]+\.sh|plugins\/gaia\/skills\/[A-Za-z0-9_.+-]+\/scripts\/[A-Za-z0-9_.+-]+\.sh)/)) {
        # Cache RSTART/RLENGTH BEFORE any nested match() call clobbers them.
        m_start = RSTART
        m_len   = RLENGTH
        ref     = substr(line, m_start, m_len)
        before  = substr(line, 1, m_start - 1)
        # Skip when the match is immediately preceded by `$VAR/` — this
        # signals a shell-variable rooted path (e.g., $FIXTURE_ROOT/...,
        # $REPO_ROOT/..., $TEST_TMP/...) rather than a canonical
        # repo-root reference. These are fixture-local paths that resolve
        # at runtime to a temp dir, not the repo root.
        if (match(before, /\$[A-Za-z_][A-Za-z0-9_]*\/$/)) {
          line = substr(line, m_start + m_len)
          continue
        }
        printf "%d\t%s\n", NR, ref
        line = substr(line, m_start + m_len)
      }
    }
  ' "$bats_file"
}

# lint_one_bats <bats-file>
# Echoes STALE: lines for any unresolved reference. Returns 1 if any stale
# refs found in this file, 0 otherwise.
lint_one_bats() {
  local bats_file="$1"
  local stale=0
  local entry line ref
  # Read every "<line>\t<ref>" pair.
  while IFS=$'\t' read -r line ref; do
    [ -n "$ref" ] || continue
    if is_ignored "$ref"; then
      continue
    fi
    if [ ! -f "$ROOT/$ref" ]; then
      printf 'STALE: %s:%s -> %s\n' "$bats_file" "$line" "$ref"
      stale=1
    fi
  done < <(extract_script_refs "$bats_file")
  return "$stale"
}

# Build the candidate file list. Prefer find over globs so we stay portable
# against bats test trees that don't exist (e.g., a project root with only
# one of the two trees populated).
TMP_LIST="$(mktemp)"
trap 'rm -f "$TMP_LIST"' EXIT

if [ -d "$ROOT/tests" ]; then
  find "$ROOT/tests" -type f -name '*.bats' >> "$TMP_LIST"
fi
if [ -d "$ROOT/plugins/gaia/tests" ]; then
  find "$ROOT/plugins/gaia/tests" -type f -name '*.bats' >> "$TMP_LIST"
fi

stale_total=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! lint_one_bats "$f"; then
    stale_total=1
  fi
done < "$TMP_LIST"

exit "$stale_total"
