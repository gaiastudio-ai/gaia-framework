#!/usr/bin/env bash
# cite-or-flag-check.sh — facilitator cite-or-flag invariant (E76-S2, FR-MTG-5)
#
# Implements:
#   - AC6 / TC-MTG-RESEARCH-3: per-line classification of DISCUSS turn lines
#       into one of: cited | inference | unflagged-inference | non-claim
#   - AC7 / TC-MTG-GUARD-1: pre-persistence gate that HALTs round-robin
#       advancement when any line classifies as 'unflagged-inference'
#   - AC10 / TC-MTG-RESEARCH-6: deterministic static check over a saved
#       transcript (no live state, no fork dispatch)
#
# A "factual claim" is detected via a conservative heuristic — a line that
# asserts a fact about a file, code behavior, prior decision, external system,
# or memory entry. Question-shaped lines, meta-conversation, and bare opinions
# without a factual assertion fall into 'non-claim'. The escape hatch for any
# borderline line is the literal token `[inference]`.
#
# Usage:
#   cite-or-flag-check.sh --classify-line "<line text>"
#   cite-or-flag-check.sh --gate-draft-turn <path-to-draft-file>
#   cite-or-flag-check.sh --verify-transcript <path-to-saved-meeting-md>
#
# Exit codes:
#   0  = PASS (line cited / inference / non-claim, or gate/transcript clean)
#   2  = HALT — at least one unflagged-inference line detected
#   3  = malformed args / missing input file

set -euo pipefail
export LC_ALL=C

# --- Classification primitives ---------------------------------------------

