#!/usr/bin/env bats
# e74-s4-apple-app-store-rubric.bats — E74-S4 Apple App Store regime rubric.
#
# Asserts that `apple-app-store.json` shipped under
# `gaia-public/plugins/gaia/rubrics/regimes/` conforms to `rubric.schema.json`
# (E68-S2) and meets the story-level acceptance criteria E74-S4 AC1..AC10.
#
#   AC1   Rubric file ships at canonical regimes path and is gaia/rubric/v1
#         (schema_version 1.0) compliant.
#   AC2   HIG conformance rules — touch-target, navigation bar, tab bar, safe
#         area, dynamic type, SF Symbols. AAS-HIG- prefix.
#   AC3   IAP compliance rules — server receipt validation, StoreKit usage,
#         subscription handling, restore-purchases, external payment ban.
#         AAS-IAP- prefix.
#   AC4   Privacy nutrition label rules — PrivacyInfo.xcprivacy, Required
#         Reason API, label-vs-SDK consistency, third-party SDK manifests.
#         AAS-PRIV- prefix.
#   AC5   ATT requirement rules — ATTrackingManager, NSUserTrackingUsage-
#         Description, ATT denial handling, fingerprinting prohibition.
#         AAS-ATT- prefix.
#   AC6   Schema validation passes for shipped file; malformed copy fails.
#   AC7   rubric-merger.sh integrates the regime rubric correctly.
#   AC8   Detector types are pattern, ast, or semantic.
#   AC9   applies_to_skills equals ["review-mobile", "review-security"].
#   AC10  Severity uses the 5-tier model exclusively.
#
# Story: E74-S4
# ADR:   ADR-079 (Layered Rubric Loading), ADR-081 (Mobile-as-Platform)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_REGIMES="$PLUGIN_DIR/rubrics/regimes"
RUBRICS_BASE="$PLUGIN_DIR/rubrics/base"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"
MERGER="$PLUGIN_DIR/scripts/rubric-merger.sh"
RUBRIC="$RUBRICS_REGIMES/apple-app-store.json"

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — file exists at canonical path with schema_version 1.0 and matching
#       name.
# ---------------------------------------------------------------------------
@test "AC1: apple-app-store.json exists at canonical regimes path" {
  [ -f "$RUBRIC" ]
}

