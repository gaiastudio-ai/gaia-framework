#!/usr/bin/env bats
# build-manifest-cards.bats — tests for the manifest card builder and
# last-published persistence helper in gaia-create-ux.
#
# Every test must FAIL on a missing or broken script, never skip.
# No project-root .gaia/ access; all fixtures use mktemp.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

SKILL_SCRIPTS="$BATS_TEST_DIRNAME/../skills/gaia-create-ux/scripts"
TARGET_SCRIPT="$SKILL_SCRIPTS/build-manifest-cards.sh"
PLANNER_SCRIPT="$SKILL_SCRIPTS/plan-publication.sh"

setup() {
  common_setup
  unset PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT
}

teardown() { common_teardown; }

# ===========================================================================
# Helpers
# ===========================================================================

fail() { printf 'FAIL: %s\n' "$1" >&2; return 1; }

# _seed_spec_tree DIR — create a local-specs tree with annotated spec files.
# Seeds 3 screen specs + 2 component specs (all annotated) + tokens.json.
_seed_spec_tree() {
  local dir="$1"
  mkdir -p "$dir/screens" "$dir/components"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$dir/screens/login.spec.html"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Dashboard</html>\n' > "$dir/screens/dashboard.spec.html"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Settings</html>\n' > "$dir/screens/settings.spec.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$dir/components/button.spec.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Card</html>\n' > "$dir/components/card.spec.html"
  printf '{"tokens":true}\n' > "$dir/tokens.json"
}

# _seed_existing_manifest FILE EXTRA_CARDS — write a _ds_manifest.json with
# Colors + Type cards, plus any extra cards passed as JSON array elements.
_seed_existing_manifest() {
  local file="$1"
  local extra="${2:-}"
  local cards='[{"path":"colors.json","group":"Colors"},{"path":"type.json","group":"Type"}'
  if [ -n "$extra" ]; then
    cards="${cards},${extra}"
  fi
  cards="${cards}]"
  printf '{"cards":%s}\n' "$cards" > "$file"
}

# _run_persist — run persist_last_published with standard fixture paths.
# Expects outcomes at $TEST_TMP/outcomes.json, hash map at
# $TEST_TMP/hash-map.json, and writes to $TEST_TMP/last-published.json.
# Prior defaults to /dev/null; pass an arg to override.
_run_persist() {
  local prior="${1:-/dev/null}"
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$prior' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json'
  "
}

# ===========================================================================
# Public function coverage gate
# ===========================================================================

@test "(AC1) build_manifest_cards is a public function in build-manifest-cards.sh" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  # Source the script in a subshell and check the function is defined
  local func_check
  func_check="$(bash -c "source '$TARGET_SCRIPT' && declare -F build_manifest_cards" 2>&1)" \
    || fail "build_manifest_cards not defined after sourcing"
  [ -n "$func_check" ] || fail "build_manifest_cards not found via declare -F"
}

@test "(AC2) persist_last_published is a public function in build-manifest-cards.sh" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  local func_check
  func_check="$(bash -c "source '$TARGET_SCRIPT' && declare -F persist_last_published" 2>&1)" \
    || fail "persist_last_published not defined after sourcing"
  [ -n "$func_check" ] || fail "persist_last_published not found via declare -F"
}

# ===========================================================================
# build_manifest_cards tests
# ===========================================================================

@test "(AC1) build_manifest_cards merges spec cards with existing Colors and Type" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_spec_tree "$TEST_TMP/specs"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # Must have 7 cards total: 3 screen + 2 component + Colors + Type
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 7 ] || fail "expected 7 cards, got $card_count"

  # Verify Colors and Type are preserved
  printf '%s' "$result" | jq -e '.cards[] | select(.group == "Colors")' >/dev/null \
    || fail "Colors card missing"
  printf '%s' "$result" | jq -e '.cards[] | select(.group == "Type")' >/dev/null \
    || fail "Type card missing"

  # Verify screen and component specs are present
  local screen_count component_count
  screen_count="$(printf '%s' "$result" | jq '[.cards[] | select(.group == "Screen specs")] | length')"
  component_count="$(printf '%s' "$result" | jq '[.cards[] | select(.group == "Component specs")] | length')"
  [ "$screen_count" -eq 3 ] || fail "expected 3 screen specs, got $screen_count"
  [ "$component_count" -eq 2 ] || fail "expected 2 component specs, got $component_count"
}

