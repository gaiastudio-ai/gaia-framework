#!/usr/bin/env bash
# adapters/dead-code/render-test-quality.sh — E70-S8 unified Test Quality renderer.
#
# Reads the three per-stack dead-code adapter outputs (go-deadcode.json,
# python-vulture.json, jvm-spotbugs.json) and appends ONE "## Test Quality"
# section to the consolidated-gaps report — with THREE per-stack H3 sub-sections
# (Go / Python / JVM), each showing its stack-native qualifier verbatim in the
# detail column (AC4 / NFR-87).
#
# DESIGN INTENT (NOT a bug): the section is deliberately NOT one flat unified
# list with a synthesized cross-stack confidence score. Each tool reports at its
# native granularity — Go: whole-program reachability binary verdict; Python:
# confidence %; JVM: priority x rank ordinal — and that per-stack precision is
# the contract this story exists to preserve (AI-2026-05-23-3, Sable turn 12).
#
# Idempotent: a pre-existing "## Test Quality" section is replaced, not appended
# twice. file_path is the universal JOIN key carried by every row.
#
# Usage: render-test-quality.sh --out-dir <brownfield-audit-dir> --report <md>

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/dead-code/render-test-quality.sh"
die() { printf 'ERROR: %s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

OUT_DIR="" REPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --report)  REPORT="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$OUT_DIR" ] || die "--out-dir required"
[ -n "$REPORT" ] || die "--report required"
[ -f "$REPORT" ] || die "report not found: $REPORT"
command -v jq >/dev/null 2>&1 || die "jq not found"

DC="$OUT_DIR/dead-code"

# Render one per-stack sub-section as a markdown table. Empty/absent input ->
# an explicit "no findings" line so the sub-section always renders (AC4).
render_subsection() {
  local heading="$1" json="$2"
  printf '### %s\n\n' "$heading"
  if [ -f "$json" ] && [ "$(jq 'length' "$json" 2>/dev/null || echo 0)" -gt 0 ]; then
    printf '| File (JOIN key) | Qualifier |\n|---|---|\n'
    jq -r '.[] | "| \(.file_path) | \(.qualifier) |"' "$json"
  else
    printf '_No dead-code findings._\n'
  fi
  printf '\n'
}

section_tmp="$(mktemp)"
trap 'rm -f "$section_tmp"' EXIT
{
  printf '## Test Quality\n\n'
  printf 'Per-stack dead-code findings. Each stack reports at its native precision — '
  printf 'Go (whole-program reachability), Python (vulture confidence%%), JVM '
  # shellcheck disable=SC2016  # backticks are literal markdown, not a subshell.
  printf '(SpotBugs priority x rank). The `file_path` column is the universal JOIN key.\n\n'
  render_subsection "Go / go-deadcode" "$DC/go-deadcode.json"
  render_subsection "Python / vulture" "$DC/python-vulture.json"
  render_subsection "JVM / SpotBugs" "$DC/jvm-spotbugs.json"
} > "$section_tmp"

# Idempotent splice: drop any existing "## Test Quality" .. (next H2 | EOF) block,
# then append the freshly rendered section.
body_tmp="$(mktemp)"
trap 'rm -f "$section_tmp" "$body_tmp"' EXIT
awk '
  /^## Test Quality[[:space:]]*$/ { skip=1; next }
  skip && /^## / { skip=0 }
  !skip { print }
' "$REPORT" > "$body_tmp"

# Ensure a trailing newline separation, then append.
printf '\n' >> "$body_tmp"
cat "$section_tmp" >> "$body_tmp"
mv "$body_tmp" "$REPORT"

printf 'INFO: %s: rendered Test Quality section (3 per-stack sub-sections) into %s\n' "$SCRIPT_NAME" "$REPORT"
exit 0
