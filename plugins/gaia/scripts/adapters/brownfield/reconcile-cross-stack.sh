#!/usr/bin/env bash
# adapters/brownfield/reconcile-cross-stack.sh — Phase 4b cross-stack
# WARNING emission + scope respect.
#
# A Phase 4b sub-step (sibling to reconcile.sh — composition, not a hard
# dep). It (a) partitions reconciliation scope by stacks[].path + stacks[].paths[], and (b) inspects
# the dependency-graph for edges that cross a stack boundary. An edge from stack A
# to stack B where B is NOT in A's cross_refs[] allowlist surfaces the canonical
# WARNING:
#   unsanctioned-cross-stack-reference: <src_stack>:<file> -> <tgt_stack>:<file>
#
# `--bypass cross-stack-refs --reason "<text>"` (the parser is reused from
# scripts/lib/parse-bypass-flag.sh) suppresses the WARNINGs for the run
# and appends an audit row to the bypass-log. The reason must match the
# allowlist ^[A-Za-z0-9 ._-]+$ (alphanumerics + space + . _ -) — shell metacharacters
# are REJECTED (the shared helper only length-validates; this script enforces the
# regex restriction).
#
# NEVER aborts the Phase 4b scan. Pure bash + jq + yq; offline; deterministic.
#
# Performance: a {file->stack} reverse-index (one path-prefix pass over the
# stack table) makes each edge an O(1) stack lookup — no per-edge graph walk.
#
# Env seams (tests/phase-4b-cross-stack.bats):
#   XSTACK_CONFIG     project-config.yaml (stacks[].path + stacks[].paths[] + cross_refs[])
#   XSTACK_DEPGRAPH   dep-graph JSON {edges:[{source,target}]} (producer is reconcile.sh; degrade if absent)
#   XSTACK_REPORT     telemetry report frontmatter (optional)
#   XSTACK_BYPASS_LOG bypass-log JSONL (default .gaia/memory/brownfield-audit/bypass-log.json)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/reconcile-cross-stack.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }
die()      { printf 'ERROR: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# Source the shared file-to-stack resolution library.
# shellcheck source=../../lib/resolve-file-to-stack.sh
. "$HERE/../../lib/resolve-file-to-stack.sh"

# --- Bypass parse (reuse parse-bypass-flag.sh helper: required-reason + length 10-500) ----
BYPASS_SKILL="" BYPASS_REASON=""
PARSE="$(cd "$HERE/../../lib" 2>/dev/null && pwd)/parse-bypass-flag.sh"
if [ -x "$PARSE" ]; then
  # The helper exits non-zero on missing/short/long reason. Capture exports +
  # status SEPARATELY: a command-substitution under `set -e` would otherwise
  # swallow the helper's failure (the substitution succeeds with empty stdout
  # and `eval ""` is a no-op). Propagate the rejection explicitly (AC4 scenario 4).
  _parse_out=""
  if ! _parse_out="$(bash "$PARSE" "$@")"; then
    die "bypass rejected by parse-bypass-flag.sh (see message above)"
  fi
  eval "$_parse_out"
fi

# --- Reason allowlist (regex half — shell metachars REJECTED) ----------
# Security: reason must be a benign label. The shared helper covers
# length only; enforce the positive char-class here. Allows
# space-bearing reasons ("needed for migration step"); rejects "; rm -rf /".
if [ -n "$BYPASS_SKILL" ] && [ "$BYPASS_SKILL" = "cross-stack-refs" ]; then
  if ! printf '%s' "$BYPASS_REASON" | grep -Eq '^[A-Za-z0-9 ._-]+$'; then
    die "--reason contains disallowed characters (allowlist: A-Za-z0-9, space, . _ -); bypass REJECTED"
  fi
fi

# --- Flag gate -----------------------------------------------------------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_PHASE_4B_CROSS_STACK_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "cross-stack analysis skipped (flag-off: deterministic_tools=$MASTER phase_4b_cross_stack_enabled=$PER_TOOL)"
  exit 0
fi

CONFIG="${XSTACK_CONFIG:-}"
[ -n "$CONFIG" ] && [ -f "$CONFIG" ] || { log_info "no project-config (XSTACK_CONFIG) — cross-stack analysis skipped"; exit 0; }
command -v yq >/dev/null 2>&1 || { log_warn "yq not found — cross-stack analysis skipped"; exit 0; }
command -v jq >/dev/null 2>&1 || { log_warn "jq not found — cross-stack analysis skipped"; exit 0; }

default_depgraph() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit/depgraph.json' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit/depgraph.json"; fi
}
DEPGRAPH="${XSTACK_DEPGRAPH:-$(default_depgraph)}"

