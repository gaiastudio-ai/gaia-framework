#!/usr/bin/env bats
# coppa-regime.bats — E74-S6 COPPA regime rubric coverage.
#
# Asserts that the COPPA regime rubric (rubrics/regimes/coppa.json) ships
# with the cohort-uniform shape, validates against rubric.schema.json,
# carries the data-collection / parental-consent rule families required
# by COPPA, and merges cleanly atop the security base via rubric-merger.sh.
#
#   AC1   coppa.json exists under rubrics/regimes/ and is valid JSON
#   AC2   coppa.json passes rubric.schema.json validation via
#         validate-rubric.sh (exit 0)
#   AC3   severity_rules cover data-collection prohibitions —
#         personal-info-without-consent, behavioral-advertising-id,
#         persistent-identifier-profiling
#   AC4   severity_rules cover parental-consent flow —
#         verifiable-consent, parental-access-delete, retention-limit
#   AC5   rubric-merger.sh loads coppa.json on top of base/security.json
#         when declared (regime-name lands in merged output); when
#         coppa.json is NOT passed to the merger, no coppa-prefixed
#         rules appear in the merged output
#   AC6   metadata.last_updated is present and parseable as ISO 8601
#         (YYYY-MM-DD); metadata.source_reference cites FTC COPPA Rule
#         (16 CFR Part 312)
#   AC7   coppa.json declares NO top-level `platforms` constraint —
#         COPPA is jurisdiction-scoped, not platform-scoped, so the
#         rubric applies cross-platform (web + mobile)
#
# Story: E74-S6
# ADR:   ADR-079 (Layered Rubric Loading), ADR-081 (store regime rubrics)
# Sprint: sprint-38

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_REGIMES="$PLUGIN_DIR/rubrics/regimes"
RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
COPPA_RUBRIC="$RUBRICS_REGIMES/coppa.json"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — file exists + is valid JSON.
# ---------------------------------------------------------------------------
@test "coppa.json exists under rubrics/regimes/" {
  [ -f "$COPPA_RUBRIC" ] || {
    echo "missing rubric: $COPPA_RUBRIC" >&2
    return 1
  }
}

