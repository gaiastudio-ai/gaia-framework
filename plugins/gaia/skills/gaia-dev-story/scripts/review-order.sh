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
#   1 — refused (drift, mismatch, bad value, fetch failure)
#   2 — usage error
#   3 — skipped (non-git CWD, via the shared guard)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="review-order.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

  local git_dir="${PROJECT_PATH:-.}"

  # Non-git CWD guard: exit 3 if not in a git work tree.
  if ! git -C "$git_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s: skipped (non-git CWD)\n' "$SCRIPT_NAME" >&2
    exit 3
  fi

  # Fetch the base branch. Fetch failure fails closed (exit 1).
  if ! git -C "$git_dir" fetch origin "$base" 2>/dev/null; then
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
# Verifies the working tree is clean and every Review Gate row is bound to HEAD.

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

  # Clean tree check.
  local dirty
  dirty="$(git -C "$git_dir" status --porcelain 2>/dev/null)" || true
  if [ -n "$dirty" ]; then
    printf '%s: working tree is not clean:\n%s\n' "$SCRIPT_NAME" "$dirty" >&2
    exit 1
  fi

  # Get current HEAD.
  local head_sha
  head_sha="$(git -C "$git_dir" rev-parse HEAD)"
  # Use the short form for comparison (review-gate rows use short SHAs).
  local head_short
  head_short="$(git -C "$git_dir" rev-parse --short HEAD)"

  # Read Review Gate rows from the story file.
  local in_gate=0
  local line
  while IFS= read -r line; do
    # Detect the Review Gate section.
    case "$line" in
      "## Review Gate"*) in_gate=1; continue ;;
      "## "*) [ "$in_gate" -eq 1 ] && break ;;
    esac
    [ "$in_gate" -eq 0 ] && continue

    # Skip header/separator rows.
    case "$line" in
      "| Review"*|"| -"*|"|-"*) continue ;;
    esac

    # Only process pipe-delimited rows with content.
    case "$line" in
      "| "*) ;;
      *) continue ;;
    esac

    local parsed
    parsed="$(parse_review_gate_row "$line" 2>/dev/null)" || continue

    local gate="" row_sha=""
    gate="$(printf '%s\n' "$parsed" | grep '^gate=' | head -1)"
    gate="${gate#gate=}"
    row_sha="$(printf '%s\n' "$parsed" | grep '^reviewed_sha=' | head -1)"
    row_sha="${row_sha#reviewed_sha=}"

    # Trim whitespace from SHA.
    row_sha="${row_sha#"${row_sha%%[![:space:]]*}"}"
    row_sha="${row_sha%"${row_sha##*[![:space:]]}"}"

    if [ -z "$gate" ]; then
      continue
    fi

    # Skip rows with "absent" SHA (legacy 3-column tables or unseeded rows).
    if [ "$row_sha" = "absent" ] || [ "$row_sha" = "—" ] || [ -z "$row_sha" ]; then
      printf '%s: row "%s" has no reviewed SHA bound\n' "$SCRIPT_NAME" "$gate" >&2
      exit 1
    fi

    # Compare the row SHA against HEAD. Review-gate writes short SHAs,
    # so compare both the full and short forms.
    if [ "$row_sha" != "$head_sha" ] && [ "$row_sha" != "$head_short" ]; then
      # Try resolving the row SHA to compare full forms.
      local row_full
      row_full="$(git -C "$git_dir" rev-parse "$row_sha" 2>/dev/null)" || row_full=""
      if [ "$row_full" != "$head_sha" ]; then
        printf '%s: row "%s" is bound to %s but HEAD is %s\n' \
          "$SCRIPT_NAME" "$gate" "$row_sha" "$head_short" >&2
        exit 1
      fi
    fi
  done < "$story_file"

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
