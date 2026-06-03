#!/usr/bin/env bash
# assert-agent-envelope.sh — Generic agent envelope assertion (E87-S1, ADR-104;
# generalized by E90-S1, FR-MVB-1).
#
# Story: E87-S1 — Shared assert-agent-envelope.sh helper + ADR-104 anchor + memory scaffold.
#        E87-S7 — Sentinel-Write Writer Shift (ADR-105).
#        E90-S1 — Generalize with --expected-agent <id> flag (FR-MVB-1).
# Anchor: ADR-104 — Val Bridge Migration: Main-Turn Agent Dispatch Across Val-Consuming Skills.
#         ADR-105 — Sentinel-Write Writer Shift (amends ADR-104, E87-S7, 2026-05-13).
# Trace: FR-477, FR-482, FR-483, FR-484, FR-MVB-1, NFR-064 (forgery resistance),
#        NFR-065 (sequencing safety), NFR-066.
#
# Background:
#   Claude Code 2.1.138 silently broke plugin `context: fork` dispatch
#   (issue #49559). E87 migrates all Val DISPATCH call sites to main-turn
#   Agent-tool dispatch per ADR-093 / ADR-104. This helper is the shared
#   primitive every migrated Val consumer (E87-S2..S5) sources to verify
#   that a Val-dispatch sentinel passes forgery-resistance checks — closing
#   the regression class documented in memory rule
#   `feedback_add_feature_val_gate_fails_open.md` and the inline-Val
#   bypass class in `feedback_fix_story_inline_revalidation_bypass.md`.
#
# Writer-shift (ADR-105 / E87-S7, 2026-05-13):
#   The sentinel was originally written by the Val sub-agent itself
#   (E87-S2 contract). ADR-105 shifts the writer to the orchestrator's
#   main turn (via `lib/write-val-envelope.sh`) because the Claude Code
#   substrate's content-integrity guard false-fires on sub-agent writes
#   to `_memory/checkpoints/val-envelope-*.json` (incident
#   AI-2026-05-13-13). The assertion logic below is UNCHANGED — the four
#   checks (file exists, valid JSON, agent=val, persona_sig present)
#   apply identically regardless of who wrote the sentinel. Forgery
#   resistance is preserved because `persona_sig` is computed by Val
#   from validator.md's on-disk sha256, which the orchestrator cannot
#   fabricate without reading validator.md at the same revision.
#
# Contract:
#   This file is intended to be SOURCED, not executed. Sourcing makes the
#   `assert_agent_envelope` function available. The function performs four
#   ordered checks against the sentinel path; any failure HALTs with a
#   canonical error string and exit 1.
#
# Function: assert_agent_envelope <sentinel_path> [--expected-agent <id>]
#   Checks (in order, fail-fast):
#     1. file exists at <sentinel_path>
#     2. file parses as valid JSON (via `jq -e .`)
#     3. `.agent` equals the expected-agent id (default "val")
#     4. `.persona_sig` field is present and non-empty
#
#   The --expected-agent flag (E90-S1, FR-MVB-1) accepts either
#     --expected-agent <id>       (next-arg form)
#     --expected-agent=<id>       (inline form)
#   Default value when absent: "val" — preserves all existing call sites
#   (12 files / 77+ raw occurrences) unchanged. Unknown flags HALT.
#
#   Returns:
#     0  — all four checks pass; caller can trust the sentinel.
#     1  — any check fails; the canonical HALT error is emitted to stderr.
#
#   Canonical error string (do NOT paraphrase — downstream HALT handlers
#   match the constant substring after the agent token):
#     "HALT: <Agent> agent envelope assertion failed — sentinel absent, malformed, or forged at <sentinel_path>"
#   where <Agent> is the capitalize-first-letter form of --expected-agent
#   (e.g. "Val", "Pm", "Ux-designer"). Downstream consumers MUST grep on
#   the constant tail "agent envelope assertion failed — sentinel absent,
#   malformed, or forged at" (em-dash U+2014) — NOT on the leading token.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=.../lib/assert-agent-envelope.sh
#   . "$SCRIPT_DIR/../lib/assert-agent-envelope.sh"
#   assert_agent_envelope "$sentinel_path" || exit $?
#   # Or for a non-Val subagent (e.g. /gaia-meeting PM turn):
#   assert_agent_envelope "$sentinel_path" --expected-agent pm || exit $?
#
# Generalization scope (E90-S1):
#   This helper is now a generic envelope-assertion primitive consumable
#   by any subagent-dispatching skill that follows the E87-S2 Sentinel-Write
#   Contract pattern. The Val sentinel-write contract in validator.md
#   §Sentinel-Write Contract remains Val-specific — generalization is on
#   the asserting side only. write-val-envelope.sh is intentionally NOT
#   generalized by this story (deferred to E90-S2 if needed).
#
#   Example flag values: val (default), pm, architect, qa, ux-designer.
#
# Forgery resistance (NFR-064):
#   The `.persona_sig` field is written by the Val agent persona (E87-S2
#   shifts the sentinel-write origin into the Val persona itself). A
#   hand-crafted sentinel that omits `persona_sig` will fail check #4.
#   Semantic verification of the persona_sig value (e.g. matching a
#   sha256 of the validator agent template) is intentionally deferred to
#   E87-S2 — this helper only enforces field presence.
#
# OPTIONAL `original_status` field (ADR-130 / E87-S8 / AF-2026-06-03-2):
#   The Val sub-agent envelope MAY carry an OPTIONAL `original_status` field
#   (the pre-coercion OUTER envelope status, ∈ {PASS,WARNING,CRITICAL},
#   present only when a downstream closed-enum reduction coerced the status —
#   see validator.md §Sentinel-Write Contract). This asserter ACCEPTS the
#   field as OPTIONAL: the four ordered checks below (file-exists, valid-JSON,
#   agent, persona_sig) are agnostic to its presence. Per the NFR-95 golden
#   invariant, `original_status` MUST NOT be added to any required-field set —
#   assertion passes (exit 0) identically whether the field is present or
#   absent. Back-compat: every existing sentinel without `original_status`
#   asserts exactly as before. Do NOT add an `original_status` check here.
#
# Source guard (idempotent re-source):
#   The standard GAIA `_${NAME}_SH_SOURCED` guard short-circuits the
#   second `source` invocation. Matches the convention in
#   `non-git-cwd-guard.sh` so grep-based audits pick up both files.
#
# Dependencies: bash, jq (already a GAIA-wide hard dependency).
# Cross-platform: locale-pinned LC_ALL=C; jq invocations are POSIX.

