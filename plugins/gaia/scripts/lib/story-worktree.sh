#!/usr/bin/env bash
# story-worktree.sh — per-story linked git worktree lifecycle.
#
# Background:
#   Developing two stories in one work tree lets their edits bleed together: the
#   checkout is shared, and scan-based generators pick up whatever is on disk
#   regardless of which branch is current. A linked git worktree gives each story
#   its own working directory and index while sharing the object store, which is
#   git's own mechanism for exactly this.
#
# Contract:
#   This file is intended to be SOURCED, not executed. Sourcing makes the
#   worktree_* functions available. Callers own their own `set -euo pipefail`;
#   this library does not set shell options for them.
#
# Lifecycle:
#   create -> export the path -> use for the story -> remove -> prune.
#   A trap removes the worktree on any exit path. Because a trap cannot fire on
#   SIGKILL, the next story start prunes whatever a killed run left behind.
#
# Mode:
#   Worktree mode is OPT-IN. It is active only when GAIA_WORKTREE_MODE=1, so a
#   project that does not ask for it behaves exactly as before.
#
# Exit codes (worktree_create):
#   0  the worktree exists and its path is on stdout
#   1  refused -- mode off, bad usage, or a real error
#   3  no git work tree here, so there is nothing to isolate. This is a
#      DEGRADATION, not a failure: the caller keeps its working directory and
#      runs the story in place. It is distinct from 1 so a caller can tell
#      "skip with a warning" from "something went wrong".
#
# Safety:
#   Removal NEVER uses --force. git refuses to remove a worktree holding modified
#   or untracked files, and that refusal is honoured: the worktree is left in
#   place with a warning rather than destroying work that was never committed.
#
# Portability:
#   Bash 3.2 (no associative arrays, no mapfile/readarray). No GNU-only tools.

# Refuse to be executed directly: this file defines functions for a caller and
# does nothing on its own. When sourced, BASH_SOURCE[0] is this file while $0 is
# the sourcing program; when executed, the two are the same path.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf 'story-worktree.sh: must be sourced, not executed\n' >&2
  exit 1
fi

_SW_NAME="story-worktree.sh"

# Directory name holding every story worktree, as a sibling of the code tree.
_SW_PARENT_BASENAME=".gaia-worktrees"

# Longest slug allowed in a branch name. A ref becomes a filesystem path under
# .git/refs, so an unbounded slug hits the per-component name limit and git
# fails with "File name too long". The story key is never truncated, so branch
# names stay unique per story regardless of how much slug is trimmed.
_SW_SLUG_MAX=60

_sw_log() { printf '%s: %s\n' "$_SW_NAME" "$*" >&2; }

# Paths already torn down in this shell, space-delimited. A trap on EXIT INT TERM
# fires twice for a signal (once for the signal, once for the EXIT that follows),
# so teardown must be silent on the second pass rather than repeating its warning.
_SW_TORN_DOWN=""

_sw_mark_torn() { _SW_TORN_DOWN="$_SW_TORN_DOWN $1 "; }

# _sw_forget_torn <path> — drop one path from the teardown bookkeeping using
# only shell string operations, so a path is never interpreted as a pattern.
_sw_forget_torn() {
  local needle=" $1 " head tail rest="$_SW_TORN_DOWN" out=""
  while :; do
    case "$rest" in
      *"$needle"*)
        head="${rest%%"$needle"*}"
        tail="${rest#*"$needle"}"
        out="$out$head "
        rest="$tail"
        ;;
      *) out="$out$rest"; break ;;
    esac
  done
  _SW_TORN_DOWN="$out"
}
_sw_already_torn() {
  case "$_SW_TORN_DOWN" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# _sw_pid_alive <pid> — 0 when the process exists, 1 only when it demonstrably
# does not. `kill -0` returns non-zero BOTH for "no such process" (ESRCH) and
# for a live process owned by another uid (EPERM), so the exit status alone
# would report a foreign-uid owner as dead and let its worktree be reaped out
# from under it. Read the error text, and fall back to ps(1); anything we cannot
# positively classify as gone counts as ALIVE (fail closed).
_sw_pid_alive() {
  local pid="${1:-}" err
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  err="$(kill -0 "$pid" 2>&1)" && return 0
  case "$err" in
    *"no such process"*|*"No such process"*) ;;
    *) return 0 ;;
  esac
  # ESRCH from kill(2). Confirm with ps before declaring the owner gone.
  if [ -n "$(ps -p "$pid" -o pid= 2>/dev/null)" ]; then
    return 0
  fi
  return 1
}