@test "(AC-EC2) orphan framework cards dropped from manifest" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  # Seed only 2 screen specs (login + dashboard), but existing manifest has
  # a framework-owned card for settings.spec.html from a prior publish
  mkdir -p "$TEST_TMP/specs/screens" "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Dashboard</html>\n' > "$TEST_TMP/specs/screens/dashboard.spec.html"

  # Existing manifest has Colors + Type + the orphan screen
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json" \
    '{"path":"screens/settings.spec.html","group":"Screen specs"}'

  # Prior published set includes settings.spec.html (so it is framework-owned)
  printf '[{"file":"screens/settings.spec.html","hash":"abc123"}]\n' > "$TEST_TMP/prior.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published '$TEST_TMP/prior.json'
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # settings.spec.html must be absent (orphan framework card)
  local orphan_hit
  orphan_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "screens/settings.spec.html")] | length')"
  [ "$orphan_hit" -eq 0 ] || fail "orphan framework card not dropped"
}

@test "(AC-EC3) corrupted existing manifest replaced, not halted" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_spec_tree "$TEST_TMP/specs"
  printf '{invalid json garbage' > "$TEST_TMP/corrupted.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/corrupted.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards halted on corrupt manifest"

  # Output must be valid JSON
  printf '%s' "$result" | jq '.' >/dev/null || fail "output is not valid JSON"

  # Must have the 5 local spec cards
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -ge 5 ] || fail "expected at least 5 cards from local specs, got $card_count"
}

@test "(AC-EC4) spec file without dsCard annotation excluded with diagnostic" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/screens"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"
  # This spec has NO annotation
  printf '<html>No annotation here</html>\n' > "$TEST_TMP/specs/screens/broken.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>&1 1>"$TEST_TMP/bmc-stdout.txt")" || true
  result="$(cat "$TEST_TMP/bmc-stdout.txt")"

  # broken.spec.html must NOT be in the cards
  local broken_hit
  broken_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("broken"))] | length')"
  [ "$broken_hit" -eq 0 ] || fail "unannotated spec should be excluded"

  # login.spec.html MUST be in the cards
  local login_hit
  login_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("login"))] | length')"
  [ "$login_hit" -eq 1 ] || fail "annotated spec should be included"

  # stderr must name the broken file
  printf '%s' "$stderr_out" | grep -qF 'broken.spec.html' || fail "diagnostic should name broken.spec.html"
}

@test "(AC-EC6) non-framework cards preserved verbatim" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_spec_tree "$TEST_TMP/specs"
  # Existing manifest: Colors + Type + a designer-registered card
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json" \
    '{"path":"designer-custom.json","group":"Custom Design"}'

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # All three non-framework cards must be preserved
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "colors.json")' >/dev/null \
    || fail "Colors card missing"
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "type.json")' >/dev/null \
    || fail "Type card missing"
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "designer-custom.json")' >/dev/null \
    || fail "designer-registered card missing"
  printf '%s' "$result" | jq -e '.cards[] | select(.group == "Custom Design")' >/dev/null \
    || fail "designer card group changed"
}

# ===========================================================================
# persist_last_published tests
# ===========================================================================

