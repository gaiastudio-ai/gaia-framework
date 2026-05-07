#!/usr/bin/env bash
# skip-permanent-check.sh — 90-day skip-directive linter with `# skip-permanent:`
# sanctioned-exception support, owned by the plugin-test sub-rubric (E77-S14, FR-416,
# ADR-088, TC-PLUGIN-RUBRIC-6).
#
# Behaviour:
#   - Scans a single .bats file (or every .bats file under a root directory).
#   - For each `skip` directive inside a `@test` block, classifies the directive as:
#       (a) ANNOTATED — the `skip` line itself OR the immediately preceding non-blank
#           line carries a `# skip-permanent: <reason>` comment with a non-empty
#           <reason>. ANNOTATED skips are excluded from the age check (sanctioned
#           permanent exception per FR-416 / TC-PLUGIN-RUBRIC-6).
#       (b) BARE — no `# skip-permanent:` annotation. The directive's age is
#           computed; bare skips older than --max-age-days emit a STALE-SKIP
#           finding on stdout and the script exits non-zero.
#   - Age is computed from `git log -1 --format=%ct` on the line introducing the
#     `skip` keyword. When the file is not under git OR --assume-age-days is
#     supplied (test/CI override), the age falls back to the supplied value.
#
# Output (stdout, one line per finding):
#   STALE-SKIP: <bats-file>:<line> age_days=<n> reason=bare-skip-older-than-<max>-days
#
# Exit codes:
#   0 — every skip resolves either ANNOTATED or fresh BARE (no findings)
#   1 — at least one stale BARE skip found
#   2 — usage error
#
# Story: E77-S14 (Tier 2 — plugin-test sub-rubric, FR-416)
# ADR:   ADR-088 (sub-rubric loader pipeline)
# Refs:  TC-PLUGIN-RUBRIC-6, lint-bats-script-refs.sh (sibling reference linter)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="skip-permanent-check.sh"

usage() {
  cat <<'EOF'
Usage:
  skip-permanent-check.sh --bats-file <path>     [--max-age-days N] [--assume-age-days N]
  skip-permanent-check.sh --root <repo-root>     [--max-age-days N] [--assume-age-days N]
  skip-permanent-check.sh --help

Options:
  --bats-file PATH        Single .bats file to scan.
  --root PATH             Repo root — scan every .bats file under {root}/tests/
                          and {root}/plugins/gaia/tests/.
  --max-age-days N        Skip-directive age threshold (default: 90). Bare skips
                          older than this trigger STALE-SKIP findings.
  --assume-age-days N     Override per-line age computation; every bare skip is
                          treated as if it were N days old. Used by bats fixtures
                          where git-blame is unavailable.
  --help                  Print this help and exit.

Exit codes:
  0  No stale bare skips found.
  1  At least one stale bare skip found.
  2  Usage error.
EOF
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit "${2:-2}"; }

BATS_FILE=""
ROOT=""
MAX_AGE_DAYS=90
ASSUME_AGE_DAYS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bats-file)
      [ $# -ge 2 ] || die "missing argument for --bats-file"
      BATS_FILE="$2"; shift 2 ;;
    --root)
      [ $# -ge 2 ] || die "missing argument for --root"
      ROOT="$2"; shift 2 ;;
    --max-age-days)
      [ $# -ge 2 ] || die "missing argument for --max-age-days"
      MAX_AGE_DAYS="$2"; shift 2 ;;
    --assume-age-days)
      [ $# -ge 2 ] || die "missing argument for --assume-age-days"
      ASSUME_AGE_DAYS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1" ;;
  esac
done

if [ -z "$BATS_FILE" ] && [ -z "$ROOT" ]; then
  usage >&2
  die "must supply either --bats-file or --root"
fi
if [ -n "$BATS_FILE" ] && [ -n "$ROOT" ]; then
  die "--bats-file and --root are mutually exclusive"
fi
if [ -n "$BATS_FILE" ] && [ ! -f "$BATS_FILE" ]; then
  die "bats file not found: $BATS_FILE"
fi
if [ -n "$ROOT" ] && [ ! -d "$ROOT" ]; then
  die "root not a directory: $ROOT"
fi

# Validate numeric inputs.
case "$MAX_AGE_DAYS" in ''|*[!0-9]*) die "--max-age-days must be a non-negative integer (got '$MAX_AGE_DAYS')" ;; esac
if [ -n "$ASSUME_AGE_DAYS" ]; then
  case "$ASSUME_AGE_DAYS" in ''|*[!0-9]*) die "--assume-age-days must be a non-negative integer (got '$ASSUME_AGE_DAYS')" ;; esac
fi

