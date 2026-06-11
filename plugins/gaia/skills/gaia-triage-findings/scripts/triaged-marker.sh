#!/usr/bin/env bash
# triaged-marker.sh — single source of truth for the TRIAGED marker token.
#
# The triage phase WRITES this marker into a story's Findings table when a
# finding is promoted (CREATE STORY / ADD TO EXISTING); the merged tech-debt
# phase READS it to validate triage targets (STALE TARGET / UNASSIGNED /
# RESOLVED). Both phases MUST use a byte-identical token — a glyph mismatch
# silently breaks the handoff (the reader matches zero targets).
#
# Canonical form: ASCII hyphen-arrow `->` (bytes 2d 3e). This is the form the
# triage writer has always emitted, so existing on-disk markers need no
# migration; the reader is aligned to the writer.
#
# Sourceable contract:
#   TRIAGED_MARKER_PREFIX   — literal prefix written before the target key
#   triaged_marker <key>    — full marker for a given target key
#   triaged_match_regex     — grep -E pattern that matches the marker + key
#
# Usage:
#   . triaged-marker.sh
#   echo "...$(triaged_marker E12-S3)"        # -> ...[TRIAGED -> E12-S3]
#   grep -E "$(triaged_match_regex)" findings  # reader side

# Canonical marker prefix — ASCII `->`. Do NOT substitute the Unicode arrow.
TRIAGED_MARKER_PREFIX='[TRIAGED -> '

# Full marker for a target key, e.g. `[TRIAGED -> E12-S3]`.
triaged_marker() {
  printf '%s%s]' "$TRIAGED_MARKER_PREFIX" "$1"
}

# grep -E pattern capturing the target key from a marker in the Findings text.
# Escapes the regex-significant `[` and `->` so the pattern matches literally.
triaged_match_regex() {
  printf '%s' '\[TRIAGED -> (E[0-9]+-S[0-9]+)\]'
}
