#!/usr/bin/env bash
# write-val-sentinel.sh — atomic Val-gate dispatch sentinel writer
#
# Mechanical mirror of /gaia-add-feature/scripts/write-val-sentinel.sh —
# same atomic write contract, jq -n construction (no heredoc-JSON),
# same sibling-tempfile + mv POSIX-atomic write.
#
# Writes the structured Val return as a JSON sentinel under
# $CHECKPOINT_PATH/sprint-review-{sprint_id}-val-dispatched.json. The
# sentinel is the script-verifiable post-fact proof that Step 3 (Track A
# Val Dispatch) of the /gaia-sprint-review skill actually dispatched a Val
# subagent and received a structured verdict. finalize.sh validates the
# sentinel before allowing the skill to complete (per the dispatch-
# checkpoint contract).
#
# Invocation:
#   write-val-sentinel.sh --sprint-id <sprint_id> < <(payload-json)
#
#   The payload on stdin is the structured Val return. The
#   minimum required keys are: status, summary, findings, agent. status
#   MUST be one of {PASS, WARNING, CRITICAL, UNVERIFIED}. agent MUST be
#   "val".
#
# Config:
#   CHECKPOINT_PATH — directory the sentinel is written under. Defaults to
#     `_memory/checkpoints/` resolved relative to the project root.
#
# Exit codes:
#   0 — sentinel written, sentinel path emitted on stdout.
#   1 — usage error, missing payload, malformed JSON, jq absent, or write
#       failure.
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-review/write-val-sentinel.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  write-val-sentinel.sh --sprint-id <sprint_id> < <(payload-json)

The Val return payload is read from stdin (structured Val return).
Required keys: status, summary, findings, agent.
Stdout (on success): the sentinel path.
USAGE
}

# ---------- Arg parse ----------

sprint_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sprint-id)        [ $# -ge 2 ] || die "--sprint-id requires an argument"
                        sprint_id="$2"; shift 2 ;;
    --sprint-id=*)      sprint_id="${1#--sprint-id=}"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  die "unknown flag: $1" ;;
  esac
done

[ -n "$sprint_id" ] || { usage; die "--sprint-id is required"; }

# Validate sprint_id format (path-traversal mitigation — mirror the
# pattern from /gaia-dev-story Step 7b which validates ^E[0-9]+-S[0-9]+$).
# Sprint IDs in GAIA are `sprint-{slug}` where {slug} contains alphanumerics,
# hyphens, and underscores — production IDs are typically numeric
# (`sprint-46`, `sprint-47`) but test fixtures using descriptive IDs
# (`sprint-test-1`, `sprint-fixture-a`) are also accepted.
# Path-traversal chars like `/`, `..`, spaces, and shell
# metacharacters are STILL rejected to preserve the path-traversal mitigation.
case "$sprint_id" in
  sprint-)                 die "invalid sprint_id format: '$sprint_id' (expected 'sprint-<slug>')" ;;
  sprint-*[!a-zA-Z0-9_-]*) die "invalid sprint_id format: '$sprint_id' (expected 'sprint-<slug>'; allowed chars: alphanumerics, '_', '-')" ;;
  sprint-*)                ;;
  *)                       die "invalid sprint_id format: '$sprint_id' (expected 'sprint-<slug>')" ;;
esac

# ---------- Tooling check ----------

command -v jq >/dev/null 2>&1 || die "jq is required but not installed (sentinel construction uses jq -n; heredoc-JSON is forbidden)"

# ---------- Resolve checkpoint path ----------
#
# CHECKPOINT_PATH env-var override is honored first. Absent, walk up from
# CWD looking for `_memory/checkpoints/` or `_memory/` — the project root
# marker. Mirrors the walk-up pattern used in /gaia-add-feature's
# write-val-sentinel.sh (which calls resolve-config.sh in a different
# constraint context). For this skill the walk-up is preferred so test
# fixtures in /tmp/ work without project-config.yaml.

SCRIPT_DIR_LOCAL="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${CHECKPOINT_PATH:-}" ]; then
  # Smart-fallback walk-up — prefer .gaia/memory/checkpoints/
  # (post-migration canonical) over legacy _memory/checkpoints/ (in-
  # deprecation-window consumers + bats fixtures). Walk up from CWD looking
  # for either marker.
  # Walk up for the canonical .gaia/memory only;
  # the legacy _memory probe was removed with the consolidation migration.
  cwd="$(pwd)"
  while [ "$cwd" != "/" ]; do
    if [ -d "$cwd/.gaia/memory/checkpoints" ] || [ -d "$cwd/.gaia/memory" ]; then
      CHECKPOINT_PATH="$cwd/.gaia/memory/checkpoints"
      break
    fi
    cwd="$(dirname "$cwd")"
  done
fi
[ -n "${CHECKPOINT_PATH:-}" ] || die "could not resolve .gaia/memory/checkpoints/ directory (set CHECKPOINT_PATH env var)"
mkdir -p "$CHECKPOINT_PATH"

# ---------- Read + validate payload ----------

payload="$(cat -)"
[ -n "$payload" ] || die "payload (stdin) is empty"

# Validate the payload is valid JSON and has the required keys.
echo "$payload" | jq -e '.status and .summary and (.findings|type=="array") and .agent' >/dev/null 2>&1 \
  || die "payload missing required keys (status, summary, findings, agent) or invalid JSON"

# Validate status enum.
status=$(echo "$payload" | jq -r '.status')
case "$status" in
  PASS|WARNING|CRITICAL|UNVERIFIED|PASSED|FAILED) ;;
  *) die "payload status '$status' is not a canonical value (expected PASS|WARNING|CRITICAL|UNVERIFIED|PASSED|FAILED)" ;;
esac

# Validate agent value.
# The agent field MUST be the literal string "val"
# (the persona identifier carried in the Val envelope), NOT the subagent
# registration name (`gaia:validator`). The orchestrator MUST set `.agent = "val"`
# in the payload regardless of how Val was dispatched. Common surprise on first
# sprint-review run; surface the expected literal in the error.
agent=$(echo "$payload" | jq -r '.agent')
[ "$agent" = "val" ] || die "payload agent '$agent' must be 'val' (the literal persona identifier, NOT the subagent registration name 'gaia:validator')"

# ---------- Construct sentinel + atomic write ----------

SENTINEL="$CHECKPOINT_PATH/sprint-review-${sprint_id}-val-dispatched.json"
SENTINEL_TMP="$SENTINEL.tmp.$$"

# Use jq -n to construct the sentinel (NOT heredoc-JSON).
jq -n \
  --argjson payload "$payload" \
  --arg sprint_id "$sprint_id" \
  --arg written_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    sprint_id: $sprint_id,
    written_at: $written_at,
    val_return: $payload
  }' > "$SENTINEL_TMP"

mv "$SENTINEL_TMP" "$SENTINEL"

log "sentinel written: $SENTINEL"
printf '%s\n' "$SENTINEL"
exit 0
