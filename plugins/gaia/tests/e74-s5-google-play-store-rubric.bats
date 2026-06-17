#!/usr/bin/env bats
# e74-s5-google-play-store-rubric.bats — E74-S5 Google Play Store regime rubric.
#
# Asserts that `google-play-store.json` shipped under
# `gaia-public/plugins/gaia/rubrics/regimes/` conforms to `rubric.schema.json`
# (E68-S2) and meets the story-level acceptance criteria E74-S5 AC1..AC7.
#
#   AC1   Rubric file exists at canonical regimes path and passes schema
#         validation against rubric.schema.json.
#   AC2   Play Store policy rules — restricted content, deceptive behavior,
#         malware/unwanted software, user data, families/children policy.
#         GPS-POL- prefix.
#   AC3   Data-safety form rules — collection, sharing, handling, security,
#         privacy-policy URL. GPS-DS- prefix.
#   AC4   Target SDK requirement rules — targetSdkVersion threshold,
#         compileSdkVersion alignment, annual API-level deadline.
#         GPS-SDK- prefix.
#   AC5   RFC 7396 merge compatibility with mobile.json base via
#         rubric-merger.sh.
#   AC6   Rubric metadata fields — name, version, description, platform,
#         regime_type, applies_when, supersedes (under metadata block).
#   AC7   Configurable thresholds — config.min_target_sdk (default 34),
#         data_safety_strict_mode (default true), enforce_families_policy
#         (default false).
#
# Story: E74-S5
# ADR:   ADR-079 (Layered Rubric Loading), ADR-081 (Mobile-as-Platform)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_REGIMES="$PLUGIN_DIR/rubrics/regimes"
RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"
RUBRIC="$RUBRICS_REGIMES/google-play-store.json"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — file exists at canonical path with schema_version 1.0 and matching
#       name; passes schema validation.
# ---------------------------------------------------------------------------
@test "google-play-store.json exists at canonical regimes path" {
  [ -f "$RUBRIC" ]
}

@test "google-play-store.json declares schema_version 1.0 and name=google-play-store" {
  sv=$(jq -r '.schema_version' "$RUBRIC")
  name=$(jq -r '.name' "$RUBRIC")
  [ "$sv" = "1.0" ] || { echo "schema_version='$sv' (expected '1.0')" >&2; return 1; }
  [ "$name" = "google-play-store" ] || { echo "name='$name' (expected 'google-play-store')" >&2; return 1; }
}

@test "shipped rubric passes validate-rubric.sh" {
  run "$VALIDATOR" "$RUBRIC"
  [ "$status" -eq 0 ] || {
    echo "validate-rubric.sh failed:" >&2
    echo "$output" >&2
    return 1
  }
}