# --- Missing dep-graph guard (degrade, never abort) --------------------------
if [ ! -f "$DEPGRAPH" ]; then
  log_info "dep-graph not found at $DEPGRAPH — cross-stack analysis skipped"
  exit 0
fi

start=$(date +%s%N)

# Global for the lazy-built TSV stacks table used by file_to_stack.
_FTS_TABLE=""
trap 'rm -f "${_FTS_TABLE:-}"' EXIT

# --- Build the {file->stack} reverse-index + per-stack cross_refs ------------
# Stacks are read once. file_to_stack resolves a file path to its owning stack by
# LONGEST path-prefix match (so nested stack paths bind to the most-specific stack).
# Single-stack path:null => path_root "." => one stack owns every file (zero cross
# edges; zero-regression baseline).
stack_count="$(yq eval '.stacks | length' "$CONFIG" 2>/dev/null || printf '0')"
[ "$stack_count" -gt 0 ] 2>/dev/null || { log_info "no stacks[] declared — no cross-stack edges to check"; exit 0; }

# bash 3.2-compat: The prior `declare -A
# CROSS_REFS=()` associative array (name -> allowlist) is replaced by a
# parallel indexed array `STACK_CROSS_REFS[]` aligned with `STACK_NAMES[]`.
# The lookup `${CROSS_REFS[$src]}` becomes a linear scan via the new helper
# `_cross_refs_for()`. The stack count in practice is small (single-digit),
# so O(N) is fine.
#
# STACK_PATHS_GLOBS[] holds the stacks[].paths[] glob-list entries
# (newline-separated per stack). This EXTENDS the scalar path field —
# a file matches a stack if it matches either the path prefix OR any paths[] glob.
STACK_NAMES=()
STACK_PREFIXES=()
STACK_CROSS_REFS=()
STACK_PATHS_GLOBS=()
i=0
while [ "$i" -lt "$stack_count" ]; do
  name="$(yq eval ".stacks[$i].name" "$CONFIG")"
  # Read the scalar path field WITHOUT a "." fallback first.
  path_root="$(yq eval ".stacks[$i].path" "$CONFIG")"
  [ "$path_root" = "null" ] && path_root=""
  refs="$(yq eval ".stacks[$i].cross_refs[]?" "$CONFIG" 2>/dev/null | tr '\n' ' ')"
  # Read the paths[] glob-list (empty-not-error when absent via ?).
  paths_globs="$(yq eval ".stacks[$i].paths[]?" "$CONFIG" 2>/dev/null || true)"
  # Apply the "." catch-all fallback ONLY when NEITHER path NOR paths[] is declared.
  # When paths[] is present without a scalar path, the stack is glob-only — the
  # "." fallback would make it own every file, defeating glob specificity.
  if [ -z "$path_root" ] && [ -z "$paths_globs" ]; then
    path_root="."
  fi
  STACK_NAMES+=("$name")
  STACK_PREFIXES+=("$path_root")
  STACK_CROSS_REFS+=("$refs")
  STACK_PATHS_GLOBS+=("$paths_globs")
  i=$((i+1))
done

# bash 3.2-compat replacement for `${CROSS_REFS[$name]:-}` (parallel-array lookup).
_cross_refs_for() {
  local _want="$1" _k=0
  while [ "$_k" -lt "${#STACK_NAMES[@]}" ]; do
    if [ "${STACK_NAMES[$_k]}" = "$_want" ]; then
      printf '%s' "${STACK_CROSS_REFS[$_k]}"
      return 0
    fi
    _k=$((_k+1))
  done
  return 0
}

# file_to_stack <path> -> stack name. Delegates to the shared resolution
# library (lib/resolve-file-to-stack.sh) via a TSV stacks table built from
# the parallel arrays above. The TSV is built once and cached in _FTS_TABLE.
file_to_stack() {
  local f="$1"
  # Lazy-build the TSV stacks table on first call.
  if [ -z "${_FTS_TABLE:-}" ]; then
    _FTS_TABLE="$(mktemp)"
    _build_fts_table > "$_FTS_TABLE"
  fi
  resolve_file_to_stack "$f" "$_FTS_TABLE"
}