# _sw_device_of <path> — filesystem device id, or empty when undeterminable.
#
# Probe GNU coreutils FIRST, then BSD. The order is load-bearing, not stylistic:
# under GNU stat, `-f` means file-SYSTEM status, so `-f '%d'` treats the format
# as a path (which fails) AND still prints a multi-line filesystem block for the
# real operand to stdout. Trying BSD first therefore emits that block on the
# failing branch and the `||` fallback appends the real device id after it, so
# the captured value contains free-block counters that differ between calls and
# no two paths ever compare equal. BSD stat rejects `-c` with an error and an
# EMPTY stdout, so probing GNU first fails cleanly on both platforms.
_sw_device_of() {
  stat -c '%d' "$1" 2>/dev/null || stat -f '%d' "$1" 2>/dev/null || printf ''
}

# worktree_mode_enabled — 0 when worktree mode is on, 1 otherwise.
# Single source of truth for the opt-in check; never re-implement it inline.
# Enforced by worktree_create below, so the default-off contract is executable
# rather than a convention a caller has to remember.
worktree_mode_enabled() {
  [ "${GAIA_WORKTREE_MODE:-}" = "1" ]
}

# worktree_slug_cap <slug> — the slug trimmed to a length that keeps the branch
# ref inside filesystem limits. Echoes the result.
worktree_slug_cap() {
  printf '%s' "${1:-}" | cut -c "1-${_SW_SLUG_MAX}"
}

# worktree_parent_dir <code_tree> — the directory that holds story worktrees:
# a sibling of the primary git tree. Echoes an absolute path.
#
# The parent is derived from the code tree's git top-level, NOT from the project
# root: in a layout where the project root sits above the git tree, those differ,
# and only the git-derived form keeps the worktree on the same filesystem as the
# object store it shares.
worktree_parent_dir() {
  local repo="${1:-}" top parent_of_top
  [ -n "$repo" ] || { _sw_log "usage: worktree_parent_dir <code_tree>"; return 1; }
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    _sw_log "not a git work tree: $repo"
    return 1
  }
  parent_of_top="$(cd "$top/.." 2>/dev/null && pwd)" || {
    _sw_log "cannot resolve the parent directory of $top"
    return 1
  }
  printf '%s' "$parent_of_top/$_SW_PARENT_BASENAME"
}

# worktree_validate_parent <parent_dir> <code_tree_toplevel> — refuse, before any
# worktree is created, when the parent is unusable. Fails closed: a probe that
# cannot be evaluated is treated as a refusal, never as permission.
worktree_validate_parent() {
  local parent="$1" top="$2" probe parent_dev top_dev

  # The parent may not exist yet; judge the nearest existing ancestor.
  probe="$parent"
  while [ ! -d "$probe" ]; do
    local next
    next="$(dirname "$probe")"
    [ "$next" != "$probe" ] || break
    probe="$next"
  done
  [ -d "$probe" ] || { _sw_log "no existing ancestor for worktree parent: $parent"; return 1; }

  probe="$(cd "$probe" && pwd)" || { _sw_log "cannot resolve worktree parent: $parent"; return 1; }
  top="$(cd "$top" && pwd)" || { _sw_log "cannot resolve code tree: $2"; return 1; }

  # At a filesystem root `..` resolves to itself, so the sibling directory the
  # convention asks for cannot exist.
  if [ "$probe" = "$top" ]; then
    _sw_log "refusing: the worktree parent cannot ascend above the code tree ($top)"
    return 1
  fi

  parent_dev="$(_sw_device_of "$probe")"
  top_dev="$(_sw_device_of "$top")"
  if [ -z "$parent_dev" ] || [ -z "$top_dev" ]; then
    _sw_log "refusing: cannot determine the filesystem for $probe"
    return 1
  fi
  if [ "$parent_dev" != "$top_dev" ]; then
    _sw_log "refusing: $probe is on a different filesystem than $top"
    return 1
  fi

  if [ ! -w "$probe" ]; then
    _sw_log "refusing: worktree parent is not writable: $probe"
    return 1
  fi

  return 0
}

