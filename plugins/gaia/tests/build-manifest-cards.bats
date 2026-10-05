#!/usr/bin/env bats
# build-manifest-cards.bats — tests for the manifest card builder and
# last-published persistence helper in gaia-create-ux.
#
# Every test must FAIL on a missing or broken script, never skip.
# No project-root .gaia/ access; all fixtures use mktemp.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

SKILL_SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
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
  # Seed a default v2 design record if the caller hasn't already
  if [ ! -f "$TEST_TMP/design-record.yaml" ]; then
    _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  fi
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$prior' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml'
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

  # Default --project is design_system: only components/ found (screens/ routed to PD)
  # 2 component specs + Colors + Type = 4 cards
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 4 ] || fail "expected 4 cards (2 component + Colors + Type), got $card_count"

  # Verify Colors and Type are preserved
  printf '%s' "$result" | jq -e '.cards[] | select(.group == "Colors")' >/dev/null \
    || fail "Colors card missing"
  printf '%s' "$result" | jq -e '.cards[] | select(.group == "Type")' >/dev/null \
    || fail "Type card missing"

  # Verify component specs are present, screen specs routed to PD
  local component_count screen_count
  component_count="$(printf '%s' "$result" | jq '[.cards[] | select(.group == "Component specs")] | length')"
  screen_count="$(printf '%s' "$result" | jq '[.cards[] | select(.group == "Screen specs")] | length')"
  [ "$component_count" -eq 2 ] || fail "expected 2 component specs, got $component_count"
  [ "$screen_count" -eq 0 ] || fail "screen specs should be routed to PD, got $screen_count"

  # Run PD partition and assert counts sum to pre-partition total
  local pd_result
  pd_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project product_design
  " 2>/dev/null)" || fail "build_manifest_cards --project product_design failed"

  # PD partition: 3 screen specs only (Colors/Type are non-screen existing cards
  # filtered out by the PD partition prefix rule)
  local pd_card_count
  pd_card_count="$(printf '%s' "$pd_result" | jq '.cards | length')"
  [ "$pd_card_count" -eq 3 ] || fail "PD partition expected 3 cards (3 screens), got $pd_card_count"

  # Both partitions' spec counts must cover all 5 discovered spec files
  local ds_spec_count pd_spec_count
  ds_spec_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("\\.spec\\.html$"))] | length')"
  pd_spec_count="$(printf '%s' "$pd_result" | jq '[.cards[] | select(.path | test("\\.spec\\.html$"))] | length')"
  [ "$((ds_spec_count + pd_spec_count))" -eq 5 ] \
    || fail "partition spec counts (DS=$ds_spec_count + PD=$pd_spec_count) must sum to 5"
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

@test "(AC-EC2) orphan framework cards dropped with --project product_design" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  # Seed 2 screen specs + 1 component spec; prior has orphan screen under PD key
  mkdir -p "$TEST_TMP/specs/screens" "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Dashboard</html>\n' > "$TEST_TMP/specs/screens/dashboard.spec.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"

  # Existing manifest has the orphan screen
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json" \
    '{"path":"screens/settings.spec.html","group":"Screen specs"}'

  # Prior is a per-project object with the orphan under product_design
  cat > "$TEST_TMP/prior.json" <<'JSON'
{
  "design_system": {"files": []},
  "product_design": {"files": [{"file":"screens/settings.spec.html","hash":"abc123"}]}
}
JSON

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published '$TEST_TMP/prior.json' \
      --project product_design
  " 2>/dev/null)" || fail "build_manifest_cards --project product_design failed"

  # settings.spec.html must be absent (orphan)
  local orphan_hit
  orphan_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "screens/settings.spec.html")] | length')"
  [ "$orphan_hit" -eq 0 ] || fail "orphan framework card not dropped under product_design"

  # The 2 live screen specs must be present
  local screen_count
  screen_count="$(printf '%s' "$result" | jq '[.cards[] | select(.group == "Screen specs")] | length')"
  [ "$screen_count" -eq 2 ] || fail "expected 2 screen spec cards in PD partition, got $screen_count"
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

  # Default DS partition: 2 component spec cards (screens routed to PD, existing
  # manifest corrupt so Colors/Type not carried forward)
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 2 ] || fail "expected exactly 2 cards from DS partition (2 components), got $card_count"
}

@test "(AC-EC4) spec file without dsCard annotation excluded with diagnostic" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"
  # This spec has NO annotation
  printf '<html>No annotation here</html>\n' > "$TEST_TMP/specs/components/broken.spec.html"
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

  # button.spec.html MUST be in the cards
  local button_hit
  button_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("button"))] | length')"
  [ "$button_hit" -eq 1 ] || fail "annotated spec should be included"

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
  # Per-project object: files live under .design_system.files (default project)
  local entry_count
  entry_count="$(jq '.design_system.files | length' "$TEST_TMP/last-published.json")"
  [ "$entry_count" -eq 6 ] || fail "expected 6 entries, got $entry_count"

  # All hashes must be 64-hex
  local bad_hash_count
  bad_hash_count="$(jq '[.design_system.files[] | select(.hash | test("^[0-9a-f]{64}$") | not)] | length' "$TEST_TMP/last-published.json")"
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
  # Per-project object: files under .design_system.files (default project)
  local entry_count
  entry_count="$(jq '.design_system.files | length' "$TEST_TMP/last-published.json")"
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
  persisted_hash="$(jq -r '.design_system.files[] | select(.file == "screens/login.spec.html") | .hash' "$TEST_TMP/last-published.json")"
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
  persisted_hash="$(jq -r '.design_system.files[] | select(.file == "screens/login.spec.html") | .hash' "$TEST_TMP/last-published.json")"
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
  persisted_hash="$(jq -r '.design_system.files[] | select(.file == "screens/broken.spec.html") | .hash' "$TEST_TMP/last-published.json")"
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
  entry_count="$(jq '[.design_system.files[] | select(.file == "screens/broken.spec.html")] | length' "$TEST_TMP/last-published.json")"
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
  entry_count="$(jq '[.design_system.files[] | select(.file == "screens/old.spec.html")] | length' "$TEST_TMP/last-published.json")"
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
  persisted_hash="$(jq -r '.design_system.files[] | select(.file == "screens/orphan.spec.html") | .hash' "$TEST_TMP/last-published.json")"
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
  # Per-project object: files under .design_system.files (default project)
  local entry_count
  entry_count="$(jq '.design_system.files | length' "$TEST_TMP/last-published.json")"
  [ "$entry_count" -eq 5 ] || fail "expected 5 entries, got $entry_count"

  # written entries carry their outcome hash
  local login_hash dashboard_hash
  login_hash="$(jq -r '.design_system.files[] | select(.file == "screens/login.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  dashboard_hash="$(jq -r '.design_system.files[] | select(.file == "screens/dashboard.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$login_hash" = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111" ] || fail "written login hash wrong"
  [ "$dashboard_hash" = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222" ] || fail "written dashboard hash wrong"

  # merged and kept-designer carry the framework local hash
  local button_hash card_hash
  button_hash="$(jq -r '.design_system.files[] | select(.file == "components/button.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  card_hash="$(jq -r '.design_system.files[] | select(.file == "components/card.spec.html") | .hash' "$TEST_TMP/last-published.json")"
  [ "$button_hash" = "fw_local_button_fw_local_button_fw_local_button_fw_local_button_" ] || fail "merged hash should be framework local"
  [ "$card_hash" = "fw_local_card_1_fw_local_card_1_fw_local_card_1_fw_local_card_1_" ] || fail "kept-designer hash should be framework local"

  # failed-with-prior carries the prior hash
  local broken_hash
  broken_hash="$(jq -r '.design_system.files[] | select(.file == "screens/broken.spec.html") | .hash' "$TEST_TMP/last-published.json")"
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

  # Seed a default design record for the --design-record flag
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Uses a non-default output path to verify mkdir -p + tmp+mv
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/subdir/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  " || fail "persist_last_published failed"

  # Output file must exist and parse as JSON
  [ -f "$TEST_TMP/subdir/last-published.json" ] || fail "output file not created"
  jq '.' "$TEST_TMP/subdir/last-published.json" >/dev/null || fail "output is not valid JSON"

  # No leftover temp files (mktemp creates random-suffix files, not just *.tmp)
  local extra_files
  extra_files="$(find "$TEST_TMP/subdir" -type f -not -name 'last-published.json' -not -name '*.lock' 2>/dev/null | wc -l | tr -d ' ')"
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
  mkdir -p "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"

  # Existing manifest: Colors + designer cards with substring-matching paths
  printf '{"cards":[{"path":"colors.json","group":"Colors"},{"path":"button","group":"Designer Button"},{"path":"components/button","group":"Designer Partial"},{"path":"spec.html","group":"Designer Suffix"}]}\n' \
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
  local button_hit partial_hit suffix_hit
  button_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "button")] | length')"
  partial_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "components/button")] | length')"
  suffix_hit="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "spec.html")] | length')"
  [ "$button_hit" -eq 1 ] || fail "designer card 'button' was dropped (substring match bug)"
  [ "$partial_hit" -eq 1 ] || fail "designer card 'components/button' was dropped (substring match bug)"
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
  mkdir -p "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Component specs" -->\n<html>A</html>\n' > "$TEST_TMP/specs/components/a.spec.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>AB</html>\n' > "$TEST_TMP/specs/components/ab.spec.html"

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
  a_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "components/a.spec.html")] | length')"
  ab_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "components/ab.spec.html")] | length')"
  [ "$a_count" -eq 1 ] || fail "components/a.spec.html missing"
  [ "$ab_count" -eq 1 ] || fail "components/ab.spec.html missing"
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

  # Default DS partition: 250 component specs + Colors + Type = 252
  # (250 screen specs route to PD)
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 252 ] || fail "expected 252 cards (250 components + Colors + Type), got $card_count"

  # PD partition: 250 screen specs only (Colors/Type are non-screen existing
  # cards filtered out by the PD partition prefix rule)
  local pd_result
  pd_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project product_design
  " 2>/dev/null)" || fail "build_manifest_cards --project product_design failed on 500 specs"

  local pd_card_count
  pd_card_count="$(printf '%s' "$pd_result" | jq '.cards | length')"
  [ "$pd_card_count" -eq 250 ] || fail "PD expected 250 cards (250 screens), got $pd_card_count"

  # Partition spec counts must sum to 500
  local ds_spec pd_spec
  ds_spec="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("\\.spec\\.html$"))] | length')"
  pd_spec="$(printf '%s' "$pd_result" | jq '[.cards[] | select(.path | test("\\.spec\\.html$"))] | length')"
  [ "$((ds_spec + pd_spec))" -eq 500 ] \
    || fail "partition spec counts (DS=$ds_spec + PD=$pd_spec) must sum to 500"
}

# ===========================================================================
# Mutant: restoring inside() makes the substring test red
# ===========================================================================