# _build_fts_table — convert parallel arrays to TSV format for the shared resolver.
# Emits name<TAB>candidate<TAB>match_type rows to stdout.
_build_fts_table() {
  local j=0
  while [ "$j" -lt "${#STACK_NAMES[@]}" ]; do
    local nm="${STACK_NAMES[$j]}" pfx="${STACK_PREFIXES[$j]}" globs="${STACK_PATHS_GLOBS[$j]}"
    # Emit scalar path prefix (including "." catch-all)
    if [ -n "$pfx" ]; then
      printf '%s\t%s\tprefix\n' "$nm" "$pfx"
    fi
    # Emit paths[] globs: classify /** as prefix, others as glob
    if [ -n "$globs" ]; then
      local g
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        # Strip surrounding quotes (YAML artifacts)
        g="${g#\"}" ; g="${g%\"}"
        g="${g#\'}" ; g="${g%\'}"
        [ -n "$g" ] || continue
        if [ "${g%/\*\*}" != "$g" ]; then
          # /** glob -> prefix type (strip the /** suffix)
          printf '%s\t%s\tprefix\n' "$nm" "${g%/\*\*}"
        else
          printf '%s\t%s\tglob\n' "$nm" "$g"
        fi
      done <<< "$globs"
    fi
    j=$((j+1))
  done
}

# ref_allowed <src_stack> <tgt_stack> -> 0 if tgt in src.cross_refs[] else 1.
# Routed through _cross_refs_for() (bash 3.2 parallel-array replacement for the
# prior CROSS_REFS assoc-array lookup).
ref_allowed() {
  local src="$1" tgt="$2" r refs
  refs="$(_cross_refs_for "$src")"
  for r in $refs; do
    [ "$r" = "$tgt" ] && return 0
  done
  return 1
}

# --- Inspect edges ---------------------------------------------------------
warnings_json="[]"
suppressed=0
emitted=0
bypass_applied="false"
[ "$BYPASS_SKILL" = "cross-stack-refs" ] && bypass_applied="true"

# Stream edges as TSV "source\ttarget".
while IFS=$'\t' read -r src tgt; do
  [ -n "$src" ] || continue
  src_stack="$(file_to_stack "$src")"
  tgt_stack="$(file_to_stack "$tgt")"
  # Log unowned files (matched by neither path scalar nor paths[] globs).
  if [ -z "$src_stack" ]; then
    log_info "unowned file (no stack match): $src" >&2
  fi
  if [ -z "$tgt_stack" ]; then
    log_info "unowned file (no stack match): $tgt" >&2
  fi
  # Same stack (or unresolved) => not a cross-stack edge.
  [ -n "$src_stack" ] && [ -n "$tgt_stack" ] || continue
  [ "$src_stack" = "$tgt_stack" ] && continue
  # Cross-stack edge — sanctioned?
  if ref_allowed "$src_stack" "$tgt_stack"; then
    continue
  fi
  # Unsanctioned. Suppress under bypass; else emit the canonical WARNING.
  if [ "$bypass_applied" = "true" ]; then
    suppressed=$((suppressed+1))
  else
    log_warn "unsanctioned-cross-stack-reference: ${src_stack}:${src} -> ${tgt_stack}:${tgt}"
    warnings_json="$(printf '%s' "$warnings_json" | jq -c \
      --arg ss "$src_stack" --arg sf "$src" --arg ts "$tgt_stack" --arg tf "$tgt" \
      '. + [{source_stack:$ss, source_file:$sf, target_stack:$ts, target_file:$tf}]')"
    emitted=$((emitted+1))
  fi
done < <(jq -r '.edges[]? | [.source, .target] | @tsv' "$DEPGRAPH" 2>/dev/null || true)

# --- Bypass audit log (append-only JSONL) ----------------------------------
if [ "$bypass_applied" = "true" ]; then
  BLOG="${XSTACK_BYPASS_LOG:-${GAIA_MEMORY_DIR:-.gaia/memory}/brownfield-audit/bypass-log.json}"
  mkdir -p "$(dirname "$BLOG")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sid="${GAIA_SESSION_ID:-$PPID}"
  jq -cn --arg ts "$ts" --arg reason "$BYPASS_REASON" --argjson n "$suppressed" --arg sid "$sid" \
    '{timestamp:$ts, bypass:"cross-stack-refs", reason:$reason, suppressed_count:$n, session_id:$sid}' >> "$BLOG"
  log_info "Bypass applied: cross-stack-refs (reason: $BYPASS_REASON); suppressed $suppressed warning(s)"
fi

end=$(date +%s%N)
seconds=$(( (end - start) / 1000000000 ))
log_info "cross-stack analysis: $emitted warning(s) emitted, $suppressed suppressed; runtime=${seconds}s"

# --- Telemetry (single-author: cross_stack_* owned here) -------------------
REPORT="${XSTACK_REPORT:-${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md}"
TELEM="$HERE/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field cross_stack_warnings --value "$warnings_json" || true
  bash "$TELEM" --report "$REPORT" --field cross_stack_bypass_applied --value "$bypass_applied" || true
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.phase_4b_cross_stack --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.phase_4b_cross_stack --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit 0