# worktree_branch_state <code_tree> <branch> — one of:
#   absent             the ref does not exist
#   free               the ref exists and no worktree holds it
#   checked-out:<path> the ref exists and that worktree holds it
#
# This is what makes creation re-entrant. A branch ref outlives every worktree
# teardown, so a second `worktree add -b` on the same branch fails; the caller
# needs to know which form of `add` to use.
worktree_branch_state() {
  local repo="${1:-}" branch="${2:-}" listing line current="" holder=""
  [ -n "$repo" ] && [ -n "$branch" ] || {
    _sw_log "usage: worktree_branch_state <code_tree> <branch>"; return 1; }

  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    printf 'absent'
    return 0
  fi

  listing="$(git -C "$repo" worktree list --porcelain 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        current="${line#worktree }"
        ;;
      "branch refs/heads/"*)
        if [ "${line#branch refs/heads/}" = "$branch" ]; then
          holder="$current"
        fi
        ;;
    esac
  done <<EOF
$listing
EOF

  if [ -n "$holder" ]; then
    printf 'checked-out:%s' "$holder"
  else
    printf 'free'
  fi
  return 0
}

# _sw_lock_reason <story_key> — the lock text this library writes and recognises.
_sw_lock_reason() { printf 'gaia story %s pid %s' "$1" "$2"; }

# _sw_pid_from_reason <reason> — the pid recorded in one of OUR lock reasons, or
# empty when the reason is not ours or carries no usable pid.
#
# The match is anchored on the exact shape `_sw_lock_reason` writes:
#   gaia story <story-key> pid <digits>
# Matching a bare " pid <n> " substring instead would claim another tool's lock
# whose reason merely mentions a pid, and with intact-directory reaping live that
# means unlocking, deleting and unregistering a worktree that was never ours.
# Anything that is not our own shape yields no pid, so every veto downstream
# treats it as foreign and leaves it strictly alone.
_sw_pid_from_reason() {
  local reason="${1:-}" rest pid key

  # Must start with our literal prefix.
  case "$reason" in
    "gaia story "*) rest="${reason#gaia story }" ;;
    *) printf ''; return 0 ;;
  esac

  # <story-key> then the literal " pid " -- and the key itself must be a single
  # token, so a crafted key cannot smuggle in a second " pid " separator.
  case "$rest" in
    *" pid "*) ;;
    *) printf ''; return 0 ;;
  esac
  key="${rest%% pid *}"
  case "$key" in
    ''|*" "*) printf ''; return 0 ;;
  esac

  # Exactly one trailing token, all digits.
  pid="${rest#* pid }"
  case "$pid" in
    ''|*" "*|*[!0-9]*) printf ''; return 0 ;;
  esac
  printf '%s' "$pid"
}

# _sw_reapable <repo> <path> <locked_reason> <branch_ref> — 0 when a locked
# record left by a finished run may be reaped. Every condition must hold; any
# probe that cannot be evaluated leaves the record alone.
#
# A kill or an out-of-memory stop leaves the worktree DIRECTORY fully intact, so
# "directory is gone" cannot be the test for an orphan -- that shape is the
# common one, not the rare one. What distinguishes an orphan is a dead owner.
# The directory then decides only whether reaping is SAFE: an empty checkout has
# nothing to lose, while one holding uncommitted work is kept (see the caller,
# which warns and leaves it locked).
_sw_reapable() {
  local repo="${1:-}" path="${2:-}" reason="${3:-}" branch="${4:-}" pid unpushed

  [ -n "$path" ] || return 1
  [ -n "$reason" ] || return 1

  # Never a candidate unless it is one of our story worktrees. A forged lock
  # reason naming the primary checkout stops here, not at git's own refusal.
  _sw_is_story_worktree "$repo" "$path" || return 1

  # Only records this library locked are ours to act on. A foreign tool's lock
  # is left strictly alone.
  pid="$(_sw_pid_from_reason "$reason")"
  [ -n "$pid" ] || return 1

  # A live owner means a story is still running: never pull its worktree out from
  # under it.
  #
  # This run's OWN pid is a live owner too. Its records fall into two kinds: a
  # worktree it is using right now, and a leftover from an earlier attempt whose
  # directory is already gone. Only the second is an orphan, so the self
  # exception is limited to a vanished directory -- otherwise a story would
  # reap the very worktree it is working in.
  if [ "$pid" = "$$" ]; then
    [ ! -e "$path" ] || return 1
  else
    _sw_pid_alive "$pid" && return 1
  fi

  # Work that exists only locally is never destroyed, even when the owner is gone.
  if [ -n "$branch" ]; then
    unpushed="$(git -C "$repo" rev-list --count "$branch" --not --remotes 2>/dev/null || printf '')"
    [ -n "$unpushed" ] || return 1
    [ "$unpushed" = "0" ] || return 1
  fi

  # Directory still present: reap only when the checkout is clean. A dirty one
  # holds work that was never committed anywhere, so it is preserved.
  if [ -e "$path" ]; then
    _sw_worktree_is_clean "$repo" "$path" || return 1
  fi

  return 0
}