@test "coppa.json parses as valid JSON" {
  jq -e . "$COPPA_RUBRIC" >/dev/null || {
    echo "coppa.json is not valid JSON" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC2 — schema validation passes via validate-rubric.sh (exit 0).
# Also assert canonical top-level fields per E68-S5 cohort uniformity:
# applies_to_skills, description, metadata, name, schema_version,
# severity_rules, skill (alphabetical, jq's `keys` default sort).
# ---------------------------------------------------------------------------
@test "validate-rubric.sh exits 0 for coppa.json" {
  run "$VALIDATOR" "$COPPA_RUBRIC"
  [ "$status" -eq 0 ] || {
    echo "validate-rubric.sh failed:" >&2
    echo "$output" >&2
    return 1
  }
}

@test "coppa.json declares applies_to_skills covering review-code and review-security" {
  has_code=$(jq '[.applies_to_skills[] | select(. == "review-code")] | length' "$COPPA_RUBRIC")
  has_sec=$(jq '[.applies_to_skills[] | select(. == "review-security")] | length' "$COPPA_RUBRIC")
  [ "$has_code" -ge 1 ] || { echo "applies_to_skills missing review-code" >&2; return 1; }
  [ "$has_sec" -ge 1 ] || { echo "applies_to_skills missing review-security" >&2; return 1; }
}

@test "coppa.json carries the canonical top-level key set" {
  expected='applies_to_skills
description
metadata
name
schema_version
severity_rules
skill'
  actual=$(jq -r 'keys[]' "$COPPA_RUBRIC")
  [ "$actual" = "$expected" ] || {
    echo "coppa.json top-level keys diverge from canonical set:" >&2
    echo "expected:" >&2
    echo "$expected" >&2
    echo "actual:" >&2
    echo "$actual" >&2
    return 1
  }
}

@test "coppa.json declares schema_version matching N.N pattern" {
  sv=$(jq -r '.schema_version' "$COPPA_RUBRIC")
  printf '%s' "$sv" | grep -Eq '^[0-9]+\.[0-9]+$' || {
    echo "schema_version='$sv' does not match N.N" >&2
    return 1
  }
}

@test "coppa.json name field equals 'coppa'" {
  name=$(jq -r '.name' "$COPPA_RUBRIC")
  [ "$name" = "coppa" ] || {
    echo "name='$name' (expected 'coppa')" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC3 — data-collection prohibition rule family.
# Each rule must declare id, category, severity, and either pattern or a
# detector hint via 'pattern' (the schema's required field).
# ---------------------------------------------------------------------------
@test "coppa.json carries a data-collection-without-consent rule" {
  count=$(jq '[.severity_rules[] | select(.category == "data-collection")] | length' "$COPPA_RUBRIC")
  [ "$count" -ge 1 ] || {
    echo "no severity_rules with category 'data-collection'" >&2
    return 1
  }
}

@test "coppa.json carries a behavioral-advertising-identifier rule" {
  count=$(jq '[.severity_rules[] | select(.category == "behavioral-advertising")] | length' "$COPPA_RUBRIC")
  [ "$count" -ge 1 ] || {
    echo "no severity_rules with category 'behavioral-advertising'" >&2
    return 1
  }
}

@test "coppa.json carries a persistent-identifier-profiling rule" {
  count=$(jq '[.severity_rules[] | select(.category == "persistent-identifier")] | length' "$COPPA_RUBRIC")
  [ "$count" -ge 1 ] || {
    echo "no severity_rules with category 'persistent-identifier'" >&2
    return 1
  }
}

@test "every coppa rule has id, category, pattern, severity, description" {
  bad=$(jq '[.severity_rules[]
            | select(
                (has("id") and has("category") and has("pattern")
                 and has("severity") and has("description")) | not)
           ] | length' "$COPPA_RUBRIC")
  [ "$bad" = "0" ] || {
    echo "$bad coppa rule(s) missing required fields" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC4 — parental-consent flow rule family.
# ---------------------------------------------------------------------------
@test "coppa.json carries a verifiable-parental-consent rule" {
  count=$(jq '[.severity_rules[] | select(.category == "parental-consent")] | length' "$COPPA_RUBRIC")
  [ "$count" -ge 1 ] || {
    echo "no severity_rules with category 'parental-consent'" >&2
    return 1
  }
}

@test "coppa.json carries a parental-access-delete rule" {
  count=$(jq '[.severity_rules[] | select(.category == "parental-access")] | length' "$COPPA_RUBRIC")
  [ "$count" -ge 1 ] || {
    echo "no severity_rules with category 'parental-access'" >&2
    return 1
  }
}

@test "coppa.json carries a data-retention-limit rule" {
  count=$(jq '[.severity_rules[] | select(.category == "data-retention")] | length' "$COPPA_RUBRIC")
  [ "$count" -ge 1 ] || {
    echo "no severity_rules with category 'data-retention'" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC5 — opt-in activation: merger surfaces COPPA rules ONLY when the
# regime file is in the layer list. Mirrors the E68-S4 merger contract.
# ---------------------------------------------------------------------------
@test "rubric-merger loads coppa rules when coppa.json is in the layer list" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out=$("$MERGER" "$RUBRICS_BASE/security.json" "$COPPA_RUBRIC")
  [ -n "$out" ] || { echo "merger produced no output" >&2; return 1; }
  name=$(printf '%s' "$out" | jq -r '.name // empty')
  [ "$name" = "coppa" ] || {
    echo "merged name='$name' (expected 'coppa')" >&2
    return 1
  }
  prefixed=$(printf '%s' "$out" | jq '[.severity_rules[].id | select(startswith("coppa-"))] | length')
  [ "$prefixed" -ge 1 ] || {
    echo "merged severity_rules contain no coppa-prefixed ids" >&2
    return 1
  }
}

@test "rubric-merger does NOT inject coppa rules when coppa.json is omitted" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out=$("$MERGER" "$RUBRICS_BASE/security.json")
  [ -n "$out" ] || { echo "merger produced no output" >&2; return 1; }
  prefixed=$(printf '%s' "$out" | jq '[.severity_rules[].id | select(startswith("coppa-"))] | length')
  [ "$prefixed" = "0" ] || {
    echo "base/security.json output unexpectedly contains coppa-prefixed rules" >&2
    return 1
  }
}

@test "merger output is byte-identical across two runs (no drift)" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out1=$("$MERGER" "$RUBRICS_BASE/security.json" "$COPPA_RUBRIC")
  out2=$("$MERGER" "$RUBRICS_BASE/security.json" "$COPPA_RUBRIC")
  [ "$out1" = "$out2" ] || {
    echo "merger output drift across two runs for coppa.json" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC6 — last_updated and source_reference metadata.
# ---------------------------------------------------------------------------
@test "coppa.json metadata.last_updated is present and ISO 8601 (YYYY-MM-DD)" {
  ts=$(jq -r '.metadata.last_updated // empty' "$COPPA_RUBRIC")
  [ -n "$ts" ] || { echo "metadata.last_updated missing" >&2; return 1; }
  printf '%s' "$ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || {
    echo "last_updated='$ts' does not match YYYY-MM-DD" >&2
    return 1
  }
}

@test "coppa.json metadata.source_reference cites FTC COPPA Rule" {
  ref=$(jq -r '.metadata.source_reference // empty' "$COPPA_RUBRIC")
  [ -n "$ref" ] || { echo "metadata.source_reference missing" >&2; return 1; }
  printf '%s' "$ref" | grep -Fq '16 CFR Part 312' || {
    echo "source_reference='$ref' does not cite '16 CFR Part 312'" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC7 — cross-platform applicability: NO top-level `platforms` key.
# ---------------------------------------------------------------------------
@test "coppa.json does NOT declare a top-level 'platforms' constraint" {
  has_platforms=$(jq 'has("platforms")' "$COPPA_RUBRIC")
  [ "$has_platforms" = "false" ] || {
    echo "coppa.json carries top-level 'platforms' (COPPA is jurisdiction-scoped)" >&2
    return 1
  }
}