@test "(AC2) persist_last_published writes 6-entry manifest after publication" {
  local outcomes_json='[
    {"file":"screens/login.spec.html","outcome":"written","hash":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"},
    {"file":"screens/dashboard.spec.html","outcome":"written","hash":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"},
    {"file":"screens/settings.spec.html","outcome":"written","hash":"cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"},
    {"file":"components/button.spec.html","outcome":"written","hash":"dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444"},
    {"file":"components/card.spec.html","outcome":"written","hash":"eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555"},
    {"file":"tokens.json","outcome":"skipped","hash":"ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666"}
  ]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  local hash_map='{"screens/login.spec.html":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111","screens/dashboard.spec.html":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222","screens/settings.spec.html":"cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333","components/button.spec.html":"dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444","components/card.spec.html":"eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555","tokens.json":"ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666"}'
  printf '%s\n' "$hash_map" > "$TEST_TMP/hash-map.json"

  _run_persist || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"
  local entry_count
  entry_count="$(jq 'length' "$TEST_TMP/last-published.json")"
  [ "$entry_count" -eq 6 ] || fail "expected 6 entries, got $entry_count"

  # All hashes must be 64-hex
  local bad_hash_count
  bad_hash_count="$(jq '[.[] | select(.hash | test("^[0-9a-f]{64}$") | not)] | length' "$TEST_TMP/last-published.json")"
  [ "$bad_hash_count" -eq 0 ] || fail "found $bad_hash_count non-64-hex hashes"
}

@test "(AC-EC5) first publication with /dev/null prior writes full set" {
  local outcomes_json='[
    {"file":"screens/login.spec.html","outcome":"written","hash":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"},
    {"file":"screens/dashboard.spec.html","outcome":"written","hash":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"},
    {"file":"screens/settings.spec.html","outcome":"written","hash":"cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"},
    {"file":"components/button.spec.html","outcome":"written","hash":"dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444"},
    {"file":"components/card.spec.html","outcome":"written","hash":"eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555"},
    {"file":"tokens.json","outcome":"skipped","hash":"ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666"}
  ]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  local hash_map='{"screens/login.spec.html":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111","screens/dashboard.spec.html":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222","screens/settings.spec.html":"cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333","components/button.spec.html":"dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444","components/card.spec.html":"eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555eeee5555","tokens.json":"ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666ffff6666"}'
  printf '%s\n' "$hash_map" > "$TEST_TMP/hash-map.json"

  _run_persist || fail "persist_last_published failed on first publish"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"
  local entry_count
  entry_count="$(jq 'length' "$TEST_TMP/last-published.json")"
  [ "$entry_count" -eq 6 ] || fail "expected 6 entries, got $entry_count"
}

@test "(AC-EC7) kept-designer stores framework local hash, not designer hash" {
  local outcomes_json='[{"file":"screens/login.spec.html","outcome":"kept-designer","hash":"designer_aabbccdd_designer_aabbccdd_designer_aabbccdd_aabbccdd"}]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  local hash_map='{"screens/login.spec.html":"framework_11223344_framework_11223344_framework_11223344_11223344"}'
  printf '%s\n' "$hash_map" > "$TEST_TMP/hash-map.json"

  _run_persist || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"

  local persisted_hash
  persisted_hash="$(jq -r '.[] | select(.file == "screens/login.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$persisted_hash" = "framework_11223344_framework_11223344_framework_11223344_11223344" ] \
    || fail "kept-designer should store framework local hash, got '$persisted_hash'"
}

@test "(AC-EC7) merged stores framework local hash" {
  local outcomes_json='[{"file":"screens/login.spec.html","outcome":"merged","hash":"merged_result_hash_merged_result_hash_merged_result_hash_merged_r"}]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  local hash_map='{"screens/login.spec.html":"framework_local_hash_framework_local_hash_framework_local_hash_f"}'
  printf '%s\n' "$hash_map" > "$TEST_TMP/hash-map.json"

  _run_persist || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"

  local persisted_hash
  persisted_hash="$(jq -r '.[] | select(.file == "screens/login.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$persisted_hash" = "framework_local_hash_framework_local_hash_framework_local_hash_f" ] \
    || fail "merged should store framework local hash, got '$persisted_hash'"
}

@test "(AC-EC7) failed with prior carries prior hash forward" {
  local outcomes_json='[{"file":"screens/broken.spec.html","outcome":"failed","hash":"irrelevant_hash_irrelevant_hash_irrelevant_hash_irrelevant_hash"}]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  printf '[{"file":"screens/broken.spec.html","hash":"prior_hash_1234_prior_hash_1234_prior_hash_1234_prior_hash_1234"}]\n' \
    > "$TEST_TMP/prior.json"

  printf '{}\n' > "$TEST_TMP/hash-map.json"

  _run_persist "$TEST_TMP/prior.json" || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"

  local persisted_hash
  persisted_hash="$(jq -r '.[] | select(.file == "screens/broken.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$persisted_hash" = "prior_hash_1234_prior_hash_1234_prior_hash_1234_prior_hash_1234" ] \
    || fail "failed with prior should carry prior hash forward, got '$persisted_hash'"
}

@test "(AC-EC7) failed with no prior is omitted" {
  local outcomes_json='[{"file":"screens/broken.spec.html","outcome":"failed","hash":"irrelevant"}]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  printf '{}\n' > "$TEST_TMP/hash-map.json"

  _run_persist || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"

  local entry_count
  entry_count="$(jq '[.[] | select(.file == "screens/broken.spec.html")] | length' "$TEST_TMP/last-published.json")"
  [ "$entry_count" -eq 0 ] || fail "failed with no prior should be omitted, found $entry_count entries"
}

@test "(AC-EC7) deleted entry removed from output" {
  local outcomes_json='[{"file":"screens/old.spec.html","outcome":"deleted","hash":"irrelevant"}]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  printf '[{"file":"screens/old.spec.html","hash":"prior_hash"}]\n' > "$TEST_TMP/prior.json"
  printf '{}\n' > "$TEST_TMP/hash-map.json"

  _run_persist "$TEST_TMP/prior.json" || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"

  local entry_count
  entry_count="$(jq '[.[] | select(.file == "screens/old.spec.html")] | length' "$TEST_TMP/last-published.json")"
  [ "$entry_count" -eq 0 ] || fail "deleted entry should be removed, found $entry_count entries"
}

@test "(AC-EC7) delete-failed keeps prior entry" {
  local outcomes_json='[{"file":"screens/orphan.spec.html","outcome":"delete-failed","hash":"irrelevant"}]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  printf '[{"file":"screens/orphan.spec.html","hash":"prior_orphan_hash_prior_orphan_hash_prior_orphan_hash_prior_or"}]\n' \
    > "$TEST_TMP/prior.json"
  printf '{}\n' > "$TEST_TMP/hash-map.json"

  _run_persist "$TEST_TMP/prior.json" || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"

  local persisted_hash
  persisted_hash="$(jq -r '.[] | select(.file == "screens/orphan.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$persisted_hash" = "prior_orphan_hash_prior_orphan_hash_prior_orphan_hash_prior_or" ] \
    || fail "delete-failed should keep prior hash, got '$persisted_hash'"
}

@test "(AC-EC7) mixed outcomes persisted correctly" {
  local outcomes_json='[
    {"file":"screens/login.spec.html","outcome":"written","hash":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"},
    {"file":"screens/dashboard.spec.html","outcome":"written","hash":"bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"},
    {"file":"components/button.spec.html","outcome":"merged","hash":"merged_junk_merged_junk_merged_junk_merged_junk_merged_junk_merg"},
    {"file":"components/card.spec.html","outcome":"kept-designer","hash":"designer_junk_designer_junk_designer_junk_designer_junk_designer"},
    {"file":"screens/broken.spec.html","outcome":"failed","hash":"failed_junk_failed_junk_failed_junk_failed_junk_failed_junk_fail"}
  ]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  printf '[{"file":"screens/broken.spec.html","hash":"prior_broken_hash_prior_broken_hash_prior_broken_hash_prior_br"}]\n' \
    > "$TEST_TMP/prior.json"

  local hash_map='{"components/button.spec.html":"fw_local_button_fw_local_button_fw_local_button_fw_local_button_","components/card.spec.html":"fw_local_card_1_fw_local_card_1_fw_local_card_1_fw_local_card_1_"}'
  printf '%s\n' "$hash_map" > "$TEST_TMP/hash-map.json"

  _run_persist "$TEST_TMP/prior.json" || fail "persist_last_published failed"

  [ -f "$TEST_TMP/last-published.json" ] || fail "output file not created"

  # 5 entries: 2 written + 1 merged + 1 kept-designer + 1 failed-with-prior
  local entry_count
  entry_count="$(jq 'length' "$TEST_TMP/last-published.json")"
  [ "$entry_count" -eq 5 ] || fail "expected 5 entries, got $entry_count"

  # written entries carry their outcome hash
  local login_hash dashboard_hash
  login_hash="$(jq -r '.[] | select(.file == "screens/login.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  dashboard_hash="$(jq -r '.[] | select(.file == "screens/dashboard.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$login_hash" = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111" ] || fail "written login hash wrong"
  [ "$dashboard_hash" = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222" ] || fail "written dashboard hash wrong"

  # merged and kept-designer carry the framework local hash
  local button_hash card_hash
  button_hash="$(jq -r '.[] | select(.file == "components/button.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  card_hash="$(jq -r '.[] | select(.file == "components/card.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$button_hash" = "fw_local_button_fw_local_button_fw_local_button_fw_local_button_" ] || fail "merged hash should be framework local"
  [ "$card_hash" = "fw_local_card_1_fw_local_card_1_fw_local_card_1_fw_local_card_1_" ] || fail "kept-designer hash should be framework local"

  # failed-with-prior carries the prior hash
  local broken_hash
  broken_hash="$(jq -r '.[] | select(.file == "screens/broken.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$broken_hash" = "prior_broken_hash_prior_broken_hash_prior_broken_hash_prior_br" ] || fail "failed hash should be prior"
}

@test "(AC3) orphan detection uses persisted manifest from prior run" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"
  # Local set: 5 files. Prior manifest had 6 (one file removed).
  printf '[{"file":"screens/login.spec.html","hash":"aaa"},{"file":"screens/dashboard.spec.html","hash":"bbb"},{"file":"screens/settings.spec.html","hash":"ccc"},{"file":"components/button.spec.html","hash":"ddd"},{"file":"tokens.json","hash":"eee"}]\n' \
    > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"screens/login.spec.html","hash":"aaa"},{"file":"screens/dashboard.spec.html","hash":"bbb"},{"file":"screens/settings.spec.html","hash":"ccc"},{"file":"components/button.spec.html","hash":"ddd"},{"file":"components/card.spec.html","hash":"fff"},{"file":"tokens.json","hash":"eee"}]\n' \
    > "$TEST_TMP/remote-listing.json"
  # Prior published had 6 entries including card.spec.html
  printf '[{"file":"screens/login.spec.html","hash":"aaa"},{"file":"screens/dashboard.spec.html","hash":"bbb"},{"file":"screens/settings.spec.html","hash":"ccc"},{"file":"components/button.spec.html","hash":"ddd"},{"file":"components/card.spec.html","hash":"fff"},{"file":"tokens.json","hash":"eee"}]\n' \
    > "$TEST_TMP/last-published.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$TEST_TMP/last-published.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DELETE_ORPHAN components/card.spec.html"* ]] \
    || fail "expected DELETE_ORPHAN for card.spec.html"
}

