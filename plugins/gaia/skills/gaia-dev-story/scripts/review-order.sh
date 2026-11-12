#!/usr/bin/env bash
# review-order.sh — review-ordering helper for /gaia-dev-story
#
# Subcommands:
#   mode                                 Print the active review ordering mode.
#   ancestor-check --base <branch>       Verify the promotion base is an ancestor of HEAD.
#   assert-reviewed-head --story <file>  Assert clean tree and all review rows bound to HEAD.
#   check-layout --story <file>          Refuse a layout that cannot keep the tree clean.
#   check-layout --worktree-mode-only    Only the worktree-mode half, for use before a worktree exists.
#   find-worktree --story-key <key>      Print this story's worktree path.
#   merge-guard --story-key <key>        Allow or refuse review -> done for a pre-push story.
#
# Exit codes:
#   0 — ok
#   1 — refused (drift, mismatch, malformed Review Gate table, bad value, fetch failure,
#       unresolvable config, unsupported layout, no worktree, PR not verified merged)
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
  printf 'Usage: %s {mode|ancestor-check|assert-reviewed-head|check-layout|find-worktree|merge-guard} [options]\n' "$SCRIPT_NAME" >&2
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

# Print the team-shared config file the resolver would use, or nothing. The
# resolver walks up from its working directory only inside the git work tree
# when outside HOME, so a repo inside a non-git project root is walked here,
# from the code path, the same bounded way the promotion-chain guard does.
_discover_shared_config() {
  local root dir depth=0
  if [ -n "${GAIA_SHARED_CONFIG:-}" ]; then
    printf '%s\n' "$GAIA_SHARED_CONFIG"
    return 0
  fi
  for root in "${PROJECT_ROOT:-}" "${CLAUDE_PROJECT_ROOT:-}"; do
    [ -n "$root" ] || continue
    if [ -f "$root/.gaia/config/project-config.yaml" ]; then
      printf '%s\n' "$root/.gaia/config/project-config.yaml"
      return 0
    elif [ -f "$root/config/project-config.yaml" ]; then
      printf '%s\n' "$root/config/project-config.yaml"
      return 0
    fi
  done
  [ -z "${GAIA_NO_PROJECT_WALKUP:-}" ] || return 0
  dir="$(cd "${PROJECT_PATH:-.}" 2>/dev/null && pwd -P)" || return 0
  while [ "$depth" -lt 8 ]; do
    if [ -f "$dir/.gaia/config/project-config.yaml" ]; then
      printf '%s\n' "$dir/.gaia/config/project-config.yaml"
      return 0
    elif [ -f "$dir/config/project-config.yaml" ]; then
      printf '%s\n' "$dir/config/project-config.yaml"
      return 0
    fi
    [ "$dir" != "/" ] || return 0
    dir="$(dirname "$dir")"
    depth=$((depth + 1))
  done
}

