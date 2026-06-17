#!/usr/bin/env bats
# dev-story-script-wiring.bats — bats coverage for E57-S8
#
# Story: E57-S8 — SKILL.md script wiring (Steps 1, 10, 11) + narrative-fallback retention
#
# Acceptance Criteria covered:
#   AC1 — Step 1 invokes story-parse.sh, detect-mode.sh, check-deps.sh and
#         contains a narrative-fallback block (TC-DSS-09).
#   AC2 — Step 10 invokes promotion-chain-guard.sh at the top of the CI section
#         AND commit-msg.sh in the commit subsection (TC-DSS-09).
#   AC3 — Step 11 documents that pr-create.sh reads its body from
#         pr-body.sh output (TC-DSS-09).
#   AC5 — Regression: re-introducing inline LLM frontmatter parsing or inline
#         PR body construction causes this test to FAIL naming the offending
#         step (TC-DSS-10).
#
# Refs: FR-DSS-1..6, AF-2026-04-28-6.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  common_setup
  SKILL_MD="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story" && pwd)/SKILL.md"
  export SKILL_MD
  [ -f "$SKILL_MD" ] || { echo "SKILL.md not found at $SKILL_MD" >&2; return 1; }
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Marker pairs — each wired step has begin/end HTML comment markers so
# regression failures name the offending step.
# ---------------------------------------------------------------------------

