#!/usr/bin/env bash
# review-order.sh — review-ordering helper for /gaia-dev-story
#
# Subcommands:
#   mode                                 Print the active review ordering mode.
#   ancestor-check --base <branch>       Verify the promotion base is an ancestor of HEAD.
#   assert-reviewed-head --story <file>  Assert clean tree and all review rows bound to HEAD.
#
# Exit codes:
#   0 — ok
#   1 — refused (drift, mismatch, malformed Review Gate table, bad value, fetch failure)
#   2 — usage error
#   3 — skipped (code path outside any git work tree)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="review-order.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The six rows a complete Review Gate table must hold, exactly once each.
CANONICAL_GATES=(
  "Code Review"
  "QA Tests"
  "Security Review"
  "Test Automation"
  "Test Review"
  "Performance Review"
)

# ---------- Source shared libraries ----------

# shellcheck source=../../../scripts/lib/non-git-cwd-guard.sh
. "$PLUGIN_ROOT/scripts/lib/non-git-cwd-guard.sh"

# shellcheck source=../../../scripts/lib/review-gate-table.sh
. "$PLUGIN_ROOT/scripts/lib/review-gate-table.sh"

# ---------- Helpers ----------

_die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

_die_usage() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  printf 'Usage: %s {mode|ancestor-check|assert-reviewed-head} [options]\n' "$SCRIPT_NAME" >&2
  exit 2
}

# Exit 3 when the code path is outside any git work tree (a bare repository has
# no work tree either). A path that does not exist is a broken setup, not a
# non-git workspace, so it is refused rather than skipped.
_require_git_work_tree() {
  local git_dir="$1" inside
  [ -d "$git_dir" ] || _die "code path is not a directory: $git_dir"
  inside="$(git -C "$git_dir" rev-parse --is-inside-work-tree 2>/dev/null)" || inside=""
  if [ "$inside" != "true" ]; then
    printf '%s: skipped (non-git CWD)\n' "$SCRIPT_NAME" >&2
    exit 3
  fi
}

# ---------- Subcommand: mode ----------
# Reads dev_story.review_before_merge from project config.
# Prints "pre-push" for true, "default" for false or empty.
# Exits non-zero for any other value.

cmd_mode() {
  local val
  val="$("$PLUGIN_ROOT/scripts/resolve-config.sh" --field dev_story.review_before_merge 2>/dev/null)" || true

  # Trim whitespace.
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"

  case "$val" in
    true)  printf 'pre-push\n' ;;
    false|"") printf 'default\n' ;;
    *)
      printf '%s: invalid value for dev_story.review_before_merge: '\''%s'\'' (allowed: true, false)\n' \
        "$SCRIPT_NAME" "$val" >&2
      exit 1
      ;;
  esac
}

# ---------- Subcommand: ancestor-check ----------
# Fetches the promotion base and verifies origin/<base> is an ancestor of HEAD.
# Uses PROJECT_PATH for git operations when set.

cmd_ancestor_check() {
  local base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        [ $# -ge 2 ] || _die_usage "--base requires a branch name"
        base="$2"; shift 2 ;;
      *) _die_usage "ancestor-check: unknown flag: $1" ;;
    esac
  done
  [ -n "$base" ] || _die_usage "ancestor-check: --base <branch> is required"

  # The value reaches git as an argument, so an option-shaped or malformed name
  # must never get that far.
  case "$base" in
    -*) _die "invalid base branch name: $base" ;;
  esac
  git check-ref-format "refs/heads/$base" || _die "invalid base branch name: $base"

  local git_dir="${PROJECT_PATH:-.}"
  _require_git_work_tree "$git_dir"

  # Fetch the base branch. Fetch failure fails closed (exit 1).
  if ! git -C "$git_dir" fetch --end-of-options origin "$base" 2>/dev/null; then
    printf '%s: fetch failed for origin/%s — halting (fail closed)\n' "$SCRIPT_NAME" "$base" >&2
    exit 1
  fi

  local base_tip head_sha
  base_tip="$(git -C "$git_dir" rev-parse "origin/$base" 2>/dev/null)" || {
    printf '%s: cannot resolve origin/%s\n' "$SCRIPT_NAME" "$base" >&2
    exit 1
  }
  head_sha="$(git -C "$git_dir" rev-parse HEAD)"

  if git -C "$git_dir" merge-base --is-ancestor "$base_tip" "$head_sha" 2>/dev/null; then
    exit 0
  else
    printf '%s: drift detected — origin/%s tip %s is not an ancestor of HEAD %s\n' \
      "$SCRIPT_NAME" "$base" "$base_tip" "$head_sha" >&2
    printf '%s: rebase or merge the base branch and re-review before pushing\n' \
      "$SCRIPT_NAME" >&2
    exit 1
  fi
}

