#!/usr/bin/env bash
# adapters/brownfield/reconcile.sh — Phase 4b reconciliation pass.
#
# A PURE JSON-join (no tool re-invocation): reads the deduped finding
# stream + per-stack call-graph outputs, builds an entry-point reachable-set, and
# DEMOTES Phase 3 file-only findings to severity INFO when the file is reachable
# from >=1 application entry point — the barrel-file / dynamic-import false-positive
# guard. The architectural lynchpin keeping FP rates tolerable for the
# deterministic-tools rollout.
#
# DEMOTE, NOT REMOVE (audit-trail integrity): a demoted finding keeps every identity
# field and gains annotations:
#   severity: "info"  (was warning|error)
#   reconciled: true
#   original_severity: "<prior>"
#   entry_points: [...]
#   reconciliation_reason: "file referenced from <N> call-graph entries"
# Identity fields (file_path, qualifier, source_tool, ruleId, start_line) are
# preserved VERBATIM. Files NOT reachable retain their original severity.
#
# Single-level reachability suffices: the call-graph outputs already encode
# transitivity, so one membership test per finding against the precomputed
# reachable-set is enough — no recursive walk, no tool re-invocation. <5s on a
# 1M-line monorepo.
#
# Producer-path contract: the per-stack call-graph outputs
# `callgraph-{js,go,python}.json` are the canonical reconciliation input.
# Cross-stack analysis is a SIBLING consumer of dependency-graph data
# (`depgraph.json`); both degrade independently when their input is absent. The
# call-graph producer is Phase 4's responsibility.
#
# Empty/missing call-graph -> WARN + passthrough unchanged
# (findings_demoted_by_reconciliation:0). NEVER aborts. Pure bash + jq; offline.
#
# Env seams (tests/phase-4b-reconciliation.bats):
#   RECON_FINDINGS      deduped-findings.json (dedup pass output)
#   RECON_CALLGRAPH_DIR dir holding callgraph-{js,go,python}.json
#   RECON_OUTPUT        reconciled-findings.json
#   RECON_REPORT        telemetry report frontmatter (optional)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/reconcile.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

default_audit() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit"; fi
}
AUDIT="$(default_audit)"
FINDINGS="${RECON_FINDINGS:-$AUDIT/deduped-findings.json}"
CG_DIR="${RECON_CALLGRAPH_DIR:-$AUDIT}"
OUTPUT="${RECON_OUTPUT:-$AUDIT/reconciled-findings.json}"

# --- Flag gate ------------------------------------------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_PHASE_4B_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "Phase 4b reconciliation skipped (flag-off: deterministic_tools=$MASTER phase_4b_enabled=$PER_TOOL); raw stream passes through"
  # Passthrough: copy the raw deduped stream to the output unchanged (no demotion).
  if [ -f "$FINDINGS" ]; then mkdir -p "$(dirname "$OUTPUT")"; cp "$FINDINGS" "$OUTPUT"; fi
  exit 0
fi

command -v jq >/dev/null 2>&1 || { log_warn "jq not found — reconciliation skipped"; exit 0; }
mkdir -p "$(dirname "$OUTPUT")"

# --- Missing findings input guard (degrade, never abort) -------------------
if [ ! -f "$FINDINGS" ]; then
  log_info "deduped findings not found at $FINDINGS — reconciliation skipped (empty stream); never aborts"
  printf '[]\n' > "$OUTPUT"
  exit 0
fi

start=$(date +%s)

# --- Build the entry-point reachable-set from all call-graph inputs --------
# Each callgraph-*.json: {entry_points:[...], reachable:[{file, referenced_by:[...]}]}.
# The reachable-set is the union of `reachable[].file` across all stacks; per-file
# we also keep its `referenced_by` list (the entry points that pull it in) for the
# annotation. Empty/missing call-graphs => empty set => zero demotions (WARN).
cg_files=()
for cg in "$CG_DIR"/callgraph-*.json; do
  [ -f "$cg" ] && cg_files+=("$cg")
done

# Written to a temp file (NOT an --argjson string): a large reachable-set would
# blow ARG_MAX (~1MB) on a real monorepo, so we pass it via --slurpfile to keep
# the reconcile join within budget at 1M-line scale.
reach_tmp="$(mktemp)"
trap 'rm -f "$reach_tmp"' EXIT
printf '{}' > "$reach_tmp"   # { "<file>": ["<entry>", ...], ... }
if [ "${#cg_files[@]}" -gt 0 ]; then
  # Merge every call-graph's reachable[] into one {file: referenced_by[]} object.
  # A file referenced across MULTIPLE call-graphs has its referenced_by lists
  # UNIONed (group_by + unique) — not last-write-wins — so the entry_points
  # annotation is complete (code-review INFO fix).
  jq -s '
    [ .[] | .reachable[]? | {file: .file, refs: (.referenced_by // [])} ]
    | group_by(.file)
    | map({ key: .[0].file, value: ([ .[].refs[] ] | unique) })
    | from_entries
  ' "${cg_files[@]}" > "$reach_tmp" 2>/dev/null || printf '{}' > "$reach_tmp"
fi
reachable_count="$(jq 'length' "$reach_tmp")"

if [ "$reachable_count" -eq 0 ]; then
  log_warn "no call-graph reachability data under $CG_DIR — reconciliation passes findings through unchanged (no demotion)"
fi

# --- Reconcile: demote findings whose file is in the reachable-set ---------
# Pure jq join: for each finding, if reach[.file_path] exists, demote + annotate;
# else pass through unchanged. Identity fields are never mutated (the object is
# extended, severity overridden, annotations added). --slurpfile binds the
# reachable-set as a 1-element array → dereference $reach[0].
reconciled="$(jq -c --slurpfile reach "$reach_tmp" '
  ($reach[0]) as $r
  | map(
    . as $f
    | ($r[$f.file_path]) as $eps
    | if ($eps != null)
      then $f + {
        severity: "info",
        reconciled: true,
        original_severity: $f.severity,
        entry_points: $eps,
        reconciliation_reason: ("file referenced from \($eps | length) call-graph entr" + (if ($eps|length)==1 then "y" else "ies" end))
      }
      else $f
      end
  )
' "$FINDINGS")"
printf '%s\n' "$reconciled" > "$OUTPUT"

demoted="$(printf '%s' "$reconciled" | jq '[.[] | select(.reconciled==true)] | length')"
total="$(printf '%s' "$reconciled" | jq 'length')"
end=$(date +%s)
seconds=$(( end - start ))
log_info "Phase 4b reconciliation: $demoted of $total finding(s) demoted to INFO (reachable from entry points); runtime=${seconds}s"

# --- Telemetry (single-author: findings_demoted_by_reconciliation + *.phase_4b)
# gap_count_* are dedup-owned by the dedup pass (single-author) — NOT re-authored here.
REPORT="${RECON_REPORT:-${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md}"
TELEM="$HERE/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field findings_demoted_by_reconciliation --value "$demoted" || true
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.phase_4b --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.phase_4b --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit 0
