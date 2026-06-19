#!/usr/bin/env bats
# e68-s4-regime-rubrics-validation.bats — E68-S4 regime rubric file coverage.
#
# Asserts that the nine regime rubric files shipped under
# `gaia-public/plugins/gaia/rubrics/regimes/` (gdpr, hipaa, pci-dss, sox, ccpa,
# soc2, iso-27001, wcag-2.1-aa, wcag-2.1-aaa) conform to `rubric.schema.json`
# (delivered by E68-S2) and meet the story-level acceptance criteria:
#
#   AC1   nine files exist at canonical paths
#   AC2   each file passes JSON-schema validation (validate-rubric.sh)
#   AC3   each file declares schema_version, name (regime id), and
#         applies_to_skills (non-empty) drawn from the six review skills
#   AC4   gdpr.json covers PII handling / retention / consent / DSAR /
#         transfer / right-to-erasure with `gdpr-` prefixed rule ids;
#         applies to review-code and review-security
#   AC5   hipaa.json covers PHI handling / access audit / minimum necessary /
#         encryption / BAA / breach with `hipaa-` prefixed rule ids
#   AC6   pci-dss.json covers cardholder data / segmentation / TLS / access /
#         audit log / vuln management with `pci-` prefixed rule ids
#   AC7   sox.json covers financial audit trail / SoD / change-management /
#         data integrity / access control with `sox-` prefixed rule ids
#   AC8   ccpa.json covers PI disclosure / opt-out / deletion / privacy
#         policy / third-party / financial incentive with `ccpa-` prefixes
#   AC9   soc2.json covers security / availability / processing-integrity /
#         confidentiality / privacy with `soc2-` prefixed rule ids
#   AC10  iso-27001.json covers asset / risk / access / crypto / ops /
#         comms / incident with `iso27k-` prefixed rule ids
#   AC11  wcag-2.1-aa.json covers perceivable / operable / understandable /
#         robust with `wcag-aa-` prefixed rule ids; applies to review-a11y
#         and review-code
#   AC12  wcag-2.1-aaa.json layers AAA enhancements (enhanced contrast, sign
#         language, extended audio, reading level, pronunciation, timing)
#         with `wcag-aaa-` prefixed rule ids
#   AC13  regime + base merge via rubric-merger.sh produces output containing
#         both layers (covered in e68-s4-regime-rubrics-merge.bats)
#   AC14  no duplicate rule ids across the nine regime rubrics
#
# Story: E68-S4
# ADR:   ADR-079 (Layered Rubric Loading), ADR-042 (Scripts-over-LLM)

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RUBRICS_REGIMES="$PLUGIN_DIR/rubrics/regimes"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"
VALIDATOR="$PLUGIN_DIR/scripts/validate-rubric.sh"

REGIMES=(gdpr hipaa pci-dss sox ccpa soc2 iso-27001 wcag-2.1-aa wcag-2.1-aaa)

setup() { common_setup; }
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# AC1 — nine regime rubric files exist at canonical paths.
# ---------------------------------------------------------------------------
@test "all nine regime rubric files exist" {
  for r in "${REGIMES[@]}"; do
    [ -f "$RUBRICS_REGIMES/${r}.json" ] || {
      echo "missing rubric: $RUBRICS_REGIMES/${r}.json" >&2
      return 1
    }
  done
}

@test "out-of-scope store regime files are NOT shipped (E74 scope)" {
  # apple-app-store.json was lifted out of this scope by E74-S4 (now shipped).
  # google-play-store.json was lifted out of this scope by E74-S5 (now shipped).
  # coppa.json was lifted out of this scope by E74-S6 (now shipped).
  # Future E74 store regime files (none currently outstanding) would be
  # listed here until their respective stories land.
  : "no remaining out-of-scope store regime files — all E74 store regimes shipped"
}

