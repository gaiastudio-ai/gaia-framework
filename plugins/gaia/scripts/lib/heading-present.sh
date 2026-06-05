#!/usr/bin/env bash
# heading-present.sh — single source of truth for the H2-heading presence check
# used by every skill finalize.sh checklist (SV-* "<section> present" items).
#
# Background:
#   17 finalize.sh scripts each defined their OWN copy of heading_present() with
#   THREE divergent regexes:
#     (a) no numbered-prefix support      — `^##\s+TEXT`            (13 skills)
#     (b) simple numbered prefix          — `^##\s+([0-9]+\.\s+)?TEXT`  (create-arch, edit-arch)
#     (c) full dotted prefix              — `^##\s+([0-9]+(\.[0-9]+)*\.?\s+)?TEXT` (create-prd, create-ux)
#   So the SAME heading `## 10. Review Findings Incorporated` PASSED in create-prd
#   but FAILED in create-epics. And NONE accepted a letter suffix on the
#   number (`## 11b. Constraints`), so the PRD template's own sub-numbering broke
#   the check. Operators were forced to editorially rename headings to
#   satisfy a brittle, inconsistent regex.
#
# This shared helper applies ONE permissive, uniform pattern across all callers:
#   ^## <optional numbered+lettered outline prefix> TEXT <word boundary>
#   where the prefix accepts:  11   11b   1.2   1.2.3   1.2.3a   (trailing dot ok)
#
# Contract (unchanged from the inline copies so call sites need no edits beyond
# sourcing this file):
#   heading_present <file> <text>   →  echoes "pass" or "fail" on stdout
#   - case-insensitive
#   - <text> is matched as a regex fragment, exactly as the inline copies did
#     (callers pass plain section names like "Constraints" or "Wireframe");
#     this preserves byte-for-byte behaviour for every existing call.
#
# Sourceable, NOT executable. Idempotent source guard prevents redefinition
# warnings when multiple libs are sourced.

if [ "${_GAIA_HEADING_PRESENT_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# heading_present FILE TEXT — echo "pass" if an H2 heading matching TEXT exists.
#
# The optional outline-prefix sub-pattern is:
#   ([0-9]+[a-z]?(\.[0-9]+[a-z]?)*\.?[[:space:]]+)?
# which matches: "11. ", "11b. ", "1.2 ", "1.2.3. ", "10.1a " — and, being
# optional, also matches an un-numbered "## Constraints".
# The trailing `[[:alpha:]]*` lets the supplied TEXT match the START of the
# heading's title, so a stem like "Wireframe" matches both "## Wireframes" and
# "## Wireframe Descriptions" — and "Persona"
# matches "## Personas". The final boundary class still anchors the match to a
# word/line edge so a bare "Test" cannot match mid-word inside another token.
heading_present() {
  local f="$1" text="$2"
  if grep -Ei "^##[[:space:]]+([0-9]+[a-z]?(\.[0-9]+[a-z]?)*\.?[[:space:]]+)?${text}[[:alpha:]]*([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

_GAIA_HEADING_PRESENT_LOADED=1
