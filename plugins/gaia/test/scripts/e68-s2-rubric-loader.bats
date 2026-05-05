#!/usr/bin/env bats
# e68-s2-rubric-loader.bats — Layered rubric loader tests
#
# Story: E68-S2 — Layered rubric loader (base + regimes + domain + project)
#
# Covers AC1 (four-layer loading order), AC8 (BLOCKED on schema fail),
# AC9 (base-only identity merge).

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
LOADER="$SCRIPTS_DIR/rubric-loader.sh"
SCHEMA="$PLUGIN_DIR/schemas/rubric.schema.json"

setup() {
  TMP_DIR="$(mktemp -d)"
  # Build a fixture rubrics tree under TMP_DIR.
  mkdir -p "$TMP_DIR/rubrics/base" "$TMP_DIR/rubrics/regimes" \
           "$TMP_DIR/rubrics/domain" "$TMP_DIR/rubrics/project"
}

teardown() {
  rm -rf "$TMP_DIR"
}

valid_rubric() {
  # $1 = skill name, optional $2 = JSON snippet to merge under .extras
  local skill="$1"
  cat <<EOF
{
  "schema_version": "1.0",
  "skill": "$skill",
  "severity_rules": [
    {"id": "${skill}.r1", "category": "category-a", "pattern": "x",
     "severity": "Medium", "description": "Test rule for $skill"}
  ]
}
EOF
}

@test "AC9 / TC-RSV2-RUBRIC-06: base-only project — merged output equals base rubric" {
  valid_rubric "code" >"$TMP_DIR/rubrics/base/code.json"
  run "$LOADER" --skill code --rubrics-root "$TMP_DIR/rubrics" --regimes "" --no-domain --no-project
  [ "$status" -eq 0 ]
  # Output equals base after sort-keys normalisation
  local base_normalised
  base_normalised=$(jq --sort-keys -c . "$TMP_DIR/rubrics/base/code.json")
  local out_normalised
  out_normalised=$(printf '%s' "$output" | jq --sort-keys -c .)
  [ "$base_normalised" = "$out_normalised" ]
}

@test "AC1 / TC-RSV2-RUBRIC-01: four-layer order — base + 2 regimes + domain + project" {
  # base sets owner=base, layer-marker=base
  cat >"$TMP_DIR/rubrics/base/code.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"owner":"base","layer_marker":"base","gdpr_only":"unset"}
EOF
  # gdpr regime overrides owner, sets gdpr_only and layer_marker
  cat >"$TMP_DIR/rubrics/regimes/gdpr.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"owner":"gdpr","layer_marker":"gdpr","gdpr_only":"set-by-gdpr"}
EOF
  # hipaa regime overrides owner and layer_marker (later regime wins)
  cat >"$TMP_DIR/rubrics/regimes/hipaa.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"owner":"hipaa","layer_marker":"hipaa"}
EOF
  # domain overrides layer_marker
  cat >"$TMP_DIR/rubrics/domain/fintech.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"layer_marker":"domain","domain_only":"yes"}
EOF
  # project overrides everything
  cat >"$TMP_DIR/rubrics/project/code.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"layer_marker":"project","project_only":"yes"}
EOF
  run "$LOADER" --skill code --rubrics-root "$TMP_DIR/rubrics" \
                --regimes "gdpr,hipaa" --domain "fintech" --no-project-discover \
                --project-rubric "$TMP_DIR/rubrics/project/code.json"
  [ "$status" -eq 0 ]
  # later layers overrode earlier
  local marker owner gdpr_only domain_only project_only
  marker=$(printf '%s' "$output" | jq -r '.layer_marker')
  owner=$(printf '%s' "$output" | jq -r '.owner')
  gdpr_only=$(printf '%s' "$output" | jq -r '.gdpr_only')
  domain_only=$(printf '%s' "$output" | jq -r '.domain_only')
  project_only=$(printf '%s' "$output" | jq -r '.project_only')
  [ "$marker" = "project" ]
  [ "$owner" = "hipaa" ]            # hipaa was last regime
  [ "$gdpr_only" = "set-by-gdpr" ]  # not overridden by later layers
  [ "$domain_only" = "yes" ]
  [ "$project_only" = "yes" ]
}

@test "AC1: regime declaration order matters (gdpr,hipaa vs hipaa,gdpr)" {
  cat >"$TMP_DIR/rubrics/base/code.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"owner":"base"}
EOF
  cat >"$TMP_DIR/rubrics/regimes/gdpr.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"owner":"gdpr"}
EOF
  cat >"$TMP_DIR/rubrics/regimes/hipaa.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[],"owner":"hipaa"}
EOF
  run bash -c "$LOADER --skill code --rubrics-root '$TMP_DIR/rubrics' --regimes 'gdpr,hipaa' --no-domain --no-project | jq -r '.owner'"
  [ "$status" -eq 0 ]
  [ "$output" = "hipaa" ]
  run bash -c "$LOADER --skill code --rubrics-root '$TMP_DIR/rubrics' --regimes 'hipaa,gdpr' --no-domain --no-project | jq -r '.owner'"
  [ "$status" -eq 0 ]
  [ "$output" = "gdpr" ]
}

@test "AC8 / TC-RSV2-RUBRIC-05: invalid rubric halts with BLOCKED" {
  # Rubric missing required schema_version field
  cat >"$TMP_DIR/rubrics/base/code.json" <<'EOF'
{"skill":"code","severity_rules":[]}
EOF
  run "$LOADER" --skill code --rubrics-root "$TMP_DIR/rubrics" --regimes "" --no-domain --no-project
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "BLOCKED"
}

@test "AC8: invalid severity enum value halts with BLOCKED" {
  cat >"$TMP_DIR/rubrics/base/code.json" <<'EOF'
{"schema_version":"1.0","skill":"code","severity_rules":[{"id":"r1","category":"c","pattern":"p","severity":"Unknown","description":"d"}]}
EOF
  run "$LOADER" --skill code --rubrics-root "$TMP_DIR/rubrics" --regimes "" --no-domain --no-project
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "BLOCKED"
}

@test "missing regime file exits non-zero with actionable error" {
  valid_rubric "code" >"$TMP_DIR/rubrics/base/code.json"
  run "$LOADER" --skill code --rubrics-root "$TMP_DIR/rubrics" --regimes "nonexistent" --no-domain --no-project
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -i "not found\|missing"
}
