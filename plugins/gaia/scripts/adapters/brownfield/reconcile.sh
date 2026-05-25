#!/usr/bin/env bash
# adapters/brownfield/reconcile.sh — E104-S2 Phase 4b reconciliation pass.
#
# A PURE JSON-join (no tool re-invocation): reads the E104-S1 deduped finding
# stream + per-stack call-graph outputs, builds an entry-point reachable-set, and
# DEMOTES Phase 3 file-only findings to severity INFO when the file is reachable
# from >=1 application entry point — the barrel-file / dynamic-import false-positive
# guard (FR-540 / ADR-124). The architectural lynchpin keeping FP rates tolerable
# for the deterministic-tools rollout.
#
# DEMOTE, NOT REMOVE (audit-trail integrity): a demoted finding keeps every identity
# field and gains annotations:
#   severity: "info"  (was warning|error)
#   reconciled: true
#   original_severity: "<prior>"
#   entry_points: [...]
#   reconciliation_reason: "file referenced from <N> call-graph entries"
# Identity fields (file_path, qualifier, source_tool, ruleId, start_line) are
# preserved VERBATIM (AC4/AC7). Files NOT reachable retain their original severity.
#
# Single-level reachability suffices: the call-graph outputs already encode
# transitivity, so one membership test per finding against the precomputed
# reachable-set is enough — no recursive walk, no tool re-invocation. <5s on a
# 1M-line monorepo (AC5).
#
# Producer-path contract (Val W1): the per-stack call-graph outputs
# `callgraph-{js,go,python}.json` are the canonical reconciliation input (AC2).
# E104-S5's cross-stack analysis is a SIBLING consumer of dependency-graph data
# (`depgraph.json`); both degrade independently when their input is absent. The
# call-graph producer is Phase 4's responsibility (see story Finding).
#
# Empty/missing call-graph -> WARN + passthrough unchanged
# (findings_demoted_by_reconciliation:0). NEVER aborts. Pure bash + jq; offline.
#
# Env seams (tests/phase-4b-reconciliation.bats):
#   RECON_FINDINGS      deduped-findings.json (E104-S1 output)
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

# --- Flag gate (ADR-078 / AC-X1) ------------------------------------------
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

reachable_json="{}"   # { "<file>": ["<entry>", ...], ... }
if [ "${#cg_files[@]}" -gt 0 ]; then
  # Merge every call-graph's reachable[] into one {file: referenced_by[]} object.
  reachable_json="$(jq -s '
    [ .[] | .reachable[]? | {key: .file, value: (.referenced_by // [])} ]
    | from_entries
  ' "${cg_files[@]}" 2>/dev/null || printf '{}')"
fi
reachable_count="$(printf '%s' "$reachable_json" | jq 'length')"

if [ "$reachable_count" -eq 0 ]; then
  log_warn "no call-graph reachability data under $CG_DIR — reconciliation passes findings through unchanged (no demotion)"
fi

# --- Reconcile: demote findings whose file is in the reachable-set ---------
# Pure jq join: for each finding, if reachable_json[.file_path] exists, demote +
# annotate; else pass through unchanged. Identity fields are never mutated (the
# object is extended, severity overridden, annotations added).
reconciled="$(jq -c --argjson reach "$reachable_json" '
  map(
    . as $f
    | ($reach[$f.file_path]) as $eps
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
# gap_count_* are dedup-owned (E104-S1, single-author) — NOT re-authored here.
REPORT="${RECON_REPORT:-${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md}"
TELEM="$HERE/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field findings_demoted_by_reconciliation --value "$demoted" || true
  bash "$TELEM" --report "$REPORT" --field phase_runtime_seconds.phase_4b --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field deterministic_tool_seconds.phase_4b --value "$seconds" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit 0