@test "Step 1 script-wiring marker pair is present" {
  run grep -c '<!-- step1 script-wiring begin -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c '<!-- step1 script-wiring end -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "Step 10 script-wiring marker pair is present" {
  run grep -c '<!-- step10 script-wiring begin -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c '<!-- step10 script-wiring end -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "Step 11 script-wiring marker pair is present" {
  run grep -c '<!-- step11 script-wiring begin -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c '<!-- step11 script-wiring end -->' "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# AC1 — Step 1 invokes story-parse.sh, detect-mode.sh, check-deps.sh and
# contains a narrative-fallback block.
# ---------------------------------------------------------------------------

@test "Step 1 block invokes story-parse.sh" {
  block="$(awk '/<!-- step1 script-wiring begin -->/,/<!-- step1 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'story-parse.sh' <<<"$block"
}

@test "Step 1 block invokes detect-mode.sh" {
  block="$(awk '/<!-- step1 script-wiring begin -->/,/<!-- step1 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'detect-mode.sh' <<<"$block"
}

@test "Step 1 block invokes check-deps.sh" {
  block="$(awk '/<!-- step1 script-wiring begin -->/,/<!-- step1 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'check-deps.sh' <<<"$block"
}

@test "Step 1 block contains a Narrative Fallback section" {
  block="$(awk '/<!-- step1 script-wiring begin -->/,/<!-- step1 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'Narrative Fallback' <<<"$block"
  # The fallback is gated on the absence of the new script via `command -v`.
  grep -Fq 'command -v story-parse.sh' <<<"$block"
}

# ---------------------------------------------------------------------------
# AC2 — Step 10 invokes promotion-chain-guard.sh at the top of the CI section
# AND commit-msg.sh in the commit subsection.
# ---------------------------------------------------------------------------

@test "Step 10 block invokes promotion-chain-guard.sh" {
  block="$(awk '/<!-- step10 script-wiring begin -->/,/<!-- step10 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'promotion-chain-guard.sh' <<<"$block"
}

@test "Step 10 block invokes commit-msg.sh" {
  block="$(awk '/<!-- step10 script-wiring begin -->/,/<!-- step10 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'commit-msg.sh' <<<"$block"
}

@test "Step 10 block contains a Narrative Fallback section" {
  block="$(awk '/<!-- step10 script-wiring begin -->/,/<!-- step10 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'Narrative Fallback' <<<"$block"
  grep -Fq 'command -v commit-msg.sh' <<<"$block"
}

@test "promotion-chain-guard.sh appears BEFORE commit-msg.sh inside Step 10 block" {
  block="$(awk '/<!-- step10 script-wiring begin -->/,/<!-- step10 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  guard_off="$(printf '%s\n' "$block" | grep -boF 'promotion-chain-guard.sh' | head -1 | cut -d: -f1)"
  msg_off="$(printf '%s\n' "$block" | grep -boF 'commit-msg.sh' | head -1 | cut -d: -f1)"
  [ -n "$guard_off" ] && [ -n "$msg_off" ]
  [ "$guard_off" -lt "$msg_off" ]
}

# ---------------------------------------------------------------------------
# AC3 — Step 11 documents that pr-create.sh reads its body from pr-body.sh.
# ---------------------------------------------------------------------------

@test "Step 11 block invokes pr-body.sh" {
  block="$(awk '/<!-- step11 script-wiring begin -->/,/<!-- step11 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'pr-body.sh' <<<"$block"
}

@test "Step 11 block references pr-create.sh" {
  block="$(awk '/<!-- step11 script-wiring begin -->/,/<!-- step11 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'pr-create.sh' <<<"$block"
}

@test "Step 11 block contains a Narrative Fallback section" {
  block="$(awk '/<!-- step11 script-wiring begin -->/,/<!-- step11 script-wiring end -->/' "$SKILL_MD")"
  [ -n "$block" ]
  grep -Fq 'Narrative Fallback' <<<"$block"
  grep -Fq 'command -v pr-body.sh' <<<"$block"
}

# ---------------------------------------------------------------------------
# Hook ordering — each script-wiring block must appear AFTER its
# corresponding step header. The Step N header precedes the matching marker.
# ---------------------------------------------------------------------------

@test "Step 1 wiring block follows Step 1 -- Load Story header" {
  step1_line="$(grep -n '^### Step 1 -- Load Story' "$SKILL_MD" | head -1 | cut -d: -f1)"
  hook_line="$(grep -n '<!-- step1 script-wiring begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$step1_line" ] && [ -n "$hook_line" ]
  [ "$hook_line" -gt "$step1_line" ]
}

@test "Step 10 wiring block follows Step 10 -- Commit and Push header" {
  step10_line="$(grep -n '^### Step 10 -- Commit and Push' "$SKILL_MD" | head -1 | cut -d: -f1)"
  hook_line="$(grep -n '<!-- step10 script-wiring begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$step10_line" ] && [ -n "$hook_line" ]
  [ "$hook_line" -gt "$step10_line" ]
}

@test "Step 11 wiring block follows Step 11 -- Create PR header" {
  step11_line="$(grep -n '^### Step 11 -- Create PR' "$SKILL_MD" | head -1 | cut -d: -f1)"
  hook_line="$(grep -n '<!-- step11 script-wiring begin -->' "$SKILL_MD" | head -1 | cut -d: -f1)"
  [ -n "$step11_line" ] && [ -n "$hook_line" ]
  [ "$hook_line" -gt "$step11_line" ]
}

# ---------------------------------------------------------------------------
# AC5 — Deprecation cadence: each fallback block names the v1.131.x → v1.132.0
# removal window so brownfield users can plan the upgrade.
# ---------------------------------------------------------------------------

@test "each fallback block names the v1.131.x deprecation cadence" {
  for marker in step1 step10 step11; do
    block="$(awk "/<!-- ${marker} script-wiring begin -->/,/<!-- ${marker} script-wiring end -->/" "$SKILL_MD")"
    [ -n "$block" ]
    grep -Fq 'v1.131.x' <<<"$block"
    grep -Fq 'v1.132.0' <<<"$block"
  done
}

# ---------------------------------------------------------------------------
# AC5 (TC-DSS-10) — Absence-assertion regression contract.
#
# The wiring blocks above prove the new scripts are PRESENT. AC5 also requires
# that the legacy LLM narrative is ABSENT outside the marker-fenced regions.
# A regression that re-introduces inline frontmatter parsing or inline PR-body
# construction (alongside, or in place of, the new script invocations) MUST
# cause this test to FAIL naming the offending step.
#
# Strategy: strip the three E57-S8 wiring blocks (begin..end inclusive) from
# SKILL.md, then grep the residue for legacy patterns. The Narrative Fallback
# subsections live INSIDE the wiring blocks, so they are not flagged.
# ---------------------------------------------------------------------------

# Emit SKILL.md with all three E57-S8 wiring blocks removed (begin..end inclusive).
_skill_md_minus_wiring_blocks() {
  awk '
    /<!-- step1 script-wiring begin -->/  { skip=1 }
    /<!-- step10 script-wiring begin -->/ { skip=1 }
    /<!-- step11 script-wiring begin -->/ { skip=1 }
    skip == 0 { print }
    /<!-- step1 script-wiring end -->/    { skip=0; next }
    /<!-- step10 script-wiring end -->/   { skip=0; next }
    /<!-- step11 script-wiring end -->/   { skip=0; next }
  ' "$SKILL_MD"
}

@test "absence: Step 1 — no inline frontmatter parsing outside wiring block" {
  residue="$(_skill_md_minus_wiring_blocks)"
  # Legacy inline narrative: 'Read the story file: extract' / 'Detect execution mode' / 'FRESH (new implementation)'.
  # Any of these outside the wiring block means a regression has re-introduced
  # the inline LLM frontmatter-parsing path that script-wiring replaced.
  if grep -nE 'Read the story file: extract|Detect execution mode|FRESH \(new implementation\)|REWORK \(fix review|RESUME \(continue from'; then <<<"$residue"
    echo "REGRESSION: Step 1 inline LLM frontmatter parsing re-introduced outside <!-- step1 script-wiring --> block." >&2
    echo "story-parse.sh + detect-mode.sh are the single source of truth (FR-DSS-1, FR-DSS-2)." >&2
    return 1
  fi
}

@test "absence: Step 10 — no inline commit-subject construction outside wiring block" {
  residue="$(_skill_md_minus_wiring_blocks)"
  # Legacy inline narrative: 'Conventional Commit' subject composition guidance, or
  # an inline 'git commit -m' usage that hand-crafts the subject. commit-msg.sh
  # is the single source of truth (FR-DSS-5, FR-DSS-6).
  if grep -nE 'Compose .*Conventional Commit subject|hand-craft.*commit subject|git commit -m "[^"]*\$\{?story_key\}?'; then <<<"$residue"
    echo "REGRESSION: Step 10 inline commit-subject composition re-introduced outside <!-- step10 script-wiring --> block." >&2
    echo "commit-msg.sh is the single source of truth (FR-DSS-5, FR-DSS-6, NFR-DSS-1)." >&2
    return 1
  fi
}

@test "absence: Step 11 — no inline PR-body construction outside wiring block" {
  residue="$(_skill_md_minus_wiring_blocks)"
  # Legacy inline narrative: heredoc-built PR body fed straight to gh, or
  # 'pr-create.sh ... --body "$(cat <<' inline-body construction. pr-body.sh is
  # the single source of truth (FR-DSS-5, FR-DSS-6).
  if grep -nE 'gh pr create .*--body "\$\(cat <<|pr-create\.sh.*--body "\$\(cat <<|Compose the PR body inline|hand-craft the PR body'; then <<<"$residue"
    echo "REGRESSION: Step 11 inline PR-body construction re-introduced outside <!-- step11 script-wiring --> block." >&2
    echo "pr-body.sh is the single source of truth (FR-DSS-5, FR-DSS-6)." >&2
    return 1
  fi
}

@test "absence: residue still names every wired step (sanity — strip didn't eat the world)" {
  residue="$(_skill_md_minus_wiring_blocks)"
  # Sanity guard: if the awk strip ever over-deletes (e.g. a regex change drops
  # too much), this test fails loudly rather than silently passing the absence
  # checks above on an empty residue.
  #
  # Use a here-string, NOT `grep -Fq`: grep -q exits on the <<<"$residue"
  # first match and closes the pipe, so echo (the writer) takes SIGPIPE and
  # exits 141, which fails the test nondeterministically under load / parallel
  # execution. A here-string has no upstream writer process to signal.
  grep -Fq '### Step 1 -- Load Story'       <<<"$residue"
  grep -Fq '### Step 10 -- Commit and Push' <<<"$residue"
  grep -Fq '### Step 11 -- Create PR'        <<<"$residue"
}

# ---------------------------------------------------------------------------
# AC4 (TC-DSS-09 integration) — End-to-end smoke run on the cluster-7-chain
# fixture. Exercises the six new scripts wired into Steps 1, 10, 11 against a
# clean fixture story file; asserts each script is invokable from SKILL.md's
# canonical path and emits the expected exit code / stdout shape.
#
# This is a unit-of-integration smoke test (not a full /gaia-dev-story run) —
# it proves the wiring resolves to working scripts on the cluster-7-chain
# fixture without LLM involvement.
# ---------------------------------------------------------------------------

@test "integration: cluster-7-chain smoke — Step 1 + Step 10 + Step 11 scripts all invokable" {
  local fixture_src dev_scripts plugin_scripts
  fixture_src="$(cd "$BATS_TEST_DIRNAME/../../../tests/fixtures/cluster-7-chain" && pwd)"
  dev_scripts="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-dev-story/scripts" && pwd)"
  plugin_scripts="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  [ -d "$fixture_src" ]
  [ -x "$dev_scripts/story-parse.sh" ]
  [ -x "$dev_scripts/detect-mode.sh" ]
  [ -x "$dev_scripts/check-deps.sh" ]
  [ -x "$dev_scripts/commit-msg.sh" ]
  [ -x "$dev_scripts/pr-body.sh" ]
  [ -x "$plugin_scripts/promotion-chain-guard.sh" ] \
    || [ -x "$dev_scripts/promotion-chain-guard.sh" ]

  cp -R "$fixture_src/." "$TEST_TMP/cluster-7-chain/"
  mkdir -p "$TEST_TMP/cluster-7-chain/docs/implementation-artifacts"
  cd "$TEST_TMP/cluster-7-chain"

  # Smoke fixture: a `done` parent dependency and an `in-progress` child story
  # whose key matches the path-traversal regex enforced by story-parse.sh.
  cat > "docs/implementation-artifacts/E99-S1-fixture-parent.md" <<'EOF'
---
template: 'story'
key: "E99-S1"
title: "Fixture parent"
status: done
depends_on: []
---

# Story: Fixture parent

## Acceptance Criteria

- [x] AC1: parent done

## Definition of Done

- [x] All acceptance criteria verified and checked off
EOF

  cat > "docs/implementation-artifacts/E99-S2-fixture-child.md" <<'EOF'
---
template: 'story'
key: "E99-S2"
type: feat
title: "Fixture child"
status: in-progress
depends_on: ["E99-S1"]
risk_level: low
---

# Story: Fixture child

## Acceptance Criteria

- [x] AC1: child wired through Step 1, Step 10, Step 11
- [x] AC2: scripts emit deterministic stdout

## Definition of Done

- [x] All acceptance criteria verified and checked off
- [x] All tests pass
EOF

  local child_path="$TEST_TMP/cluster-7-chain/docs/implementation-artifacts/E99-S2-fixture-child.md"

  # ----- Step 1 wiring -----
  # story-parse.sh: emits eval-able key=val pairs covering frontmatter.
  run "$dev_scripts/story-parse.sh" "$child_path"
  [ "$status" -eq 0 ]
  grep -Eq "^STORY_KEY='E99-S2'$" <<<"$output"
  grep -Eq "^STATUS='in-progress'$" <<<"$output"

  # detect-mode.sh: in-progress -> RESUME or REWORK; either is acceptable for
  # AC4 smoke — the contract is "exit 0 + a known mode token on stdout".
  run "$dev_scripts/detect-mode.sh" "$child_path"
  [ "$status" -eq 0 ]
  grep -Eq '^(FRESH|RESUME|REWORK)$' <<<"$output"

  # check-deps.sh: parent is done, so exit 0 with empty stderr.
  run --separate-stderr "$dev_scripts/check-deps.sh" "$child_path"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]

  # ----- Step 10 wiring -----
  # commit-msg.sh: emits a Conventional Commit line with the story key.
  run "$dev_scripts/commit-msg.sh" "$child_path"
  [ "$status" -eq 0 ]
  grep -Eq '\(E99-S2\)' <<<"$output"

  # ----- Step 11 wiring -----
  # pr-body.sh: emits the four canonical Markdown sections.
  run "$dev_scripts/pr-body.sh" "$child_path"
  [ "$status" -eq 0 ]
  grep -Fq 'Acceptance Criteria' <<<"$output"
  grep -Fq 'Definition of Done' <<<"$output"
}