@test "AC1: apple-app-store.json declares schema_version 1.0 and name=apple-app-store" {
  sv=$(jq -r '.schema_version' "$RUBRIC")
  name=$(jq -r '.name' "$RUBRIC")
  [ "$sv" = "1.0" ] || { echo "schema_version='$sv' (expected '1.0')" >&2; return 1; }
  [ "$name" = "apple-app-store" ] || { echo "name='$name' (expected 'apple-app-store')" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# AC6 — schema validation succeeds for shipped file, fails for a malformed
#       copy with a rule missing severity.
# ---------------------------------------------------------------------------
@test "AC6: shipped rubric passes validate-rubric.sh" {
  run "$VALIDATOR" "$RUBRIC"
  [ "$status" -eq 0 ] || {
    echo "validate-rubric.sh failed:" >&2
    echo "$output" >&2
    return 1
  }
}

@test "AC6: malformed rubric (rule missing severity) fails validation" {
  bad="$TEST_TMP/bad.json"
  jq 'del(.severity_rules[0].severity)' "$RUBRIC" > "$bad"
  run "$VALIDATOR" "$bad"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC9 — applies_to_skills exactly equals ["review-mobile","review-security"].
# ---------------------------------------------------------------------------
@test "AC9: applies_to_skills equals [review-mobile, review-security]" {
  got=$(jq -c '.applies_to_skills | sort' "$RUBRIC")
  want='["review-mobile","review-security"]'
  [ "$got" = "$want" ] || {
    echo "applies_to_skills=$got (expected $want)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC2..AC5 — required AAS-* rule prefixes are present.
# ---------------------------------------------------------------------------
@test "AC2: at least one AAS-HIG- prefixed rule exists" {
  n=$(jq '[.severity_rules[] | select(.id | startswith("AAS-HIG-"))] | length' "$RUBRIC")
  [ "$n" -ge 6 ] || { echo "AAS-HIG- rule count=$n (expected >=6)" >&2; return 1; }
}

@test "AC2: AAS-HIG covers touch-target / nav / tab / safe-area / dynamic-type / sf-symbols" {
  cats=$(jq -r '[.severity_rules[] | select(.id | startswith("AAS-HIG-"))] | .[] | .category' "$RUBRIC" | sort -u)
  for c in touch-target navigation-bar tab-bar safe-area dynamic-type sf-symbols; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "missing AAS-HIG category: $c" >&2
      echo "categories present:" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

@test "AC3: at least one AAS-IAP- prefixed rule exists" {
  n=$(jq '[.severity_rules[] | select(.id | startswith("AAS-IAP-"))] | length' "$RUBRIC")
  [ "$n" -ge 5 ] || { echo "AAS-IAP- rule count=$n (expected >=5)" >&2; return 1; }
}

@test "AC3: AAS-IAP covers receipt-validation / storekit / subscription / restore / external-payment" {
  cats=$(jq -r '[.severity_rules[] | select(.id | startswith("AAS-IAP-"))] | .[] | .category' "$RUBRIC" | sort -u)
  for c in receipt-validation storekit-api subscription-status restore-purchases external-payment; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "missing AAS-IAP category: $c" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

@test "AC4: at least one AAS-PRIV- prefixed rule exists" {
  n=$(jq '[.severity_rules[] | select(.id | startswith("AAS-PRIV-"))] | length' "$RUBRIC")
  [ "$n" -ge 4 ] || { echo "AAS-PRIV- rule count=$n (expected >=4)" >&2; return 1; }
}

@test "AC4: AAS-PRIV covers manifest / required-reason / label-consistency / third-party-sdk" {
  cats=$(jq -r '[.severity_rules[] | select(.id | startswith("AAS-PRIV-"))] | .[] | .category' "$RUBRIC" | sort -u)
  for c in privacy-manifest required-reason-api nutrition-label-consistency third-party-sdk-manifest; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "missing AAS-PRIV category: $c" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

@test "AC5: at least one AAS-ATT- prefixed rule exists" {
  n=$(jq '[.severity_rules[] | select(.id | startswith("AAS-ATT-"))] | length' "$RUBRIC")
  [ "$n" -ge 4 ] || { echo "AAS-ATT- rule count=$n (expected >=4)" >&2; return 1; }
}

@test "AC5: AAS-ATT covers tracking-authorization / usage-description / denial-handling / fingerprinting" {
  cats=$(jq -r '[.severity_rules[] | select(.id | startswith("AAS-ATT-"))] | .[] | .category' "$RUBRIC" | sort -u)
  for c in tracking-authorization usage-description denial-handling fingerprinting-prohibition; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "missing AAS-ATT category: $c" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC8 — every rule's detector_type is one of pattern|ast|semantic.
# ---------------------------------------------------------------------------
@test "AC8: every rule declares detector_type in {pattern,ast,semantic}" {
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
# AC10 — severity strictly in {Critical,High,Medium,Low,Info}.
# ---------------------------------------------------------------------------
@test "AC10: every rule declares severity in 5-tier model" {
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

@test "AC10: 3.1.1 IAP and 5.1 privacy guideline violations are Critical" {
  # Spot-check that the most serious rules carry Critical severity.
  iap_critical=$(jq -r '[.severity_rules[] | select(.category == "external-payment") | .severity] | unique | .[]' "$RUBRIC")
  [ "$iap_critical" = "Critical" ] || {
    echo "external-payment rule severity='$iap_critical' (expected Critical)" >&2
    return 1
  }
  fp_critical=$(jq -r '[.severity_rules[] | select(.category == "fingerprinting-prohibition") | .severity] | unique | .[]' "$RUBRIC")
  [ "$fp_critical" = "Critical" ] || {
    echo "fingerprinting rule severity='$fp_critical' (expected Critical)" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# Required-fields hygiene — schema-level required fields plus the story-level
# extras (detector_type, applies_to_files, guideline_ref).
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
# Rule-id uniqueness within this rubric and against the nine E68-S4 regimes.
# ---------------------------------------------------------------------------
@test "all rule ids in apple-app-store.json are unique" {
  total=$(jq '[.severity_rules[].id] | length' "$RUBRIC")
  unique=$(jq '[.severity_rules[].id] | unique | length' "$RUBRIC")
  [ "$total" -eq "$unique" ] || {
    echo "duplicate rule ids: total=$total unique=$unique" >&2
    return 1
  }
}

@test "AAS-* rule ids do not collide with the nine E68-S4 regime rubrics" {
  ids_file="$TEST_TMP/all-ids.txt"
  : > "$ids_file"
  for r in gdpr hipaa pci-dss sox ccpa soc2 iso-27001 wcag-2.1-aa wcag-2.1-aaa apple-app-store; do
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

# ---------------------------------------------------------------------------
# AC2 — rule-id format AAS-{HIG|IAP|PRIV|ATT}-{NNN}.
# ---------------------------------------------------------------------------
@test "rule ids match AAS-(HIG|IAP|PRIV|ATT)-NNN format" {
  bad=$(jq -r '.severity_rules[].id
              | select(test("^AAS-(HIG|IAP|PRIV|ATT)-[0-9]{3}$") | not)' "$RUBRIC")
  [ -z "$bad" ] || {
    echo "rule ids outside AAS-(HIG|IAP|PRIV|ATT)-NNN format:" >&2
    echo "$bad" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# AC7 — rubric-merger.sh integration. Merge a base regime (gdpr) with the
# new apple-app-store regime; output is valid JSON, contains AAS-* rules.
# Because RFC 7396 array-replace replaces the earlier severity_rules with
# the later layer, we verify by ordering apple-app-store as the LATER layer.
# ---------------------------------------------------------------------------
@test "AC7: rubric-merger.sh merges with apple-app-store as later layer" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  run "$MERGER" "$RUBRICS_REGIMES/gdpr.json" "$RUBRIC"
  [ "$status" -eq 0 ] || {
    echo "merger failed:" >&2
    echo "$output" >&2
    return 1
  }
  echo "$output" | jq -e . >/dev/null
  merged_name=$(echo "$output" | jq -r '.name')
  [ "$merged_name" = "apple-app-store" ] || {
    echo "merged name='$merged_name' (expected 'apple-app-store')" >&2
    return 1
  }
  # Merged layer has at least one AAS-* rule.
  aas_count=$(echo "$output" | jq '[.severity_rules[] | select(.id | startswith("AAS-"))] | length')
  [ "$aas_count" -ge 1 ] || {
    echo "merged result has no AAS-* rules" >&2
    return 1
  }
}

@test "AC7: rubric-merger.sh produces deterministic output" {
  if [ ! -x "$MERGER" ]; then
    skip "depends on E68-S2 rubric-merger.sh"
  fi
  out1=$("$MERGER" "$RUBRICS_REGIMES/gdpr.json" "$RUBRIC")
  out2=$("$MERGER" "$RUBRICS_REGIMES/gdpr.json" "$RUBRIC")
  [ "$out1" = "$out2" ]
}
