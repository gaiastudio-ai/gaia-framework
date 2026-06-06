#!/usr/bin/env bash
# issue-1391-no-bash4-case-expansion.bats
#
# bash-4 case-conversion parameter expansion (${var^^}, ${var,,}, ${var^},
# ${var,}) is a syntax error ("bad substitution") on macOS's default bash
# 3.2 — the documented GAIA dev/runtime environment. A `${TIER^^}` in the
# brownfield SKILL.md scan-fidelity banner caused the degradation notice to
# silently fail to render (the exact failure the banner exists to prevent).
#
# This guard scans shipped .sh scripts and SKILL.md prose for any such
# expansion. Comments / docs that NAME the prohibited form (to document it)
# are excluded.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
}
teardown() { common_teardown; }

# Match ${NAME^^}, ${NAME^}, ${NAME,,}, ${NAME,} (optionally with [idx] or a
# :offset). Excludes lines that merely reference the form inside a comment or
# prose by requiring the expansion to be inside a double-quoted echo/printf or
# an assignment — i.e., a real shell usage, not a description.
_scan_bash4_case_expansion() {
  local f="$1"
  # The raw pattern: ${ <name> [opt index] ^^|^|,,|, }. The trailing `|| true`
  # keeps a no-match (grep exit 1) from tripping the caller's `set -e`.
  { grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^?|,,?)\}' "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | grep -vE 'no [`$]?\$?\{?var|does not exist|bash 3\.2|bash-3\.2|POSIX|compatible|prohibited|\^\^-style' ; } || true
}

@test "issue-1391: gaia-brownfield SKILL.md has no bash-4 case-conversion expansion" {
  local f="$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  [ -f "$f" ]
  run _scan_bash4_case_expansion "$f"
  [ -z "$output" ]
}

@test "issue-1391: the scan-fidelity banner uses a tr-based uppercase" {
  local f="$PLUGIN_ROOT/skills/gaia-brownfield/SKILL.md"
  grep -qF "tr '[:lower:]' '[:upper:]'" "$f"
  grep -qF 'Scan fidelity:' "$f"
}

@test "issue-1391: no shipped .sh script under scripts/ uses bash-4 case expansion" {
  local hits=""
  while IFS= read -r f; do
    local h
    h="$(_scan_bash4_case_expansion "$f")"
    [ -n "$h" ] && hits="${hits}
${f}:
${h}"
  done < <(find "$PLUGIN_ROOT/scripts" -type f -name '*.sh' 2>/dev/null)
  if [ -n "$hits" ]; then
    printf 'bash-4 case-conversion expansion found:%s\n' "$hits" >&2
    return 1
  fi
}