# _sw_is_story_worktree <repo> <path> — 0 only when <path> is a story worktree
# this library would have created: a direct child of the worktree parent, and
# not the repository's own main work tree.
#
# Defence in depth. A forged or corrupted lock reason must never be able to aim
# a removal at the primary checkout. Git refuses to remove a main work tree, but
# that refusal is the last line, not the only one -- and it says nothing about
# some unrelated directory that merely happens to be registered.
_sw_is_story_worktree() {
  local repo="${1:-}" path="${2:-}" parent main
  [ -n "$repo" ] && [ -n "$path" ] || return 1

  parent="$(worktree_parent_dir "$repo" 2>/dev/null)" || return 1

  # Must sit directly under the story-worktree parent: <parent>/<story key>.
  case "$path" in
    "$parent"/*) ;;
    *) return 1 ;;
  esac
  case "${path#"$parent"/}" in
    */*) return 1 ;;
    '') return 1 ;;
  esac

  # And must not be the repository's own main work tree.
  main="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '')"
  if [ -n "$main" ] && [ -e "$path" ]; then
    local a b
    a="$(cd "$path" 2>/dev/null && pwd)" || return 1
    b="$(cd "$main" 2>/dev/null && pwd)" || return 1
    [ "$a" != "$b" ] || return 1
  fi
  return 0
}

# _sw_worktree_is_clean <repo> <path> — 0 only when the worktree holds NOTHING
# that removing it would destroy. A checkout we cannot inspect counts as dirty
# (fail closed).
#
# `--ignored` is load-bearing. Plain `status --porcelain` omits gitignored files,
# but `git worktree remove` deletes them along with everything else, so without
# it a checkout holding only ignored files reads as clean and is removed — and
# ignored is precisely where local state lives (this project ignores `.gaia/`,
# which holds the runtime tree, memory and checkpoints). Any output at all,
# `!!` ignored entries included, means there is something here to lose.
_sw_worktree_is_clean() {
  local out
  out="$(git -C "${2:-}" status --porcelain --ignored 2>/dev/null)" || return 1
  [ -z "$out" ]
}

# _sw_prune_flush <repo> <path> <locked_reason> <branch> — decide one record.
# Unlocks a reapable orphan so the following prune can clear it; announces a
# crashed run's worktree that still holds uncommitted work instead of silently
# passing over it, and leaves that one locked.
_sw_prune_flush() {
  local repo="${1:-}" path="${2:-}" reason="${3:-}" branch="${4:-}" pid

  [ -n "$path" ] || return 0
  [ -n "$reason" ] || return 0

  if _sw_reapable "$repo" "$path" "$reason" "$branch"; then
    git -C "$repo" worktree unlock "$path" >/dev/null 2>&1 || true
    # A vanished directory is cleared by the prune that follows; one still on
    # disk is not (prune only clears records whose directory is gone), so remove
    # it here. Never --force: _sw_reapable already established the checkout is
    # clean, so a refusal here means something changed under us and the worktree
    # should survive.
    if [ -e "$path" ]; then
      git -C "$repo" worktree remove "$path" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # Name the one case an operator has to act on: our lock, owner gone, but the
  # checkout holds work that was never committed. Everything else -- a live
  # owner, a foreign lock, unpushed commits -- is a routine veto and stays quiet.
  pid="$(_sw_pid_from_reason "$reason")"
  if [ -n "$pid" ] && [ "$pid" != "$$" ] && ! _sw_pid_alive "$pid" \
     && [ -e "$path" ] && ! _sw_worktree_is_clean "$repo" "$path"; then
    _sw_log "kept a stopped story's worktree: it holds modified, untracked or ignored local files: $path"
    _sw_log "review it, then remove it with: git -C \"$repo\" worktree unlock \"$path\" && git -C \"$repo\" worktree remove --force \"$path\""
  fi
  return 0
}

