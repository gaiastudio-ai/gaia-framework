#!/usr/bin/env bash
# track-b-dispatch.sh — Track B per-stack execution dispatch (E93-S3 STUB)
#
# E93-S3 SCOPE: this script is a STUB per the E88-S2 / FR-DPD-2 deferred-
# wiring contract. The story's frontmatter carries `delivered: false` to
# signal that the real per-stack execution runner lands in E93-S4. This
# stub:
#
#   1. Reads the `sprint_review:` section from project-config.yaml (the
#      E93-S2 deliverable) — verifies the matrix is configured.
#   2. Iterates the per-stack matrix.
#   3. For each stack, emits a JSON envelope with
#      `verdict: SKIPPED, reason: "E93-S4 not yet shipped"`.
#   4. The per-goal AskUserQuestion gate is fired at the MAIN-TURN caller
#      level (the /gaia-sprint-review SKILL.md Step 4 orchestration), NOT
#      here — this script just returns the envelope and the caller drives
#      the user prompt. This preserves the NFR-067 main-turn-only
#      AskUserQuestion contract (a forked script cannot expose
#      AskUserQuestion).
#
# E93-S4 will replace this stub with the real per-stack execution runner:
# foreground Playwright, visible simulator/emulator, headed Electron/Tauri,
# screen-recording fallback, etc. per FR-491 + NFR-069.
#
# Usage:
#   track-b-dispatch.sh --sprint <sprint_id> [--config <path>]
#
# Output (stdout): JSON array, one element per configured stack, with
#   schema: { stack: "<id>", verdict: "SKIPPED",
#             reason: "E93-S4 not yet shipped", stdout: "", stderr: "" }.
#
# Exit codes:
#   0 — stub completed (always — the stub never fails).
#   1 — usage error or missing sprint_review section.
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-review/track-b-dispatch.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  track-b-dispatch.sh --sprint <sprint_id> [--config <project-config.yaml>]

E93-S3 STUB — per-stack execution dispatch is deferred to E93-S4 per the
E88-S2 / FR-DPD-2 deferred-wiring contract. This stub reads the
sprint_review: matrix from project-config.yaml, iterates the configured
stacks, and emits a JSON envelope per stack with verdict: SKIPPED.

Stdout: JSON array of per-stack envelopes.
USAGE
}

# ---------- Arg parse ----------

sprint_id=""
config_path="config/project-config.yaml"
while [ $# -gt 0 ]; do
  case "$1" in
    --sprint)         [ $# -ge 2 ] || die "--sprint requires an argument"
                      sprint_id="$2"; shift 2 ;;
    --sprint=*)       sprint_id="${1#--sprint=}"; shift ;;
    --config)         [ $# -ge 2 ] || die "--config requires an argument"
                      config_path="$2"; shift 2 ;;
    --config=*)       config_path="${1#--config=}"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unknown flag: $1" ;;
  esac
done

[ -n "$sprint_id" ] || { usage; die "--sprint is required"; }

# ---------- Read sprint_review matrix from project-config.yaml ----------

# If config file doesn't exist OR the sprint_review: section is missing,
# the stub emits an empty array — the caller treats this as "no Track B
# stacks configured" which folds into the SKIPPED path during composite
# verdict reduction. This matches FR-494 AC6 (graceful degradation when
# section absent).
if [ ! -f "$config_path" ]; then
  log "config file not found at '$config_path' — emitting empty Track B envelope"
  printf '[]\n'
  exit 0
fi

# Use yq to extract sprint_review.backend_commands keys (the canonical
# per-stack list). Soft-fail to empty array if yq absent or section
# missing.
if ! command -v yq >/dev/null 2>&1; then
  log "yq not available — emitting empty Track B envelope (E93-S3 stub)"
  printf '[]\n'
  exit 0
fi

stacks=$(yq eval '.sprint_review.backend_commands | keys | .[]' "$config_path" 2>/dev/null || true)
if [ -z "$stacks" ]; then
  # Also check mobile_commands / desktop_commands / plugin_commands as
  # fallback indicators of any configured stacks.
  stacks=$(yq eval '.sprint_review | (.mobile_commands // {} | keys) + (.desktop_commands // {} | keys) + (.plugin_commands // {} | keys) | .[]' "$config_path" 2>/dev/null || true)
fi

if [ -z "$stacks" ]; then
  log "no Track B stacks configured in $config_path sprint_review section — emitting empty envelope"
  printf '[]\n'
  exit 0
fi

# ---------- Emit per-stack SKIPPED envelopes ----------

# Construct via jq -n (NOT heredoc — same ADR-074 + AC4 discipline as
# write-val-sentinel.sh).
if ! command -v jq >/dev/null 2>&1; then
  die "jq is required to construct the Track B envelope"
fi

# Build the JSON array.
result='[]'
while IFS= read -r stack; do
  [ -n "$stack" ] || continue
  result=$(printf '%s' "$result" | jq --arg stack "$stack" '. + [{
    stack: $stack,
    verdict: "SKIPPED",
    reason: "E93-S4 not yet shipped",
    stdout: "",
    stderr: ""
  }]')
done <<< "$stacks"

printf '%s\n' "$result"
log "Track B stub: emitted SKIPPED envelopes for stacks ($(printf '%s' "$stacks" | tr '\n' ' '))"
exit 0
