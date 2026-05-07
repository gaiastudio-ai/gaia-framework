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

@test "AC5 (TC-MTG-SP-3): path uses YYYY-MM/slug/SP-N format" {
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

@test "AC6: auto-slug from textual first line, lowercased + dashed + truncated to 40 chars" {
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

@test "AC6: non-textual content falls back to intent-derived slug" {
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

@test "AC6: empty content + empty intent -> auto-slug 'untitled'" {
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

@test "AC7: content-type drives extension (json)" {
  run "$HELPER" \
    --date 2026-05-05 --slug s --sp-n SP-1 \
    --content '{"k":1}' --intent "shape" --content-type json
  [[ "$output" == *.json ]]
}

@test "AC7: content-type drives extension (ts)" {
  run "$HELPER" \
    --date 2026-05-05 --slug s --sp-n SP-1 \
    --content "interface X {}" --intent "iface" --content-type ts
  [[ "$output" == *.ts ]]
}

@test "AC11 (TC-MTG-SP-6): different slugs produce distinct paths for same SP-N" {
  out_a="$("$HELPER" --date 2026-05-05 --slug meeting-a --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  out_b="$("$HELPER" --date 2026-05-05 --slug meeting-b --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  [ "$out_a" != "$out_b" ]
  [[ "$out_a" == *"/meeting-a/"* ]]
  [[ "$out_b" == *"/meeting-b/"* ]]
}

@test "AC11: different YYYY-MM produces distinct paths for same slug + SP-N" {
  out_a="$("$HELPER" --date 2026-05-05 --slug s --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  out_b="$("$HELPER" --date 2026-06-01 --slug s --sp-n SP-1 --content "x" --intent "i" --content-type md)"
  [ "$out_a" != "$out_b" ]
  [[ "$out_a" == *"/2026-05/"* ]]
  [[ "$out_b" == *"/2026-06/"* ]]
}

@test "AC5: rejects non-canonical SP-N format" {
  run "$HELPER" --date 2026-05-05 --slug s --sp-n "X-1" --content "c" --intent "i" --content-type md
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC5: rejects malformed date" {
  run "$HELPER" --date "2026/05/05" --slug s --sp-n SP-1 --content "c" --intent "i" --content-type md
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}