# worktree_prune_stale <code_tree> — remove records left behind by runs that
# ended without their trap firing (a kill, an out-of-memory stop, a power loss).
#
# Two passes. Pass A is git's own prune, which reaps records whose directory is
# gone and which carry no lock. Pass B handles the shape Pass A cannot see: this
# library locks each worktree it creates, and a locked record is never reported
# as prunable, so a killed run leaves a record that plain pruning keeps forever.
# Pass B unlocks only those records it can prove are safe, then prunes again.
worktree_prune_stale() {
  local repo="${1:-}" listing line current="" locked="" branch=""
  [ -n "$repo" ] || { _sw_log "usage: worktree_prune_stale <code_tree>"; return 1; }

  git -C "$repo" worktree prune >/dev/null 2>&1 || true

  listing="$(git -C "$repo" worktree list --porcelain 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        _sw_prune_flush "$repo" "$current" "$locked" "$branch"
        current="${line#worktree }"
        locked=""
        branch=""
        ;;
      "branch "*)
        branch="${line#branch }"
        ;;
      "locked"*)
        locked="${line#locked}"
        locked="${locked# }"
        # A lock with no reason still marks the record as ours to skip.
        [ -n "$locked" ] || locked="(no reason)"
        ;;
    esac
  done <<EOF
$listing
EOF
  # The final record has no following "worktree " line to flush it.
  _sw_prune_flush "$repo" "$current" "$locked" "$branch"

  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  return 0
}

# worktree_create <code_tree> <story_key> <slug> — create (or re-enter) the
# story's worktree. Echoes its absolute path on stdout; every diagnostic goes to
# stderr, so `PROJECT_PATH="$(worktree_create ...)"` is safe.
worktree_create() {
  local repo="${1:-}" story_key="${2:-}" raw_slug="${3:-}"
  local slug branch top parent path state holder

  [ -n "$repo" ] && [ -n "$story_key" ] || {
    _sw_log "usage: worktree_create <code_tree> <story_key> <slug>"
    return 1
  }

  # Fail closed on the opt-in, with no override. Worktree mode is off unless it
  # is switched on, and that is enforced here rather than left to the caller: a
  # workflow step that forgot the check would otherwise silently relocate the
  # story's working directory. There is deliberately no "I already checked"
  # argument -- the library cannot tell an honest acknowledgement from a
  # forgotten skip, so it re-reads the one environment variable instead.
  if ! worktree_mode_enabled; then
    _sw_log "worktree mode is off — set GAIA_WORKTREE_MODE=1 to enable it; no worktree created"
    return 1
  fi

  slug="$(worktree_slug_cap "$raw_slug")"
  branch="feat/${story_key}-${slug}"

  # Clear anything a previous crashed run left behind before adding to the set.
  worktree_prune_stale "$repo"

  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    # Not a git work tree: nothing to isolate. Report this distinctly (3) so the
    # caller degrades to running in place rather than treating it as an error.
    _sw_log "skipped (non-git CWD) — no git work tree at $repo; running in place"
    return 3
  }
  parent="$(worktree_parent_dir "$repo")" || return 1
  worktree_validate_parent "$parent" "$top" || return 1

  mkdir -p "$parent" || { _sw_log "cannot create worktree parent: $parent"; return 1; }
  path="$parent/$story_key"

  # Uncommitted work in the primary tree stays there: a new worktree starts from
  # HEAD. Say so rather than moving anyone's work around.
  if [ -n "$(git -C "$repo" status --porcelain --ignored 2>/dev/null)" ]; then
    _sw_log "the primary tree has uncommitted or ignored local files; they stay there and the story worktree starts from HEAD"
  fi

  state="$(worktree_branch_state "$repo" "$branch")"
  case "$state" in
    absent)
      git -C "$repo" worktree add "$path" -b "$branch" >/dev/null 2>&1 || {
        # git can create the ref and still fail to lay down the directory (for
        # example when the target path is already occupied). Leaving the ref
        # behind would turn a clean retry into an attach of a branch nothing
        # ever committed to, so drop it -- but only when this call is what
        # created it and no worktree ended up holding it.
        if [ "$(worktree_branch_state "$repo" "$branch")" = "free" ]; then
          git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
        fi
        _sw_log "cannot create worktree at $path on new branch $branch"
        return 1
      }
      ;;
    free)
      # The branch outlived an earlier worktree (a retry, a resume, or a start
      # after a crashed run was pruned), or was left by a partially-failed
      # creation. Attach it instead of creating it.
      git -C "$repo" worktree add "$path" "$branch" >/dev/null 2>&1 || {
        _sw_log "cannot attach existing branch $branch at $path"
        return 1
      }
      ;;
    checked-out:*)
      holder="${state#checked-out:}"
      if [ "$holder" = "$path" ]; then
        # Already ours: re-entry is a no-op that returns the same path.
        printf '%s' "$path"
        return 0
      fi
      _sw_log "refusing: branch $branch is already checked out at $holder"
      return 1
      ;;
    *)
      _sw_log "cannot determine the state of branch $branch"
      return 1
      ;;
  esac

  # Record ownership so a later prune can tell a live story from a dead one.
  git -C "$repo" worktree lock "$path" --reason "$(_sw_lock_reason "$story_key" "$$")" >/dev/null 2>&1 || true

  # A fresh worktree is a fresh teardown subject even if this shell tore down the
  # same path earlier in the run. Rebuilt with parameter expansion rather than
  # sed, so no character in a path (a literal `|` included) is special here.
  _sw_forget_torn "$path"

  printf '%s' "$path"
  return 0
}

