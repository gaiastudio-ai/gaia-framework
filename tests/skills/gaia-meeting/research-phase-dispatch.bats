#!/usr/bin/env bats
# research-phase-dispatch.bats — gaia-meeting RESEARCH-phase fork dispatch (E76-S2)
#
# Covers AC1, AC2, AC3, AC5, AC11 / TC-MTG-RESEARCH-1, TC-MTG-RESEARCH-2,
# TC-MTG-RESEARCH-4, TC-MTG-RESEARCH-5.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/research-phase-dispatch.sh"
  TMP_DIR="$(mktemp -d)"
  export MEETING_STATE_FILE="$TMP_DIR/state.env"
}

teardown() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}

@test "Pre-flight: research-phase-dispatch.sh exists and is executable" {
  [ -x "$HELPER" ]
}

# AC11 / TC-MTG-RESEARCH-2 + TC-MTG-RESEARCH-5: allowlist source-of-truth
@test "AC11: --print-allowlist (web enabled) emits exactly [Read, Grep, Glob, Bash, WebSearch, WebFetch]" {
  run "$HELPER" --print-allowlist
  [ "$status" -eq 0 ]
  [ "$output" = "Read,Grep,Glob,Bash,WebSearch,WebFetch" ]
}

@test "AC11: --print-allowlist --no-web emits exactly [Read, Grep, Glob, Bash]" {
  run "$HELPER" --print-allowlist --no-web
  [ "$status" -eq 0 ]
  [ "$output" = "Read,Grep,Glob,Bash" ]
}

@test "AC11: allowlist NEVER contains write-capable tools (web on)" {
  run "$HELPER" --print-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" != *"Write"* ]]
  [[ "$output" != *"Edit"* ]]
  [[ "$output" != *"NotebookEdit"* ]]
}

@test "AC11: allowlist NEVER contains write-capable tools (--no-web)" {
  run "$HELPER" --print-allowlist --no-web
  [ "$status" -eq 0 ]
  [[ "$output" != *"Write"* ]]
  [[ "$output" != *"Edit"* ]]
  [[ "$output" != *"NotebookEdit"* ]]
}

# AC1 / TC-MTG-RESEARCH-1: per-agent sidecar canonical path
@test "AC1: --sidecar-path resolves canonical _memory/{agent}-sidecar/ for an agent name" {
  run "$HELPER" --sidecar-path Theo
  [ "$status" -eq 0 ]
  [ "$output" = "_memory/Theo-sidecar" ]
}

@test "AC1: --sidecar-path REJECTS the intake-shorthand _memory/agent-decisions/{agent}/" {
  run "$HELPER" --sidecar-path agent-decisions/Theo
  [ "$status" -ne 0 ]
}

# AC3 / TC-MTG-RESEARCH-5: --no-web plumbing
@test "AC3: --check-web-flag returns 'enabled' by default" {
  run "$HELPER" --check-web-flag
  [ "$status" -eq 0 ]
  [ "$output" = "enabled" ]
}

@test "AC3: --check-web-flag returns 'disabled' when --no-web is set" {
  run "$HELPER" --check-web-flag --no-web
  [ "$status" -eq 0 ]
  [ "$output" = "disabled" ]
}

# AC5 / TC-MTG-RESEARCH-4: --skip-research audit invariant
@test "AC5: --check-research-flag returns 'enabled' by default" {
  run "$HELPER" --check-research-flag
  [ "$status" -eq 0 ]
  [ "$output" = "enabled" ]
}

@test "AC5: --check-research-flag returns 'skipped' when --skip-research is set" {
  run "$HELPER" --check-research-flag --skip-research
  [ "$status" -eq 0 ]
  [ "$output" = "skipped" ]
}

@test "AC5: --emit-frontmatter --skip-research emits 'research_phase: skipped'" {
  run "$HELPER" --emit-frontmatter --skip-research
  [ "$status" -eq 0 ]
  [[ "$output" == *"research_phase: skipped"* ]]
}

@test "AC3: --emit-frontmatter --no-web emits 'web_search: disabled'" {
  run "$HELPER" --emit-frontmatter --no-web
  [ "$status" -eq 0 ]
  [[ "$output" == *"web_search: disabled"* ]]
}

@test "AC3: --emit-frontmatter (web on) emits 'web_search: enabled'" {
  run "$HELPER" --emit-frontmatter
  [ "$status" -eq 0 ]
  [[ "$output" == *"web_search: enabled"* ]]
}

# Mode stacking: skip-research and no-web compose
@test "AC3+AC5: --skip-research --no-web both reflected in frontmatter" {
  run "$HELPER" --emit-frontmatter --skip-research --no-web
  [ "$status" -eq 0 ]
  [[ "$output" == *"research_phase: skipped"* ]]
  [[ "$output" == *"web_search: disabled"* ]]
}

# Reject unknown args
@test "rejects unknown arguments with non-zero exit" {
  run "$HELPER" --bogus-flag
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
