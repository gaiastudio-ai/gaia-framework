#!/usr/bin/env bats
# scratchpad-extractor.bats — gaia-meeting extracted-file writer (E76-S4)
#
# AC8 (frontmatter linkage), AC10 (replace-at-same-path), AC11 (cross-meeting
# never collide), AC12 (lazy directory creation), AC14 (state-free write
# boundary). Exercises TC-MTG-SP-5 + TC-MTG-SP-6.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/scratchpad-extractor.sh"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "Pre-flight: scratchpad-extractor.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "AC5 + AC8 (TC-MTG-SP-3 + TC-MTG-SP-5): writes to deterministic path with full frontmatter" {
  run "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug my-meeting \
    --sp-n SP-1 \
    --content "Adopt JWT refresh tokens" \
    --intent "decision" \
    --pinning-agent "alpha" \
    --action-items "AI-2026-05-05-1,AI-2026-05-05-2"
  [ "$status" -eq 0 ]
  out="$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/my-meeting/SP-1-adopt-jwt-refresh-tokens.md"
  [ -f "$out" ]
  grep -qE '^source_meeting: meeting-2026-05-05-my-meeting\.md' "$out"
  grep -qE '^source_scratchpad_id: SP-1' "$out"
  grep -qE '^source_action_items: \[AI-2026-05-05-1, AI-2026-05-05-2\]' "$out"
  grep -qE '^extracted_by: gaia-meeting' "$out"
  grep -qE '^extracted_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$out"
  grep -qE '^content_type: md' "$out"
}

@test "AC8: empty action_items renders as []" {
  "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content "x" \
    --intent "i" \
    --pinning-agent "alpha" \
    --action-items ""
  out="$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture/SP-1-x.md"
  grep -qE '^source_action_items: \[\]' "$out"
}

@test "AC7: JSON content gets .json extension and content_type: json" {
  "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content '{"k":1}' \
    --intent "shape token payload" \
    --pinning-agent "alpha" \
    --action-items ""
  out="$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture/SP-1-shape-token-payload.json"
  [ -f "$out" ]
  grep -qE '^content_type: json' "$out"
}

@test "AC10 (TC-MTG-SP-6): replace-at-same-path — re-extract overwrites in place + advances extracted_at" {
  "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content "v1" \
    --intent "i" \
    --pinning-agent "alpha" \
    --action-items ""
  out="$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture/SP-1-v1.md"
  [ -f "$out" ]
  ts1="$(grep -E '^extracted_at:' "$out" | head -1)"

  # Sleep one second to ensure a new ISO-8601 second-precision timestamp
  sleep 1

  "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content "v1" \
    --intent "i" \
    --pinning-agent "alpha" \
    --action-items ""
  ts2="$(grep -E '^extracted_at:' "$out" | head -1)"
  [ "$ts1" != "$ts2" ]

  # No duplicate or appended file
  count="$(find "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture" -type f | wc -l | tr -d ' ')"
  [ "$count" = "1" ]
}

@test "AC11 (TC-MTG-SP-6): independent meetings produce distinct paths" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug meeting-a --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug meeting-b --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  [ -f "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/meeting-a/SP-1-x.md" ]
  [ -f "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/meeting-b/SP-1-x.md" ]
}

@test "AC12: directories are created lazily (no .gitkeep placeholders)" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  [ ! -f "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/.gitkeep" ]
  [ ! -f "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/.gitkeep" ]
  [ ! -f "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture/.gitkeep" ]
}

@test "AC12: empty-bucket pruning compatibility — find -type d -empty -delete + re-extract works" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  rm -rf "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture"
  # Now prune any empty parent
  find "$ROOT_T/docs/creative-artifacts/meeting-scratchpad" -type d -empty -delete
  # Re-extract — must transparently re-create directories
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  [ -f "$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture/SP-1-x.md" ]
}

@test "AC14: emits content body after frontmatter so the file is human-readable" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "interesting body content" --intent "i" --pinning-agent "a" --action-items ""
  out="$ROOT_T/docs/creative-artifacts/meeting-scratchpad/2026-05/fixture/SP-1-interesting-body-content.md"
  grep -q "interesting body content" "$out"
}

@test "AC14: rejects an attempt to write outside docs/creative-artifacts/meeting-scratchpad/" {
  # The extractor MUST refuse to honor a forged --root that escapes (defense-in-depth)
  run "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug "../escape" --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
