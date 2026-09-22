#!/usr/bin/env bats
# scratchpad-extractor.bats — gaia-meeting extracted-file writer
#
# Covers frontmatter linkage, replace-at-same-path, cross-meeting path
# independence, lazy directory creation, and the write boundary.
#
# Every expected output location is obtained from scratchpad-resolve-path.sh —
# the same resolver the extractor calls — so a move of the artifacts tree is
# picked up here automatically instead of re-breaking these cases.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/scratchpad-extractor.sh"
  RESOLVER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/scratchpad-resolve-path.sh"
  TMPDIR_T="$(mktemp -d)"
  ROOT_T="$TMPDIR_T/root"
  mkdir -p "$ROOT_T"
}

# _expect_path — ask the SAME resolver the extractor asks where an extraction
# lands, then prefix the fixture root exactly as the extractor does. Asserting
# through the production resolver rather than a second literal keeps these
# cases correct across a tree move.
#
# Args: <date> <slug> <sp-n> <content> <intent> <content-type>
_expect_path() {
  local rel
  rel="$(env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH "$RESOLVER" \
    --date "$1" --slug "$2" --sp-n "$3" \
    --content "$4" --intent "$5" --content-type "$6")"
  printf '%s/%s\n' "$ROOT_T" "$rel"
}

# _expect_dir — the meeting-scratchpad directory for a given year-month + slug,
# derived from a resolved path so the layout stays single-sourced.
_expect_dir() {
  dirname "$(_expect_path "$@")"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "Pre-flight: scratchpad-extractor.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "extraction writes to a deterministic path with full frontmatter" {
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
  out="$(_expect_path 2026-05-05 my-meeting SP-1 "Adopt JWT refresh tokens" "decision" md)"
  [ -f "$out" ]
  grep -qE '^source_meeting: meeting-2026-05-05-my-meeting\.md' "$out"
  grep -qE '^source_scratchpad_id: SP-1' "$out"
  grep -qE '^source_action_items: \[AI-2026-05-05-1, AI-2026-05-05-2\]' "$out"
  grep -qE '^extracted_by: gaia-meeting' "$out"
  grep -qE '^extracted_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$out"
  grep -qE '^content_type: md' "$out"
}

@test "an empty action-items list renders as an empty array" {
  "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content "x" \
    --intent "i" \
    --pinning-agent "alpha" \
    --action-items ""
  out="$(_expect_path 2026-05-05 fixture SP-1 "x" "i" md)"
  grep -qE '^source_action_items: \[\]' "$out"
}

@test "JSON content gets a .json extension and a json content type" {
  "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content '{"k":1}' \
    --intent "shape token payload" \
    --pinning-agent "alpha" \
    --action-items ""
  out="$(_expect_path 2026-05-05 fixture SP-1 '{"k":1}' "shape token payload" json)"
  [ -f "$out" ]
  grep -qE '^content_type: json' "$out"
}

@test "re-extracting overwrites the same path in place and advances the extraction timestamp" {
  "$HELPER" \
    --root "$ROOT_T" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content "v1" \
    --intent "i" \
    --pinning-agent "alpha" \
    --action-items ""
  out="$(_expect_path 2026-05-05 fixture SP-1 "v1" "i" md)"
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
  count="$(find "$(_expect_dir 2026-05-05 fixture SP-1 "v1" "i" md)" -type f | wc -l | tr -d ' ')"
  [ "$count" = "1" ]
}

@test "independent meetings produce distinct extraction paths" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug meeting-a --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug meeting-b --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  a="$(_expect_path 2026-05-05 meeting-a SP-1 "x" "i" md)"
  b="$(_expect_path 2026-05-05 meeting-b SP-1 "x" "i" md)"
  [ "$a" != "$b" ]
  [ -f "$a" ]
  [ -f "$b" ]
}

@test "directories are created lazily with no placeholder files" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  slug_dir="$(_expect_dir 2026-05-05 fixture SP-1 "x" "i" md)"
  month_dir="$(dirname "$slug_dir")"
  scratchpad_dir="$(dirname "$month_dir")"
  # The directories must exist (otherwise the placeholder assertions below are
  # vacuous) and must carry no placeholder file at any level.
  [ -d "$slug_dir" ]
  [ ! -f "$scratchpad_dir/.gitkeep" ]
  [ ! -f "$month_dir/.gitkeep" ]
  [ ! -f "$slug_dir/.gitkeep" ]
}

@test "re-extraction works after empty directories have been pruned" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  out="$(_expect_path 2026-05-05 fixture SP-1 "x" "i" md)"
  slug_dir="$(dirname "$out")"
  scratchpad_dir="$(dirname "$(dirname "$slug_dir")")"
  [ -f "$out" ]
  rm -rf "$slug_dir"
  # Now prune any empty parent
  find "$scratchpad_dir" -type d -empty -delete
  [ ! -d "$slug_dir" ]
  # Re-extract — must transparently re-create directories
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  [ -f "$out" ]
}

@test "the content body is emitted after the frontmatter so the file stays human-readable" {
  "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug fixture --sp-n SP-1 --content "interesting body content" --intent "i" --pinning-agent "a" --action-items ""
  out="$(_expect_path 2026-05-05 fixture SP-1 "interesting body content" "i" md)"
  grep -q "interesting body content" "$out"
}

@test "an attempt to write outside the meeting-scratchpad directory is rejected" {
  # The extractor MUST refuse to honor a forged --root that escapes (defense-in-depth)
  run "$HELPER" --root "$ROOT_T" --date 2026-05-05 --slug "../escape" --sp-n SP-1 --content "x" --intent "i" --pinning-agent "a" --action-items ""
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
