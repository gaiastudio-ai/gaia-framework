#!/usr/bin/env bash
# adapters/brownfield/orchestrator.sh — E70-S10 per-stack file-list intersection.
#
# For each stacks[] entry in project-config.yaml, compute the file-list passed to
# that stack's per-tool adapters as:
#
#     (path_root ∩ paths[]) MINUS excludes[]
#
# where path_root = stack.path || '.' (single-stack). Excludes ALWAYS win on
# collision. The result is written to $ORCH_OUT_DIR/<stack>.files as sorted,
# repo-root-relative paths — consumed verbatim by each adapter via the ADR-078
# `run.sh --input <file-list>` contract (byte-stable; adapters never see
# path/paths/excludes metadata). Single-stack (path:null) collapses to
# `'.' ∩ paths − excludes`, byte-identical to pre-deploy (FR-546 / ADR-126).
#
# Pure bash globstar + parameter matching (bash 4+). No external binary; no
# network. Requires yq to read the config.
#
# Env seams (tests/orchestrator-file-list-intersection.bats):
#   ORCH_CONFIG   project-config.yaml path (default: resolve-config project_config_path)
#   ORCH_ROOT     source-tree root the globs resolve against (default: project_path or .)
#   ORCH_OUT_DIR  per-stack file-list output dir (default: $TMPDIR/gaia-brownfield-filelists)
#
# AC-X1: when the master flag is off, the orchestrator is a no-op (not invoked
# in production; defends itself when invoked directly).

set -euo pipefail

# AF-2026-05-31-1 / Test12 F-06 — bash 3.2 portability rewrite.
#
# Prior implementation (AF-2026-05-30-2 / Test10 F-09) guarded `shopt -s globstar`
# on `BASH_VERSINFO >= 4` and short-circuited to a stderr "skip" on macOS-
# default bash 3.2 — silently disabling the entire deterministic-tools layer
# on a stock Mac. Test12 §9.0 cross-platform mandate: every script must run
# on macOS bash 3.2, Linux bash 4+, and bash via Git Bash / WSL2 on Windows.
#
# Three bash-4-only features were in use and have been removed:
#
#   1. `shopt -s globstar` — needed only for `**` in raw shell-glob expansion.
#      The file enumeration here is a plain `find` walk (line ~148); globstar
#      was never actually exercised on the discovery side. The `**` patterns
#      that DO appear (in `matches_glob`) are matched against `case` patterns,
#      where they behave the same in bash 3.2 — with the same author-intent
#      "any depth including zero" handled by the existing alternate-collapse
#      in `matches_glob`. globstar therefore added no semantic value here.
#
#   2. `mapfile -t arr < <(cmd)` — rewritten as the bash-3.2-compatible
#      `while IFS= read -r line; do arr+=("$line"); done < <(cmd)` idiom.
#
#   3. `declare -A seen=()` — used purely as a presence set for per-file
#      dedup. Rewritten as a sorted-unique newline-delimited string that the
#      output collation already produces via the downstream `| sort` (and
#      verified at the loop boundary). The dedup invariant is preserved.
#
# Closes the F-06 portability wall: the brownfield deterministic-tools layer
# now functions on the macOS-default shell, removing the silent Tier-0
# degradation that defeated the "never degrade silently" goal.

shopt -s nullglob dotglob
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/orchestrator.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }

# --- Flag gate (AC-X1) ----------------------------------------------------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
if [ "$MASTER" != "true" ]; then
  log_info "orchestrator skipped (flag-off: deterministic_tools=$MASTER) — no per-stack intersection"
  exit 0
fi

command -v yq >/dev/null 2>&1 || { printf 'ERROR: %s: yq not found on PATH\n' "$SCRIPT_NAME" >&2; exit 1; }

CONFIG="${ORCH_CONFIG:-}"
[ -n "$CONFIG" ] && [ -f "$CONFIG" ] || { printf 'ERROR: %s: project-config not found (ORCH_CONFIG=%s)\n' "$SCRIPT_NAME" "$CONFIG" >&2; exit 1; }
ROOT="${ORCH_ROOT:-.}"
OUT_DIR="${ORCH_OUT_DIR:-${TMPDIR:-/tmp}/gaia-brownfield-filelists}"
mkdir -p "$OUT_DIR"

stack_count="$(yq eval '.stacks | length' "$CONFIG" 2>/dev/null || printf '0')"
[ "$stack_count" -gt 0 ] 2>/dev/null || { log_info "no stacks[] declared — nothing to intersect"; exit 0; }