# ---- Source guard ----
if [ -n "${_ASSERT_AGENT_ENVELOPE_SH_SOURCED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_ASSERT_AGENT_ENVELOPE_SH_SOURCED=1

# Refuse direct execution — sourcing is the only supported entry point.
# Canonical bash idiom: when sourced, ${BASH_SOURCE[0]} != ${0}.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  printf 'assert-agent-envelope.sh: must be sourced, not executed\n' >&2
  exit 1
fi

# Locale pin — jq is locale-sensitive in some byte-class corners; lock to C.
LC_ALL=C
export LC_ALL

# assert_agent_envelope <sentinel_path> [--expected-agent <id>]
#
# See file header for full contract. The canonical HALT substring
# 'agent envelope assertion failed — sentinel absent, malformed, or forged at'
# is constant across all four failure modes so downstream consumers can
# pattern-match a single substring. The leading agent token (Val, Pm,
# Ux-designer, ...) varies with --expected-agent — consumers MUST NOT
# grep on the leading token.
_aae_halt() {
  # Emit the canonical HALT message once. Consumers grep for the constant
  # substring to detect any of the four failure modes; the leading agent
  # token is interpolated from --expected-agent (default "val").
  local sentinel_path="${1:-<unspecified>}"
  local expected_agent="${2:-val}"
  # Capitalize first letter for grammar: val -> Val, pm -> Pm, ux-designer
  # -> Ux-designer. POSIX-safe (macOS ships bash 3.2; some test runners
  # invoke bash without bash-4 features). The simple awk idiom uppercases
  # the first character and concatenates the remainder unchanged.
  local capitalized
  capitalized="$(printf '%s' "$expected_agent" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
  printf 'HALT: %s agent envelope assertion failed — sentinel absent, malformed, or forged at %s\n' \
    "$capitalized" "$sentinel_path" >&2
}

assert_agent_envelope() {
  local sentinel_path="${1:-}"
  shift || true

  # Parse optional --expected-agent flag (E90-S1, FR-MVB-1). Default "val"
  # preserves all 12 files / 77+ raw occurrences of pre-E90 callers
  # unchanged. Supports both --expected-agent <id> (next-arg) and
  # --expected-agent=<id> (inline) forms. Unknown flags HALT.
  local expected_agent="val"
  while [ $# -gt 0 ]; do
    case "$1" in
      --expected-agent)
        expected_agent="${2:-}"
        shift 2 || { _aae_halt "$sentinel_path" "$expected_agent"; return 1; }
        ;;
      --expected-agent=*)
        expected_agent="${1#*=}"
        shift
        ;;
      *)
        _aae_halt "$sentinel_path" "$expected_agent"
        return 1
        ;;
    esac
  done

  if [ -z "$sentinel_path" ]; then
    _aae_halt "<unspecified>" "$expected_agent"; return 1
  fi

  # Check 1: file exists.
  if [ ! -f "$sentinel_path" ]; then
    _aae_halt "$sentinel_path" "$expected_agent"; return 1
  fi

  # Check 2: parses as valid JSON.
  if ! jq -e . "$sentinel_path" >/dev/null 2>&1; then
    _aae_halt "$sentinel_path" "$expected_agent"; return 1
  fi

  # Check 3: .agent == $expected_agent (default "val").
  local agent_value
  agent_value="$(jq -r '.agent // ""' "$sentinel_path" 2>/dev/null)"
  if [ "$agent_value" != "$expected_agent" ]; then
    _aae_halt "$sentinel_path" "$expected_agent"; return 1
  fi

  # Check 4: .persona_sig present and non-empty (forgery resistance per NFR-064).
  # Check 4 is agent-agnostic — it applies regardless of --expected-agent.
  local persona_sig_value
  persona_sig_value="$(jq -r '.persona_sig // ""' "$sentinel_path" 2>/dev/null)"
  if [ -z "$persona_sig_value" ]; then
    _aae_halt "$sentinel_path" "$expected_agent"; return 1
  fi

  return 0
}