@test "(AC2) persist_last_published atomic write via tmp+mv" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  local outcomes_json='[{"file":"tokens.json","outcome":"written","hash":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"
  printf '{"tokens.json":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}\n' \
    > "$TEST_TMP/hash-map.json"

  # Uses a non-default output path to verify mkdir -p + tmp+mv
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/subdir/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json'
  " || fail "persist_last_published failed"

  # Output file must exist and parse as JSON
  [ -f "$TEST_TMP/subdir/last-published.json" ] || fail "output file not created"
  jq '.' "$TEST_TMP/subdir/last-published.json" >/dev/null || fail "output is not valid JSON"

  # No leftover temp files (mktemp creates random-suffix files, not just *.tmp)
  local extra_files
  extra_files="$(find "$TEST_TMP/subdir" -type f -not -name 'last-published.json' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$extra_files" -eq 0 ] || fail "leftover temp files found in output directory"
}

# ===========================================================================
# Round-trip: persist then re-plan
# ===========================================================================

@test "(AC3) kept-designer persisted hash triggers CONFLICT on re-plan" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  # Step 1: persist outcomes — one written, one kept-designer
  local outcomes_json='[
    {"file":"screens/login.spec.html","outcome":"written","hash":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"},
    {"file":"screens/dashboard.spec.html","outcome":"kept-designer","hash":"designer_version_hash_designer_version_hash_designer_version_hash"}
  ]'
  printf '%s\n' "$outcomes_json" > "$TEST_TMP/outcomes.json"

  local hash_map='{"screens/login.spec.html":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111","screens/dashboard.spec.html":"fw_local_dashboard_fw_local_dashboard_fw_local_dashboard_fw_loc"}'
  printf '%s\n' "$hash_map" > "$TEST_TMP/hash-map.json"

  _run_persist || fail "persist_last_published failed"
  [ -f "$TEST_TMP/last-published.json" ] || fail "last-published.json not created"

  # Step 2: re-plan with remote holding the designer hash for dashboard
  # and the written hash for login (unchanged)
  printf '[{"file":"screens/login.spec.html","hash":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"},{"file":"screens/dashboard.spec.html","hash":"fw_local_dashboard_fw_local_dashboard_fw_local_dashboard_fw_loc"}]\n' \
    > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"screens/login.spec.html","hash":"aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"},{"file":"screens/dashboard.spec.html","hash":"designer_version_hash_designer_version_hash_designer_version_hash"}]\n' \
    > "$TEST_TMP/remote-listing.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$TEST_TMP/last-published.json"
  [ "$status" -eq 0 ]

  # The kept-designer file must show CONFLICT (remote != last-published)
  [[ "$output" == *"CONFLICT screens/dashboard.spec.html"* ]] \
    || fail "expected CONFLICT for kept-designer file, got: $output"

  # The written file must show SKIP_UNCHANGED (hashes all match)
  [[ "$output" == *"SKIP_UNCHANGED screens/login.spec.html"* ]] \
    || fail "expected SKIP_UNCHANGED for written file, got: $output"
}