# ---------------------------------------------------------------------------
# AC2 — every regime rubric validates against rubric.schema.json.
# ---------------------------------------------------------------------------
@test "each regime rubric passes schema validation" {
  for r in "${REGIMES[@]}"; do
    run "$VALIDATOR" "$RUBRICS_REGIMES/${r}.json"
    [ "$status" -eq 0 ] || {
      echo "validate-rubric.sh failed for $r.json:" >&2
      echo "$output" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC3 — schema_version, name, and applies_to_skills are declared.
# `name` is the story-level regime identifier; the canonical schema also
# requires `skill` (singular) which we set to the primary applicable skill.
# ---------------------------------------------------------------------------
@test "each rubric declares schema_version, name, applies_to_skills" {
  for r in "${REGIMES[@]}"; do
    sv=$(jq -r '.schema_version' "$RUBRICS_REGIMES/${r}.json")
    [ "$sv" = "1.0" ] || {
      echo "$r.json schema_version='$sv' (expected '1.0')" >&2
      return 1
    }
    name=$(jq -r '.name // empty' "$RUBRICS_REGIMES/${r}.json")
    [ "$name" = "$r" ] || {
      echo "$r.json name='$name' (expected '$r')" >&2
      return 1
    }
    n=$(jq '.applies_to_skills | length' "$RUBRICS_REGIMES/${r}.json")
    [ "$n" -ge 1 ] || {
      echo "$r.json applies_to_skills empty" >&2
      return 1
    }
    bad=$(jq -r '
      .applies_to_skills[]
      | select(IN("review-code","review-qa","review-test",
                  "review-security","review-perf","review-a11y") | not)
    ' "$RUBRICS_REGIMES/${r}.json")
    [ -z "$bad" ] || {
      echo "$r.json applies_to_skills contains unknown skill(s):" >&2
      echo "$bad" >&2
      return 1
    }
  done
}

@test "each rubric has at least 5 severity rules with required fields" {
  for r in "${REGIMES[@]}"; do
    n=$(jq '.severity_rules | length' "$RUBRICS_REGIMES/${r}.json")
    [ "$n" -ge 5 ] || {
      echo "$r.json has $n rules (expected >= 5)" >&2
      return 1
    }
    bad=$(jq '[.severity_rules[]
              | select(
                  (has("id")          | not) or (.id          | type != "string") or (.id          | length == 0) or
                  (has("category")    | not) or (.category    | type != "string") or (.category    | length == 0) or
                  (has("pattern")     | not) or (.pattern     | type != "string") or (.pattern     | length < 4)  or
                  (has("severity")    | not) or ([.severity] | inside(["Critical","High","Medium","Low","Info"] | [.[]]) | not) or
                  (has("description") | not) or (.description | type != "string") or (.description | length == 0)
                )
              ] | length' "$RUBRICS_REGIMES/${r}.json")
    [ "$bad" -eq 0 ] || {
      echo "$r.json has $bad rule(s) with missing/invalid required fields" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# Per-regime rule-id prefix and applies_to_skills checks.
# Prefix matches case-insensitively to satisfy the story-mandated uppercase
# prefix while keeping IDs consistent with base-rubric lowercase convention.
# ---------------------------------------------------------------------------
check_prefix() {
  local file="$1" prefix="$2"
  local bad
  bad=$(jq -r --arg p "$prefix" '
    .severity_rules[].id
    | select(ascii_downcase | startswith($p) | not)
  ' "$file")
  [ -z "$bad" ] || {
    echo "$file has rule ids missing prefix '$prefix':" >&2
    echo "$bad" >&2
    return 1
  }
}

check_categories() {
  local file="$1"; shift
  local cats
  cats=$(jq -r '.severity_rules[].category' "$file" | sort -u)
  for c in "$@"; do
    grep -Fxq "$c" <<<"$cats" || {
      echo "$file missing required category: $c" >&2
      echo "categories present:" >&2
      echo "$cats" >&2
      return 1
    }
  done
}

check_applies() {
  local file="$1"; shift
  local skills
  skills=$(jq -r '.applies_to_skills[]' "$file" | sort -u)
  for s in "$@"; do
    grep -Fxq "$s" <<<"$skills" || {
      echo "$file applies_to_skills missing: $s" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC4 — GDPR rubric.
# ---------------------------------------------------------------------------
@test "gdpr.json covers PII / retention / consent / DSAR / transfer / erasure" {
  check_categories "$RUBRICS_REGIMES/gdpr.json" \
    pii-handling data-retention consent dsar cross-border-transfer right-to-erasure
}

@test "gdpr.json rule ids prefixed gdpr" {
  check_prefix "$RUBRICS_REGIMES/gdpr.json" "gdpr-"
}

@test "gdpr.json applies to review-code and review-security" {
  check_applies "$RUBRICS_REGIMES/gdpr.json" review-code review-security
}

# ---------------------------------------------------------------------------
# AC5 — HIPAA rubric.
# ---------------------------------------------------------------------------
@test "hipaa.json covers PHI / access-audit / minimum-necessary / encryption / baa / breach" {
  check_categories "$RUBRICS_REGIMES/hipaa.json" \
    phi-handling access-audit minimum-necessary encryption baa breach-notification
}

@test "hipaa.json rule ids prefixed hipaa" {
  check_prefix "$RUBRICS_REGIMES/hipaa.json" "hipaa-"
}

@test "hipaa.json applies to review-code and review-security" {
  check_applies "$RUBRICS_REGIMES/hipaa.json" review-code review-security
}

# ---------------------------------------------------------------------------
# AC6 — PCI-DSS rubric.
# ---------------------------------------------------------------------------
@test "pci-dss.json covers cardholder / segmentation / tls / access / audit / vuln" {
  check_categories "$RUBRICS_REGIMES/pci-dss.json" \
    cardholder-data network-segmentation tls-enforcement access-control audit-log vuln-management
}

@test "pci-dss.json rule ids prefixed pci" {
  check_prefix "$RUBRICS_REGIMES/pci-dss.json" "pci-"
}

@test "pci-dss.json applies to review-code and review-security" {
  check_applies "$RUBRICS_REGIMES/pci-dss.json" review-code review-security
}

# ---------------------------------------------------------------------------
# AC7 — SOX rubric.
# ---------------------------------------------------------------------------
@test "sox.json covers audit-trail / sod / change-management / integrity / access" {
  check_categories "$RUBRICS_REGIMES/sox.json" \
    financial-audit-trail segregation-of-duties change-management data-integrity access-control
}

@test "sox.json rule ids prefixed sox" {
  check_prefix "$RUBRICS_REGIMES/sox.json" "sox-"
}

@test "sox.json applies to review-code and review-security" {
  check_applies "$RUBRICS_REGIMES/sox.json" review-code review-security
}

# ---------------------------------------------------------------------------
# AC8 — CCPA rubric.
# ---------------------------------------------------------------------------
@test "ccpa.json covers disclosure / opt-out / deletion / policy / sharing / incentive" {
  check_categories "$RUBRICS_REGIMES/ccpa.json" \
    pi-disclosure opt-out deletion-handler privacy-policy third-party-sharing financial-incentive
}

@test "ccpa.json rule ids prefixed ccpa" {
  check_prefix "$RUBRICS_REGIMES/ccpa.json" "ccpa-"
}

@test "ccpa.json applies to review-code and review-security" {
  check_applies "$RUBRICS_REGIMES/ccpa.json" review-code review-security
}

# ---------------------------------------------------------------------------
# AC9 — SOC2 rubric.
# ---------------------------------------------------------------------------
@test "soc2.json covers security / availability / processing-integrity / confidentiality / privacy" {
  check_categories "$RUBRICS_REGIMES/soc2.json" \
    security availability processing-integrity confidentiality privacy
}

@test "soc2.json rule ids prefixed soc2" {
  check_prefix "$RUBRICS_REGIMES/soc2.json" "soc2-"
}

@test "soc2.json applies to review-code and review-security" {
  check_applies "$RUBRICS_REGIMES/soc2.json" review-code review-security
}

# ---------------------------------------------------------------------------
# AC10 — ISO-27001 rubric.
# ---------------------------------------------------------------------------
@test "iso-27001.json covers asset / risk / access / crypto / ops / comms / incident" {
  check_categories "$RUBRICS_REGIMES/iso-27001.json" \
    asset-inventory risk-assessment access-control cryptography operations-security communications-security incident-management
}

@test "iso-27001.json rule ids prefixed iso27k" {
  check_prefix "$RUBRICS_REGIMES/iso-27001.json" "iso27k-"
}

@test "iso-27001.json applies to review-code and review-security" {
  check_applies "$RUBRICS_REGIMES/iso-27001.json" review-code review-security
}

# ---------------------------------------------------------------------------
# AC11 — WCAG 2.1 AA rubric.
# ---------------------------------------------------------------------------
@test "wcag-2.1-aa.json covers perceivable / operable / understandable / robust" {
  check_categories "$RUBRICS_REGIMES/wcag-2.1-aa.json" \
    perceivable operable understandable robust
}

@test "wcag-2.1-aa.json rule ids prefixed wcag-aa" {
  check_prefix "$RUBRICS_REGIMES/wcag-2.1-aa.json" "wcag-aa-"
}

@test "wcag-2.1-aa.json applies to review-a11y and review-code" {
  check_applies "$RUBRICS_REGIMES/wcag-2.1-aa.json" review-a11y review-code
}

# ---------------------------------------------------------------------------
# AC12 — WCAG 2.1 AAA rubric.
# ---------------------------------------------------------------------------
@test "wcag-2.1-aaa.json covers AAA enhancements" {
  check_categories "$RUBRICS_REGIMES/wcag-2.1-aaa.json" \
    enhanced-contrast sign-language extended-audio-description reading-level pronunciation timing-and-animation
}

@test "wcag-2.1-aaa.json rule ids prefixed wcag-aaa" {
  check_prefix "$RUBRICS_REGIMES/wcag-2.1-aaa.json" "wcag-aaa-"
}

@test "wcag-2.1-aaa.json applies to review-a11y and review-code" {
  check_applies "$RUBRICS_REGIMES/wcag-2.1-aaa.json" review-a11y review-code
}

# ---------------------------------------------------------------------------
# AC14 — no duplicate rule ids across the nine regime rubrics.
# ---------------------------------------------------------------------------
@test "no rule-id collisions across the nine regime rubrics" {
  ids_file="$TEST_TMP/all-regime-ids.txt"
  : > "$ids_file"
  for r in "${REGIMES[@]}"; do
    jq -r '.severity_rules[].id' "$RUBRICS_REGIMES/${r}.json" >> "$ids_file"
  done
  total=$(wc -l < "$ids_file")
  unique=$(sort -u "$ids_file" | wc -l)
  [ "$total" -eq "$unique" ] || {
    echo "rule-id collisions detected: total=$total unique=$unique" >&2
    sort "$ids_file" | uniq -d >&2
    return 1
  }
}