# worktree_ignored_only <code_tree> <worktree_path> — classify the local state a
# worktree holds. Echoes exactly one token and returns 0:
#
#   no         tracked modifications or untracked files are present. Real work,
#              never discardable.
#   protected  ignored state only, but at least one entry is state a resumed run
#              depends on (memory, checkpoints), an unexpanded directory that
#              could contain such state, or a symlink.
#   yes        ignored state only, and every entry is safe to discard.
#
# The listing flags are load-bearing and each closes a fail-open:
#   --ignored  report ignored files at all; without it a checkout holding only
#              ignored state reads clean and git deletes it anyway.
#   -uall      expand ignored DIRECTORIES to their files. Without it git reports
#              `!! .gaia/` and a protected path inside is never seen.
#   -z         emit raw NUL-delimited bytes. Without it git C-quotes any path
#              holding a space or a non-ASCII byte (`!! ".gaia/memory/side car.md"`),
#              and the quoted form matches no protected pattern while still
#              parsing as an ordinary relative path -- so it looks normal and
#              reaches the discard arm.
#
# Every unknown is resolved toward preserving.
worktree_ignored_only() {
  local repo="${1:-}" path="${2:-}" entry rest state="yes"

  [ -n "$repo" ] && [ -n "$path" ] || {
    _sw_log "usage: worktree_ignored_only <code_tree> <worktree_path>"
    return 1
  }

  # Tracked or untracked changes are real work and settle the question.
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    printf 'no'
    return 0
  fi

  # The listing is read straight from the process, never through $(...):
  # command substitution STRIPS NUL bytes, which would collapse the whole
  # NUL-delimited listing into a single entry and defeat the -z that the
  # C-quoting fix depends on. A temp file keeps the bytes intact and keeps the
  # loop in THIS shell, so the verdict it computes survives.
  local listing_file
  listing_file="$(mktemp "${TMPDIR:-/tmp}/sw-ignored.XXXXXX")" || {
    printf 'protected'
    return 0
  }
  if ! git -C "$path" status --porcelain --ignored -uall -z >"$listing_file" 2>/dev/null; then
    rm -f "$listing_file" 2>/dev/null || true
    printf 'protected'
    return 0
  fi

  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      '!! '*) rest="${entry#\!\! }" ;;
      *) continue ;;
    esac

    # An entry still naming a directory means the expansion did not happen, so
    # anything could be inside it.
    case "$rest" in
      */) state="protected"; break ;;
    esac

    # Symlinks are reported bare, with no trailing slash, so the rule above does
    # not see them. git unlinks rather than follows, but this does not rely on it.
    if [ -L "$path/$rest" ]; then
      state="protected"
      break
    fi

    case "$rest" in
      .gaia/memory/*|*/.gaia/memory/*) state="protected"; break ;;
      .gaia/*checkpoints/*|*/checkpoints/*) state="protected"; break ;;
    esac
  done < "$listing_file"

  rm -f "$listing_file" 2>/dev/null || true
  printf '%s' "$state"
  return 0
}

# worktree_teardown <code_tree> <worktree_path> — remove the story worktree and
# prune. Idempotent, and silent on a repeat call for the same path.
#
# Returns non-zero WITHOUT removing anything when the worktree holds uncommitted
# work: git refuses that removal and this honours the refusal. An orphaned
# directory is a far smaller problem than deleted work, and the next prune will
# not reap it either, so it survives for inspection.
worktree_teardown() {
  local repo="${1:-}" path="${2:-}" discard_ignored=0

  [ -n "$repo" ] && [ -n "$path" ] || {
    _sw_log "usage: worktree_teardown <code_tree> <worktree_path> [--discard-ignored]"
    return 1
  }

  # Opt-in, default off: every existing caller keeps the preserving behaviour.
  case "${3:-}" in
    --discard-ignored) discard_ignored=1 ;;
    '') : ;;
    *) _sw_log "unknown option: $3"; return 1 ;;
  esac

  # Refuse outright to act on anything that is not one of our story worktrees.
  if ! _sw_is_story_worktree "$repo" "$path"; then
    _sw_log "refusing: not a story worktree of this repository: $path"
    return 1
  fi

  # Second firing of a trap, or a path already gone: nothing to say.
  if _sw_already_torn "$path" || [ ! -e "$path" ]; then
    _sw_mark_torn "$path"
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    return 0
  fi

  # Refuse before asking git. Git's own removal refusal does not consider
  # gitignored files, so a checkout holding only those would be deleted.
  if ! _sw_worktree_is_clean "$repo" "$path"; then
    local kind="preserve"
    if [ "$discard_ignored" -eq 1 ]; then
      # Only the ignored-only, nothing-protected case may be forced, and only
      # because the caller reached this on the post-merge path where the work is
      # provably merged. Tracked and untracked state still refuse below.
      [ "$(worktree_ignored_only "$repo" "$path")" = "yes" ] && kind="discard"
    fi

    if [ "$kind" = "discard" ]; then
      git -C "$repo" worktree unlock "$path" >/dev/null 2>&1 || true
      if git -C "$repo" worktree remove --force "$path" >/dev/null 2>&1; then
        git -C "$repo" worktree prune >/dev/null 2>&1 || true
        _sw_mark_torn "$path"
        return 0
      fi
      _sw_mark_torn "$path"
      _sw_log "could not remove the worktree: $path"
      return 1
    fi

    _sw_mark_torn "$path"
    _sw_log "worktree kept: it holds modified, untracked or ignored local files: $path"
    # A kept worktree stays LOCKED, so a bare `remove --force` fails against it.
    _sw_log "review it, then remove it with: git -C \"$repo\" worktree unlock \"$path\" && git -C \"$repo\" worktree remove --force \"$path\""
    return 1
  fi

  git -C "$repo" worktree unlock "$path" >/dev/null 2>&1 || true

  if git -C "$repo" worktree remove "$path" >/dev/null 2>&1; then
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    _sw_mark_torn "$path"
    return 0
  fi

  # The cleanliness pre-check above already reported and returned for the case
  # git refuses on, so reaching here means removal failed for some other reason
  # (a permission problem, a concurrent change). Never --force; say what happened
  # once, without repeating the "kept" wording the pre-check owns.
  _sw_mark_torn "$path"
  _sw_log "could not remove the worktree: $path"
  return 1
}

# worktree_teardown_trap <code_tree> <worktree_path> — trap-facing wrapper.
# Never lets its own failure change the exit status the run was already reporting.
#
# Always pass the worktree path CAPTURED at creation, not a live variable that
# later steps re-point: after a successful teardown the working-directory
# variable moves back to the primary checkout, and a trap that read it then would
# aim removal at the main work tree instead of the story's.
worktree_teardown_trap() {
  worktree_teardown "${1:-}" "${2:-}" || true
  return 0
}