# ===========================================================================
# Exact-match membership (substring matching via inside() is a defect)
# ===========================================================================

@test "(AC-EC6) designer card whose path is a substring of a framework spec path is preserved" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/screens"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"

  # Existing manifest: Colors + designer cards with substring-matching paths
  printf '{"cards":[{"path":"colors.json","group":"Colors"},{"path":"login","group":"Designer Login"},{"path":"screens/login","group":"Designer Partial"},{"path":"spec.html","group":"Designer Suffix"}]}\n' \
    > "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # All three designer cards must be preserved (they are NOT framework-owned)
  local login_hit partial_hit suffix_hit
  login_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "login")] | length')"
  partial_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "screens/login")] | length')"
  suffix_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "spec.html")] | length')"
  [ "$login_hit" -eq 1 ] || fail "designer card 'login' was dropped (substring match bug)"
  [ "$partial_hit" -eq 1 ] || fail "designer card 'screens/login' was dropped (substring match bug)"
  [ "$suffix_hit" -eq 1 ] || fail "designer card 'spec.html' was dropped (substring match bug)"
}

@test "(AC-EC6) designer card with empty path is preserved" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/screens"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"

  # Existing manifest includes a card with an empty path
  printf '{"cards":[{"path":"","group":"Empty Path Card"},{"path":"colors.json","group":"Colors"}]}\n' \
    > "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  local empty_hit
  empty_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "")] | length')"
  [ "$empty_hit" -eq 1 ] || fail "card with empty path was dropped"
}