# ---------- Subcommand: assert-reviewed-head ----------
# Verifies the working tree is clean and each of the six Review Gate rows is
# bound to HEAD. Anything that cannot be shown to be bound is refused: a missing
# section, a missing, duplicated, unknown or unparseable row, or a SHA cell that
# is not a commit hash.

cmd_assert_reviewed_head() {
  local story_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        [ $# -ge 2 ] || _die_usage "assert-reviewed-head: --story requires a file path"
        story_file="$2"; shift 2 ;;
      *) _die_usage "assert-reviewed-head: unknown flag: $1" ;;
    esac
  done
  [ -n "$story_file" ] || _die_usage "assert-reviewed-head: --story <file> is required"
  [ -f "$story_file" ] || _die "story file not found: $story_file"

  local git_dir="${PROJECT_PATH:-.}"
  _require_git_work_tree "$git_dir"

  # Clean tree check.
  local dirty
  dirty="$(git -C "$git_dir" status --porcelain 2>/dev/null)" || _die "cannot read working tree state in $git_dir"
  if [ -n "$dirty" ]; then
    printf '%s: working tree is not clean:\n%s\n' "$SCRIPT_NAME" "$dirty" >&2
    exit 1
  fi

  local head_sha head_short
  head_sha="$(git -C "$git_dir" rev-parse --verify --quiet HEAD)" || _die "cannot resolve HEAD in $git_dir"
  head_short="$(git -C "$git_dir" rev-parse --short HEAD)"

  local rows
  rows="$(parse_review_gate_table "$story_file")" || _die "no readable Review Gate table in $story_file"

  local gate row_shas row_sha
  for gate in "${CANONICAL_GATES[@]}"; do
    row_shas="$(printf '%s\n' "$rows" | awk -F'\t' -v g="$gate" '$1 == g { print $4 }')"
    case "$row_shas" in
      "") _die "Review Gate has no row for \"$gate\"" ;;
      *$'\n'*) _die "Review Gate has more than one row for \"$gate\"" ;;
    esac
    row_sha="$row_shas"

    case "$row_sha" in
      absent|none|"—") _die "row \"$gate\" has no reviewed SHA bound" ;;
      *[!0-9a-f]*) _die "row \"$gate\" holds '$row_sha', which is not a commit SHA" ;;
    esac
    if [ "${#row_sha}" -lt 7 ] || [ "${#row_sha}" -gt 40 ]; then
      _die "row \"$gate\" holds '$row_sha', which is not a commit SHA"
    fi

    # A full or abbreviated hash is bound to HEAD when HEAD starts with it.
    case "$head_sha" in
      "$row_sha"*) ;;
      *) _die "row \"$gate\" is bound to $row_sha but HEAD is $head_short" ;;
    esac
  done

  # Every canonical gate matched exactly once, so any further row is unknown.
  local unknown
  unknown="$(printf '%s\n' "$rows" | awk -F'\t' 'NR > 6 { print $1; exit }')"
  [ -z "$unknown" ] || _die "Review Gate has an unknown row \"$unknown\" (expected the six canonical rows)"

  exit 0
}

# ---------- Dispatch ----------

[ $# -ge 1 ] || _die_usage "subcommand required"

subcmd="$1"; shift
case "$subcmd" in
  mode)                 cmd_mode "$@" ;;
  ancestor-check)       cmd_ancestor_check "$@" ;;
  assert-reviewed-head) cmd_assert_reviewed_head "$@" ;;
  --help|-h)
    printf 'Usage: %s {mode|ancestor-check|assert-reviewed-head} [options]\n' "$SCRIPT_NAME"
    exit 0 ;;
  *) _die_usage "unknown subcommand: $subcmd" ;;
esac