# Returns one of: cited | inference | unflagged-inference | non-claim
classify_line() {
  local line="$1"

  # Strip leading/trailing whitespace for checks.
  local trimmed
  trimmed="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  # Empty line, markdown header, frontmatter delimiter, or list marker is non-claim.
  if [[ -z "$trimmed" ]]; then echo "non-claim"; return 0; fi
  case "$trimmed" in
    \#*|---|\>\ *|\>*|\`\`\`*) echo "non-claim"; return 0 ;;
  esac

  # Question-shaped lines are non-claims.
  if [[ "$trimmed" == *\? ]]; then echo "non-claim"; return 0; fi

  # Meta facilitator log lines (e.g., "[round 1 / turn 2 / ...]") are non-claims.
  if [[ "$trimmed" == \[round\ * ]]; then echo "non-claim"; return 0; fi
  if [[ "$trimmed" == \[Prelude\]* ]]; then echo "non-claim"; return 0; fi

  # Citation markers — file path, URL, or _memory/ reference.
  local has_citation=0
  # URL: http(s)://...
  if printf '%s' "$trimmed" | grep -Eq 'https?://[^[:space:]]+'; then
    has_citation=1
  fi
  # .gaia/memory/ reference (path component, not bare word). AF-2026-05-27-3:
  # legacy _memory/ recognition dropped — .gaia/ is the canonical tree (ADR-111).
  if printf '%s' "$trimmed" | grep -Eq '(^|[[:space:]/(])\.gaia/memory/[A-Za-z0-9._/-]+'; then
    has_citation=1
  fi
  # Project-relative file path matching docs/ or gaia-public/ or _gaia/ prefix
  # with a recognized extension (.md, .yaml, .yml, .json, .sh, .ts, .js, .py).
  if printf '%s' "$trimmed" \
      | grep -Eq '(^|[[:space:](`])(docs|gaia-public|gaia-enterprise|Gaia-framework|_gaia|plugins|scripts|tests)/[A-Za-z0-9._/-]+\.(md|yaml|yml|json|sh|ts|js|py|bats|csv|sql)\b'; then
    has_citation=1
  fi

  # Inference token (literal).
  local has_inference=0
  if printf '%s' "$trimmed" | grep -Fq '[inference]'; then
    has_inference=1
  fi

  # Resolve classification by precedence: cited beats inference.
  if [[ "$has_citation" -eq 1 ]]; then
    echo "cited"
    return 0
  fi
  if [[ "$has_inference" -eq 1 ]]; then
    echo "inference"
    return 0
  fi

  # Heuristic factual-claim detector — lines that assert facts. We err on the
  # side of flagging rather than silently letting a claim through (FR-MTG-5).
  # A "factual claim" = a declarative sentence that asserts a definite fact:
  #   - contains a function/identifier-call shape: foo() or Foo.bar(...)
  #   - mentions a present/past indicative copula or assertion verb
  #     ("is", "are", "was", "were", "has", "have", "had", "will", "MUST",
  #     "returns", "resolves", "depends", "produces", "emits", "decided",
  #     "landed", "shipped", "retired", "always", "never", etc.)
  #   - mentions a constraint/dependency verb ("depends on", "is mandatory")
  #
  # The verb list is intentionally broad (FR-MTG-5 "err on flagging" — the
  # escape hatch is the literal [inference] token, not a permissive
  # detector). See manual-test finding F5 (gaia-meeting QA, 2026-05-18) for
  # the prior narrow-detector failure modes — `"X resolves to Y"`,
  # `"X depends on Y"`, `"X is N turns"`, `"we decided to retire Y"` all
  # bypassed the previous list.
  if printf '%s' "$trimmed" \
      | grep -Eq '\b[A-Za-z_][A-Za-z0-9_]*\(\)' \
      || printf '%s' "$trimmed" \
      | grep -Eqi '\b(is|are|was|were|has|have|had|will|would|MUST|MUST NOT|cannot|can|always|never|is the|is set|is mandatory|requires|returns|resolves|depends|produces|emits|enables|disables|decided|landed|shipped|retired|exists|lives|sits|points|references|covers|implements|enforces|asserts)\b'; then
    echo "unflagged-inference"
    return 0
  fi

  # Default — non-claim (opinions, meta-talk, transitions).
  echo "non-claim"
}

# --- Subcommands ------------------------------------------------------------

cmd_classify_line() {
  local line="$1"
  classify_line "$line"
}

cmd_gate_draft_turn() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "cite-or-flag-check.sh: draft file not found: $file" >&2
    exit 3
  fi
  local violators=()
  local lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    local cls
    cls="$(classify_line "$line")"
    if [[ "$cls" == "unflagged-inference" ]]; then
      violators+=("line ${lineno}: ${line}")
    fi
  done < "$file"

  if [[ ${#violators[@]} -eq 0 ]]; then
    echo "PASS — every factual claim line carries a citation marker or [inference]"
    return 0
  fi
  echo "HALT — unflagged-inference detected; round-robin advancement halted"
  printf '%s\n' "${violators[@]}"
  echo ""
  echo "Re-emit the turn with a citation marker (file path, URL, or .gaia/memory/ ref)"
  echo "or the literal [inference] token before persistence (FR-MTG-5, FR-MTG-28)."
  exit 2
}

cmd_verify_transcript() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "cite-or-flag-check.sh: transcript file not found: $file" >&2
    exit 3
  fi

  # Skip frontmatter region (--- ... ---) at top, then classify body lines.
  local in_frontmatter=0
  local seen_frontmatter=0
  local violators=()
  local lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$lineno" -eq 1 && "$line" == "---" ]]; then
      in_frontmatter=1
      seen_frontmatter=1
      continue
    fi
    if [[ "$in_frontmatter" -eq 1 ]]; then
      if [[ "$line" == "---" ]]; then
        in_frontmatter=0
      fi
      continue
    fi
    local cls
    cls="$(classify_line "$line")"
    if [[ "$cls" == "unflagged-inference" ]]; then
      violators+=("line ${lineno}: ${line}")
    fi
  done < "$file"

  if [[ ${#violators[@]} -eq 0 ]]; then
    echo "PASS — transcript is cite-or-flag clean"
    return 0
  fi
  echo "FAIL — transcript contains unflagged-inference lines"
  printf '%s\n' "${violators[@]}"
  exit 2
}

# --- Argument parsing -------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "cite-or-flag-check.sh: a subcommand is required (see source header)." >&2
  exit 3
fi

case "$1" in
  --classify-line)
    if [[ $# -lt 2 ]]; then
      echo "cite-or-flag-check.sh: --classify-line requires a line arg." >&2
      exit 3
    fi
    cmd_classify_line "$2"
    ;;
  --gate-draft-turn)
    if [[ $# -lt 2 ]]; then
      echo "cite-or-flag-check.sh: --gate-draft-turn requires a path arg." >&2
      exit 3
    fi
    cmd_gate_draft_turn "$2"
    ;;
  --verify-transcript)
    if [[ $# -lt 2 ]]; then
      echo "cite-or-flag-check.sh: --verify-transcript requires a path arg." >&2
      exit 3
    fi
    cmd_verify_transcript "$2"
    ;;
  *)
    echo "cite-or-flag-check.sh: unknown subcommand: $1" >&2
    exit 3
    ;;
esac