@test "(AC-EC6) prior-published entry with short path does not cause designer card to be dropped" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/screens"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"

  # Prior published has a short path that is a substring of the framework spec
  printf '[{"file":"login","hash":"aaa"}]\n' > "$TEST_TMP/prior.json"

  # Existing manifest: a designer card with path "login-notes.json"
  printf '{"cards":[{"path":"login-notes.json","group":"Designer Notes"},{"path":"colors.json","group":"Colors"}]}\n' \
    > "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published '$TEST_TMP/prior.json'
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  local notes_hit
  notes_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "login-notes.json")] | length')"
  [ "$notes_hit" -eq 1 ] || fail "designer card 'login-notes.json' was dropped by substring match on prior path 'login'"
}

@test "(AC-EC6) spec_paths filter includes only exact matches" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  # Two specs: one with a path that is a substring of the other
  mkdir -p "$TEST_TMP/specs/screens"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>A</html>\n' > "$TEST_TMP/specs/screens/a.spec.html"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>AB</html>\n' > "$TEST_TMP/specs/screens/ab.spec.html"

  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # Both must be present (exact match, not substring)
  local a_count ab_count
  a_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "screens/a.spec.html")] | length')"
  ab_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "screens/ab.spec.html")] | length')"
  [ "$a_count" -eq 1 ] || fail "screens/a.spec.html missing"
  [ "$ab_count" -eq 1 ] || fail "screens/ab.spec.html missing"
}