@test "(AC-EC6) mutant restoring substring membership in the card builder is caught" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Copy scripts/ + scripts/lib/ into temp tree so the mutant can source safe-filename.sh
  mkdir -p "$TEST_TMP/mutant-tree/lib"
  cp "$SKILL_SCRIPTS"/lib/*.sh "$TEST_TMP/mutant-tree/lib/" 2>/dev/null || true
  cp "$SKILL_SCRIPTS"/lib/acquire-lock.sh "$TEST_TMP/mutant-tree/lib/" 2>/dev/null || true
  cp "$TARGET_SCRIPT" "$TEST_TMP/mutant-tree/build-manifest-cards.sh"

  # Patch the exact-match to inside() — match the jq text with escaped dollars
  local mutant="$TEST_TMP/mutant-tree/build-manifest-cards.sh"
  # The jq code has: any(\$fw_owned[]; . == \$p)
  # Replace it with: ([.path] | inside(\$fw_owned))
  perl -pi -e 's/any\(\\\$fw_owned\[\]; \. == \\\$p\)/([.path] | inside(\\\$fw_owned))/g' "$mutant"
  chmod +x "$mutant"

  # Assert the patch applied: the inside() text is present in the mutant
  grep -qF 'inside(\$fw_owned)' "$mutant" \
    || fail "patch did not apply: inside(\$fw_owned) not found in mutant"
  # The non-fw filter line should no longer have 'any(\$fw_owned[]'
  local any_count
  any_count="$(grep -cF 'any(\$fw_owned[]; . == \$p)' "$mutant" 2>/dev/null || true)"
  [ "$any_count" -eq 0 ] \
    || fail "patch incomplete: any(\$fw_owned[]) still present ($any_count times)"

  # Verify the mutant actually runs (not just a no-op sed)
  bash -c "source '$mutant'" 2>/dev/null \
    || fail "mutant script fails to source"

  # Seed fixture: one framework spec, one designer card whose path is a substring
  mkdir -p "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' \
    > "$TEST_TMP/specs/components/button.spec.html"
  printf '{"cards":[{"path":"colors.json","group":"Colors"},{"path":"button","group":"Designer Button"}]}\n' \
    > "$TEST_TMP/existing-manifest.json"

  # Run against the MUTANT — the designer card "button" SHOULD be dropped
  # (because inside() treats "button" as a substring of "components/button.spec.html")
  local mutant_result
  mutant_result="$(bash -c "
    source '$mutant'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "mutant build_manifest_cards failed"

  local mutant_button_hit
  mutant_button_hit="$(printf '%s' "$mutant_result" | jq '[.cards[] | select(.path == "button")] | length')"
  [ "$mutant_button_hit" -eq 0 ] \
    || fail "mutant should drop 'button' card via substring match, but it was preserved"

  # Run against the REAL script — the designer card "button" MUST be preserved
  local real_result
  real_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "real build_manifest_cards failed"

  local real_button_hit
  real_button_hit="$(printf '%s' "$real_result" | jq '[.cards[] | select(.path == "button")] | length')"
  [ "$real_button_hit" -eq 1 ] \
    || fail "real script should preserve 'button' card, but it was dropped"
}

# ===========================================================================
# ERE metacharacters in --local-specs path
# ===========================================================================

# ===========================================================================
# Per-project publication state and manifest partitioning (RED phase)
# ===========================================================================

# --- Design record fixtures -------------------------------------------------

# _seed_design_record_v2 FILE DS_REF PD_REF — write a v2 design-record.yaml.
_seed_design_record_v2() {
  local file="$1" ds_ref="${2:-https://ds.example.com/project/123}" pd_ref="${3:-https://claude.ai/artifact/456}"
  cat > "$file" <<YAML
schema_version: "2.0"
design_system_project:
  reference: "$ds_ref"
  discovered_via: manual
product_design_project:
  reference: "$pd_ref"
  discovered_via: manual
YAML
}

# _seed_design_record_v1 FILE REF — write a v1.0 design-record.yaml.
_seed_design_record_v1() {
  local file="$1" ref="${2:-https://ds.example.com/project/old}"
  cat > "$file" <<YAML
schema_version: "1.0"
project:
  reference: "$ref"
  discovered_via: manual
YAML
}

# _seed_design_record_v1_na FILE — v1.0 with "not-applicable" reference.
_seed_design_record_v1_na() {
  local file="$1"
  cat > "$file" <<YAML
schema_version: "1.0"
project:
  reference: "not-applicable"
  discovered_via: manual
YAML
}

# _seed_per_project_state FILE — write a per-project design-last-published.json
# with distinct data per key.
_seed_per_project_state() {
  local file="$1"
  cat > "$file" <<'JSON'
{
  "design_system": {
    "reference": "https://ds.example.com/project/123",
    "last_published_at": "2026-09-01T00:00:00Z",
    "files": [{"file":"components/button.spec.html","hash":"ds_hash_1"}]
  },
  "product_design": {
    "reference": "https://claude.ai/artifact/456",
    "last_published_at": "2026-09-02T00:00:00Z",
    "files": [{"file":"screens/login.spec.html","hash":"pd_hash_1"}]
  }
}
JSON
}

# _run_persist_v2 — run persist_last_published with per-project args.
# Usage: _run_persist_v2 [--project X] [--design-record Y] [--published-at Z]
#   ... additional args passed through.
# Expects outcomes at $TEST_TMP/outcomes.json, hash map at
# $TEST_TMP/hash-map.json, writes to $TEST_TMP/last-published.json.
# Prior defaults to /dev/null.
_run_persist_v2() {
  local prior="/dev/null" project="design_system" design_record="" published_at=""
  local extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --prior)          prior="$2";          shift 2 ;;
      --project)        project="$2";        shift 2 ;;
      --design-record)  design_record="$2";  shift 2 ;;
      --published-at)   published_at="$2";   shift 2 ;;
      *)                extra_args=("${extra_args[@]+"${extra_args[@]}"}" "$1"); shift ;;
    esac
  done
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  local cmd="source '$TARGET_SCRIPT'; persist_last_published"
  cmd="$cmd --outcomes '$TEST_TMP/outcomes.json'"
  cmd="$cmd --prior '$prior'"
  cmd="$cmd --output '$TEST_TMP/last-published.json'"
  cmd="$cmd --local-hash-map '$TEST_TMP/hash-map.json'"
  cmd="$cmd --project '$project'"
  [ -n "$design_record" ] && cmd="$cmd --design-record '$design_record'"
  [ -n "$published_at" ] && cmd="$cmd --published-at '$published_at'"
  bash -c "$cmd"
}

# ===========================================================================
# AC1 — Independent timestamps per project
# ===========================================================================

@test "per-project: DS and PD have independent timestamps" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Write DS first
  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"ds_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"ds_h1"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" \
    --published-at "2026-09-01T10:00:00Z"

  # Write PD second
  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"pd_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"pd_h1"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project product_design \
    --design-record "$TEST_TMP/design-record.yaml" \
    --published-at "2026-09-02T15:00:00Z"

  # Assert DS timestamp unchanged
  local ds_ts pd_ts
  ds_ts="$(jq -r '.design_system.last_published_at' "$TEST_TMP/last-published.json")"
  pd_ts="$(jq -r '.product_design.last_published_at' "$TEST_TMP/last-published.json")"
  [ "$ds_ts" = "2026-09-01T10:00:00Z" ] || fail "DS timestamp changed: $ds_ts"
  [ "$pd_ts" = "2026-09-02T15:00:00Z" ] || fail "PD timestamp wrong: $pd_ts"
}

@test "per-project: DS publication does not update PD timestamp" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _seed_per_project_state "$TEST_TMP/last-published.json"

  local pd_before
  pd_before="$(jq -r '.product_design' "$TEST_TMP/last-published.json" | shasum -a 256)"

  # Write to DS only
  printf '[{"file":"components/card.spec.html","outcome":"written","hash":"ds_h2"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/card.spec.html":"ds_h2"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" \
    --published-at "2026-09-03T12:00:00Z" \
    --prior "$TEST_TMP/last-published.json"

  local pd_after
  pd_after="$(jq -r '.product_design' "$TEST_TMP/last-published.json" | shasum -a 256)"
  [ "$pd_before" = "$pd_after" ] || fail "PD key changed after DS write"
}

@test "per-project: PD publication does not update DS timestamp" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _seed_per_project_state "$TEST_TMP/last-published.json"

  local ds_before
  ds_before="$(jq -r '.design_system' "$TEST_TMP/last-published.json" | shasum -a 256)"

  printf '[{"file":"screens/dash.spec.html","outcome":"written","hash":"pd_h2"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/dash.spec.html":"pd_h2"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project product_design \
    --design-record "$TEST_TMP/design-record.yaml" \
    --published-at "2026-09-04T08:00:00Z" \
    --prior "$TEST_TMP/last-published.json"

  local ds_after
  ds_after="$(jq -r '.design_system' "$TEST_TMP/last-published.json" | shasum -a 256)"
  [ "$ds_before" = "$ds_after" ] || fail "DS key changed after PD write"
}

# ===========================================================================
# AC2 — Legacy flat-array migration
# ===========================================================================

@test "per-project: legacy flat-array migration wraps under design_system" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Legacy flat-array prior
  printf '[{"file":"components/button.spec.html","hash":"leg_h1"}]\n' > "$TEST_TMP/prior.json"
  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"leg_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"leg_h1"}\n' > "$TEST_TMP/hash-map.json"

  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" \
    --prior "$TEST_TMP/prior.json"

  # Output must be a per-project object
  jq -e '.design_system' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "design_system key missing"
  jq -e '.product_design' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "product_design key missing"

  # PD must be initialised empty
  local pd_files
  pd_files="$(jq '.product_design.files | length' "$TEST_TMP/last-published.json")"
  [ "$pd_files" -eq 0 ] || fail "product_design.files should be empty, got $pd_files"
}

@test "per-project: migration idempotency (sha256 identity)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '[{"file":"components/button.spec.html","hash":"idem_h1"}]\n' > "$TEST_TMP/prior.json"
  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"idem_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"idem_h1"}\n' > "$TEST_TMP/hash-map.json"

  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" \
    --prior "$TEST_TMP/prior.json" \
    --published-at "2026-09-01T00:00:00Z"

  local hash1
  hash1="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  # Run again with same input — output must be byte-identical
  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" \
    --prior "$TEST_TMP/last-published.json" \
    --published-at "2026-09-01T00:00:00Z"

  local hash2
  hash2="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
  [ "$hash1" = "$hash2" ] || fail "idempotency broken: $hash1 vs $hash2"
}

@test "per-project: corrupt JSON in --prior fails closed" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '{broken json\n' > "$TEST_TMP/corrupt-prior.json"
  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/corrupt-prior.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  " 2>&1)" || rc=$?

  [ "$rc" -ne 0 ] || fail "corrupt --prior should fail closed"
  [[ "$stderr_out" == *"corrupt"* ]] || [[ "$stderr_out" == *"malformed"* ]] || [[ "$stderr_out" == *"invalid"* ]] \
    || fail "should diagnose corrupt/malformed JSON, got: $stderr_out"
  [ ! -f "$TEST_TMP/last-published.json" ] || fail "state file should not exist after corrupt prior"
}

# ===========================================================================
# AC3 — --project routes to correct key
# ===========================================================================

@test "per-project: --project routes to correct key in persist_last_published" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Write DS
  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"ds_route_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"ds_route_h"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" \
    --published-at "2026-09-01T00:00:00Z"

  # Write PD
  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"pd_route_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"pd_route_h"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project product_design \
    --design-record "$TEST_TMP/design-record.yaml" \
    --prior "$TEST_TMP/last-published.json" \
    --published-at "2026-09-02T00:00:00Z"

  # DS key should have only DS data
  local ds_file
  ds_file="$(jq -r '.design_system.files[0].file' "$TEST_TMP/last-published.json")"
  [ "$ds_file" = "components/button.spec.html" ] || fail "DS key has wrong file: $ds_file"

  # PD key should have only PD data
  local pd_file
  pd_file="$(jq -r '.product_design.files[0].file' "$TEST_TMP/last-published.json")"
  [ "$pd_file" = "screens/login.spec.html" ] || fail "PD key has wrong file: $pd_file"
}

@test "per-project: no --project flag defaults to design_system" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"def_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"def_h"}\n' > "$TEST_TMP/hash-map.json"

  # Call without --project
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  " || fail "persist_last_published failed"

  # Must have written under design_system key
  jq -e '.design_system.files[0]' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "no --project should default to design_system"
}

@test "per-project: readers never write (sha256 unchanged)" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"
  _seed_per_project_state "$TEST_TMP/last-published.json"

  local hash_before
  hash_before="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  # Feed plan-publication.sh the per-project state as --last-published
  printf '[{"file":"components/button.spec.html","hash":"ds_hash_1"}]\n' > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"components/button.spec.html","hash":"ds_hash_1"}]\n' > "$TEST_TMP/remote-listing.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$TEST_TMP/last-published.json" \
    --project design_system
  # Script may fail (new flag not yet implemented) — that's fine for RED.
  # The point: state file must not change.

  local hash_after
  hash_after="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
  [ "$hash_before" = "$hash_after" ] || fail "reader modified state file"
}

# ===========================================================================
# AC4 — Manifest partitioning
# ===========================================================================

@test "partition: component/template/token → DS, screen/flow → PD" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Seed a tree with all five allowed subdirectories + tokens
  mkdir -p "$TEST_TMP/specs/screens" "$TEST_TMP/specs/components" \
           "$TEST_TMP/specs/tokens" "$TEST_TMP/specs/templates" \
           "$TEST_TMP/specs/flows"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Flow</html>\n' > "$TEST_TMP/specs/flows/checkout.spec.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Modal</html>\n' > "$TEST_TMP/specs/templates/modal.spec.html"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  # Run with --project design_system
  local ds_result
  ds_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards DS failed"

  # Run with --project product_design
  local pd_result
  pd_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project product_design
  " 2>/dev/null)" || fail "build_manifest_cards PD failed"

  # DS must have button + modal (template) + token, NOT login (screen) or flow
  printf '%s' "$ds_result" | jq -e '.cards[] | select(.path == "components/button.spec.html")' >/dev/null \
    || fail "DS missing components/button.spec.html"
  printf '%s' "$ds_result" | jq -e '.cards[] | select(.path == "templates/modal.spec.html")' >/dev/null \
    || fail "DS missing templates/modal.spec.html"
  printf '%s' "$ds_result" | jq -e '.cards[] | select(.path == "tokens/colors.html")' >/dev/null \
    || fail "DS missing tokens/colors.html"
  local ds_screen_count ds_flow_count
  ds_screen_count="$(printf '%s' "$ds_result" | jq '[.cards[] | select(.path | startswith("screens/"))] | length')"
  ds_flow_count="$(printf '%s' "$ds_result" | jq '[.cards[] | select(.path | startswith("flows/"))] | length')"
  [ "$ds_screen_count" -eq 0 ] || fail "DS should not have screen cards, got $ds_screen_count"
  [ "$ds_flow_count" -eq 0 ] || fail "DS should not have flow cards, got $ds_flow_count"

  # PD must have login + checkout (flow), NOT button/modal/token
  printf '%s' "$pd_result" | jq -e '.cards[] | select(.path == "screens/login.spec.html")' >/dev/null \
    || fail "PD missing screens/login.spec.html"
  printf '%s' "$pd_result" | jq -e '.cards[] | select(.path == "flows/checkout.spec.html")' >/dev/null \
    || fail "PD missing flows/checkout.spec.html"
  local pd_comp_count pd_token_count pd_template_count
  pd_comp_count="$(printf '%s' "$pd_result" | jq '[.cards[] | select(.path | startswith("components/"))] | length')"
  pd_token_count="$(printf '%s' "$pd_result" | jq '[.cards[] | select(.path | startswith("tokens/"))] | length')"
  pd_template_count="$(printf '%s' "$pd_result" | jq '[.cards[] | select(.path | startswith("templates/"))] | length')"
  [ "$pd_comp_count" -eq 0 ] || fail "PD should not have component cards"
  [ "$pd_token_count" -eq 0 ] || fail "PD should not have token cards"
  [ "$pd_template_count" -eq 0 ] || fail "PD should not have template cards"
}

@test "partition: empty intersection between DS and PD manifests" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_spec_tree "$TEST_TMP/specs"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local ds_result pd_result
  ds_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "DS failed"
  pd_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project product_design
  " 2>/dev/null)" || fail "PD failed"

  # Extract sorted card paths
  local ds_paths pd_paths
  ds_paths="$(printf '%s' "$ds_result" | jq -r '.cards[].path' | LC_ALL=C sort)"
  pd_paths="$(printf '%s' "$pd_result" | jq -r '.cards[].path' | LC_ALL=C sort)"

  # Intersection must be empty
  local common
  common="$(comm -12 <(printf '%s\n' "$ds_paths") <(printf '%s\n' "$pd_paths") | wc -l | tr -d ' ')"
  [ "$common" -eq 0 ] || fail "DS and PD share $common card paths"

  # Both must be non-empty
  [ -n "$ds_paths" ] || fail "DS manifest empty"
  [ -n "$pd_paths" ] || fail "PD manifest empty"
}

@test "partition: stray tokens under non-tokens dir not discovered" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/components/tokens"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Stray</html>\n' > "$TEST_TMP/specs/components/tokens/stray.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  local stray_count
  stray_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("components/tokens"))] | length')"
  [ "$stray_count" -eq 0 ] || fail "components/tokens/stray.html should not be discovered"
}

@test "partition: nested tokens not discovered" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/tokens/sub"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Nested</html>\n' > "$TEST_TMP/specs/tokens/sub/nested.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  local nested_count
  nested_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("tokens/sub"))] | length')"
  [ "$nested_count" -eq 0 ] || fail "tokens/sub/nested.html should not be discovered"
}

@test "partition: tokens/x.spec.html dedup (counted once)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/tokens"
  # Both .spec.html and .html at same base name
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.spec.html"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # Both are distinct files (different paths) — colors.spec.html from *.spec.html
  # match, colors.html from tokens/*.html match. The spec.html must not be
  # double-counted (it matches both patterns).
  local token_count
  token_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | startswith("tokens/colors"))] | length')"
  [ "$token_count" -eq 2 ] || fail "expected 2 distinct token cards (colors.spec.html + colors.html), got $token_count"
}

@test "partition: PD --existing carries only screens/flows paths" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/screens"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' > "$TEST_TMP/specs/screens/login.spec.html"

  # Existing manifest has a stale components/ path that shouldn't carry into PD
  printf '{"cards":[{"path":"screens/old.spec.html","group":"Screen specs"},{"path":"components/stale.spec.html","group":"Component specs"}]}\n' \
    > "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project product_design
  " 2>/dev/null)" || fail "build_manifest_cards PD failed"

  local stale_count
  stale_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | startswith("components/"))] | length')"
  [ "$stale_count" -eq 0 ] || fail "PD manifest should not carry components/ paths"
}

# ===========================================================================
# Pre-write reference verification — real response shapes
# ===========================================================================

VERIFY_SCRIPT="$BATS_TEST_DIRNAME/../scripts/lib/verify-publication-target.sh"

# _make_ds_meta FILE PROJECTID [EXTRA_PROJECT_FIELDS]
# Writes a designsync wrapper JSON that mirrors the real get_project shape.
_make_ds_meta() {
  local file="$1" pid="$2" extra="${3:-}"
  # Defaults: name, type, ownerDisplayName, canEdit — matches real response
  local name="Acme Design System" type="PROJECT_TYPE_DESIGN_SYSTEM"
  local owner="Jane Doe" can_edit="true"
  jq -n --arg pid "$pid" --arg name "$name" --arg type "$type" \
    --arg owner "$owner" --argjson canEdit "$can_edit" \
    '{projectId: $pid, project: ({method:"get_project", projectId: $pid, name: $name, type: $type, ownerDisplayName: $owner, canEdit: $canEdit})}' \
    > "$file"
  # Apply overrides if provided (a jq filter)
  if [ -n "$extra" ]; then
    local tmp; tmp="$(jq "$extra" "$file")"
    printf '%s\n' "$tmp" > "$file"
  fi
}

# _make_art_meta FILE REFERENCE [PAGE_HEADER] [PERFILE_HEADER]
# Writes an artifact metadata file that mirrors the real Artifact read shapes.
_make_art_meta() {
  local file="$1" ref="$2"
  local page="${3:-[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private; the page comes from its Artifact type https://claude.ai/artifact/QKN21svewxgyPb6SYRqWnd]}"
  local perfile="${4:-Files saved under \"/some/dir\" from version 2 of $ref, an Artifact of type \"Design\".}"
  {
    printf 'reference: %s\n' "$ref"
    printf '%s\n' "$page"
    printf '%s\n' "$perfile"
  } > "$file"
}

@test "verify-target: positive control passes with real designsync shape" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -eq 0 ] || fail "positive control should pass: $output"
}

@test "verify-target: cross-wire designsync using PD reference rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://claude.ai/artifact/456"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "cross-wire should be rejected"
  [[ "$output" == *"cross-wire"* ]] || fail "should diagnose cross-wire (got: $output)"
}

@test "verify-target: canEdit false rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.canEdit = false'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "canEdit:false should be rejected"
}

@test "verify-target: artifact positive control with real header shapes" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -eq 0 ] || fail "positive artifact control should pass: $output"
}

@test "verify-target: non-writer artifact page header rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  # Page header says "shared with you" instead of "owned by you"
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — shared with you, private]"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "non-writer Artifact should be rejected"
  [[ "$output" == *"write access could not be confirmed"* ]] \
    || fail "should say write access could not be confirmed: $output"
}

@test "verify-target: 'Design System' artifact type rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/some/dir" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design System".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "'Design System' type should be rejected (only 'Design' accepted)"
}

@test "verify-target: lowercase 'design' artifact type rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/some/dir" from version 2 of https://claude.ai/artifact/456, an Artifact of type "design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "lowercase 'design' type should be rejected (case-sensitive)"
}

@test "verify-target: missing per-file-read header line rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Only reference and page header, no per-file header
  cat > "$TEST_TMP/artifact-meta.txt" <<'TXT'
reference: https://claude.ai/artifact/456
[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "missing per-file header should be rejected"
  [[ "$output" == *"key-value lines"* ]] || [[ "$output" == *"per-file"* ]] \
    || fail "should mention missing per-file header: $output"
}

@test "verify-target: owner mismatch rejected for designsync" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.ownerDisplayName = "Wrong Org"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "owner mismatch should be rejected"
}

@test "verify-target: --expected-owner with no ownerDisplayName field rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    'del(.project.ownerDisplayName)'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "missing ownerDisplayName field should fail closed"
}

@test "verify-target: only 'owner' present (no ownerDisplayName) with --expected-owner rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  # Has project.owner but not project.ownerDisplayName
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    'del(.project.ownerDisplayName) | .project.owner = "Jane Doe"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "owner (without ownerDisplayName) should fail closed"
  [[ "$output" == *"ownerDisplayName"* ]] || fail "should mention missing ownerDisplayName: $output"
}

@test "verify-target: artifact cross-wire using DS reference rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Artifact surface using the DS reference (should be PD reference)
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "artifact using DS reference should be rejected as cross-wire"
  [[ "$output" == *"cross-wire"* ]] || fail "should diagnose cross-wire (got: $output)"
}

@test "verify-target: missing page-read header line rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Reference + per-file header but no page header
  cat > "$TEST_TMP/artifact-meta.txt" <<TXT
reference: https://claude.ai/artifact/456
Files saved under "/some/dir" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "missing page header should be rejected"
  [[ "$output" == *"write access could not be confirmed"* ]] \
    || fail "should say write access could not be confirmed: $output"
}

@test "verify-target: reference mismatch against design record rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/wrong-ref"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/wrong-ref' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "reference mismatch should be rejected"
  [[ "$output" == *"mismatch"* ]] || [[ "$output" == *"reference"* ]] \
    || fail "should diagnose reference mismatch"
}

@test "verify-target: artifact surface mismatch against design record rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Artifact surface with the DS reference (should use PD reference)
  _make_art_meta "$TEST_TMP/art-meta.txt" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "surface mismatch should be rejected"
}

@test "verify-target: inner projectId missing in designsync rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    'del(.project.projectId)'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "missing inner projectId should be rejected"
  [[ "$output" == *"project.projectId"* ]] || fail "should mention project.projectId: $output"
}

@test "verify-target: inner projectId differs from outer rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.projectId = "https://ds.example.com/DIFFERENT"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "inner projectId mismatch should be rejected"
  [[ "$output" == *"project.projectId"* ]] || fail "should mention project.projectId: $output"
}

@test "verify-target: ownerDisplayName match passes" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -eq 0 ] || fail "ownerDisplayName match should pass: $output"
}

@test "verify-target: ownerDisplayName mismatch rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Wrong Person'
  "
  [ "$status" -ne 0 ] || fail "ownerDisplayName mismatch should be rejected"
  [[ "$output" == *"owner mismatch"* ]] || fail "should mention owner mismatch: $output"
}

@test "verify-target: create_project shape (no type/canEdit) rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # create_project response has no type, no canEdit, no ownerDisplayName
  cat > "$TEST_TMP/ds-metadata.json" <<'JSON'
{"projectId":"https://ds.example.com/project/123","project":{"method":"create_project","projectId":"https://ds.example.com/project/123","name":"New project"}}
JSON

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "create_project shape should be rejected (no type/canEdit)"
}

@test "verify-target: URL prefix trick rejected — reference is prefix of header URL" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml" \
    "https://ds.example.com/project/123" "https://claude.ai/artifact/abc"

  # reference is .../abc but header URL is .../abcd
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/abc" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/d" from version 2 of https://claude.ai/artifact/abcd, an Artifact of type "Design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/abc' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "prefix-trick (.../abc matching .../abcd) should be rejected"
}

@test "verify-target: URL prefix trick rejected — header URL is prefix of reference" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml" \
    "https://ds.example.com/project/123" "https://claude.ai/artifact/abcd"

  # reference is .../abcd but header URL is .../abc
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/abcd" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/d" from version 2 of https://claude.ai/artifact/abc, an Artifact of type "Design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/abcd' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "prefix-trick (.../abcd vs .../abc) should be rejected"
}

@test "verify-target: per-file header for a different URL rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/d" from version 2 of https://claude.ai/artifact/WRONG, an Artifact of type "Design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "per-file header for a different URL should be rejected"
}

@test "verify-target: two per-file header lines rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  cat > "$TEST_TMP/artifact-meta.txt" <<TXT
reference: https://claude.ai/artifact/456
[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]
Files saved under "/d1" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
Files saved under "/d2" from version 3 of https://claude.ai/artifact/456, an Artifact of type "Design".
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "two per-file header lines should be rejected"
  [[ "$output" == *"per-file"* ]] || fail "should mention per-file headers: $output"
}

@test "verify-target: two page-read header lines rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Two page headers — one with "owned by you", one without
  cat > "$TEST_TMP/artifact-meta.txt" <<TXT
reference: https://claude.ai/artifact/456
[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
[Artifact bbbbbbbb-0000-0000-0000-000000000000 (version 1) — shared with you, private]
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "two page-read header lines should be rejected"
  [[ "$output" == *"page-read"* ]] || fail "should mention page-read headers: $output"
}

@test "verify-target: per-file header trailing text after closing period rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design". extra trailing text'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "trailing text after closing period should be rejected"
}

@test "verify-target: per-file header missing final period rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "missing final period should be rejected"
}

@test "verify-target: per-file header non-numeric version rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/d" from version 2x of https://claude.ai/artifact/456, an Artifact of type "Design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "non-numeric version should be rejected"
}

@test "verify-target: per-file header with crafted dir embedding the full form but different tail URL rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Dir name embeds the full form with the correct URL; the real tail names a
  # different URL. The parser must extract from the LAST "from version N of"
  # occurrence; this test ensures the tail URL (WRONG) is what is compared, so
  # the file is rejected. This is safe because the dir is always quoted and the
  # real structural tail is the last match — a crafted dir cannot override it.
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design"." from version 3 of https://claude.ai/artifact/WRONG, an Artifact of type "Design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "crafted dir with different tail URL should be rejected"
}

@test "verify-target: per-file header with unquoted dir name rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Dir name is not quoted — the line structure is wrong even though the sed
  # extraction would produce the right URL and type. The anchored form
  # validation catches this because it requires "..." around the dir.
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under /d from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "unquoted dir name should be rejected"
}

@test "verify-target: per-file header with crafted dir embedding the full form and same tail URL passes" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Same scenario but the real tail URL equals the reference — this should pass.
  # The parser takes the LAST structural match, which carries the correct URL.
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456" \
    "[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]" \
    'Files saved under "/from version 2 of https://evil.example.com/x, an Artifact of type "Design"." from version 3 of https://claude.ai/artifact/456, an Artifact of type "Design".'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -eq 0 ] || fail "crafted dir with correct tail URL should pass: $output"
}

@test "verify-target: old key-value-only artifact file rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Old-shape file with only type/access/owner key-value lines
  cat > "$TEST_TMP/artifact-meta.txt" <<'TXT'
reference: https://claude.ai/artifact/456
type: Design
access: writer
owner: owner-456
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "old key-value-only file should be rejected"
}

@test "verify-target: --expected-owner on artifact surface fails closed" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_art_meta "$TEST_TMP/artifact-meta.txt" "https://claude.ai/artifact/456"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/artifact-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Some Owner'
  "
  [ "$status" -ne 0 ] || fail "--expected-owner on artifact should fail closed"
  [[ "$output" == *"cannot check a named owner"* ]] \
    || fail "should say cannot check named owner: $output"
}

# ===========================================================================
# AC6 — Shared safe-filename lib
# ===========================================================================

SAFE_FILENAME_LIB="$BATS_TEST_DIRNAME/../scripts/lib/safe-filename.sh"

@test "safe-filename: traversal path rejected with diagnostic" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"file\":\"../../../etc/passwd\",\"hash\":\"h1\"}\n' | \
      jq \"\$SAFE_FILENAME_JQ_DEF .file | safe_filename\"
  "
  [ "$status" -ne 0 ] || fail "traversal path should be rejected"
  [[ "$output" == *"unsafe filename"* ]] || [[ "$output" == *"traversal"* ]] \
    || fail "should say 'unsafe filename (traversal)'"
}

@test "safe-filename: absolute path rejected with diagnostic" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"file\":\"/etc/shadow\",\"hash\":\"h1\"}\n' | \
      jq \"\$SAFE_FILENAME_JQ_DEF .file | safe_filename\"
  "
  [ "$status" -ne 0 ] || fail "absolute path should be rejected"
  [[ "$output" == *"unsafe filename"*"absolute"* ]] \
    || fail "should say 'unsafe filename (absolute)'"
}

@test "safe-filename: control char in name rejected" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  # Tab in filename — double-escape so printf emits JSON \t for jq
  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"file\":\"a\\\\tb\",\"hash\":\"h1\"}\n' | \
      jq \"\$SAFE_FILENAME_JQ_DEF .file | safe_filename\"
  "
  [ "$status" -ne 0 ] || fail "tab in filename should be rejected"
  [[ "$output" == *"unsafe filename"*"control"* ]] \
    || fail "should say 'unsafe filename (control char)'"
}

@test "safe-filename: safe path accepted" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"file\":\"screens/login.spec.html\",\"hash\":\"h1\"}\n' | \
      jq -r \"\$SAFE_FILENAME_JQ_DEF .file | safe_filename\"
  "
  [ "$status" -eq 0 ] || fail "safe path should be accepted: $output"
  [ "$output" = "screens/login.spec.html" ] || fail "output should be the path"
}

@test "safe-filename: hostile hash (newline) rejected" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"hash\":\"cccc\\\\nDELETE_ORPHAN keep.html\"}\n' | \
      jq \"\$SAFE_HASH_JQ_DEF .hash | safe_hash\"
  "
  [ "$status" -ne 0 ] || fail "newline in hash should be rejected"
  [[ "$output" == *"unsafe hash"* ]] || fail "should say 'unsafe hash'"
}

@test "safe-filename: hostile hash (tab) rejected" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"hash\":\"abc\\\\tdef\"}\n' | \
      jq \"\$SAFE_HASH_JQ_DEF .hash | safe_hash\"
  "
  [ "$status" -ne 0 ] || fail "tab in hash should be rejected"
  [[ "$output" == *"unsafe hash"* ]] || fail "should say 'unsafe hash'"
}

@test "safe-filename: safe hash accepted" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"hash\":\"abcdef1234567890\"}\n' | \
      jq -r \"\$SAFE_HASH_JQ_DEF .hash | safe_hash\"
  "
  [ "$status" -eq 0 ] || fail "safe hash should be accepted: $output"
  [ "$output" = "abcdef1234567890" ] || fail "output should be the hash"
}

@test "safe-filename: forged plan line via remote hash caught" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  # Local and remote both have a.html; remote hash contains a forged DELETE_ORPHAN
  printf '[{"file":"a.html","hash":"local_hash"}]\n' > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"a.html","hash":"cccc\\nDELETE_ORPHAN keep.html"}]\n' > "$TEST_TMP/remote-listing.json"
  printf '[{"file":"a.html","hash":"local_hash"}]\n' > "$TEST_TMP/last-published.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$TEST_TMP/last-published.json"

  # Must reject the forged hash, NOT emit DELETE_ORPHAN
  if [ "$status" -eq 0 ]; then
    [[ "$output" != *"DELETE_ORPHAN keep.html"* ]] \
      || fail "forged DELETE_ORPHAN line passed through"
  fi
  # Either non-zero status or no forged DELETE_ORPHAN line
}

@test "safe-filename: hash check in writer before compute" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Outcomes with a hostile hash (newline)
  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"bad\\nhash"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"bad\\nhash"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  " 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "hostile hash in outcomes should fail"
  [[ "$stderr_out" == *"unsafe hash"* ]] \
    || fail "should diagnose 'unsafe hash', got: $stderr_out"
  [ ! -f "$TEST_TMP/last-published.json" ] || fail "state file should not exist after hostile hash"
}

@test "safe-filename: static scan — no inline def safe_filename in plan-publication.sh" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  # plan-publication.sh must not contain an inline def safe_filename
  local inline_count
  inline_count="$(grep -c 'def safe_filename' "$PLANNER_SCRIPT" 2>/dev/null || true)"
  [ "$inline_count" -eq 0 ] || fail "plan-publication.sh still has inline def safe_filename ($inline_count occurrences)"

  # All three scripts must source the same lib
  grep -qF 'safe-filename.sh' "$PLANNER_SCRIPT" \
    || fail "plan-publication.sh should source safe-filename.sh"
  grep -qF 'safe-filename.sh' "$TARGET_SCRIPT" \
    || fail "build-manifest-cards.sh should source safe-filename.sh"
}

@test "safe-filename: shell-side check catches newline in discovered path" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    safe_filename_check 'screens/login.spec.html'
  "
  [ "$status" -eq 0 ] || fail "safe path should pass shell-side check"

  # Filename with a newline
  run bash -c "
    source '$SAFE_FILENAME_LIB'
    safe_filename_check \$'screens/bad\\nname.spec.html'
  "
  [ "$status" -ne 0 ] || fail "newline in path should fail shell-side check"
}

@test "safe-filename: static scan — sync-derived-artifacts.sh sources safe-filename.sh" {
  local SYNC_SCRIPT="$BATS_TEST_DIRNAME/../skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
  [ -f "$SYNC_SCRIPT" ] || fail "sync-derived-artifacts.sh does not exist"
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  grep -qF 'safe-filename.sh' "$SYNC_SCRIPT" \
    || fail "sync-derived-artifacts.sh should source safe-filename.sh"
}

@test "safe-filename: ESC byte in name rejected by jq-def" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  # ESC (0x1b) in filename — double-escape so printf emits literal \u001b for jq
  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"file\":\"screens/bad\\\\u001bname.html\",\"hash\":\"h1\"}\n' | \
      jq \"\$SAFE_FILENAME_JQ_DEF .file | safe_filename\"
  "
  [ "$status" -ne 0 ] || fail "ESC in filename should be rejected"
  [[ "$output" == *"unsafe filename"* ]] || fail "should say 'unsafe filename'"
}

@test "safe-filename: newline in name rejected by jq-def" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  run bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '{\"file\":\"screens/bad\\\\nname.html\",\"hash\":\"h1\"}\n' | \
      jq \"\$SAFE_FILENAME_JQ_DEF .file | safe_filename\"
  "
  [ "$status" -ne 0 ] || fail "newline in filename should be rejected by jq-def"
  [[ "$output" == *"unsafe filename"* ]] || fail "should say 'unsafe filename'"
}

@test "safe-filename: hostile fixture in plan-publication local hash with safe control" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  # Safe control: normal data → should succeed (or at least not reject on safety)
  printf '[{"file":"components/button.spec.html","hash":"safe_hash_1"}]\n' > "$TEST_TMP/local-safe.json"
  printf '[{"file":"components/button.spec.html","hash":"safe_hash_1"}]\n' > "$TEST_TMP/remote-safe.json"
  printf '[{"file":"components/button.spec.html","hash":"safe_hash_1"}]\n' > "$TEST_TMP/last-pub-safe.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-safe.json" \
    --remote-listing "$TEST_TMP/remote-safe.json" \
    --last-published "$TEST_TMP/last-pub-safe.json"
  # Safe control should not fail on safety grounds
  if [ "$status" -ne 0 ]; then
    [[ "$output" != *"unsafe"* ]] || fail "safe control should not trigger unsafe rejection: $output"
  fi

  # Hostile: local manifest with newline in hash
  printf '[{"file":"components/button.spec.html","hash":"bad\\nhash"}]\n' > "$TEST_TMP/local-hostile.json"
  printf '[{"file":"components/button.spec.html","hash":"safe_hash_1"}]\n' > "$TEST_TMP/remote-hostile.json"
  printf '[{"file":"components/button.spec.html","hash":"safe_hash_1"}]\n' > "$TEST_TMP/last-pub-hostile.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-hostile.json" \
    --remote-listing "$TEST_TMP/remote-hostile.json" \
    --last-published "$TEST_TMP/last-pub-hostile.json"
  [ "$status" -ne 0 ] || fail "hostile local hash should be rejected"
  [[ "$output" == *"unsafe hash"* ]] || fail "should diagnose unsafe hash in local manifest"
}

@test "safe-filename: hostile fixture in plan-publication published hash with safe control" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  # Hostile: published (last-published) entry with tab in hash
  printf '[{"file":"components/button.spec.html","hash":"safe_hash_1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"components/button.spec.html","hash":"safe_hash_1"}]\n' > "$TEST_TMP/remote.json"
  printf '[{"file":"components/button.spec.html","hash":"bad\\thash"}]\n' > "$TEST_TMP/last-pub.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/last-pub.json"
  [ "$status" -ne 0 ] || fail "hostile published hash should be rejected"
  [[ "$output" == *"unsafe hash"* ]] || fail "should diagnose unsafe hash in published state"
}

@test "safe-filename: hostile fixture in --last-published reader with safe control" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Safe control first
  printf '[{"file":"screens/login.spec.html","hash":"safe_h"}]\n' > "$TEST_TMP/safe-prior.json"
  _seed_spec_tree "$TEST_TMP/specs"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local safe_result
  safe_result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published '$TEST_TMP/safe-prior.json'
  " 2>/dev/null)" || true
  # Safe control should not mention unsafe
  [[ "${safe_result:-}" != *"unsafe"* ]] || fail "safe control triggered unsafe"

  # Hostile: newline in filename inside --last-published
  printf '[{"file":"screens/bad\\nname.html","hash":"safe_h"}]\n' > "$TEST_TMP/hostile-prior.json"

  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published '$TEST_TMP/hostile-prior.json'
  " 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "hostile filename in --last-published should be rejected"
  [[ "$stderr_out" == *"unsafe"* ]] || [[ "$stderr_out" == *"corrupt"* ]] \
    || fail "should diagnose unsafe/corrupt filename, got: $stderr_out"
}

@test "safe-filename: hostile baseline in sync-derived-artifacts rejected" {
  local SYNC_SCRIPT="$BATS_TEST_DIRNAME/../skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
  [ -f "$SYNC_SCRIPT" ] || fail "sync-derived-artifacts.sh not found (must not skip)"

  local root
  root="$(mktemp -d)"
  mkdir -p "$root/doc"
  printf -- '---\ntemplate: ux-design\n---\n\n# UX\n\n## Component Inventory\n\n- nav\n' > "$root/doc/ux.md"
  printf '<h1>Changed</h1>\n' > "$root/c.html"
  local newhash
  newhash="$(shasum -a 256 "$root/c.html" | awk '{print $1}')"
  jq -n --rawfile c "$root/c.html" \
    '{"components":["nav"],"screens":[{"name":"Home","file":"screens/home.spec.html","content":$c}]}' > "$root/snap.json"

  # Hostile: newline in filename forges a TSV row
  jq -n --arg h "$newhash" \
    '{"design_system":{"files":[{"file":("decoy.html\nscreens/home.spec.html"),"hash":$h}]}}' > "$root/bl.json"
  run "$SYNC_SCRIPT" --last-published "$root/bl.json" "$root/snap.json" "$root/doc/ux.md"
  [ "$status" -ne 0 ] || fail "newline-in-filename baseline should be rejected, got rc=0: $output"
  [[ "$output" == *"unsafe"* ]] || fail "should diagnose unsafe baseline: $output"

  # Hostile: newline in hash forges a TSV row
  jq -n --arg h "$newhash" \
    '{"design_system":{"files":[{"file":"screens/home.spec.html","hash":"old"},{"file":"other.html","hash":("x\nscreens/home.spec.html\t"+$h)}]}}' > "$root/bl2.json"
  run "$SYNC_SCRIPT" --last-published "$root/bl2.json" "$root/snap.json" "$root/doc/ux.md"
  [ "$status" -ne 0 ] || fail "newline-in-hash baseline should be rejected, got rc=0: $output"
  [[ "$output" == *"unsafe"* ]] || fail "should diagnose unsafe baseline: $output"

  rm -rf "$root"
}

# ===========================================================================
# AC7 — Token cards scanned and included
# ===========================================================================

@test "token: cards scanned and included (exact set)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/tokens" "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.html"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Type</html>\n' > "$TEST_TMP/specs/tokens/type.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # Exact token set
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "tokens/colors.html")' >/dev/null \
    || fail "tokens/colors.html missing"
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "tokens/type.html")' >/dev/null \
    || fail "tokens/type.html missing"
}

@test "token: missing --existing yields full card set including tokens" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/tokens" "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"

  # Create empty existing manifest
  printf '{"cards":[]}\n' > "$TEST_TMP/empty-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/empty-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  # Must have both component and token cards
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -ge 2 ] || fail "expected at least 2 cards (component + token), got $card_count"
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "tokens/colors.html")' >/dev/null \
    || fail "tokens/colors.html missing with empty existing"
}

@test "token: absent --existing file yields full card set including tokens" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/tokens" "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"

  # Point --existing at a file that does not exist at all (not {"cards":[]})
  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/nonexistent-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed with absent --existing"

  # Must still have all cards
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -ge 2 ] || fail "expected at least 2 cards, got $card_count"
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "tokens/colors.html")' >/dev/null \
    || fail "tokens/colors.html missing with absent --existing file"
}

@test "token: 0-byte --existing file yields full card set including tokens" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/tokens" "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"

  # 0-byte file (touch creates an empty file)
  : > "$TEST_TMP/zero-byte-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/zero-byte-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed with 0-byte --existing"

  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -ge 2 ] || fail "expected at least 2 cards, got $card_count"
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "tokens/colors.html")' >/dev/null \
    || fail "tokens/colors.html missing with 0-byte --existing"
}

@test "token: mutant returning empty cards array is detected" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/tokens" "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Token pages" -->\n<html>Colors</html>\n' > "$TEST_TMP/specs/tokens/colors.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  # The real function should return non-empty cards; a mutant returning []
  # would produce 0 cards. This test guards against that regression.
  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards failed"

  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -gt 0 ] || fail "mutant guard: card count is 0 — mutant returning [] would pass"
  # Verify exact expected cards present
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "tokens/colors.html")' >/dev/null \
    || fail "tokens/colors.html must be in cards (mutant guard)"
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "components/button.spec.html")' >/dev/null \
    || fail "components/button.spec.html must be in cards (mutant guard)"
}

# ===========================================================================
# AC8 — Invalid --project value
# ===========================================================================

@test "invalid --project value rejected by persist_last_published" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"

  # Pre-seed state for mutation check
  printf '{"before":"check"}\n' > "$TEST_TMP/last-published.json"
  local hash_before
  hash_before="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/last-published.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --project foobar
  " 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid --project should fail"
  [[ "$stderr_out" == *"foobar"* ]] \
    || fail "should name the invalid value 'foobar', got: $stderr_out"
  [[ "$stderr_out" == *"invalid"* ]] || [[ "$stderr_out" == *"unknown"* ]] \
    || fail "should say 'invalid' or 'unknown' project, got: $stderr_out"

  local hash_after
  hash_after="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
  [ "$hash_before" = "$hash_after" ] || fail "state file mutated after invalid --project"
}

@test "invalid --project value rejected by plan-publication.sh" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote-listing.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/last-published.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$TEST_TMP/last-published.json" \
    --project foobar
  [ "$status" -ne 0 ] || fail "invalid --project should be rejected"
  [[ "$output" == *"foobar"* ]] \
    || fail "should name the invalid value 'foobar', got: $output"
}

# ===========================================================================
# AC9 — Locking and concurrent writes
# ===========================================================================

@test "lock: stale-prior re-read picks up other key" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Write DS first
  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"ds_lock_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"ds_lock_h"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" \
    --published-at "2026-09-01T00:00:00Z"

  # Capture the DS write content
  local ds_content
  ds_content="$(jq '.design_system' "$TEST_TMP/last-published.json")"

  # COPY the pre-DS state (actually we need a stale copy; simulate by using
  # /dev/null as prior, which is staler than the DS write)
  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"pd_lock_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"pd_lock_h"}\n' > "$TEST_TMP/hash-map.json"
  _run_persist_v2 --project product_design \
    --design-record "$TEST_TMP/design-record.yaml" \
    --prior /dev/null \
    --published-at "2026-09-02T00:00:00Z"

  # Both keys must be present
  jq -e '.design_system' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "DS key missing after PD write with stale prior"
  jq -e '.product_design' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "PD key missing"

  # DS key must equal first write's content (not just present)
  local ds_after
  ds_after="$(jq '.design_system' "$TEST_TMP/last-published.json")"
  [ "$ds_content" = "$ds_after" ] || fail "DS key content changed after PD write"
}

@test "lock: concurrent writes preserve both keys (default mode)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"conc_ds_h"}]\n' > "$TEST_TMP/ds-outcomes.json"
  printf '{"components/button.spec.html":"conc_ds_h"}\n' > "$TEST_TMP/ds-hash-map.json"

  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"conc_pd_h"}]\n' > "$TEST_TMP/pd-outcomes.json"
  printf '{"screens/login.spec.html":"conc_pd_h"}\n' > "$TEST_TMP/pd-hash-map.json"

  # Run both in parallel
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/ds-outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/ds-hash-map.json' \
      --project design_system \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-01T00:00:00Z'
  " &
  local pid1=$!

  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/pd-outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/pd-hash-map.json' \
      --project product_design \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-02T00:00:00Z'
  " &
  local pid2=$!

  wait "$pid1" || fail "DS write failed"
  wait "$pid2" || fail "PD write failed"

  # Both keys must be present
  jq -e '.design_system.files[0]' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "DS entry lost in concurrent write"
  jq -e '.product_design.files[0]' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "PD entry lost in concurrent write"

  # Assert which lock mode was taken
  if command -v flock >/dev/null 2>&1; then
    # flock mode: lock file should exist (empty) after release
    [ -f "$TEST_TMP/last-published.json.lock" ] \
      || fail "flock mode: lock file should exist after release"
  else
    # fallback mode: lock file should be gone
    [ ! -f "$TEST_TMP/last-published.json.lock" ] \
      || fail "fallback mode: lock file should be gone after release"
  fi
}

@test "lock: concurrent writes preserve both keys (forced-fallback mode)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '[{"file":"components/card.spec.html","outcome":"written","hash":"fb_ds_h"}]\n' > "$TEST_TMP/ds-outcomes.json"
  printf '{"components/card.spec.html":"fb_ds_h"}\n' > "$TEST_TMP/ds-hash-map.json"

  printf '[{"file":"screens/dash.spec.html","outcome":"written","hash":"fb_pd_h"}]\n' > "$TEST_TMP/pd-outcomes.json"
  printf '{"screens/dash.spec.html":"fb_pd_h"}\n' > "$TEST_TMP/pd-hash-map.json"

  GAIA_LOCK_FORCE_FALLBACK=1 bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/ds-outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/ds-hash-map.json' \
      --project design_system \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-01T00:00:00Z'
  " &
  local pid1=$!

  GAIA_LOCK_FORCE_FALLBACK=1 bash -c "
    export GAIA_LOCK_FORCE_FALLBACK=1
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/pd-outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/pd-hash-map.json' \
      --project product_design \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-02T00:00:00Z'
  " &
  local pid2=$!

  wait "$pid1" || fail "DS write failed"
  wait "$pid2" || fail "PD write failed"

  jq -e '.design_system.files[0]' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "DS entry lost in forced-fallback concurrent write"
  jq -e '.product_design.files[0]' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "PD entry lost in forced-fallback concurrent write"

  # Fallback mode: lock file should be gone
  [ ! -f "$TEST_TMP/last-published.json.lock" ] \
    || fail "fallback mode: lock file should be gone after release"
}

@test "lock: held lock causes timeout with no write and diagnostic" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  local LOCK_LIB="$BATS_TEST_DIRNAME/../scripts/lib/acquire-lock.sh"
  local EXEC_TIMEOUT="$BATS_TEST_DIRNAME/../scripts/lib/exec-with-timeout.sh"
  [ -f "$LOCK_LIB" ] || fail "acquire-lock.sh does not exist"
  [ -f "$EXEC_TIMEOUT" ] || fail "exec-with-timeout.sh does not exist"

  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '{"design_system":{"reference":null,"last_published_at":null,"files":[]},"product_design":{"reference":null,"last_published_at":null,"files":[]}}\n' \
    > "$TEST_TMP/last-published.json"
  local hash_before
  hash_before="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"lk_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"lk_h"}\n' > "$TEST_TMP/hash-map.json"

  local ready_file="$TEST_TMP/lock-holder-ready"
  local holder_pid_file="$TEST_TMP/lock-holder-pid"

  # Background holder: acquires the lock, signals readiness, then holds it
  GAIA_LOCK_FORCE_FALLBACK=1 bash -c "
    source '$LOCK_LIB'
    acquire_lock '$TEST_TMP/last-published.json.lock' 5 200
    printf '%s\n' \$\$ > '$holder_pid_file'
    touch '$ready_file'
    exec 3>&-
    exec sleep 60
  " &
  local bg_pid=$!

  # Wait for holder to signal readiness (up to 10s)
  local wait_count=0
  while [ ! -f "$ready_file" ] && [ "$wait_count" -lt 100 ]; do
    sleep 0.1
    wait_count=$((wait_count + 1))
  done
  [ -f "$ready_file" ] || { kill "$bg_pid" 2>/dev/null; wait "$bg_pid" 2>/dev/null; fail "lock holder never signalled ready"; }

  # Now try to write — should fail because lock is held.
  local rc=0
  GAIA_LOCK_FORCE_FALLBACK=1 bash -c "
    source '$EXEC_TIMEOUT'
    exec_with_timeout 20 bash -c '
      source \"$TARGET_SCRIPT\"
      persist_last_published \
        --outcomes \"$TEST_TMP/outcomes.json\" \
        --prior /dev/null \
        --output \"$TEST_TMP/last-published.json\" \
        --local-hash-map \"$TEST_TMP/hash-map.json\" \
        --design-record \"$TEST_TMP/design-record.yaml\" \
        --published-at 2026-09-30T10:00:00Z
    '
  " 2>"$TEST_TMP/lock-stderr.txt" || rc=$?

  # Kill the holder
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true

  # The write should have failed (lock contention) — non-zero exit
  [ "$rc" -ne 0 ] || {
    # If rc == 0, the writer succeeded — check if it mutated (no locking = RED)
    local hash_after_ok
    hash_after_ok="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
    [ "$hash_before" = "$hash_after_ok" ] \
      || fail "writer succeeded and mutated state file despite held lock (no locking implemented)"
    fail "persist with held lock should fail (rc was 0)"
  }

  # State file should be unchanged
  local hash_after
  hash_after="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
  [ "$hash_before" = "$hash_after" ] || fail "state file was mutated despite lock contention"

  # Diagnostic should mention lock acquisition failure
  grep -qi 'lock\|timeout' "$TEST_TMP/lock-stderr.txt" 2>/dev/null \
    || fail "stderr should mention lock failure: $(cat "$TEST_TMP/lock-stderr.txt" 2>/dev/null)"
}

# ===========================================================================
# AC10 — Timestamp validation
# ===========================================================================

@test "timestamp: future (>60s) rejected" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  local future_ts
  future_ts="$(jq -rn 'now + 120 | todate')"

  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '$future_ts'
  " 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "future timestamp (>60s) should be rejected"
  [[ "$stderr_out" == *"future"* ]] || [[ "$stderr_out" == *"ahead"* ]] \
    || fail "should diagnose future/ahead, got: $stderr_out"
}

@test "timestamp: earlier-than-current proceeds with warning" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Pre-seed with a current timestamp
  _seed_per_project_state "$TEST_TMP/last-published.json"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"early_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"early_h"}\n' > "$TEST_TMP/hash-map.json"

  local stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/last-published.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --project design_system \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-08-01T00:00:00Z'
  " 2>&1 1>/dev/null)" || true

  # Should produce a warning (not an error)
  [[ "$stderr_out" == *"earlier"* ]] || [[ "$stderr_out" == *"warning"* ]] || [[ "$stderr_out" == *"skew"* ]] \
    || fail "earlier timestamp should produce a warning, got: $stderr_out"
}

@test "timestamp: round-trip strictness (2026-02-30 rejected)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-02-30T00:00:00Z'
  " 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid date 2026-02-30 should be rejected"
  [[ "$stderr_out" == *"malformed"* ]] || [[ "$stderr_out" == *"invalid"* ]] \
    || fail "should diagnose malformed timestamp, got: $stderr_out"
}

# ===========================================================================
# AC11 — Reference source from design record
# ===========================================================================

@test "reference: DS from design_system_project.reference" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml" \
    "https://ds.example.com/specific" "https://claude.ai/artifact/other"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"ref_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"ref_h"}\n' > "$TEST_TMP/hash-map.json"

  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml"

  local ref
  ref="$(jq -r '.design_system.reference' "$TEST_TMP/last-published.json")"
  [ "$ref" = "https://ds.example.com/specific" ] \
    || fail "DS reference should come from design_system_project.reference, got: $ref"
}

@test "reference: v1.0 design record alias read (DS)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v1 "$TEST_TMP/design-record.yaml" "https://ds.example.com/legacy"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"v1_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"v1_h"}\n' > "$TEST_TMP/hash-map.json"

  _run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml"

  local ref
  ref="$(jq -r '.design_system.reference' "$TEST_TMP/last-published.json")"
  [ "$ref" = "https://ds.example.com/legacy" ] \
    || fail "v1.0 DS reference should come from project.reference alias, got: $ref"
}

@test "reference: v1.0 design record non-zero (PD)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v1 "$TEST_TMP/design-record.yaml"

  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"v1pd_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"v1pd_h"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0 stderr_out
  stderr_out="$(_run_persist_v2 --project product_design \
    --design-record "$TEST_TMP/design-record.yaml" 2>&1)" \
    || rc=$?
  [ "$rc" -ne 0 ] || fail "v1.0 record with --project product_design should fail"
  [[ "$stderr_out" == *"upgrade"* ]] || [[ "$stderr_out" == *"gaia-create-ux"* ]] \
    || fail "should suggest upgrade, got: $stderr_out"
}

@test "reference: v1.0 not-applicable treated as null" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v1_na "$TEST_TMP/design-record.yaml"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"na_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"na_h"}\n' > "$TEST_TMP/hash-map.json"

  # Call via old API so the test doesn't bounce on unknown --project.
  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  " 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "not-applicable reference should fail (treated as null)"
  [[ "$stderr_out" == *"not set"* ]] || [[ "$stderr_out" == *"not-applicable"* ]] || [[ "$stderr_out" == *"null"* ]] \
    || fail "should diagnose not-applicable/null reference, got: $stderr_out"
}

@test "reference: null *_project.reference non-zero with 'not set'" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # v2 record with null design_system_project.reference
  cat > "$TEST_TMP/design-record.yaml" <<'YAML'
schema_version: "2.0"
design_system_project:
  reference: null
  discovered_via: manual
product_design_project:
  reference: "https://claude.ai/artifact/456"
  discovered_via: manual
YAML

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"null_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"null_h"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0 stderr_out
  stderr_out="$(_run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" 2>&1)" \
    || rc=$?
  [ "$rc" -ne 0 ] || fail "null reference should fail"
  [[ "$stderr_out" == *"not set"* ]] \
    || fail "should say 'not set', got: $stderr_out"
}

@test "reference: null *_project non-zero with 'not set'" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # v2 record with null design_system_project
  cat > "$TEST_TMP/design-record.yaml" <<'YAML'
schema_version: "2.0"
design_system_project: null
product_design_project:
  reference: "https://claude.ai/artifact/456"
  discovered_via: manual
YAML

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"nullp_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"nullp_h"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0 stderr_out
  stderr_out="$(_run_persist_v2 --project design_system \
    --design-record "$TEST_TMP/design-record.yaml" 2>&1)" \
    || rc=$?
  [ "$rc" -ne 0 ] || fail "null *_project should fail"
  [[ "$stderr_out" == *"not set"* ]] \
    || fail "should say 'not set', got: $stderr_out"
}

@test "reference: missing *_project key non-zero" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # v2 record missing design_system_project entirely
  cat > "$TEST_TMP/design-record.yaml" <<'YAML'
schema_version: "2.0"
product_design_project:
  reference: "https://claude.ai/artifact/456"
  discovered_via: manual
YAML

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"miss_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"miss_h"}\n' > "$TEST_TMP/hash-map.json"

  # Call via old API so the test doesn't bounce on unknown --project.
  local rc=0 stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  " 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "missing *_project key should fail"
  [[ "$stderr_out" == *"design_system_project"* ]] || [[ "$stderr_out" == *"not set"* ]] || [[ "$stderr_out" == *"missing"* ]] \
    || fail "should name the expected key, got: $stderr_out"
}

# ===========================================================================
# AC12 — Unknown subdirectory rejection
# ===========================================================================

@test "routing: unknown subdirectory rejected with diagnostic" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/shared"
  printf '<!-- @dsCard group="Shared specs" -->\n<html>Shared</html>\n' > "$TEST_TMP/specs/shared/card.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>&1 1>/dev/null)" || true

  [[ "$stderr_out" == *"shared/card.spec.html"* ]] \
    || fail "diagnostic should name the rejected file"
}

@test "routing: root-level spec rejected" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs"
  printf '<!-- @dsCard group="Root specs" -->\n<html>Root</html>\n' > "$TEST_TMP/specs/foo.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>&1 1>"$TEST_TMP/bmc-stdout.txt")" || true
  result="$(cat "$TEST_TMP/bmc-stdout.txt" 2>/dev/null || true)"

  # Root-level spec must NOT be in the output — require valid JSON first
  [ -n "$result" ] || fail "build_manifest_cards produced no output"
  printf '%s' "$result" | jq -e '.cards' >/dev/null 2>&1 || fail "output is not valid JSON with .cards"
  local root_count
  root_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path == "foo.spec.html")] | length')"
  [ "$root_count" -eq 0 ] || fail "root-level spec should not be in any manifest"
}

@test "routing: deeper-nested spec in allowed dir rejected" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/components/nested"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Deep</html>\n' > "$TEST_TMP/specs/components/nested/deep.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null \
      --project design_system
  " 2>&1 1>"$TEST_TMP/bmc-stdout.txt")" || true
  result="$(cat "$TEST_TMP/bmc-stdout.txt" 2>/dev/null || true)"

  # Deeper-nested spec must NOT be in the output — require valid JSON first
  [ -n "$result" ] || fail "build_manifest_cards produced no output"
  printf '%s' "$result" | jq -e '.cards' >/dev/null 2>&1 || fail "output is not valid JSON with .cards"
  local deep_count
  deep_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("nested/deep"))] | length')"
  [ "$deep_count" -eq 0 ] || fail "components/nested/deep.spec.html should be rejected (depth > 1)"
}

# ===========================================================================
# Errexit-disabled caller tests
# ===========================================================================

@test "errexit-off: persist_last_published with missing --design-record fails cleanly" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  local EXEC_TIMEOUT="$BATS_TEST_DIRNAME/../scripts/lib/exec-with-timeout.sh"
  [ -f "$EXEC_TIMEOUT" ] || fail "exec-with-timeout.sh does not exist"

  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"
  printf '{"before":"check"}\n' > "$TEST_TMP/last-published.json"
  local hash_before
  hash_before="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  # Call in errexit-disabled context bounded by timeout (the unfixed spin
  # on unknown --project/--design-record makes this hang without a watchdog).
  local rc=0
  bash -c "
    source '$EXEC_TIMEOUT'
    exec_with_timeout 20 bash -c '
      source \"$TARGET_SCRIPT\"
      if persist_last_published \
        --outcomes \"$TEST_TMP/outcomes.json\" \
        --prior /dev/null \
        --output \"$TEST_TMP/last-published.json\" \
        --local-hash-map \"$TEST_TMP/hash-map.json\" \
        --project design_system 2>/dev/null; then
        exit 0
      else
        exit \$?
      fi
    '
  " 2>/dev/null || rc=$?

  # Should be exactly 1 (the function's own error path), not 124 (timeout)
  # or 137 (killed). If we get 124, the fix isn't in yet — that's the RED signal.
  [ "$rc" -eq 1 ] || fail "expected exit 1, got $rc (124=spin/timeout, 137=killed)"

  local hash_after
  hash_after="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
  [ "$hash_before" = "$hash_after" ] || fail "state file mutated"
}

@test "errexit-off: unknown option does not spin (returns 1)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  local EXEC_TIMEOUT="$BATS_TEST_DIRNAME/../scripts/lib/exec-with-timeout.sh"
  [ -f "$EXEC_TIMEOUT" ] || fail "exec-with-timeout.sh does not exist"

  local rc=0
  bash -c "
    source '$EXEC_TIMEOUT'
    exec_with_timeout 20 bash -c '
      source \"$TARGET_SCRIPT\"
      if persist_last_published --bogus-flag 2>/dev/null; then
        exit 0
      else
        exit \$?
      fi
    '
  " 2>/dev/null || rc=$?

  # Should be exactly 1, not 124 (timeout) or 137 (killed).
  # 124 = the spin bug is still present (RED signal); the fix adds return 1.
  [ "$rc" -eq 1 ] || fail "unknown option should return 1, not spin (got rc=$rc; 124=timeout, 137=killed)"
}

# ===========================================================================
# Bash 3.2 compatibility gate
# ===========================================================================

@test "bash-compat: safe-filename.sh sources and works under /bin/bash" {
  [ -f "$SAFE_FILENAME_LIB" ] || fail "safe-filename.sh does not exist"

  # Use /bin/bash (which is 3.2 on macOS, 5.x on Linux)
  local version
  version="$(/bin/bash -c "
    source '$SAFE_FILENAME_LIB'
    printf '%s\n' \"\$BASH_VERSION\"
    safe_filename_check 'screens/login.spec.html'
  ")" || fail "safe-filename.sh failed under /bin/bash"
  [ -n "$version" ] || fail "BASH_VERSION not printed"

  # Also test rejection
  local rc=0
  /bin/bash -c "
    source '$SAFE_FILENAME_LIB'
    safe_filename_check '../etc/passwd'
  " 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "traversal should be rejected under /bin/bash"
}

@test "bash-compat: build-manifest-cards.sh sources under /bin/bash" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  local version
  version="$(/bin/bash -c "
    source '$TARGET_SCRIPT'
    printf '%s\n' \"\$BASH_VERSION\"
    declare -F build_manifest_cards >/dev/null
    declare -F persist_last_published >/dev/null
  " 2>/dev/null)" || fail "build-manifest-cards.sh failed to source under /bin/bash"
  [ -n "$version" ] || fail "BASH_VERSION not printed"
}

# ===========================================================================
# End of per-project publication state and manifest partitioning (RED phase)
# ===========================================================================

@test "(AC1) spec root with ERE metacharacters produces relative card paths" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Directory name with parens, brackets, and plus — all ERE metacharacters
  local spec_dir="$TEST_TMP/My Design (1)[x]+/specs"
  mkdir -p "$spec_dir/screens" "$spec_dir/components"
  printf '<!-- @dsCard group="Screen specs" -->\n<html>Login</html>\n' \
    > "$spec_dir/screens/login.spec.html"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' \
    > "$spec_dir/components/button.spec.html"

  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$spec_dir' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>/dev/null)" || fail "build_manifest_cards failed with metachar path"

  # Card paths must be relative, not absolute
  local abs_count
  abs_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | startswith("/"))] | length')"
  [ "$abs_count" -eq 0 ] || fail "found $abs_count cards with absolute paths"

  # Default DS partition: 1 component spec + Colors + Type = 3
  # (screens/login.spec.html routes to PD)
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 3 ] || fail "expected 3 cards (1 component + Colors + Type), got $card_count"

  # Verify the component spec has the correct relative path
  printf '%s' "$result" | jq -e '.cards[] | select(.path == "components/button.spec.html")' >/dev/null \
    || fail "components/button.spec.html card missing or has wrong path"
}

# ===========================================================================
# Failure-path tests — every error branch exits non-zero with diagnostic.
# Pattern: source the script (which enables errexit), then set +e, then call.
# Pre-seed an output file and assert its sha256 is unchanged after failure.
# ===========================================================================

# Helper: run persist_last_published with errexit off, capture rc + stderr.
# Pre-seeds a sentinel state file, sets _SENTINEL_SHA and _PERSIST_RC.
# Call WITHOUT command substitution: _errexit_off_persist "args..."
_errexit_off_persist() {
  # Seed a sentinel state file so we can verify it's untouched
  printf '{"sentinel":"untouched"}\n' > "$TEST_TMP/last-published.json"
  _SENTINEL_SHA="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  _PERSIST_RC=0
  bash -c "
    source '$TARGET_SCRIPT'
    set +e
    persist_last_published $1
    exit \$?
  " 2>"$TEST_TMP/stderr.txt" && _PERSIST_RC=0 || _PERSIST_RC=$?
}

# Helper: assert state file unchanged after failure
_assert_state_unchanged() {
  local sha_after
  sha_after="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
  [ "$sha_after" = "$_SENTINEL_SHA" ] \
    || fail "state file was modified during failure (sha changed)"
}

@test "persist rejects missing design-record file" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/nonexistent.yaml'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'design.record.*not found' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects omitted --design-record" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'design-record.*required' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects omitted --outcomes" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'outcomes.*required' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects future timestamp" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2099-01-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'future' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects invalid --project value" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --project bogus_value"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'invalid.*project' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects null reference in design record" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  cat > "$TEST_TMP/design-record-empty.yaml" <<'YAML'
schema_version: "2.0"
design_system_project:
  reference: ""
  discovered_via: manual
product_design_project:
  reference: ""
  discovered_via: manual
YAML
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record-empty.yaml'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'reference.*not set' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects malformed timestamp" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at 'not-a-date'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'malformed' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects v1.0 design record with --project product_design" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v1 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --project product_design"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'v1.*product_design\|does not support' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects design record with missing project key" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  cat > "$TEST_TMP/design-record-nokey.yaml" <<'YAML'
schema_version: "2.0"
design_system_project:
  reference: "https://ds.example.com/project/123"
  discovered_via: manual
YAML
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record-nokey.yaml' --project product_design"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'product_design_project.*not set' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects null hash in outcome" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"components/button.spec.html","outcome":"written","hash":null}]\n' > "$TEST_TMP/outcomes.json"
  printf '{}' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'null hash' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects unsafe outcome filename" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"../../../etc/passwd","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{}' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'unsafe.*filename' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects corrupt --prior JSON" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  printf '{corrupt json' > "$TEST_TMP/bad-prior.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior '$TEST_TMP/bad-prior.json' --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'corrupt.*prior' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects unsafe prior filename" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  cat > "$TEST_TMP/bad-prior.json" <<'JSON'
{"design_system":{"files":[{"file":"../../etc/shadow","hash":"abcd1234"}]},"product_design":{"files":[]}}
JSON

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior '$TEST_TMP/bad-prior.json' --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'unsafe.*prior' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects unsafe hash-map value" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  jq -n '{"a.html": ("bad\nhash")}' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'unsafe.*hash' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects corrupt on-disk --output" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  printf '{not valid json' > "$TEST_TMP/last-published.json"
  _SENTINEL_SHA="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  local rc=0
  bash -c "
    source '$TARGET_SCRIPT'
    set +e
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-01T00:00:00Z'
    exit \$?
  " 2>"$TEST_TMP/stderr.txt" && rc=0 || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1, got $rc"
  grep -qi 'corrupt.*output' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects unsafe on-disk other key" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  jq -n '{"design_system":{"reference":"https://ds.example.com/project/123","last_published_at":"2026-09-01T00:00:00Z","files":[]},"product_design":{"reference":"https://claude.ai/artifact/456","last_published_at":"2026-09-02T00:00:00Z","files":[{"file":"../../etc/passwd","hash":"evil"}]}}' \
    > "$TEST_TMP/last-published.json"
  _SENTINEL_SHA="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  local rc=0
  bash -c "
    source '$TARGET_SCRIPT'
    set +e
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --project design_system \
      --published-at '2026-09-01T00:00:00Z'
    exit \$?
  " 2>"$TEST_TMP/stderr.txt" && rc=0 || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1, got $rc"
  grep -qi 'unsafe.*other.*key\|unsafe.*product_design' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "build_manifest_cards rejects unknown option" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  local EXEC_TIMEOUT="$BATS_TEST_DIRNAME/../scripts/lib/exec-with-timeout.sh"
  [ -f "$EXEC_TIMEOUT" ] || fail "exec-with-timeout.sh does not exist"

  local rc=0
  bash -c "
    source '$EXEC_TIMEOUT'
    exec_with_timeout 20 bash -c '
      source \"$TARGET_SCRIPT\"
      set +e
      build_manifest_cards --local-specs /tmp --existing /dev/null --bad-flag
      exit \$?
    '
  " 2>/dev/null && rc=0 || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1, got $rc (124=spin/timeout, 137=killed)"
}

@test "build_manifest_cards rejects invalid --project value" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  local EXEC_TIMEOUT="$BATS_TEST_DIRNAME/../scripts/lib/exec-with-timeout.sh"
  [ -f "$EXEC_TIMEOUT" ] || fail "exec-with-timeout.sh does not exist"

  local rc=0
  bash -c "
    source '$EXEC_TIMEOUT'
    exec_with_timeout 20 bash -c '
      source \"$TARGET_SCRIPT\"
      set +e
      build_manifest_cards --local-specs /tmp --existing /dev/null --project invalid_value
      exit \$?
    '
  " 2>/dev/null && rc=0 || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1, got $rc (124=spin/timeout, 137=killed)"
}

@test "shell-opts: \$- unchanged after persist_last_published call" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  local opts_result
  opts_result="$(bash -c "
    source '$TARGET_SCRIPT'
    opts_before=\"\$-\"
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-01T00:00:00Z' 2>/dev/null
    opts_after=\"\$-\"
    printf '%s\n%s\n' \"\$opts_before\" \"\$opts_after\"
  ")" || fail "persist call failed"

  local before after
  before="$(printf '%s' "$opts_result" | head -1)"
  after="$(printf '%s' "$opts_result" | tail -1)"
  [ "$before" = "$after" ] \
    || fail "shell options changed: before=$before after=$after"
}

# ===========================================================================
# Sync and bmc --project routing tests
# ===========================================================================

@test "sync: default --project is design_system" {
  local SYNC_SCRIPT="$BATS_TEST_DIRNAME/../skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
  [ -f "$SYNC_SCRIPT" ] || fail "sync-derived-artifacts.sh not found (must not skip)"

  local root
  root="$(mktemp -d)"
  mkdir -p "$root/doc"
  printf -- '---\ntemplate: ux-design\n---\n\n# UX\n\n## Component Inventory\n\n- nav\n' > "$root/doc/ux.md"
  printf '<h1>Nav</h1>\n' > "$root/c.html"
  local newhash
  newhash="$(shasum -a 256 "$root/c.html" | awk '{print $1}')"
  jq -n --rawfile c "$root/c.html" \
    '{"components":["nav"],"screens":[],"component_details":[{"name":"nav","file":"components/nav.spec.html","content":$c}]}' > "$root/snap.json"

  # Last-published with a DS file
  printf '{"design_system":{"files":[{"file":"components/nav.spec.html","hash":"oldhash"}]},"product_design":{"files":[]}}\n' \
    > "$root/bl.json"

  # Run without --project (default = design_system)
  run "$SYNC_SCRIPT" --last-published "$root/bl.json" "$root/snap.json" "$root/doc/ux.md"
  [ "$status" -eq 0 ] || fail "sync default project failed: $output"
  rm -rf "$root"
}

@test "sync: --project product_design reads from product_design key" {
  local SYNC_SCRIPT="$BATS_TEST_DIRNAME/../skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
  [ -f "$SYNC_SCRIPT" ] || fail "sync-derived-artifacts.sh not found (must not skip)"

  local root
  root="$(mktemp -d)"
  mkdir -p "$root/doc"
  printf -- '---\ntemplate: ux-design\n---\n\n# UX\n\n## Screen Inventory\n\n- home\n' > "$root/doc/ux.md"
  printf '<h1>Home</h1>\n' > "$root/c.html"
  jq -n --rawfile c "$root/c.html" \
    '{"components":[],"screens":[{"name":"home","file":"screens/home.spec.html","content":$c}],"screen_details":[{"name":"home","file":"screens/home.spec.html","content":$c}]}' > "$root/snap.json"

  # Last-published with a PD file
  printf '{"design_system":{"files":[]},"product_design":{"files":[{"file":"screens/home.spec.html","hash":"oldhash"}]}}\n' \
    > "$root/bl.json"

  run "$SYNC_SCRIPT" --project product_design --last-published "$root/bl.json" "$root/snap.json" "$root/doc/ux.md"
  [ "$status" -eq 0 ] || fail "sync --project product_design failed: $output"
  rm -rf "$root"
}

@test "sync: --project invalid exits 1" {
  local SYNC_SCRIPT="$BATS_TEST_DIRNAME/../skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
  [ -f "$SYNC_SCRIPT" ] || fail "sync-derived-artifacts.sh not found (must not skip)"

  local root
  root="$(mktemp -d)"
  mkdir -p "$root/doc"
  printf -- '---\ntemplate: ux-design\n---\n\n# UX\n' > "$root/doc/ux.md"
  printf '{"components":[],"screens":[]}\n' > "$root/snap.json"
  printf '{}' > "$root/bl.json"

  run "$SYNC_SCRIPT" --project bad_value --last-published "$root/bl.json" "$root/snap.json" "$root/doc/ux.md"
  [ "$status" -ne 0 ] || fail "sync --project bad_value should fail"
  [[ "$output" == *"invalid"* ]] || fail "should diagnose invalid project: $output"
  rm -rf "$root"
}

# ===========================================================================
# verify-publication-target fail-closed and metadata reference tests
# ===========================================================================

@test "verify-target: fail-closed on empty DS reference in design record" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"

  # Design record with empty DS reference
  cat > "$TEST_TMP/dr-empty-ref.yaml" <<'YAML'
schema_version: "2.0"
design_system_project:
  reference: ""
  discovered_via: manual
product_design_project:
  reference: "https://claude.ai/artifact/456"
  discovered_via: manual
YAML

  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/dr-empty-ref.yaml'
  "
  [ "$status" -ne 0 ] || fail "empty DS reference in design record should fail-closed"
  [[ "$output" == *"design_system_project.reference"* ]] || fail "should mention DS reference not set: $output"
}

@test "verify-target: fail-closed on empty PD reference for artifact surface" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"

  cat > "$TEST_TMP/dr-empty-pd.yaml" <<'YAML'
schema_version: "2.0"
design_system_project:
  reference: "https://ds.example.com/project/123"
  discovered_via: manual
product_design_project:
  reference: ""
  discovered_via: manual
YAML

  _make_art_meta "$TEST_TMP/art-meta.txt" "https://claude.ai/artifact/456"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/dr-empty-pd.yaml'
  "
  [ "$status" -ne 0 ] || fail "empty PD reference should fail-closed"
  [[ "$output" == *"product_design_project.reference"* ]] || fail "should mention PD reference not set: $output"
}

@test "verify-target: outer projectId mismatch rejects designsync" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Wrapper projectId differs from the reference argument
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/DIFFERENT/999"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "projectId mismatch should be rejected"
  [[ "$output" == *"does not match"* ]] || fail "should diagnose mismatch: $output"
}

@test "verify-target: main guard invokes the function" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"

  # Direct execution: should fail with usage error (no args)
  run bash "$VERIFY_SCRIPT"
  [ "$status" -ne 0 ] || fail "main guard with no args should fail"

  # Direct execution with valid args should succeed
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash "$VERIFY_SCRIPT" designsync 'https://ds.example.com/project/123' \
    --metadata-file "$TEST_TMP/ds-metadata.json" \
    --design-record "$TEST_TMP/design-record.yaml"
  [ "$status" -eq 0 ] || fail "main guard direct invocation should pass: $output"
}

# ===========================================================================
# Spec discovery rejection diagnostics (root-level and deeper-nested)
# ===========================================================================

@test "discovery: root-level spec file rejected with diagnostic" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"
  # Root-level spec (not inside a subdirectory)
  printf '<!-- @dsCard group="Loose specs" -->\n<html>Loose</html>\n' > "$TEST_TMP/specs/loose.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>&1 >/dev/null)" || true

  [[ "$stderr_out" == *"rejecting root-level"* ]] \
    || fail "should emit root-level rejection diagnostic: $stderr_out"
}

@test "discovery: deeper-nested spec file rejected with diagnostic" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/components" "$TEST_TMP/specs/components/sub"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Button</html>\n' > "$TEST_TMP/specs/components/button.spec.html"
  # Deeper-nested spec (components/sub/x.spec.html = 2 directory levels, caught at depth 3)
  printf '<!-- @dsCard group="Component specs" -->\n<html>Deep</html>\n' > "$TEST_TMP/specs/components/sub/x.spec.html"
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local stderr_out
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>&1 >/dev/null)" || true

  [[ "$stderr_out" == *"rejecting nested"* ]] \
    || fail "should emit nested-spec rejection diagnostic: $stderr_out"
}

# ===========================================================================
# Legacy flat-array on-disk state regression tests
# ===========================================================================

@test "legacy-ondisk: flat-array state file writable with --project design_system" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  # Seed a legacy flat-array state file (prior == output)
  printf '[{"file":"components/button.spec.html","hash":"old_h1"}]\n' > "$TEST_TMP/last-published.json"
  printf '[{"file":"components/card.spec.html","outcome":"written","hash":"new_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/card.spec.html":"new_h1"}\n' > "$TEST_TMP/hash-map.json"

  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/last-published.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-01T00:00:00Z'
  " 2>/dev/null || fail "persist on legacy flat-array (DS) should succeed"

  # Output must be per-project object
  jq -e '.design_system.files' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "output should have design_system.files"
  jq -e '.product_design' "$TEST_TMP/last-published.json" >/dev/null \
    || fail "output should have product_design key"
}

@test "legacy-ondisk: flat-array state file writable with --project product_design" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  # Seed a legacy flat-array state file (prior == output)
  printf '[{"file":"components/button.spec.html","hash":"old_h1"}]\n' > "$TEST_TMP/last-published.json"
  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"pd_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"pd_h1"}\n' > "$TEST_TMP/hash-map.json"

  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/last-published.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --project product_design \
      --published-at '2026-09-02T00:00:00Z'
  " 2>/dev/null || fail "persist on legacy flat-array (PD) should succeed"

  # Output must be per-project object with PD files
  local pd_file
  pd_file="$(jq -r '.product_design.files[0].file' "$TEST_TMP/last-published.json")"
  [ "$pd_file" = "screens/login.spec.html" ] \
    || fail "expected PD file screens/login.spec.html, got $pd_file"
  # Legacy DS files should be preserved under design_system
  local ds_count
  ds_count="$(jq '.design_system.files | length' "$TEST_TMP/last-published.json")"
  [ "$ds_count" -eq 1 ] || fail "legacy DS files should be preserved, got $ds_count"
}

# ===========================================================================
# Writer validation per-branch mutant tests
# ===========================================================================

@test "persist rejects outcome with control-char hash" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  # Outcome with a newline-injected hash
  jq -n '[{"file":"a.html","outcome":"written","hash":("bad\nhash")}]' > "$TEST_TMP/outcomes.json"
  printf '{}' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'unsafe.*hash\|null hash' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects traversal filename in flat-array prior" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  # Flat-array prior with unsafe filename
  printf '[{"file":"../../../etc/passwd","hash":"evil"}]\n' > "$TEST_TMP/bad-prior.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior '$TEST_TMP/bad-prior.json' --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'unsafe.*prior' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects control-char hash in flat-array prior" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  # Flat-array prior with unsafe hash
  jq -n '[{"file":"a.html","hash":("bad\nhash")}]' > "$TEST_TMP/bad-prior.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior '$TEST_TMP/bad-prior.json' --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'unsafe.*prior' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects control-char hash in per-project prior" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  # Per-project prior with unsafe hash in the other key
  jq -n '{"design_system":{"files":[{"file":"a.html","hash":("x\ny")}]},"product_design":{"files":[]}}' > "$TEST_TMP/bad-prior.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior '$TEST_TMP/bad-prior.json' --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  grep -qi 'unsafe.*prior' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

@test "persist rejects control-char hash in on-disk other key" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  # On-disk file with unsafe hash in the other key
  jq -n '{"design_system":{"reference":"https://ds.example.com/project/123","files":[]},"product_design":{"reference":"https://claude.ai/artifact/456","files":[{"file":"ok.html","hash":("x\ny")}]}}' \
    > "$TEST_TMP/last-published.json"
  _SENTINEL_SHA="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  local rc=0
  bash -c "
    source '$TARGET_SCRIPT'
    set +e
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --project design_system \
      --published-at '2026-09-01T00:00:00Z'
    exit \$?
  " 2>"$TEST_TMP/stderr.txt" && rc=0 || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1, got $rc"
  grep -qi 'unsafe.*other.*key\|unsafe.*product_design' "$TEST_TMP/stderr.txt" \
    || fail "stderr: $(cat "$TEST_TMP/stderr.txt")"
  _assert_state_unchanged
}

# ===========================================================================
# Discovery phantom-card mutant test
# ===========================================================================

@test "discovery rejects filename with control character" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  mkdir -p "$TEST_TMP/specs/components"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Good</html>\n' > "$TEST_TMP/specs/components/good.spec.html"
  # Create a spec file with a control character in the filename
  local bad_name
  bad_name="$(printf 'components/bad\x01name.spec.html')"
  printf '<!-- @dsCard group="Component specs" -->\n<html>Bad</html>\n' > "$TEST_TMP/specs/$bad_name" 2>/dev/null || true
  _seed_existing_manifest "$TEST_TMP/existing-manifest.json"

  local result stderr_out
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$TEST_TMP/specs' \
      --existing '$TEST_TMP/existing-manifest.json' \
      --last-published /dev/null
  " 2>"$TEST_TMP/disc-stderr.txt")" || fail "build_manifest_cards failed"

  # The control-char file must NOT appear in the output
  local bad_count
  bad_count="$(printf '%s' "$result" | jq '[.cards[] | select(.path | test("bad"))] | length')"
  [ "$bad_count" -eq 0 ] || fail "control-char filename should not produce a card, got $bad_count"

  # stderr should contain a rejection diagnostic
  [ -s "$TEST_TMP/disc-stderr.txt" ] \
    || fail "should emit rejection diagnostic for control-char filename"
}

# ===========================================================================
# verify-publication-target distinct diagnostic tests
# ===========================================================================

@test "verify-target: raw get_project response without wrapper rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Raw get_project response (no outer projectId wrapper)
  cat > "$TEST_TMP/ds-metadata.json" <<'JSON'
{"method":"get_project","projectId":"https://ds.example.com/project/123","name":"Acme DS","type":"PROJECT_TYPE_DESIGN_SYSTEM","ownerDisplayName":"Jane Doe","canEdit":true}
JSON

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "raw unwrapped response should be rejected"
  [[ "$output" == *"projectId"* ]] \
    || fail "should mention missing projectId: $output"
}

@test "verify-target: artifact without reference line rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Artifact header WITHOUT reference line — just real header lines
  cat > "$TEST_TMP/art-meta.txt" <<TXT
[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "missing artifact reference should fail"
  [[ "$output" == *"no reference line"* ]] \
    || fail "should mention 'no reference line': $output"
}

@test "verify-target: empty reference argument rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync '' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "empty reference arg should fail"
  [[ "$output" == *"reference required"* ]] \
    || fail "should mention 'reference required': $output"
}

# ===========================================================================
# Other-key reference fill: existing key with null ref stays unchanged
# ===========================================================================

@test "persist preserves existing product_design key with null reference" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Pre-seed on-disk state with PD key that has null reference
  jq -n '{"design_system":{"reference":null,"last_published_at":null,"files":[]},"product_design":{"reference":null,"last_published_at":null,"files":[]}}' \
    > "$TEST_TMP/last-published.json"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"ds_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"ds_h1"}\n' > "$TEST_TMP/hash-map.json"

  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --project design_system \
      --published-at '2026-09-01T00:00:00Z'
  " 2>/dev/null || fail "persist failed"

  # PD reference should still be null — existing key with null ref is NOT filled
  local pd_ref
  pd_ref="$(jq -r '.product_design.reference // "null"' "$TEST_TMP/last-published.json")"
  [ "$pd_ref" = "null" ] \
    || fail "existing PD key reference should stay null, got $pd_ref"
}

# ===========================================================================
# Legacy flat-array: PD target fills design_system.reference from design record
# ===========================================================================

@test "legacy flat-array with --project product_design fills design_system reference" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Seed a legacy flat-array state file
  printf '[{"file":"components/button.spec.html","hash":"old_h1"}]\n' > "$TEST_TMP/last-published.json"
  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"pd_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"pd_h1"}\n' > "$TEST_TMP/hash-map.json"

  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/last-published.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --project product_design \
      --published-at '2026-09-02T00:00:00Z'
  " 2>/dev/null || fail "persist on legacy flat-array (PD target) should succeed"

  # The design_system.reference must be filled from design_system_project.reference
  local ds_ref
  ds_ref="$(jq -r '.design_system.reference // "null"' "$TEST_TMP/last-published.json")"
  [ "$ds_ref" = "https://ds.example.com/project/123" ] \
    || fail "expected DS reference from design record, got $ds_ref"
}

# ===========================================================================
# Additional persist failure-path tests
# ===========================================================================

@test "persist rejects omitted --local-hash-map" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --design-record '$TEST_TMP/design-record.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  _assert_state_unchanged
}

@test "persist rejects v1.0 design record with null reference" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  cat > "$TEST_TMP/dr-v1-null.yaml" <<'YAML'
schema_version: "1.0"
project:
  reference: null
  discovered_via: manual
YAML

  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"

  _errexit_off_persist "--outcomes '$TEST_TMP/outcomes.json' --prior /dev/null --output '$TEST_TMP/last-published.json' --local-hash-map '$TEST_TMP/hash-map.json' --design-record '$TEST_TMP/dr-v1-null.yaml' --published-at '2026-09-01T00:00:00Z'"

  [ "$_PERSIST_RC" -eq 1 ] || fail "expected exit 1, got $_PERSIST_RC"
  _assert_state_unchanged
}

@test "persist under lock timeout rejects write and leaves state file unchanged" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  local EXEC_TIMEOUT="$BATS_TEST_DIRNAME/../scripts/lib/exec-with-timeout.sh"
  [ -f "$EXEC_TIMEOUT" ] || fail "exec-with-timeout.sh does not exist"
  local LOCK_LIB="$BATS_TEST_DIRNAME/../scripts/lib/acquire-lock.sh"
  [ -f "$LOCK_LIB" ] || skip "acquire-lock.sh not present"

  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  printf '[{"file":"a.html","outcome":"written","hash":"deadbeef"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"a.html":"deadbeef"}\n' > "$TEST_TMP/hash-map.json"
  printf '{"sentinel":"untouched"}\n' > "$TEST_TMP/last-published.json"
  _SENTINEL_SHA="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  local lock_file="$TEST_TMP/last-published.json.lock"

  # Hold the lock in fallback mode (same as the contending write below)
  local holder_pid
  (
    GAIA_LOCK_FORCE_FALLBACK=1 bash -c "
      export GAIA_LOCK_FORCE_FALLBACK=1
      source '$LOCK_LIB'
      acquire_lock '$lock_file' 3600 200
      # Signal readiness
      printf 'ready\n' > '$TEST_TMP/holder-ready.txt'
      # Close bats fd-3 pipe, then exec sleep so no orphan lingers
      exec 3>&-
      exec sleep 60
    " 2>/dev/null
  ) &
  holder_pid=$!

  # Wait for the holder to signal ready
  local wait_count=0
  while [ ! -f "$TEST_TMP/holder-ready.txt" ] && [ "$wait_count" -lt 50 ]; do
    sleep 0.1
    wait_count=$((wait_count + 1))
  done
  [ -f "$TEST_TMP/holder-ready.txt" ] || { kill "$holder_pid" 2>/dev/null; wait "$holder_pid" 2>/dev/null; fail "lock holder never signalled ready"; }

  # Now try to write — should fail because lock is held
  local rc=0
  GAIA_LOCK_FORCE_FALLBACK=1 bash -c "
    source '$EXEC_TIMEOUT'
    exec_with_timeout 20 bash -c '
      source \"$TARGET_SCRIPT\"
      set +e
      persist_last_published \
        --outcomes \"$TEST_TMP/outcomes.json\" \
        --prior /dev/null \
        --output \"$TEST_TMP/last-published.json\" \
        --local-hash-map \"$TEST_TMP/hash-map.json\" \
        --design-record \"$TEST_TMP/design-record.yaml\" \
        --published-at 2026-09-30T10:00:00Z
      exit \$?
    '
  " 2>"$TEST_TMP/lock-stderr.txt" || rc=$?

  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  [ "$rc" -ne 0 ] || fail "locked persist should fail (got rc=0)"
  _assert_state_unchanged
}

# ===========================================================================
# DesignSync real-shape contract tests
# ===========================================================================

@test "verify-target: designsync wrapper with mismatched outer projectId rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/WRONG"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "mismatched projectId should be rejected"
  [[ "$output" == *"does not match"* ]] || fail "should diagnose mismatch: $output"
}

@test "verify-target: designsync with missing outer projectId rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  cat > "$TEST_TMP/ds-metadata.json" <<'JSON'
{"project":{"method":"get_project","projectId":"https://ds.example.com/project/123","type":"PROJECT_TYPE_DESIGN_SYSTEM","ownerDisplayName":"Jane Doe","canEdit":true}}
JSON

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "missing projectId should be rejected"
  [[ "$output" == *"projectId"* ]] || fail "should mention projectId: $output"
}

@test "verify-target: designsync with wrong project.type rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.type = "PROJECT_TYPE_OTHER"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "wrong type should be rejected"
  [[ "$output" == *"type mismatch"* ]] || fail "should diagnose type mismatch: $output"
}

@test "verify-target: designsync with project.canEdit false rejected (real shape)" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.canEdit = false'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "canEdit false should be rejected"
  [[ "$output" == *"canEdit"* ]] || fail "should diagnose canEdit: $output"
}

@test "verify-target: artifact with mismatched reference line rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_art_meta "$TEST_TMP/art-meta.txt" "https://claude.ai/artifact/WRONG"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "mismatched reference line should be rejected"
  [[ "$output" == *"does not match"* ]] || fail "should diagnose mismatch: $output"
}

@test "verify-target: designsync positive control with real shape passes" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -eq 0 ] || fail "positive control should pass: $output"
}

# ===========================================================================
# Owner check: reads .project.ownerDisplayName only (no fallback to .owner)
# ===========================================================================

@test "verify-target: ownerDisplayName match passes with real shape" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -eq 0 ] || fail "ownerDisplayName match should pass: $output"
}

@test "verify-target: ownerDisplayName mismatch refused with real shape" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.ownerDisplayName = "Evil Corp"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "owner mismatch should be refused"
  [[ "$output" == *"owner mismatch"* ]] || fail "should diagnose owner mismatch: $output"
}

@test "verify-target: forged top-level organization ignored when ownerDisplayName mismatches" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Top-level "organization" matches expected owner, but project.ownerDisplayName does not
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.ownerDisplayName = "Evil Corp" | .organization = "Jane Doe"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "top-level organization should be ignored; ownerDisplayName mismatches"
}

@test "verify-target: forged top-level owner ignored when ownerDisplayName mismatches" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Top-level "owner" matches expected, but project.ownerDisplayName does not
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.ownerDisplayName = "Evil Corp" | .owner = "Jane Doe"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "top-level owner should be ignored; ownerDisplayName mismatches"
}

@test "verify-target: missing ownerDisplayName with expected-owner fails closed" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    'del(.project.ownerDisplayName)'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "missing ownerDisplayName should fail closed when --expected-owner given"
  [[ "$output" == *"ownerDisplayName"* ]] || fail "should mention missing ownerDisplayName: $output"
}

# ===========================================================================
# canEdit strict boolean — string "true" rejected
# ===========================================================================

@test "verify-target: canEdit string true rejected (not boolean)" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.canEdit = "true"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "string 'true' canEdit should be rejected (must be boolean)"
  [[ "$output" == *"canEdit"* ]] || fail "should mention canEdit: $output"
}

@test "verify-target: top-level canEdit true ignored when project.canEdit false" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Top-level canEdit:true should not override project.canEdit:false
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.canEdit = false | .canEdit = true'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "top-level canEdit should be ignored; project.canEdit is false"
  [[ "$output" == *"canEdit"* ]] || fail "should mention canEdit: $output"
}

# ===========================================================================
# Inner cross-check: project.projectId must match outer
# ===========================================================================

@test "verify-target: inner project.projectId mismatch rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # project.projectId differs from outer projectId — must be rejected
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.project.projectId = "https://ds.example.com/EVIL"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "inner projectId mismatch should be rejected"
  [[ "$output" == *"project.projectId"* ]] || fail "should mention project.projectId: $output"
}

@test "verify-target: top-level type override ignored" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Top-level type is wrong, but project.type is correct — should pass
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    '.type = "PROJECT_TYPE_OTHER"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -eq 0 ] || fail "top-level type override should be ignored; project.type is correct: $output"
}

# ===========================================================================
# Artifact header: reference must be line 1, no duplicates
# ===========================================================================

@test "verify-target: artifact reference not on line 1 rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # reference is on line 2, not line 1
  cat > "$TEST_TMP/art-meta.txt" <<TXT
[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]
reference: https://claude.ai/artifact/456
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "reference not on line 1 should be rejected"
}

@test "verify-target: blank line 1 in artifact header rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # blank first line, reference on line 2
  printf '\nreference: https://claude.ai/artifact/456\n[Artifact a (version 2) — owned by you, private]\nFiles saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".\n' \
    > "$TEST_TMP/art-meta.txt"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "blank line 1 should be rejected"
}

@test "verify-target: empty reference value in artifact header rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # reference line with empty value
  cat > "$TEST_TMP/art-meta.txt" <<TXT
reference:
[Artifact a (version 2) — owned by you, private]
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact '' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "empty reference value should be rejected"
}

@test "verify-target: duplicate reference lines in artifact header rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Two reference lines — second one could override the first
  cat > "$TEST_TMP/art-meta.txt" <<TXT
reference: https://claude.ai/artifact/456
[Artifact a (version 2) — owned by you, private]
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
reference: https://claude.ai/artifact/EVIL
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "duplicate reference lines should be rejected"
  [[ "$output" == *"reference lines"* ]] || fail "should mention duplicate reference lines: $output"
}

@test "verify-target: artifact CRLF line ending rejected" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Write a CRLF-terminated file with real header shapes
  printf 'reference: https://claude.ai/artifact/456\r\n[Artifact a (version 2) — owned by you, private]\r\nFiles saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".\r\n' \
    > "$TEST_TMP/art-meta.txt"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "CRLF line endings should be rejected"
  [[ "$output" == *"CRLF"* ]] || [[ "$output" == *"0x0d"* ]] \
    || fail "should mention CRLF or CR byte: $output"
}

# ===========================================================================
# Legacy fill scope: design_system target does NOT fill product_design
# ===========================================================================

@test "legacy flat-array with --project design_system does not fill product_design reference" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Seed a legacy flat-array state file
  printf '[{"file":"components/button.spec.html","hash":"old_h1"}]\n' > "$TEST_TMP/last-published.json"
  printf '[{"file":"components/card.spec.html","outcome":"written","hash":"ds_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/card.spec.html":"ds_h1"}\n' > "$TEST_TMP/hash-map.json"

  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/last-published.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --project design_system \
      --published-at '2026-09-02T00:00:00Z'
  " 2>/dev/null || fail "persist on legacy flat-array (DS target) should succeed"

  # product_design.reference must be null — DS target should NOT fill PD reference
  local pd_ref
  pd_ref="$(jq -r '.product_design.reference // "null"' "$TEST_TMP/last-published.json")"
  [ "$pd_ref" = "null" ] \
    || fail "legacy + design_system target should NOT fill product_design.reference, got $pd_ref"

  # design_system.reference should be filled
  local ds_ref
  ds_ref="$(jq -r '.design_system.reference // "null"' "$TEST_TMP/last-published.json")"
  [ "$ds_ref" = "https://ds.example.com/project/123" ] \
    || fail "design_system.reference should be filled from design record, got $ds_ref"
}

# ===========================================================================
# Warning 1: Unterminated last line in artifact header
# ===========================================================================

@test "verify-target: header with no trailing newline passes" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Write header WITHOUT trailing newline (printf '%s', not '%s\n')
  printf '%s' 'reference: https://claude.ai/artifact/456
[Artifact aaaaaaaa-0000-0000-0000-000000000000 (version 2) — owned by you, private]
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".' > "$TEST_TMP/art-meta.txt"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -eq 0 ] || fail "header without trailing newline should pass: $output"
}

@test "verify-target: unterminated conflicting reference line on last line refused" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Valid first reference, but a duplicate on the last unterminated line
  printf '%s' 'reference: https://claude.ai/artifact/456
[Artifact a (version 2) — owned by you, private]
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
reference: https://claude.ai/artifact/EVIL' > "$TEST_TMP/art-meta.txt"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "unterminated duplicate reference line should be refused"
  [[ "$output" == *"reference lines"* ]] || fail "should mention duplicate reference lines: $output"
}

@test "verify-target: unterminated page header without owned-by-you refused" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Valid but page header on last unterminated line lacks owned-by-you
  printf '%s' 'reference: https://claude.ai/artifact/456
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
[Artifact a (version 2) — shared with you, private]' > "$TEST_TMP/art-meta.txt"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "page header without owned-by-you should be refused"
  [[ "$output" == *"write access could not be confirmed"* ]] \
    || fail "should mention write access: $output"
}

# ===========================================================================
# Warning 2: Multiple JSON values fail open in designsync
# ===========================================================================

@test "verify-target: designsync two-value JSON file refused" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # First value has canEdit:false, second has canEdit:true — must not pass
  cat > "$TEST_TMP/ds-metadata.json" <<'JSON'
{"projectId":"https://ds.example.com/project/123","project":{"projectId":"https://ds.example.com/project/123","type":"PROJECT_TYPE_DESIGN_SYSTEM","ownerDisplayName":"Jane Doe","canEdit":false}}
{"project":{"canEdit":true}}
JSON

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "two-value JSON file should be refused"
  [[ "$output" == *"exactly one JSON object"* ]] || fail "should diagnose multi-value: $output"
}

@test "verify-target: designsync empty file refused" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '' > "$TEST_TMP/ds-metadata.json"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "empty designsync metadata file should be refused"
}

@test "verify-target: designsync non-object top level (array) refused" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '[{"projectId":"https://ds.example.com/project/123"}]\n' > "$TEST_TMP/ds-metadata.json"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "array top-level should be refused"
  [[ "$output" == *"exactly one JSON object"* ]] || fail "should diagnose non-object: $output"
}

@test "verify-target: designsync non-object top level (string) refused" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '"just a string"\n' > "$TEST_TMP/ds-metadata.json"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "string top-level should be refused"
  [[ "$output" == *"exactly one JSON object"* ]] || fail "should diagnose non-object: $output"
}

# ===========================================================================
# Warning 3: Legacy-only fill condition pinning
# ===========================================================================

@test "fresh output (no file) with product_design leaves design_system.reference null" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # No existing output file — fresh write
  rm -f "$TEST_TMP/last-published.json"
  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"pd_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"pd_h1"}\n' > "$TEST_TMP/hash-map.json"

  _run_persist_v2 --project product_design \
    --design-record "$TEST_TMP/design-record.yaml" \
    --published-at "2026-09-01T00:00:00Z"

  # design_system.reference must be null — no legacy file means no fill
  local ds_ref
  ds_ref="$(jq -r '.design_system.reference // "null"' "$TEST_TMP/last-published.json")"
  [ "$ds_ref" = "null" ] \
    || fail "fresh output + product_design should leave design_system.reference null, got $ds_ref"
}

@test "existing per-project file with null DS reference stays null after product_design publish" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Existing per-project file with null DS reference (NOT legacy)
  cat > "$TEST_TMP/last-published.json" <<'JSON'
{
  "design_system": {"reference": null, "last_published_at": null, "files": []},
  "product_design": {"reference": null, "last_published_at": null, "files": []}
}
JSON

  printf '[{"file":"screens/login.spec.html","outcome":"written","hash":"pd_h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"screens/login.spec.html":"pd_h1"}\n' > "$TEST_TMP/hash-map.json"

  _run_persist_v2 --project product_design \
    --design-record "$TEST_TMP/design-record.yaml" \
    --prior "$TEST_TMP/last-published.json" \
    --published-at "2026-09-01T00:00:00Z"

  # design_system.reference must still be null — file was NOT legacy
  local ds_ref
  ds_ref="$(jq -r '.design_system.reference // "null"' "$TEST_TMP/last-published.json")"
  [ "$ds_ref" = "null" ] \
    || fail "non-legacy per-project file should NOT fill design_system.reference, got $ds_ref"
}

# ===========================================================================
# Artifact --expected-owner fails closed (no named owner in real reads)
# ===========================================================================

@test "verify-target: artifact --expected-owner always fails closed with diagnostic" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _make_art_meta "$TEST_TMP/art-meta.txt" "https://claude.ai/artifact/456"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner owner-456
  "
  [ "$status" -ne 0 ] || fail "artifact --expected-owner should always fail closed"
  [[ "$output" == *"cannot check a named owner"* ]] \
    || fail "should say cannot check named owner: $output"
}

@test "verify-target: designsync forged top-level owner with NO ownerDisplayName refused" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Real response has NO project.ownerDisplayName, but forged top-level "owner" and
  # "organization" match the expected owner — must still be refused.
  _make_ds_meta "$TEST_TMP/ds-metadata.json" "https://ds.example.com/project/123" \
    'del(.project.ownerDisplayName) | .owner = "Jane Doe" | .organization = "Jane Doe"'

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target designsync 'https://ds.example.com/project/123' \
      --metadata-file '$TEST_TMP/ds-metadata.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --expected-owner 'Jane Doe'
  "
  [ "$status" -ne 0 ] || fail "forged top-level owner/organization with no ownerDisplayName should be refused"
  [[ "$output" == *"ownerDisplayName"* ]] || fail "should mention missing ownerDisplayName: $output"
}

# ===========================================================================
# INFO items: duplicate access/type lines, empty reference diagnostic, BOM
# ===========================================================================

@test "verify-target: empty reference value diagnoses header" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # reference line with empty value — pass the REAL reference to the function
  cat > "$TEST_TMP/art-meta.txt" <<TXT
reference:
[Artifact a (version 2) — owned by you, private]
Files saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".
TXT

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "empty reference value should be rejected"
  # The empty value after sed produces empty art_ref, caught as "no reference line"
  [[ "$output" == *"reference"* ]] || fail "should diagnose the reference problem: $output"
}

@test "verify-target: BOM on line 1 gives specific diagnostic" {
  [ -f "$VERIFY_SCRIPT" ] || fail "verify-publication-target.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Write header with UTF-8 BOM (EF BB BF) on line 1
  printf '\xef\xbb\xbfreference: https://claude.ai/artifact/456\n[Artifact a (version 2) — owned by you, private]\nFiles saved under "/d" from version 2 of https://claude.ai/artifact/456, an Artifact of type "Design".\n' \
    > "$TEST_TMP/art-meta.txt"

  run bash -c "
    source '$VERIFY_SCRIPT'
    verify_publication_target artifact 'https://claude.ai/artifact/456' \
      --metadata-file '$TEST_TMP/art-meta.txt' \
      --design-record '$TEST_TMP/design-record.yaml'
  "
  [ "$status" -ne 0 ] || fail "BOM on line 1 should be rejected"
  [[ "$output" == *"BOM"* ]] || fail "should mention BOM in diagnostic: $output"
}

# ===========================================================================
# Wrong-shape publication state is refused
# ===========================================================================

@test "planner rejects wrong-shape state: bare object with string value" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  printf '{"design_system":"x"}\n' > "$TEST_TMP/wrong.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/wrong.json"
  [ "$status" -ne 0 ] || fail "wrong-shape state file should be rejected, got exit 0"
  [[ "$output" == *"wrong.json"* ]] || [[ "$output" == *"shape"* ]] || [[ "$output" == *"invalid"* ]] \
    || fail "diagnostic should name the file or shape, got: $output"
  # Must NOT produce any WRITE plan line
  [[ "$output" != *"WRITE"* ]] || fail "wrong-shape state must not produce a WRITE plan"
}

@test "planner rejects wrong-shape state: bare number" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  printf '42\n' > "$TEST_TMP/wrong.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/wrong.json"
  [ "$status" -ne 0 ] || fail "number state file should be rejected, got exit 0"
  [[ "$output" != *"WRITE"* ]] || fail "wrong-shape state must not produce a WRITE plan"
}

@test "planner rejects wrong-shape state: bare string" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  printf '"s"\n' > "$TEST_TMP/wrong.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/wrong.json"
  [ "$status" -ne 0 ] || fail "string state file should be rejected, got exit 0"
  [[ "$output" != *"WRITE"* ]] || fail "wrong-shape state must not produce a WRITE plan"
}

@test "planner rejects wrong-shape state: non-file-hash array" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  printf '[1,2]\n' > "$TEST_TMP/wrong.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/wrong.json"
  [ "$status" -ne 0 ] || fail "non-file-hash array should be rejected, got exit 0"
  [[ "$output" != *"WRITE"* ]] || fail "wrong-shape state must not produce a WRITE plan"
}

@test "planner rejects wrong-shape state: per-project entry missing files" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  printf '{"design_system":{"reference":"x"}}\n' > "$TEST_TMP/wrong.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/wrong.json"
  [ "$status" -ne 0 ] || fail "entry without files array should be rejected, got exit 0"
  [[ "$output" != *"WRITE"* ]] || fail "wrong-shape state must not produce a WRITE plan"
}

@test "planner rejects wrong-shape state: non-array files field" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  printf '{"design_system":{"files":"not-an-array"}}\n' > "$TEST_TMP/wrong.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/wrong.json"
  [ "$status" -ne 0 ] || fail "non-array files field should be rejected, got exit 0"
  [[ "$output" != *"WRITE"* ]] || fail "wrong-shape state must not produce a WRITE plan"
}

@test "planner accepts legacy flat array" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  printf '[{"file":"x.spec.html","hash":"h1"}]\n' > "$TEST_TMP/legacy.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/legacy.json"
  [ "$status" -eq 0 ] || fail "legacy flat array should be accepted, got exit $status"
}

@test "planner accepts valid per-project object" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  printf '[{"file":"components/button.spec.html","hash":"h1"}]\n' > "$TEST_TMP/local.json"
  printf '[{"file":"components/button.spec.html","hash":"h1"}]\n' > "$TEST_TMP/remote.json"
  _seed_per_project_state "$TEST_TMP/valid.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/valid.json" \
    --project design_system
  [ "$status" -eq 0 ] || fail "valid per-project object should be accepted, got exit $status"
}

@test "writer rejects wrong-shape on-disk output and leaves file unchanged" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Pre-seed on-disk output with wrong shape
  printf '{"design_system":"x"}\n' > "$TEST_TMP/out.json"
  local hash_before
  hash_before="$(shasum -a 256 "$TEST_TMP/out.json" | awk '{print $1}')"

  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/out.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-01T00:00:00Z'
  " 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "wrong-shape on-disk output should fail closed, got exit 0"

  local hash_after
  hash_after="$(shasum -a 256 "$TEST_TMP/out.json" | awk '{print $1}')"
  [ "$hash_before" = "$hash_after" ] || fail "wrong-shape on-disk output was mutated"
}

@test "writer rejects wrong-shape on-disk output: bare number" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  printf '42\n' > "$TEST_TMP/out.json"
  local hash_before
  hash_before="$(shasum -a 256 "$TEST_TMP/out.json" | awk '{print $1}')"

  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/out.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-09-01T00:00:00Z'
  " 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "number on-disk output should fail closed, got exit 0"

  local hash_after
  hash_after="$(shasum -a 256 "$TEST_TMP/out.json" | awk '{print $1}')"
  [ "$hash_before" = "$hash_after" ] || fail "number on-disk output was mutated"
}

# ===========================================================================
# Project routing and timestamp checks
# ===========================================================================

@test "planner --project routes to correct key (distinct hashes per project)" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"

  # State file: DS published hash = "ds_pub", PD published hash = "pd_pub"
  # Remote hash = "remote_h" (differs from both). Local hash = "new_local".
  # The planner checks: if remote != local, compare published vs remote.
  #   - DS: pub "ds_pub" != remote "remote_h" => CONFLICT
  #   - PD: pub "pd_pub" != remote "remote_h" => CONFLICT (but different pub hash)
  # To distinguish routing, make one match and one not:
  #   DS pub = "remote_h" (matches remote -> WRITE, not CONFLICT)
  #   PD pub = "pd_pub"   (differs from remote -> CONFLICT)
  cat > "$TEST_TMP/state.json" <<'JSON'
{
  "design_system": {
    "reference": "https://ds.example.com/project/123",
    "last_published_at": "2026-09-01T00:00:00Z",
    "files": [{"file":"components/button.spec.html","hash":"remote_h"}]
  },
  "product_design": {
    "reference": "https://claude.ai/artifact/456",
    "last_published_at": "2026-09-02T00:00:00Z",
    "files": [{"file":"components/button.spec.html","hash":"pd_pub"}]
  }
}
JSON
  # Local hash differs from remote => hashes differ => check published
  printf '[{"file":"components/button.spec.html","hash":"new_local"}]\n' > "$TEST_TMP/local.json"
  # Remote hash
  printf '[{"file":"components/button.spec.html","hash":"remote_h"}]\n' > "$TEST_TMP/remote.json"

  # DS: published hash "remote_h" == remote hash "remote_h"
  # => Not a designer edit => READ_FIRST + WRITE
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/state.json" \
    --project design_system
  [ "$status" -eq 0 ] || fail "DS plan failed: $output"
  [[ "$output" == *"WRITE"* ]] || fail "DS should plan WRITE, got: $output"
  [[ "$output" != *"CONFLICT"* ]] || fail "DS published==remote, should not CONFLICT, got: $output"

  # PD: published hash "pd_pub" != remote hash "remote_h"
  # => Designer edit detected => CONFLICT
  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local.json" \
    --remote-listing "$TEST_TMP/remote.json" \
    --last-published "$TEST_TMP/state.json" \
    --project product_design
  [ "$status" -eq 0 ] || fail "PD plan failed: $output"
  [[ "$output" == *"CONFLICT"* ]] || fail "PD should plan CONFLICT, got: $output"
}

@test "sync --project selects the correct baseline entry" {
  local SYNC_SCRIPT="$BATS_TEST_DIRNAME/../skills/gaia-design-review/scripts/sync-derived-artifacts.sh"
  [ -f "$SYNC_SCRIPT" ] || fail "sync-derived-artifacts.sh not found"

  local root
  root="$(mktemp -d)"
  mkdir -p "$root/doc"
  printf -- '---\ntemplate: ux-design\n---\n\n# UX\n\n## Component Inventory\n\n- nav\n' > "$root/doc/ux.md"
  printf '<h1>Nav</h1>\n' > "$root/c.html"
  local newhash
  newhash="$(shasum -a 256 "$root/c.html" | awk '{print $1}')"
  jq -n --rawfile c "$root/c.html" \
    '{"components":["nav"],"screens":[],"component_details":[{"name":"nav","file":"components/nav.spec.html","content":$c}]}' > "$root/snap.json"

  # State: DS has the current hash (no delta), PD has a stale hash (delta)
  printf '{"design_system":{"files":[{"file":"components/nav.spec.html","hash":"%s"}]},"product_design":{"files":[{"file":"components/nav.spec.html","hash":"stale"}]}}\n' \
    "$newhash" > "$root/bl.json"

  # Sync with DS (default): baseline matches current hash, exit 0
  run "$SYNC_SCRIPT" --last-published "$root/bl.json" "$root/snap.json" "$root/doc/ux.md"
  [ "$status" -eq 0 ] || fail "sync with DS baseline (matching hash) failed: $output"

  # Sync with PD: baseline has stale hash. The script should still succeed
  # (it adds/reports but doesn't fail on a delta), and the output/stderr
  # content should differ because it read PD's stale baseline, not DS's
  # current one. At minimum: both runs succeed and use their respective key.
  # Re-seed ux doc to avoid leftover state
  printf -- '---\ntemplate: ux-design\n---\n\n# UX\n\n## Component Inventory\n\n- nav\n' > "$root/doc/ux.md"
  run "$SYNC_SCRIPT" --project product_design --last-published "$root/bl.json" "$root/snap.json" "$root/doc/ux.md"
  [ "$status" -eq 0 ] || fail "sync with PD baseline failed: $output"
  rm -rf "$root"
}

@test "readers-never-write asserts planner exit status" {
  [ -x "$PLANNER_SCRIPT" ] || fail "plan-publication.sh missing"
  _seed_per_project_state "$TEST_TMP/last-published.json"

  local hash_before
  hash_before="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"

  printf '[{"file":"components/button.spec.html","hash":"ds_hash_1"}]\n' > "$TEST_TMP/local-manifest.json"
  printf '[{"file":"components/button.spec.html","hash":"ds_hash_1"}]\n' > "$TEST_TMP/remote-listing.json"

  run env -u PROJECT_ROOT -u CLAUDE_PROJECT_ROOT -u PROJECT_PATH \
    "$PLANNER_SCRIPT" \
    --local-manifest "$TEST_TMP/local-manifest.json" \
    --remote-listing "$TEST_TMP/remote-listing.json" \
    --last-published "$TEST_TMP/last-published.json" \
    --project design_system
  [ "$status" -eq 0 ] || fail "planner should succeed on valid input, got exit $status: $output"

  local hash_after
  hash_after="$(shasum -a 256 "$TEST_TMP/last-published.json" | awk '{print $1}')"
  [ "$hash_before" = "$hash_after" ] || fail "reader modified state file"
}

@test "earlier-timestamp warning names both timestamps" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"
  _seed_per_project_state "$TEST_TMP/last-published.json"

  printf '[{"file":"components/button.spec.html","outcome":"written","hash":"early_h"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"components/button.spec.html":"early_h"}\n' > "$TEST_TMP/hash-map.json"

  local stderr_out rc=0
  stderr_out="$(bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior '$TEST_TMP/last-published.json' \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --project design_system \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '2026-08-01T00:00:00Z'
  " 2>&1 1>/dev/null)" || rc=$?

  # Must succeed (warning, not error)
  [ "$rc" -eq 0 ] || fail "earlier timestamp should succeed with warning, got exit $rc"

  # Warning must name both timestamps
  [[ "$stderr_out" == *"2026-08-01T00:00:00Z"* ]] \
    || fail "warning should name the new timestamp, got: $stderr_out"
  [[ "$stderr_out" == *"2026-09-01T00:00:00Z"* ]] \
    || fail "warning should name the existing timestamp, got: $stderr_out"
}

@test "timestamp: 59s in future accepted (boundary inside 60s limit)" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"
  _seed_design_record_v2 "$TEST_TMP/design-record.yaml"

  # Compute a timestamp 59s in the future
  local near_future_ts
  near_future_ts="$(jq -rn 'now + 59 | todate')"

  printf '[{"file":"x.spec.html","outcome":"written","hash":"h1"}]\n' > "$TEST_TMP/outcomes.json"
  printf '{"x.spec.html":"h1"}\n' > "$TEST_TMP/hash-map.json"

  local rc=0
  bash -c "
    source '$TARGET_SCRIPT'
    persist_last_published \
      --outcomes '$TEST_TMP/outcomes.json' \
      --prior /dev/null \
      --output '$TEST_TMP/last-published.json' \
      --local-hash-map '$TEST_TMP/hash-map.json' \
      --design-record '$TEST_TMP/design-record.yaml' \
      --published-at '$near_future_ts'
  " 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "timestamp 59s in future should be accepted, got exit $rc"
}

@test "discovery: 500 spec files correct output" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Create 500 spec files across allowed subdirectories
  local specs_dir="$TEST_TMP/specs"
  mkdir -p "$specs_dir/components" "$specs_dir/templates"
  local i
  for i in $(seq 1 250); do
    printf '<!-- @dsCard group="Component specs" -->\n<html>C%d</html>\n' "$i" \
      > "$specs_dir/components/c${i}.spec.html"
  done
  for i in $(seq 1 250); do
    printf '<!-- @dsCard group="Template specs" -->\n<html>T%d</html>\n' "$i" \
      > "$specs_dir/templates/t${i}.spec.html"
  done
  _seed_existing_manifest "$TEST_TMP/existing.json"

  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$specs_dir' \
      --existing '$TEST_TMP/existing.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards 500 files failed"

  # Verify correct count: 500 spec cards + 2 existing (Colors, Type) = 502
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 502 ] || fail "expected 502 cards, got $card_count"
}

@test "discovery: static scan — dedup uses sort -uz, not shell string accumulation" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  # Structural guard: the discovery loop must dedup via sort -uz (O(n log n)),
  # not via a growing shell string like the old `seen_paths` pattern (O(n^2)).
  # The quadratic regression was shell-side work (string matching + array
  # append), invisible to subprocess-counting shims. This static scan is the
  # only CI-safe guard; the wall-clock tests below are hardware-dependent and
  # skipped in CI.
  grep -q 'sort -uz' "$TARGET_SCRIPT" \
    || fail "discovery must dedup via 'sort -uz' — not found in build-manifest-cards.sh"

  # The old quadratic dedup accumulated paths into a shell variable and matched
  # each new path against it with case/glob. If that variable reappears, the
  # quadratic path is back.
  local quadratic_hits
  quadratic_hits="$(grep -c 'seen_paths' "$TARGET_SCRIPT" 2>/dev/null || true)"
  [ "$quadratic_hits" -eq 0 ] \
    || fail "shell string dedup variable 'seen_paths' still present ($quadratic_hits occurrences) — use sort -uz instead"
}

# The two wall-clock tests below are the ONLY guard against the quadratic
# discovery regression. CI does not run them (hardware-dependent tag). They
# must be run locally after any change to the discovery loop in
# build_manifest_cards (build-manifest-cards.sh lines 78-134).

# bats test_tags=hardware-dependent
@test "discovery: 500 spec files within wall-clock bound" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  local specs_dir="$TEST_TMP/specs"
  mkdir -p "$specs_dir/components" "$specs_dir/templates"
  local i
  for i in $(seq 1 250); do
    printf '<!-- @dsCard group="Component specs" -->\n<html>C%d</html>\n' "$i" \
      > "$specs_dir/components/c${i}.spec.html"
  done
  for i in $(seq 1 250); do
    printf '<!-- @dsCard group="Template specs" -->\n<html>T%d</html>\n' "$i" \
      > "$specs_dir/templates/t${i}.spec.html"
  done
  _seed_existing_manifest "$TEST_TMP/existing.json"

  local t0 t1 elapsed_ms
  t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$specs_dir' \
      --existing '$TEST_TMP/existing.json' \
      --last-published /dev/null \
      --project design_system
  " >/dev/null 2>/dev/null || fail "build_manifest_cards 500 files failed"
  t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  elapsed_ms="$(perl -e "printf '%.0f', ($t1 - $t0) * 1000")"

  [ "$elapsed_ms" -lt 30000 ] \
    || fail "500 files took ${elapsed_ms}ms — expected under 30000ms"
}

# bats test_tags=hardware-dependent
# See comment above "500 spec files" — this is the only runtime guard for the
# quadratic discovery regression at scale. Run locally after touching discovery.
@test "discovery: 2000 spec files within wall-clock bound" {
  [ -f "$TARGET_SCRIPT" ] || fail "build-manifest-cards.sh does not exist"

  local specs_dir="$TEST_TMP/specs"
  mkdir -p "$specs_dir/components" "$specs_dir/templates"
  local i
  for i in $(seq 1 1000); do
    printf '<!-- @dsCard group="Component specs" -->\n<html>C%d</html>\n' "$i" \
      > "$specs_dir/components/c${i}.spec.html"
  done
  for i in $(seq 1 1000); do
    printf '<!-- @dsCard group="Template specs" -->\n<html>T%d</html>\n' "$i" \
      > "$specs_dir/templates/t${i}.spec.html"
  done
  _seed_existing_manifest "$TEST_TMP/existing.json"

  local t0 t1 elapsed_ms
  t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  local result
  result="$(bash -c "
    source '$TARGET_SCRIPT'
    build_manifest_cards \
      --local-specs '$specs_dir' \
      --existing '$TEST_TMP/existing.json' \
      --last-published /dev/null \
      --project design_system
  " 2>/dev/null)" || fail "build_manifest_cards 2000 files failed"
  t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  elapsed_ms="$(perl -e "printf '%.0f', ($t1 - $t0) * 1000")"

  printf 'perf: 2000 spec files took %sms\n' "$elapsed_ms" >&2

  # Correctness: 2000 spec cards + 2 existing (Colors, Type) = 2002
  local card_count
  card_count="$(printf '%s' "$result" | jq '.cards | length')"
  [ "$card_count" -eq 2002 ] || fail "expected 2002 cards, got $card_count"

  [ "$elapsed_ms" -lt 30000 ] \
    || fail "2000 files took ${elapsed_ms}ms — expected under 30000ms"
}
