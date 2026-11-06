#!/usr/bin/env bash
# mutation-evidence-check.sh — read mutation evidence and emit a checks[]
# fragment for QA and test-review consumers.
#
# Neither consumer generates or runs mutants. Both read the score from the
# evidence file produced by /gaia-test-automate and report a mutation-score
# check.
#
# Usage:
#   mutation-evidence-check.sh --story-key <key> --evidence <json> \
#     --commit <sha> [--priority <P>] [--thresholds <json>] [--zero-kill]
#   mutation-evidence-check.sh --help
#
# Flags:
#   --story-key <key>    Story key for the audit trail
#   --evidence <json>    Path to the mutation evidence file
#   --commit <sha>       Expected HEAD commit sha (for staleness check)
#   --priority <P>       Story priority (P0..P3)
#   --thresholds <json>  Threshold object (from config resolver)
#   --zero-kill          Also emit findings for covering tests that killed 0 mutants
#   --help               Show usage
#
# Output (stdout): a checks[] fragment (JSON object) named "mutation-score",
# valid against analysis-results.schema.json.
#
# A check with status failed always carries a blocking finding, so the verdict
# resolver blocks on it even when the only other findings are advisory
# weak-assertion ones. A check skipped for a P2 or P3 story, or for a project
# without thresholds, says why in skip_reason. A story whose priority could not
# be resolved is gated like P0/P1: an unknown priority never loosens the check.
#
# Exit codes:
#   0  Check emitted (any status: passed, failed, errored, skipped)
#   1  Caller error
#
# POSIX discipline: bash 3.2, no local -A, no mapfile.

set -euo pipefail
LC_ALL=C; export LC_ALL

SCRIPT_NAME="mutation-evidence-check.sh"

_mec_err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
_mec_die() { local rc="$1"; shift; _mec_err "$*"; exit "$rc"; }

# ---------- Arg parsing ----------
_mec_story_key=""
_mec_evidence=""
_mec_commit=""
_mec_priority=""
_mec_thresholds=""
_mec_zero_kill=0

while [ $# -gt 0 ]; do
  case "$1" in
    --story-key)  shift; _mec_story_key="${1:-}"; shift ;;
    --evidence)   shift; _mec_evidence="${1:-}"; shift ;;
    --commit)     shift; _mec_commit="${1:-}"; shift ;;
    --priority)   shift; _mec_priority="${1:-}"; shift ;;
    --thresholds) shift; _mec_thresholds="${1:-}"; shift ;;
    --zero-kill)  _mec_zero_kill=1; shift ;;
    --help|-h)    printf 'Usage: mutation-evidence-check.sh --story-key <key> --evidence <json> --commit <sha> [opts...]\n'; exit 0 ;;
    *)            _mec_die 1 "unknown argument: $1" ;;
  esac
done

[ -n "$_mec_story_key" ] || _mec_die 1 "--story-key is required"
[ -n "$_mec_commit" ]    || _mec_die 1 "--commit is required"

_mec_skip() {
  jq -n --arg reason "$1" \
    '{"name":"mutation-score","status":"skipped","skip_reason":$reason,"message":$reason,"findings":[]}'
  exit 0
}

# ---------- Check if thresholds are configured ----------
# An empty object is configured: missing priorities take their defaults.
case "$_mec_thresholds" in
  ''|null) _mec_skip "mutation_thresholds is not configured" ;;
esac

# P2/P3 stories: advisory only, skip check
case "$_mec_priority" in
  P2|P3)
    _mec_skip "$_mec_priority stories are advisory for mutation testing"
    ;;
esac

# ---------- Check evidence file ----------
if [ -z "$_mec_evidence" ] || [ ! -f "$_mec_evidence" ]; then
  # Missing evidence
  jq -n \
    --arg name "mutation-score" \
    --arg status "errored" \
    --arg message "No mutation evidence found. Run /gaia-test-automate --mutation ${_mec_story_key} to produce it." \
    '{"name":$name,"status":$status,"message":$message,"findings":[]}'
  exit 0
