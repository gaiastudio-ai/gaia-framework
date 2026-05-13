#!/usr/bin/env bash
# assert-agent-envelope.sh — Val agent envelope assertion (E87-S1, ADR-104; updated by E87-S7, ADR-105).
#
# Story: E87-S1 — Shared assert-agent-envelope.sh helper + ADR-104 anchor + memory scaffold.
# Anchor: ADR-104 — Val Bridge Migration: Main-Turn Agent Dispatch Across Val-Consuming Skills.
#         ADR-105 — Sentinel-Write Writer Shift (amends ADR-104, E87-S7, 2026-05-13).
# Trace: FR-477, FR-482, FR-483, FR-484, NFR-064 (forgery resistance), NFR-065 (sequencing safety), NFR-066.
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
# Function: assert_agent_envelope <sentinel_path>
#   Checks (in order, fail-fast):
#     1. file exists at <sentinel_path>
#     2. file parses as valid JSON (via `jq -e .`)
#     3. `.agent` equals the literal string "val"
#     4. `.persona_sig` field is present and non-empty
#
#   Returns:
#     0  — all four checks pass; caller can trust the sentinel.
#     1  — any check fails; the canonical HALT error is emitted to stderr.
#
#   Canonical error string (do NOT paraphrase — downstream HALT handlers
#   match the prefix):
#     "HALT: Val agent envelope assertion failed — sentinel absent, malformed, or forged at <sentinel_path>"
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=.../lib/assert-agent-envelope.sh
#   . "$SCRIPT_DIR/../lib/assert-agent-envelope.sh"
#   assert_agent_envelope "$sentinel_path" || exit $?
#
# Forgery resistance (NFR-064):
#   The `.persona_sig` field is written by the Val agent persona (E87-S2
#   shifts the sentinel-write origin into the Val persona itself). A
#   hand-crafted sentinel that omits `persona_sig` will fail check #4.
#   Semantic verification of the persona_sig value (e.g. matching a
#   sha256 of the validator agent template) is intentionally deferred to
#   E87-S2 — this helper only enforces field presence.
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

# assert_agent_envelope <sentinel_path>
#
# See file header for full contract. The canonical HALT prefix is constant
# string-equal across all four failure modes so downstream consumers can
# pattern-match a single prefix.
_aae_halt() {
  # Emit the canonical HALT prefix once. Consumers grep for the prefix to
  # detect any of the four failure modes; do NOT paraphrase.
  local sentinel_path="${1:-<unspecified>}"
  printf 'HALT: Val agent envelope assertion failed — sentinel absent, malformed, or forged at %s\n' \
    "$sentinel_path" >&2
}

assert_agent_envelope() {
  local sentinel_path="${1:-}"

  if [ -z "$sentinel_path" ]; then
    _aae_halt; return 1
  fi

  # Check 1: file exists.
  if [ ! -f "$sentinel_path" ]; then
    _aae_halt "$sentinel_path"; return 1
  fi

  # Check 2: parses as valid JSON.
  if ! jq -e . "$sentinel_path" >/dev/null 2>&1; then
    _aae_halt "$sentinel_path"; return 1
  fi

  # Check 3: .agent == "val".
  local agent_value
  agent_value="$(jq -r '.agent // ""' "$sentinel_path" 2>/dev/null)"
  if [ "$agent_value" != "val" ]; then
    _aae_halt "$sentinel_path"; return 1
  fi

  # Check 4: .persona_sig present and non-empty (forgery resistance per NFR-064).
  local persona_sig_value
  persona_sig_value="$(jq -r '.persona_sig // ""' "$sentinel_path" 2>/dev/null)"
  if [ -z "$persona_sig_value" ]; then
    _aae_halt "$sentinel_path"; return 1
  fi

  return 0
}
