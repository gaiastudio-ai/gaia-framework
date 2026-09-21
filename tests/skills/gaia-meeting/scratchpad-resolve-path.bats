#!/usr/bin/env bats
# scratchpad-resolve-path.bats — gaia-meeting deterministic path resolver (E76-S4)
#
# AC5 / AC6 / AC11 / AC12. Exercises TC-MTG-SP-3 + path component of TC-MTG-SP-6.
#
# Resolves the deterministic extraction path from
#   (date, slug, sp_n, content, intent, content_type)
# Path formula:
#   docs/creative-artifacts/meeting-scratchpad/{YYYY-MM}/{slug}/SP-{N}-{auto-slug}.{ext}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/scratchpad-resolve-path.sh"
}

@test "Pre-flight: scratchpad-resolve-path.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "the resolved path uses the year-month, slug and slot-id layout" {
  run "$HELPER" \
    --date 2026-05-05 \
    --slug my-meeting \
    --sp-n SP-1 \
    --content "Adopt JWT refresh tokens" \
    --intent "decision" \
    --content-type md
  [ "$status" -eq 0 ]
  [ "$output" = "docs/creative-artifacts/meeting-scratchpad/2026-05/my-meeting/SP-1-adopt-jwt-refresh-tokens.md" ]
}

@test "the auto-slug comes from the first text line, lowercased, dashed and truncated to 40 characters" {
  run "$HELPER" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-2 \
    --content "This is a Reasonably Long First Line With Many Words That Should Be Truncated" \
    --intent "x" \
    --content-type md
  [ "$status" -eq 0 ]
  # The slug portion (between SP-2- and .md) MUST be <= 40 chars
  fname="${output##*/}"
  slug_part="${fname#SP-2-}"
  slug_part="${slug_part%.md}"
  [ "${#slug_part}" -le 40 ]
}

@test "non-textual content falls back to a slug derived from the intent" {
  # Content is a JSON snippet (non-textual first line), so auto-slug derives from intent.
  run "$HELPER" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-1 \
    --content "{\"k\":1}" \
    --intent "Pin auth token shape for downstream" \
    --content-type json
  [ "$status" -eq 0 ]
  [[ "$output" == *"SP-1-pin-auth-token-shape-for-downstream.json" ]]
}

@test "empty content and empty intent produce the slug untitled" {
  run "$HELPER" \
    --date 2026-05-05 \
    --slug fixture \
    --sp-n SP-3 \
    --content "" \
    --intent "" \
    --content-type md
  [ "$status" -eq 0 ]
  [[ "$output" == *"SP-3-untitled.md" ]]
}

@test "the json content type drives the file extension" {
  run "$HELPER" \
    --date 2026-05-05 --slug s --sp-n SP-1 \
    --content '{"k":1}' --intent "shape" --content-type json
  [[ "$output" == *.json ]]
}

@test "the ts content type drives the file extension" {
  run "$HELPER" \
    --date 2026-05-05 --slug s --sp-n SP-1 \
    --content "interface X {}" --intent "iface" --content-type ts
  [[ "$output" == *.ts ]]
}

@test "different slugs produce distinct paths for the same slot" {
  out_a="$("$HELPER" --date 2026-05-05 --slug meeting-a --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  out_b="$("$HELPER" --date 2026-05-05 --slug meeting-b --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  [ "$out_a" != "$out_b" ]
  [[ "$out_a" == *"/meeting-a/"* ]]
  [[ "$out_b" == *"/meeting-b/"* ]]
}

@test "a different year-month produces a distinct path for the same slug and slot" {
  out_a="$("$HELPER" --date 2026-05-05 --slug s --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  out_b="$("$HELPER" --date 2026-06-01 --slug s --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  [ "$out_a" != "$out_b" ]
  [[ "$out_a" == *"/2026-05/"* ]]
  [[ "$out_b" == *"/2026-06/"* ]]
}

@test "a non-canonical slot id is rejected" {
  run "$HELPER" --date 2026-05-05 --slug s --sp-n "X-1" --content "c" --intent "i" --content-type md
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "a malformed date is rejected" {
  run "$HELPER" --date "2026/05/05" --slug s --sp-n SP-1 --content "c" --intent "i" --content-type md
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
