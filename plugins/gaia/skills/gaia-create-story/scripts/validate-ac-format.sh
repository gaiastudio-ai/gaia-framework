#!/usr/bin/env bash
# validate-ac-format.sh — gaia-create-story Step 6 deterministic
#                         AC-format validator (E63-S6 / Work Item 6.6)
#
# Purpose:
#   Verify every `- [ ]` line in a story's `## Acceptance Criteria` section
#   matches the canonical Given/When/Then ERE (case-insensitive). Surfaces
#   format issues deterministically BEFORE Val dispatch in Step 6 of
#   /gaia-create-story, saving Val tokens on the trivial mismatch class and
#   removing AC-format judgment from the LLM.
#
# Consumers:
#   - /gaia-create-story Step 6 — pre-Val deterministic sweep, alongside
#     E63-S5 validate-frontmatter.sh (parallel sibling validator).
#   - The 3-attempt fix loop (ADR-050) consumes the findings emitted here
#     to re-prompt the SM auto-fixer with concrete line numbers.
#
# Algorithm (in order):
#   1. Parse CLI: `--file <path>` (single required flag).
#   2. Verify the target file exists and is readable.
#   3. Extract the AC section using an awk state-machine (NOT a range
#      pattern — see gaia-shell-idioms for the awk range-bug rationale).
#      The state flips on `## Acceptance Criteria` and flips off at the
#      next `## ` heading.
#   4. Filter to `- [ ]` lines (primary ACs and AC-EC entries uniformly —
#      the validator MUST NOT special-case the AC-EC prefix per AC2).
#   5. Validate each line against the case-insensitive ERE
#      `Given .+, when .+, then .+`. Mismatches emit one finding row to
#      stdout in the canonical `severity\tfield\tmessage` format.
#   6. Empty AC section (zero `- [ ]` lines between the heading and the
#      next `## ` heading) emits a single CRITICAL finding and exits
#      non-zero (AC3 path).
#   7. All-pass exits 0 with empty stdout (AC4 path) — the validator-
#      script convention used by E63-S4 (validate-canonical-filename.sh).
#
# Findings format:
#   `<severity>\t<field>\t<message>` — tab-separated, one finding per line.
#   - severity: WARNING (per-line format mismatch) | CRITICAL (empty section)
#   - field:    `acceptance-criteria` (constant; this script only inspects
#               the AC section)
#   - message:  human-readable explanation; for line-level findings,
#               includes the absolute line number and verbatim content.
#   This format is parallel to E63-S5 (validate-frontmatter.sh) and will
#   be harmonized with it in E63-S11 (the SKILL.md thin-orchestrator
#   rewrite).
#
# Exit codes:
#   0 — every AC line matches the Given/When/Then ERE (silent success)
#   1 — usage error, missing/unreadable --file path, or at least one
#       finding emitted
#
# Locale invariance:
#   `LC_ALL=C` is set so awk and grep character classes / regex semantics
#   are byte-level and identical on macOS BSD and Linux GNU userland.
#
# Spec references:
#   - .gaia/artifacts/planning-artifacts/feature-create-story-hardening.md#Work-Item-6.6
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log — ADR-074
#     (deterministic-script lift)
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log — ADR-042
#     (Scripts-over-LLM precedent)
#   - .gaia/artifacts/planning-artifacts/architecture.md §Decision Log — ADR-050
#     (Shared Val + SM Fix-Loop Dispatch Pattern)
#   - gaia-public/plugins/gaia/skills/gaia-shell-idioms/SKILL.md
#   - Sibling: gaia-public/plugins/gaia/skills/gaia-create-story/scripts/slugify.sh (E63-S1)
#   - Sibling: gaia-public/plugins/gaia/skills/gaia-create-story/scripts/next-story-id.sh (E63-S2)
#   - Sibling: gaia-public/plugins/gaia/skills/gaia-create-story/scripts/validate-canonical-filename.sh (E63-S4)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="validate-ac-format.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: validate-ac-format.sh --file <story-file>
       validate-ac-format.sh <story-file>          (deprecated positional form — emits NOTICE)

  --file <path>  Path to a story file. Required.

Verifies that every `- [ ]` line in the story's `## Acceptance Criteria`
section matches the case-insensitive ERE `Given .+, when .+, then .+`.
Emits one finding row per malformed line (severity\tfield\tmessage)
on stdout. Empty AC sections emit a single CRITICAL finding.

Exit codes:
  0 — every AC line matches (silent success)
  1 — usage error, missing/unreadable file, or at least one finding emitted
USAGE
}

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die_usage() { log "$*"; usage; exit 1; }
die_input() { log "$*"; exit 1; }

# ---------- CLI parsing ----------

file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die_usage "--file requires a value"
      file="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*)
      die_usage "unknown argument: $1" ;;
    *)
      # AF-2026-05-30-4 D-05 — positional path form is accepted with a
      # deprecation NOTICE. Canonical form is `--file <path>`.
      if [ -n "$file" ]; then
        die_usage "positional path '$1' supplied after --file '$file' — use only one form"
      fi
      log "NOTICE: positional path is deprecated; prefer '--file $1' (AF-2026-05-30-4 D-05)"
      file="$1"; shift ;;
  esac
done

[ -n "$file" ] || die_usage "--file is required (or pass a positional path; --file is canonical)"
if [ ! -r "$file" ]; then
  die_input "file not found: $file"
fi

# ---------- AC section extraction (awk state-machine) ----------
#
# Walk the file once. Flip `in_ac` on the literal `## Acceptance Criteria`
# heading; flip it off on the next `## ` heading (any subsequent H2). For
# every line while `in_ac` is true, emit a record `<lineno>\t<content>`
# so downstream filters preserve the absolute file line number.

ac_lines="$(awk '
  /^## Acceptance Criteria[[:space:]]*$/ { in_ac = 1; next }
  /^## / && in_ac                        { in_ac = 0 }
  in_ac                                  { printf "%d\t%s\n", NR, $0 }
' "$file")"

# ---------- Filter to checkbox AC lines ----------
#
# Both primary AC lines and AC-EC entries start with `- [ ] ` (unchecked) or
# `- [x] ` (checked, e.g. on a done story file). The validator MUST NOT
# special-case the `AC-EC` prefix per AC2 — and it accepts either checkbox
# state so the live-tree smoke (Subtask 3.1) works against done stories.
# The format check applies uniformly regardless of checked state.

checkbox_lines="$(printf '%s\n' "$ac_lines" \
  | awk -F'\t' 'NF >= 2 && $2 ~ /^- \[[ xX]\] /')"

# ---------- Empty AC section (AC3) ----------

if [ -z "$checkbox_lines" ]; then
  printf 'CRITICAL\tacceptance-criteria\tsection is empty (zero `- [ ]` lines under `## Acceptance Criteria`)\n'
  exit 1
fi

# ---------- Validate each AC line against case-insensitive Given/When/Then ----------

findings=0
while IFS=$'\t' read -r lineno content; do
  [ -n "$lineno" ] || continue
  # `grep -iE` matches case-insensitively under LC_ALL=C; the regex
  # accepts any non-empty bridging text between Given/when/then.
  if ! printf '%s' "$content" | grep -iqE 'Given .+, when .+, then .+'; then
    printf 'WARNING\tacceptance-criteria\tline %d: %s\n' "$lineno" "$content"
    findings=$((findings + 1))
  fi
done <<EOF
$checkbox_lines
EOF

if [ "$findings" -gt 0 ]; then
  exit 1
fi

exit 0