@test "malformed rubric (rule missing severity) fails validation" {
  bad="$TEST_TMP/bad.json"
  jq 'del(.severity_rules[0].severity)' "$RUBRIC" > "$bad"
  run "$VALIDATOR" "$bad"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# applies_to_skills — same scope as the apple-app-store sibling.
# ---------------------------------------------------------------------------
@test "applies_to_skills equals [review-mobile, review-security]" {
  got=$(jq -c '.applies_to_skills | sort' "$RUBRIC")
  want='["review-mobile","review-security"]'
  [ "$got" = "$want" ] || {
    echo "applies_to_skills=$got (expected $want)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC2 — Play Store policy rules.
# ---------------------------------------------------------------------------
@test "at least one GPS-POL- prefixed rule exists" {
  n=$(jq '[.severity_rules[] | select(.id | startswith("GPS-POL-"))] | length' "$RUBRIC")
  [ "$n" -ge 5 ] || { echo "GPS-POL- rule count=$n (expected >=5)" >&2; return 1; }
}

@test "GPS-POL covers restricted-content / deceptive-behavior / malware / user-data / families" {
  cats=$(jq -r '[.severity_rules[] | select(.id | startswith("GPS-POL-"))] | .[] | .category' "$RUBRIC" | sort -u)
  for c in restricted-content deceptive-behavior malware user-data families-policy; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "missing GPS-POL category: $c" >&2
      echo "categories present:" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC3 — data-safety form rules.
# ---------------------------------------------------------------------------
@test "at least one GPS-DS- prefixed rule exists" {
  n=$(jq '[.severity_rules[] | select(.id | startswith("GPS-DS-"))] | length' "$RUBRIC")
  [ "$n" -ge 5 ] || { echo "GPS-DS- rule count=$n (expected >=5)" >&2; return 1; }
}

@test "GPS-DS covers data-collection / data-sharing / data-handling / security-practices / privacy-policy" {
  cats=$(jq -r '[.severity_rules[] | select(.id | startswith("GPS-DS-"))] | .[] | .category' "$RUBRIC" | sort -u)
  for c in data-collection data-sharing data-handling security-practices privacy-policy; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "missing GPS-DS category: $c" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC4 — target SDK requirement rules.
# ---------------------------------------------------------------------------
@test "at least one GPS-SDK- prefixed rule exists" {
  n=$(jq '[.severity_rules[] | select(.id | startswith("GPS-SDK-"))] | length' "$RUBRIC")
  [ "$n" -ge 3 ] || { echo "GPS-SDK- rule count=$n (expected >=3)" >&2; return 1; }
}

@test "GPS-SDK covers target-sdk-version / compile-sdk-alignment / annual-deadline" {
  cats=$(jq -r '[.severity_rules[] | select(.id | startswith("GPS-SDK-"))] | .[] | .category' "$RUBRIC" | sort -u)
  for c in target-sdk-version compile-sdk-alignment annual-deadline; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "missing GPS-SDK category: $c" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

@test "GPS-SDK rules reference Android API level in description" {
  bad=$(jq -r '[.severity_rules[]
                | select(.id | startswith("GPS-SDK-"))
                | select((.description | test("API[ -]?level|API ?[0-9]+"; "i")) | not)
                | .id] | length' "$RUBRIC")
  [ "$bad" -eq 0 ] || {
    echo "$bad GPS-SDK rule(s) missing API-level reference in description" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC5 — RFC 7396 merge compatibility with mobile.json base.
# ---------------------------------------------------------------------------
@test "rubric-merger.sh merges with mobile.json base + google-play-store regime" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  run "$MERGER" "$RUBRICS_BASE/mobile.json" "$RUBRIC"
  [ "$status" -eq 0 ] || {
    echo "merger failed:" >&2
    echo "$output" >&2
    return 1
  }
  echo "$output" | jq -e . >/dev/null
  merged_name=$(echo "$output" | jq -r '.name')
  [ "$merged_name" = "google-play-store" ] || {
    echo "merged name='$merged_name' (expected 'google-play-store')" >&2
    return 1
  }
  gps_count=$(echo "$output" | jq '[.severity_rules[] | select(.id | startswith("GPS-"))] | length')
  [ "$gps_count" -ge 1 ] || {
    echo "merged result has no GPS-* rules" >&2
    return 1
  }
}

@test "rubric-merger.sh produces deterministic output" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out1=$("$MERGER" "$RUBRICS_BASE/mobile.json" "$RUBRIC")
  out2=$("$MERGER" "$RUBRICS_BASE/mobile.json" "$RUBRIC")
  [ "$out1" = "$out2" ]
}

# ---------------------------------------------------------------------------
# AC6 — metadata fields complete.
# ---------------------------------------------------------------------------
@test "top-level metadata has name, version, description, platform, regime_type, applies_when, supersedes" {
  for f in name version description platform regime_type applies_when supersedes; do
    val=$(jq -r ".metadata.$f // empty" "$RUBRIC")
    [ -n "$val" ] || {
      # supersedes may be an empty array (jq -r prints empty). Distinguish.
      if [ "$f" = "supersedes" ]; then
        type=$(jq -r '.metadata.supersedes | type' "$RUBRIC")
        [ "$type" = "array" ] || { echo "metadata.$f missing or not array (type=$type)" >&2; return 1; }
      else
        echo "metadata.$f missing" >&2
        return 1
      fi
    }
  done
}

@test "metadata.platform = android, metadata.regime_type = store, metadata.name = google-play-store" {
  platform=$(jq -r '.metadata.platform' "$RUBRIC")
  regime_type=$(jq -r '.metadata.regime_type' "$RUBRIC")
  meta_name=$(jq -r '.metadata.name' "$RUBRIC")
  [ "$platform" = "android" ] || { echo "metadata.platform='$platform' (expected android)" >&2; return 1; }
  [ "$regime_type" = "store" ] || { echo "metadata.regime_type='$regime_type' (expected store)" >&2; return 1; }
  [ "$meta_name" = "google-play-store" ] || { echo "metadata.name='$meta_name' (expected google-play-store)" >&2; return 1; }
}

@test "metadata.version is semver" {
  v=$(jq -r '.metadata.version' "$RUBRIC")
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "metadata.version='$v' is not semver" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC7 — configurable thresholds.
# ---------------------------------------------------------------------------
@test "config.min_target_sdk defaults to 34 (integer)" {
  v=$(jq -r '.config.min_target_sdk' "$RUBRIC")
  t=$(jq -r '.config.min_target_sdk | type' "$RUBRIC")
  [ "$v" = "34" ] || { echo "config.min_target_sdk='$v' (expected 34)" >&2; return 1; }
  [ "$t" = "number" ] || { echo "config.min_target_sdk type='$t' (expected number)" >&2; return 1; }
}

@test "config.data_safety_strict_mode defaults to true (boolean)" {
  v=$(jq -r '.config.data_safety_strict_mode' "$RUBRIC")
  t=$(jq -r '.config.data_safety_strict_mode | type' "$RUBRIC")
  [ "$v" = "true" ] || { echo "config.data_safety_strict_mode='$v' (expected true)" >&2; return 1; }
  [ "$t" = "boolean" ] || { echo "config.data_safety_strict_mode type='$t' (expected boolean)" >&2; return 1; }
}

@test "config.enforce_families_policy defaults to false (boolean)" {
  v=$(jq -r '.config.enforce_families_policy' "$RUBRIC")
  t=$(jq -r '.config.enforce_families_policy | type' "$RUBRIC")
  [ "$v" = "false" ] || { echo "config.enforce_families_policy='$v' (expected false)" >&2; return 1; }
  [ "$t" = "boolean" ] || { echo "config.enforce_families_policy type='$t' (expected boolean)" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Detector type discipline (mirrors apple-app-store sibling, AC8).
# ---------------------------------------------------------------------------
@test "every rule declares detector_type in {pattern,ast,semantic}" {
  bad=$(jq '[.severity_rules[]
            | select(
                (has("detector_type") | not) or
                ([.detector_type] | inside(["pattern","ast","semantic"] | [.[]]) | not)
              )
           ] | length' "$RUBRIC")
  [ "$bad" -eq 0 ] || {
    echo "$bad rule(s) missing or invalid detector_type" >&2
    jq -r '.severity_rules[] | select(
              (has("detector_type") | not) or
              ([.detector_type] | inside(["pattern","ast","semantic"] | [.[]]) | not)
            ) | .id' "$RUBRIC" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Severity tier discipline (5-tier model, mirrors apple-app-store AC10).
# ---------------------------------------------------------------------------
@test "every rule declares severity in 5-tier model" {
  bad=$(jq '[.severity_rules[]
            | select(
                ([.severity] | inside(["Critical","High","Medium","Low","Info"] | [.[]]) | not)
              )
           ] | length' "$RUBRIC")
  [ "$bad" -eq 0 ] || {
    echo "$bad rule(s) outside the 5-tier severity model" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Required-field hygiene plus story-mandated extras.
# ---------------------------------------------------------------------------
@test "every rule has required schema fields plus story-mandated metadata" {
  bad=$(jq '[.severity_rules[]
            | select(
                (has("id")             | not) or (.id          | type != "string") or (.id          | length == 0) or
                (has("category")       | not) or (.category    | type != "string") or (.category    | length == 0) or
                (has("pattern")        | not) or (.pattern     | type != "string") or (.pattern     | length < 4)  or
                (has("severity")       | not) or
                (has("description")    | not) or (.description | type != "string") or (.description | length == 0) or
                (has("remediation")    | not) or
                (has("detector_type")  | not) or
                (has("applies_to_files") | not) or
                (has("guideline_ref")  | not)
              )
           ] | length' "$RUBRIC")
  [ "$bad" -eq 0 ] || {
    echo "$bad rule(s) missing required fields" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Rule-id uniqueness inside this rubric and across all regime rubrics.
# ---------------------------------------------------------------------------
@test "all rule ids in google-play-store.json are unique" {
  total=$(jq '[.severity_rules[].id] | length' "$RUBRIC")
  unique=$(jq '[.severity_rules[].id] | unique | length' "$RUBRIC")
  [ "$total" -eq "$unique" ] || {
    echo "duplicate rule ids: total=$total unique=$unique" >&2
    return 1
  }
}

@test "GPS-* rule ids do not collide with sibling regime rubrics" {
  ids_file="$TEST_TMP/all-ids.txt"
  : > "$ids_file"
  for r in gdpr hipaa pci-dss sox ccpa soc2 iso-27001 wcag-2.1-aa wcag-2.1-aaa apple-app-store google-play-store; do
    jq -r '.severity_rules[].id' "$RUBRICS_REGIMES/${r}.json" >> "$ids_file"
  done
  total=$(wc -l < "$ids_file")
  unique=$(sort -u "$ids_file" | wc -l)
  [ "$total" -eq "$unique" ] || {
    echo "rule-id collisions across regimes: total=$total unique=$unique" >&2
    sort "$ids_file" | uniq -d >&2
    return 1
  }
}

@test "rule ids match GPS-(POL|DS|SDK)-NNN format" {
  bad=$(jq -r '.severity_rules[].id
              | select(test("^GPS-(POL|DS|SDK)-[0-9]{3}$") | not)' "$RUBRIC")
  [ -z "$bad" ] || {
    echo "rule ids outside GPS-(POL|DS|SDK)-NNN format:" >&2
    echo "$bad" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Spot-check critical-severity rules (mirrors apple AC10 spot-checks).
# Malware and external-payment style violations must be Critical.
# ---------------------------------------------------------------------------
@test "malware policy rule severity is Critical" {
  malware_sev=$(jq -r '[.severity_rules[] | select(.category == "malware") | .severity] | unique | .[]' "$RUBRIC")
  [ "$malware_sev" = "Critical" ] || {
    echo "malware rule severity='$malware_sev' (expected Critical)" >&2
    return 1
  }
}