# Run the resolver against the discovered project. Without an explicit root the
# discovered one is passed down, which also finds the machine-local overlay.
_resolve() {
  local cfg anchor
  cfg="$(_discover_shared_config)"
  case "$cfg" in
    ""|"${GAIA_SHARED_CONFIG:-///}"|"${PROJECT_ROOT:-///}"/*|"${CLAUDE_PROJECT_ROOT:-///}"/*)
      "$PLUGIN_ROOT/scripts/resolve-config.sh" "$@"
      return
      ;;
  esac
  anchor="$(dirname "$(dirname "$cfg")")"
  anchor="${anchor%/.gaia}"
  CLAUDE_PROJECT_ROOT="$anchor" "$PLUGIN_ROOT/scripts/resolve-config.sh" "$@"
}

# ---------- Subcommand: mode ----------
# Reads dev_story.review_before_merge from project config.
# Prints "pre-push" for true, "default" for false or empty, and also "default"
# when no config file exists anywhere, since then the key is absent.
# Exits non-zero for any other value and when the config cannot be resolved: a
# broken config must never read as the default order.

cmd_mode() {
  local val err_file err rc=0
  err_file="$(mktemp)" || _die "cannot create a temporary file"
  val="$(_resolve --field dev_story.review_before_merge 2>"$err_file")" || rc=$?
  err="$(cat "$err_file")"
  rm -f "$err_file"

  if [ "$rc" -ne 0 ]; then
    case "$err" in
      *"no config path"*) val="" ;;
      *"config file not found"*)
        if [ -n "${GAIA_SHARED_CONFIG:-}" ]; then
          _die "cannot resolve dev_story.review_before_merge: $err"
        fi
        val="" ;;
      *) _die "cannot resolve dev_story.review_before_merge: $err" ;;
    esac
  fi

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

  # Fetch the base into its tracking ref with an explicit refspec, so a narrowed
  # remote.origin.fetch cannot leave that ref stale. Fetch failure fails closed.
  local tracking_ref="refs/remotes/origin/$base"
  if ! git -C "$git_dir" fetch --end-of-options origin "+refs/heads/$base:$tracking_ref" 2>/dev/null; then
    printf '%s: fetch failed for origin/%s — halting (fail closed)\n' "$SCRIPT_NAME" "$base" >&2
    exit 1
  fi

  # The full ref name: a local branch or tag called origin/<base> must not shadow it.
  local base_tip head_sha
  base_tip="$(git -C "$git_dir" rev-parse --verify --quiet "$tracking_ref^{commit}")" || {
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

# ---------- Subcommand: check-layout ----------
# Pre-push review needs a story worktree whose tree the review artifacts do not
# dirty. Refuses worktree mode off, a code path that is not a linked worktree,
# and a story file inside the code work tree. A non-git code path skips (exit 3)
# and a project with no promotion chain passes, since neither ever pushes.

_layout_refusal() {
  printf '%s: review_before_merge cannot run in this layout: %s\n' "$SCRIPT_NAME" "$1" >&2
  printf '%s: enable worktree mode with GAIA_WORKTREE_MODE=1, or set dev_story.review_before_merge to false\n' "$SCRIPT_NAME" >&2
  exit 1
}

# Print the absolute physical path of a file, following symlinks.
_real_file_path() {
  local path="$1" dir link
  while [ -L "$path" ]; do
    link="$(readlink "$path")"
    case "$link" in
      /*) path="$link" ;;
      *) path="$(dirname "$path")/$link" ;;
    esac
  done
  dir="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# Prints the promotion chain's first branch, nothing when there is none or the
# code path is not a git work tree. Non-zero when the guard itself failed.
_promotion_base() {
  local code_path="$1" cfg out rc=0
  cfg="$(_discover_shared_config)"
  out="$(cd "$code_path" && PROJECT_CONFIG="${cfg:-${PROJECT_CONFIG:-}}" \
    "$SCRIPT_DIR/promotion-chain-guard.sh" 2>&1)" || rc=$?
  case "$rc" in
    0)
      # No PRESENT line on a clean exit is the guard's non-git skip.
      printf '%s\n' "$out" | sed -n 's/^PRESENT://p'
      ;;
    1)
      case "$out" in
        *"ABSENT:"*) ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

cmd_check_layout() {
  local story_file="" mode_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --story)
        [ $# -ge 2 ] || _die_usage "check-layout: --story requires a file path"
        story_file="$2"; shift 2 ;;
      --worktree-mode-only) mode_only=1; shift ;;
      *) _die_usage "check-layout: unknown flag: $1" ;;
    esac
  done
  if [ "$mode_only" -eq 0 ] && [ -z "$story_file" ]; then
    _die_usage "check-layout: --story <file> or --worktree-mode-only is required"
  fi

  # Resolve the code path. When PROJECT_PATH is unset and the doctor calls
  # --worktree-mode-only from a non-git root, fall back to the config's
  # project_path so the worktree-mode check can still fire.
  local git_dir="${PROJECT_PATH:-.}" base
  if [ "$mode_only" -eq 1 ] && [ -z "${PROJECT_PATH:-}" ]; then
    local _cfg_pairs _cfg_path _cfg_root
    _cfg_pairs="$(_resolve 2>/dev/null)" || true
    _cfg_path="$(printf '%s\n' "$_cfg_pairs" | sed -n "s/^project_path='\\(.*\\)'\$/\\1/p")"
    _cfg_root="$(printf '%s\n' "$_cfg_pairs" | sed -n "s/^project_root='\\(.*\\)'\$/\\1/p")"
    if [ -n "$_cfg_path" ]; then
      case "$_cfg_path" in
        /*) git_dir="$_cfg_path" ;;
        *)  git_dir="${_cfg_root:-.}/$_cfg_path" ;;
      esac
    fi
  fi
  _require_git_work_tree "$git_dir"
  base="$(_promotion_base "$git_dir")" || _die "cannot read the promotion chain from $git_dir"
  [ -n "$base" ] || exit 0

  [ "${GAIA_WORKTREE_MODE:-0}" = "1" ] || _layout_refusal "worktree mode is off"
  [ "$mode_only" -eq 0 ] || exit 0

  [ -f "$story_file" ] || _die "story file not found: $story_file"

  local dirs abs_git abs_common toplevel story_real rest
  dirs="$(cd "$git_dir" && git rev-parse --git-dir --git-common-dir --show-toplevel)" \
    || _die "cannot read the git layout of $git_dir"
  abs_git="$(cd "$git_dir" && cd "${dirs%%$'\n'*}" && pwd -P)" || _die "cannot resolve the git directory of $git_dir"
  rest="${dirs#*$'\n'}"
  abs_common="$(cd "$git_dir" && cd "${rest%%$'\n'*}" && pwd -P)" || _die "cannot resolve the common git directory of $git_dir"
  toplevel="$(cd "${rest#*$'\n'}" && pwd -P)" || _die "cannot resolve the work tree of $git_dir"

  [ "$abs_git" != "$abs_common" ] || _layout_refusal "the code path $toplevel is not a linked worktree"

  story_real="$(_real_file_path "$story_file")" || _die "cannot resolve story file: $story_file"
  case "$story_real" in
    "$toplevel"/*) _layout_refusal "the story file $story_real is inside the code work tree $toplevel" ;;
  esac
  exit 0
}

# ---------- Subcommand: find-worktree ----------
# Prints this story's worktree: the newest checkpoint for this story_key whose
# worktree still exists on the story's branch, else a linked worktree on that
# branch. Exit 1 when there is none, naming the key.

_validate_story_key() {
  case "$1" in
    ""|-*|*[!A-Za-z0-9_-]*) _die "invalid story key: $1" ;;
  esac
}

_on_story_branch() {
  local dir="$1" key="$2" branch
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  branch="$(git -C "$dir" branch --show-current 2>/dev/null)" || return 1
  case "$branch" in
    "feat/$key-"*) return 0 ;;
  esac
  return 1
}

_worktree_from_checkpoints() {
  local key="$1" root files file path
  root="${CHECKPOINT_ROOT:-${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/memory/checkpoints}"
  [ -d "$root/gaia-dev-story" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  files="$(find "$root/gaia-dev-story" -maxdepth 1 -name '*-step-*.json' -exec grep -lF -- "$key" {} + 2>/dev/null | sort -r)" || true
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    path="$(CHECKPOINT_ROOT="$root" "$PLUGIN_ROOT/scripts/resume-checkpoint.sh" read --path "$file" 2>/dev/null \
      | jq -r --arg k "$key" 'select(.key_variables.story_key == $k) | .key_variables.worktree_path // empty' 2>/dev/null)" || continue
    if _on_story_branch "$path" "$key"; then
      printf '%s\n' "$path"
      return 0
    fi
  done <<EOF
$files
EOF
  return 1
}

_worktree_from_git() {
  local key="$1" line path="" first=1
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path=""
        # The first record is the main checkout, never a story worktree.
        [ "$first" -eq 1 ] || path="${line#worktree }"
        first=0
        ;;
      "branch refs/heads/feat/$key-"*)
        if [ -n "$path" ] && _on_story_branch "$path" "$key"; then
          printf '%s\n' "$path"
          return 0
        fi
        ;;
    esac
  done <<EOF
$(git -C "${PROJECT_PATH:-.}" worktree list --porcelain 2>/dev/null)
EOF
  return 1
}

_worktree_from_config_path() {
  # Fallback: when PROJECT_PATH is unset (e.g. running from a non-git root),
  # resolve the code path from config and try git worktree list there.
  local key="$1"
  [ -z "${PROJECT_PATH:-}" ] || return 1
  local _cfg_pairs _cfg_path _cfg_root _resolved
  _cfg_pairs="$(_resolve 2>/dev/null)" || return 1
  _cfg_path="$(printf '%s\n' "$_cfg_pairs" | sed -n "s/^project_path='\\(.*\\)'\$/\\1/p")"
  _cfg_root="$(printf '%s\n' "$_cfg_pairs" | sed -n "s/^project_root='\\(.*\\)'\$/\\1/p")"
  [ -n "$_cfg_path" ] || return 1
  case "$_cfg_path" in
    /*) _resolved="$_cfg_path" ;;
    *)  _resolved="${_cfg_root:-.}/$_cfg_path" ;;
  esac
  [ -d "$_resolved" ] || return 1
  PROJECT_PATH="$_resolved" _worktree_from_git "$key"
}

cmd_find_worktree() {
  local key=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story-key)
        [ $# -ge 2 ] || _die_usage "find-worktree: --story-key requires a value"
        key="$2"; shift 2 ;;
      *) _die_usage "find-worktree: unknown flag: $1" ;;
    esac
  done
  [ -n "$key" ] || _die_usage "find-worktree: --story-key <key> is required"
  _validate_story_key "$key"
  _worktree_from_checkpoints "$key" || _worktree_from_git "$key" \
    || _worktree_from_config_path "$key" \
    || _die "no worktree on a feat/$key- branch for story $key"
}

# ---------- Subcommand: merge-guard ----------
# Decides review -> done for a pre-push story; every caller that can make that
# move shares this one decision. Default mode ends right after the mode read,
# with no verifier or network call. Anything that cannot be determined refuses.

_merge_refusal() {
  printf '%s: review -> done refused for %s: %s\n' "$SCRIPT_NAME" "$1" "$2" >&2
  exit 1
}

cmd_merge_guard() {
  local key=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --story-key)
        [ $# -ge 2 ] || _die_usage "merge-guard: --story-key requires a value"
        key="$2"; shift 2 ;;
      *) _die_usage "merge-guard: unknown flag: $1" ;;
    esac
  done
  [ -n "$key" ] || _die_usage "merge-guard: --story-key <key> is required"

  [ "${GAIA_ALLOW_REVIEW_TO_DONE_WITHOUT_GATE:-0}" != "1" ] || exit 0

  local mode
  mode="$(cmd_mode 2>/dev/null)" || mode=""
  # The guard engages only when mode is known to be pre-push. A resolver
  # failure or an unreadable config cannot confirm opt-in, so the guard
  # allows the transition — the user never opted in.
  [ "$mode" = "pre-push" ] || exit 0

  # Validate after the mode check so default-mode users with non-standard keys
  # are never refused (they exit 0 above and no verifier or network call runs).
  _validate_story_key "$key"

  # The code path comes from config: a transition may run from a non-git root.
  local pairs code_path root
  pairs="$(_resolve 2>/dev/null)" || _merge_refusal "$key" "the code path could not be read from project config"
  code_path="$(printf '%s\n' "$pairs" | sed -n "s/^project_path='\\(.*\\)'\$/\\1/p")"
  root="$(printf '%s\n' "$pairs" | sed -n "s/^project_root='\\(.*\\)'\$/\\1/p")"
  [ -n "$code_path" ] || _merge_refusal "$key" "project config names no code path"
  case "$code_path" in
    /*) ;;
    *) code_path="$root/$code_path" ;;
  esac
  [ -d "$code_path" ] || _merge_refusal "$key" "the code path does not exist: $code_path"

  local base target rc=0
  base="$(_promotion_base "$code_path")" || _merge_refusal "$key" "the promotion chain could not be read"
  target="${base:---no-chain}"
  PROJECT_PATH="$code_path" "$SCRIPT_DIR/verify-pr-merged.sh" --strict "$key" "$target" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|3) exit 0 ;;
    2) _merge_refusal "$key" "its PR is not verified merged; finish push and merge with /gaia-dev-story $key" ;;
    *) _merge_refusal "$key" "the merge could not be verified (exit $rc); finish push and merge with /gaia-dev-story $key" ;;
  esac
}

# ---------- Dispatch ----------

[ $# -ge 1 ] || _die_usage "subcommand required"

subcmd="$1"; shift
case "$subcmd" in
  mode)                 cmd_mode "$@" ;;
  ancestor-check)       cmd_ancestor_check "$@" ;;
  assert-reviewed-head) cmd_assert_reviewed_head "$@" ;;
  check-layout)         cmd_check_layout "$@" ;;
  find-worktree)        cmd_find_worktree "$@" ;;
  merge-guard)          cmd_merge_guard "$@" ;;
  --help|-h)
    printf 'Usage: %s {mode|ancestor-check|assert-reviewed-head|check-layout|find-worktree|merge-guard} [options]\n' "$SCRIPT_NAME"
    exit 0 ;;
  *) _die_usage "unknown subcommand: $subcmd" ;;
esac