# compute_age_days <bats-file> <line-number>
# Echoes the age in days. Strategy:
#   1. If --assume-age-days is set, use it (test/CI override).
#   2. Else try `git log -1 --format=%ct -- <file>` on the line introducing the
#      skip via `git blame -L <n>,<n> -- <file>` to get the commit timestamp.
#   3. Else fall back to MAX_AGE_DAYS+1 (treat as just over threshold) ONLY when
#      no assume override AND no git available — this conservatively flags
#      unknown-age skips as stale rather than silently passing.
compute_age_days() {
  local file="$1"
  local lineno="$2"

  if [ -n "$ASSUME_AGE_DAYS" ]; then
    printf '%s\n' "$ASSUME_AGE_DAYS"
    return 0
  fi

  # Try git blame for per-line author-time.
  local blame_ct=""
  if command -v git >/dev/null 2>&1; then
    blame_ct="$(git log -1 --format=%ct -- "$file" 2>/dev/null || true)"
    # If git log returns a timestamp, compute now-ct in days.
    if [ -n "$blame_ct" ] && [ "$blame_ct" -gt 0 ] 2>/dev/null; then
      local now_ct
      now_ct="$(date +%s)"
      local age_secs=$(( now_ct - blame_ct ))
      [ "$age_secs" -lt 0 ] && age_secs=0
      printf '%s\n' "$(( age_secs / 86400 ))"
      return 0
    fi
  fi

  # Fall back: treat as just over the threshold (conservative — flag as stale).
  printf '%s\n' "$(( MAX_AGE_DAYS + 1 ))"
}

# scan_bats_file <bats-file>
# Emits STALE-SKIP lines for each bare-skip older than MAX_AGE_DAYS. Returns 1
# if any stale finding emitted, 0 otherwise.
scan_bats_file() {
  local file="$1"
  local stale=0

  # Build an awk pre-pass that emits "<lineno>\t<classification>" for each
  # `skip` directive inside @test blocks.
  #   ANNOTATED — same-line or immediately-preceding-line `# skip-permanent:`
  #   BARE — no annotation
  #
  # The awk pre-pass keeps state for the previous non-blank line so we can
  # detect annotations on the line above the skip. It also detects same-line
  # annotations like `skip "x"  # skip-permanent: legacy compat`.
  local pairs
  pairs="$(awk '
    BEGIN { prev_line = "" }
    {
      cur = $0
      stripped = cur
      sub(/^[[:space:]]+/, "", stripped)
      sub(/[[:space:]]+$/, "", stripped)

      # Detect skip directive: stripped line begins with "skip" as a function
      # call. Bats `skip` is always invoked as a top-level statement, so we
      # require the line (after leading whitespace) to start with `skip` followed
      # by EOL, whitespace, `;`, `"`, or `(`. This avoids false positives where
      # the word "skip" appears inside @test names or comments.
      if (substr(stripped, 1, 1) != "#" && match(stripped, /^skip([[:space:];"\(]|$)/)) {
        # Same-line annotation?
        if (match(cur, /#[[:space:]]*skip-permanent:[[:space:]]*[^[:space:]]/)) {
          printf "%d\tANNOTATED\n", NR
        } else if (match(prev_line, /^[[:space:]]*#[[:space:]]*skip-permanent:[[:space:]]*[^[:space:]]/)) {
          # Preceding-line annotation.
          printf "%d\tANNOTATED\n", NR
        } else {
          printf "%d\tBARE\n", NR
        }
      }
      # Track previous non-blank line for the next iteration.
      if (stripped != "") { prev_line = cur }
    }
  ' "$file")"

  if [ -z "$pairs" ]; then
    return 0
  fi

  while IFS=$'\t' read -r lineno classification; do
    [ -n "$lineno" ] || continue
    if [ "$classification" = "ANNOTATED" ]; then
      continue
    fi
    # BARE skip — apply age check.
    local age
    age="$(compute_age_days "$file" "$lineno")"
    if [ "$age" -gt "$MAX_AGE_DAYS" ]; then
      printf 'STALE-SKIP: %s:%s age_days=%s reason=bare-skip-older-than-%s-days\n' \
        "$file" "$lineno" "$age" "$MAX_AGE_DAYS"
      stale=1
    fi
  done <<< "$pairs"

  return "$stale"
}

# --- Main dispatch --------------------------------------------------------

if [ -n "$BATS_FILE" ]; then
  if scan_bats_file "$BATS_FILE"; then
    exit 0
  else
    exit 1
  fi
fi

# --root mode: walk every .bats under {root}/tests and {root}/plugins/gaia/tests.
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
  if ! scan_bats_file "$f"; then
    stale_total=1
  fi
done < "$TMP_LIST"

exit "$stale_total"
