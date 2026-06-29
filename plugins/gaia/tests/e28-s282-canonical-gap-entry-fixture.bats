#!/usr/bin/env bats
# e28-s282-canonical-gap-entry-fixture.bats — the canonical shipped gap-entry
# fixture that scan subagents copy from.
#
# The gap-entry schema is complete, but no canonical example instance was
# shipped — each adapter invented its own. This pins a single canonical fixture
# (tests/fixtures/brownfield-gap-entry-example.json), asserts every entry
# validates against schemas/brownfield-gap-entry.schema.json, asserts it
# demonstrates all three claim_types, and asserts the gaia-brownfield SKILL.md
# scan fragment references it.
#
# Schema-validation assertions skip gracefully when no validator backend
# (ajv / python3+jsonschema) is available; prose + structural assertions run
# unconditionally.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCHEMA="$PLUGIN/schemas/brownfield-gap-entry.schema.json"
  SKILL="$PLUGIN/skills/gaia-brownfield/SKILL.md"
  VALIDATOR="$PLUGIN/scripts/lib/validate-artifact-schema.sh"
  FIXTURE="$PLUGIN/tests/fixtures/brownfield-gap-entry-example.json"
}

teardown() { common_teardown; }

_has_backend() {
  if command -v ajv >/dev/null 2>&1; then return 0; fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then return 0; fi
  return 1
}

@test "canonical gap-entry fixture exists and is valid JSON (AC1)" {
  [ -f "$FIXTURE" ]
  run python3 -c "import json; json.load(open('$FIXTURE'))"
  [ "$status" -eq 0 ]
}

@test "fixture demonstrates all three claim_types (AC2)" {
  run python3 -c "import json; cts=sorted(e.get('claim_type','positive') for e in json.load(open('$FIXTURE'))); print(','.join(cts))"
  [ "$status" -eq 0 ]
  [[ "$output" == *"positive"* ]]
  [[ "$output" == *"negative"* ]]
  [[ "$output" == *"contradiction"* ]]
}

@test "every fixture entry validates against the gap-entry schema (AC1)" {
  _has_backend || skip "no JSON-schema validator backend available"
  source "$VALIDATOR"
  n="$(python3 -c "import json; print(len(json.load(open('$FIXTURE'))))")"
  for i in $(seq 0 $((n - 1))); do
    local entry="$BATS_TEST_TMPDIR/entry-$i.json"
    python3 -c "import json; json.dump(json.load(open('$FIXTURE'))[$i], open('$entry','w'))"
    run validate_artifact_schema "$SCHEMA" "$entry"
    [ "$status" -eq 0 ]
  done
}

@test "gaia-brownfield SKILL.md gap-entry fragment references the fixture (AC3)" {
  grep -qF 'tests/fixtures/brownfield-gap-entry-example.json' "$SKILL"
  # The reference lives inside the <gap-entry-schema-ref> block dispatched to subagents.
  run awk '/<gap-entry-schema-ref>/{f=1} f&&/brownfield-gap-entry-example.json/{print "found"} /<\/gap-entry-schema-ref>/{f=0}' "$SKILL"
  [[ "$output" == *"found"* ]]
}

@test "fixture gap_ids match the {SCANNER}-{NNN} convention (AC1)" {
  run python3 -c "import json,re; ids=[e['gap_id'] for e in json.load(open('$FIXTURE'))]; print('ok' if all(re.match(r'^[A-Z]+-[0-9]{3,}\$', i) for i in ids) else 'bad:'+str(ids))"
  [ "$output" = "ok" ]
}