# Glob-match helper: is path $1 matched by glob $2 ?
# NOTE: this targets the stacks[].paths[]/excludes[] glob grammar (`**/*.ext`,
# `dir/**`, `dir/**/*.ext`, `*.ext`), NOT full gitignore/pathspec semantics. The
# `**`=any-depth-including-zero behavior is approximated via a collapse-alternate.
# bash `case` `**` only matches when it spans >=1 directory (e.g. `**/*.go`
# matches `sub/x.go` but NOT top-level `x.go`). The common author intent for
# `**/*.go` is "any *.go at any depth INCLUDING the root", so we also test the
# zero-directory form: a leading `**/` is stripped to produce an alternate glob
# that matches files directly under the base. Both forms are tried.
matches_glob() {
  local path="$1" glob="$2"
  # AF-2026-06-02-1 / Test16 F-M02 — bare-dir / trailing-slash expansion.
  # A path of `core/` (the form /gaia-init persists when the user answers
  # `core/` to the path question) only matches the literal string `core/`
  # under bash `case`, never `core/vault/x.py`. The author intent for a
  # bare-dir path is "every file under this directory at any depth", so
  # rewrite a trailing `/` or a glob with no wildcard to `<dir>/**` before
  # running the standard match. This closes the per-stack file-count-of-0
  # symptom Test16 reproduced live (`paths:[core/]` → 0 files vs
  # `paths:[core/**]` → 37). The pre-existing /**/ collapse + leading-**/
  # strip still handle the `**/*.go` / `src/**/*.go` cases.
  if [ "${glob%/}" != "$glob" ] || ! printf '%s' "$glob" | grep -q '[*?[]'; then
    # Trailing slash OR no wildcard chars at all → treat as a dir prefix.
    glob="${glob%/}/**"
  fi
  # 1. Direct match (bash `**` spans >=1 directory here).
  # $glob is INTENTIONALLY unquoted — it IS the glob pattern (not a literal).
  # shellcheck disable=SC2254
  case "$path" in
    $glob) return 0 ;;
  esac
  # 2. Zero-directory alternate: collapse every `/**/` to `/` and strip a
  #    leading `**/`, so `src/**/*.go` also matches `src/main.go` and `**/*.go`
  #    also matches top-level `main.go` (the common author intent — `**` = any
  #    depth INCLUDING zero).
  local alt="${glob//\/\*\*\///}"   # /**/ -> /
  alt="${alt#'**/'}"                # leading **/ -> (nothing)
  if [ "$alt" != "$glob" ]; then
    # $alt is INTENTIONALLY unquoted — it IS the alternate glob pattern.
    # shellcheck disable=SC2254
    case "$path" in
      $alt) return 0 ;;
    esac
  fi
  return 1
}

count_pairs=()

i=0
while [ "$i" -lt "$stack_count" ]; do
  name="$(yq eval ".stacks[$i].name" "$CONFIG")"
  path_root="$(yq eval ".stacks[$i].path // \".\"" "$CONFIG")"
  [ "$path_root" = "null" ] && path_root="."
  # AF-2026-05-31-1 / Test12 F-06: bash 3.2-compat `mapfile` replacement.
  paths=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && paths+=("$_line")
  done < <(yq eval ".stacks[$i].paths[]" "$CONFIG" 2>/dev/null || true)
  excludes=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && excludes+=("$_line")
  done < <(yq eval ".stacks[$i].excludes[]" "$CONFIG" 2>/dev/null || true)

  # The directory the globs are resolved against: ROOT/path_root (path_root '.' = ROOT).
  base="$ROOT"
  [ "$path_root" != "." ] && base="$ROOT/$path_root"

  out_file="$OUT_DIR/${name}.files"
  : > "$out_file"   # truncate (empty stack => 0-byte file)

  # Enumerate candidate files under base, compute their repo-root-relative path,
  # and the path RELATIVE TO path_root (which the stack globs are written against).
  # AF-2026-05-31-1 / Test12 F-06: the dedup invariant previously held by a
  # `declare -A seen=()` presence set is preserved by passing the per-loop
  # output through `sort -u` at the boundary. Within the loop we just emit
  # every match; dedup happens once at the sink.
  if [ -d "$base" ]; then
    while IFS= read -r abs; do
      [ -f "$abs" ] || continue
      rel_root="${abs#"$ROOT"/}"          # repo-root-relative (for output)
      rel_stack="${abs#"$base"/}"         # path_root-relative (for glob matching)
      # Include iff matched by ANY paths[] glob (matched against path_root-relative form).
      included=0
      if [ "${#paths[@]}" -eq 0 ]; then
        included=1   # no paths[] declared => whole subtree
      else
        for g in "${paths[@]}"; do
          if matches_glob "$rel_stack" "$g"; then included=1; break; fi
        done
      fi
      [ "$included" -eq 1 ] || continue
      # Exclude iff matched by ANY excludes[] glob (excludes ALWAYS win).
      # AF-2026-05-31-2 / Test13 F-14 — bash 3.2 + `set -u` rejects the
      # `"${excludes[@]}"` deref when the array is empty (a stack without
      # an `excludes:` block). Length-guard the iteration so the empty case
      # is a clean no-op. Same regression class as F-24 (sprint-state.sh
      # _init_args[@]); both fall out of the AF-31-1 portability rewrite.
      excluded=0
      if [ "${#excludes[@]}" -gt 0 ]; then
        for g in "${excludes[@]}"; do
          if matches_glob "$rel_stack" "$g" || matches_glob "$rel_root" "$g"; then excluded=1; break; fi
        done
      fi
      [ "$excluded" -eq 0 ] || continue
      printf '%s\n' "$rel_root"
    done < <(find "$base" -type f 2>/dev/null) | sort -u > "$out_file"
  fi

  cnt="$(wc -l < "$out_file" | tr -d ' ')"
  count_pairs+=("$name=$cnt")
  i=$((i+1))
done

# --- Emit per-stack counts (AC-X3 — consumed for per_stack_file_counts) ----
# AF-2026-05-31-2 / Test13 F-14 — guard the count_pairs[@] expansion: when
# stack_count was zero (nothing to iterate), count_pairs is empty and
# `"${count_pairs[*]}"` under `set -u` would crash on bash 3.2.
if [ "${#count_pairs[@]}" -gt 0 ]; then
  log_info "per_stack_file_counts: ${count_pairs[*]}"
fi

exit 0