fi

# ---------- Read evidence ----------
_mec_ev_commit=$(jq -r '.commit_sha // ""' "$_mec_evidence" 2>/dev/null || true)
_mec_ev_score=$(jq -r '.score // ""' "$_mec_evidence" 2>/dev/null || true)
_mec_ev_gate=$(jq -r '.gate // ""' "$_mec_evidence" 2>/dev/null || true)

# Staleness check
if [ "$_mec_ev_commit" != "$_mec_commit" ]; then
  jq -n \
    --arg name "mutation-score" \
    --arg status "errored" \
    --arg message "Mutation evidence is stale (recorded at ${_mec_ev_commit}, HEAD is ${_mec_commit}). Run /gaia-test-automate --mutation ${_mec_story_key} to update it." \
    '{"name":$name,"status":$status,"message":$message,"findings":[]}'
  exit 0
fi

# ---------- Map gate to check status ----------
_mec_status="passed"
case "$_mec_ev_gate" in
  failed)  _mec_status="failed" ;;
  errored) _mec_status="errored" ;;
  passed)  _mec_status="passed" ;;
  advisory) _mec_status="passed" ;;
  *)       _mec_status="errored" ;;
esac

# ---------- Build findings ----------
_mec_findings="[]"

if [ "$_mec_zero_kill" -eq 1 ]; then
  # Identify covering tests that killed zero mutants. killed_by holds test
  # names, so the comparison is against the names reported by the covering test
  # files, not the files themselves. Without a scored mutant there is nothing to
  # measure a test against, so nothing is reported.
  _mec_covering=""
  if [ "$(jq -r '[.mutants[]? | select(.status == "killed" or .status == "survived" or .status == "timeout")] | length' "$_mec_evidence" 2>/dev/null || echo 0)" -gt 0 ]; then
    _mec_covering=$(jq -r '.covering_test_names[]?' "$_mec_evidence" 2>/dev/null || true)
  fi
  _mec_killers=$(jq -r '[.mutants[]? | .killed_by[]?] | unique[]' "$_mec_evidence" 2>/dev/null || true)

  _mec_finding_list="[]"
  if [ -n "$_mec_covering" ]; then
    while IFS= read -r _ctest; do
      [ -n "$_ctest" ] || continue
      # Check if this test appears in any killed_by
      _ctest_is_killer=0
      if [ -n "$_mec_killers" ]; then
        while IFS= read -r _ktest; do
          if [ "$_ctest" = "$_ktest" ]; then
            _ctest_is_killer=1
            break
          fi
        done <<< "$_mec_killers"
      fi
      if [ "$_ctest_is_killer" -eq 0 ]; then
        _mec_finding_list=$(printf '%s' "$_mec_finding_list" | jq --arg t "$_ctest" \
          '. + [{"severity":"warning","message":("weak-assertion: " + $t + " killed zero mutants"),"rule":"weak-assertion","blocking":false}]')
      fi
    done <<< "$_mec_covering"
  fi

  _mec_findings="$_mec_finding_list"
fi

# ---------- A failed score blocks, whatever else was found ----------
if [ "$_mec_status" = "failed" ]; then
  _mec_findings=$(printf '%s' "$_mec_findings" | jq --arg score "${_mec_ev_score:-n/a}" \
    '[{"severity":"critical","message":("mutation score " + $score + "% is below the threshold"),"rule":"mutation-score","blocking":true}] + .')
fi

# ---------- Emit check ----------
jq -n \
  --arg name "mutation-score" \
  --arg status "$_mec_status" \
  --arg message "Mutation score: ${_mec_ev_score:-n/a}% (gate: ${_mec_ev_gate:-unknown})" \
  --argjson findings "$_mec_findings" \
  '{"name":$name,"status":$status,"message":$message,"findings":$findings}'

exit 0
