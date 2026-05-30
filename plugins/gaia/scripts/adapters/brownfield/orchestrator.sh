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

# AF-2026-05-30-2 / Test10 F-09: guard on bash 4+ for globstar. macOS ships
# bash 3.2 by default — `shopt -s globstar` is a no-op there and the `**`
# expansion silently produces nothing, so every per-stack file-list comes
# back empty and the orchestrator's intersection is degenerate. Without
# this guard the bug was invisible: no error, no warning, just zero hits.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf 'ERROR: %s: bash 4.0+ required for globstar (`**` glob expansion).\n' "adapters/brownfield/orchestrator.sh" >&2
  printf '       Detected: bash %s (likely macOS default).\n' "${BASH_VERSION:-unknown}" >&2
  printf '       Install a newer bash via:  brew install bash\n' >&2
  printf '       Then ensure /opt/homebrew/bin (or /usr/local/bin) precedes /bin in PATH.\n' >&2
  printf '       Skipping per-stack file-list intersection. Brownfield deterministic-tools layer\n' >&2
  printf '       will fall back to LLM-only scanning (Tier 0; see /gaia-doctor for the readiness report).\n' >&2
  exit 0
fi

shopt -s globstar nullglob dotglob
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

declare -a count_pairs=()

i=0
while [ "$i" -lt "$stack_count" ]; do
  name="$(yq eval ".stacks[$i].name" "$CONFIG")"
  path_root="$(yq eval ".stacks[$i].path // \".\"" "$CONFIG")"
  [ "$path_root" = "null" ] && path_root="."
  mapfile -t paths < <(yq eval ".stacks[$i].paths[]" "$CONFIG" 2>/dev/null || true)
  mapfile -t excludes < <(yq eval ".stacks[$i].excludes[]" "$CONFIG" 2>/dev/null || true)

  # The directory the globs are resolved against: ROOT/path_root (path_root '.' = ROOT).
  base="$ROOT"
  [ "$path_root" != "." ] && base="$ROOT/$path_root"

  out_file="$OUT_DIR/${name}.files"
  : > "$out_file"   # truncate (empty stack => 0-byte file)

  # Enumerate candidate files under base, compute their repo-root-relative path,
  # and the path RELATIVE TO path_root (which the stack globs are written against).
  declare -A seen=()
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
      excluded=0
      for g in "${excludes[@]}"; do
        if matches_glob "$rel_stack" "$g" || matches_glob "$rel_root" "$g"; then excluded=1; break; fi
      done
      [ "$excluded" -eq 0 ] || continue
      # De-dup (a nested manifest must not cause a file to be listed twice).
      if [ -z "${seen[$rel_root]:-}" ]; then
        seen["$rel_root"]=1
        printf '%s\n' "$rel_root"
      fi
    done < <(find "$base" -type f 2>/dev/null) | sort > "$out_file"
  fi

  cnt="$(wc -l < "$out_file" | tr -d ' ')"
  count_pairs+=("$name=$cnt")
  unset seen
  i=$((i+1))
done

# --- Emit per-stack counts (AC-X3 — consumed for per_stack_file_counts) ----
log_info "per_stack_file_counts: ${count_pairs[*]}"

exit 0