# ===========================================================================
# Scale test for build_manifest_cards
# ===========================================================================

@test "(AC1) build_manifest_cards handles 500 spec files under 10 seconds" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Generate 500 annotated spec files (250 screens + 250 components)
  mkdir -p "$TEST_TMP/specs/screens" "$TEST_TMP/specs/components"
  local i
  for i in $(seq 1 250); do
    printf '<!-- @dsCard group="Screen specs" -->\n<html>Screen %d</html>\n' "$i" \
      > "$TEST_TMP/specs/screens/screen-$(printf '%04d' "$i").spec.html"
  done
  for i in $(seq 1 250); do
    printf '<!-- @dsCard group="Component specs" -->\n<html>Component %d</html>\n' "$i" \
      > "$TEST_TMP/specs/components/component-$(printf '%04d' "$i").spec.html"
  done

  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local start_time end_time elapsed
  start_time="$(date +%s)"
  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards failed on 500 specs"
  end_time="$(date +%s)"

  elapsed=$((end_time - start_time))
  [ "$elapsed" -lt 10 ] || fail "500 specs took ${elapsed}s (expected < 10s)"

  # Verify output has 502 cards (500 spec + Colors + Type)
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 502 ] || fail "expected 502 cards, got $card_count"
}

# ===========================================================================
# Mutant: restoring inside() makes the substring test red
# ===========================================================================

@test "(AC-EC6) mutant restoring substring membership in the card builder is caught" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Copy the script into $TEST_TMP and patch the exact-match back to inside()
  local mutant="$TEST_TMP/build-manifest-cards-mutant.sh"
  sed 's/\.path as \$p | any(\$fw_owned\[\]; \. == \$p)/([.path] | inside($fw_owned))/' \
    "$TARGET_SCRIPT" > "$mutant"
  chmod +x "$mutant"

  # Assert the patch applied: the inside() line is present, the any() line is gone
  grep -qF 'inside($fw_owned)' "$mutant" \
    || fail "patch did not apply: inside(\$fw_owned) not found in mutant"
  if grep -qF 'any($fw_owned[]' "$mutant"; then
    fail "patch incomplete: any(\$fw_owned[]) still present in mutant"
  fi

  # Seed fixture: one framework spec, one designer card whose path is a substring
  mkdir -p "$TEST_TMP/specs/screens"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' \
    > "$TEST_TMP/specs/screens/login.spec.html"
  printf '{"cards":[{"path":"colors.json","group":"Colors"},{"path":"login","group":"Designer Login"}]}\n' \
    > "$TEST_TMP/existing-manifest.json"

  # Run against the MUTANT — the designer card "login" SHOULD be dropped
  # (because inside() treats "login" as a substring of "screens/login.spec.html")
  local mutant_result
  mutant_result="$(bash -c "
    source '$mutant'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "mutant build_manifest_cards failed"

  local mutant_login_hit
  mutant_login_hit="$(printf '%s' "$mutant_result" | jq '[.cards[] | select(.path == "login")] | length')"
  [ "$mutant_login_hit" -eq 0 ] \
    || fail "mutant should drop 'login' card via substring match, but it was preserved"

  # Run against the REAL script — the designer card "login" MUST be preserved
  local real_result
  real_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "real build_manifest_cards failed"

  local real_login_hit
  real_login_hit="$(printf '%s' "$real_result" | jq '[.cards[] | select(.path == "login")] | length')"
  [ "$real_login_hit" -eq 1 ] \
    || fail "real script should preserve 'login' card, but it was dropped"
}
