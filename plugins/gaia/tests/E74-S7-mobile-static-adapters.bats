#!/usr/bin/env bats
# E74-S7-mobile-static-adapters.bats — covers AC1, AC2, AC5, AC7 for the seven
# mobile-static adapters (SwiftLint, SwiftFormat, Detekt, ktlint, MobSF, xcsize,
# apkanalyzer). AC3/AC4 are exercised by each adapter's test/contract.bats via the
# canonical four-state probe. AC6 is satisfied by the existence of contract.bats
# under each adapter directory (asserted here).

bats_require_minimum_version 1.5.0

ADAPTERS_DIR="$BATS_TEST_DIRNAME/../scripts/adapters"
SCHEMA="$ADAPTERS_DIR/_schema/adapter.schema.json"
RESOLVER="$BATS_TEST_DIRNAME/../scripts/adapter-platform-resolver.sh"

ADAPTERS=(swiftlint swiftformat detekt ktlint mobsf xcsize apkanalyzer)

# ---------------- AC1 — seven adapter directories present -----------------

@test "all seven mobile-static adapter directories exist" {
  for tool in "${ADAPTERS[@]}"; do
    [ -d "$ADAPTERS_DIR/$tool" ] || { echo "missing $tool directory" >&2; return 1; }
  done
}

@test "each adapter ships adapter.json + run.sh + test/contract.bats" {
  for tool in "${ADAPTERS[@]}"; do
    [ -f "$ADAPTERS_DIR/$tool/adapter.json" ] || { echo "missing $tool/adapter.json" >&2; return 1; }
    [ -x "$ADAPTERS_DIR/$tool/run.sh" ]       || { echo "missing/non-exec $tool/run.sh" >&2; return 1; }
    [ -f "$ADAPTERS_DIR/$tool/test/contract.bats" ] || { echo "missing $tool/test/contract.bats" >&2; return 1; }
  done
}

# ---------------- AC2 — schema conformance + platforms field ---------------

_validate_adapter() {
  local adapter_file="$1"
  if python3 -c "import jsonschema" >/dev/null 2>&1; then
    python3 - "$SCHEMA" "$adapter_file" <<'PY'
import json, sys, jsonschema
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
jsonschema.validate(instance=inst, schema=schema)
PY
    return $?
  fi
  return 99
}

@test "each adapter.json validates against the canonical schema" {
  local skipped=1
  for tool in "${ADAPTERS[@]}"; do
    run _validate_adapter "$ADAPTERS_DIR/$tool/adapter.json"
    if [ "$status" -ne 99 ]; then skipped=0; fi
    [ "$status" -eq 99 ] || [ "$status" -eq 0 ] || { echo "$tool/adapter.json failed schema validation: $output" >&2; return 1; }
  done
  if [ "$skipped" -eq 1 ]; then skip "python3 jsonschema not available"; fi
}

@test "each adapter.json declares 'category' from canonical enum" {
  for tool in "${ADAPTERS[@]}"; do
    run jq -r '.category // ""' "$ADAPTERS_DIR/$tool/adapter.json"
    [ "$status" -eq 0 ]
    case "$output" in
      mobile-static|mobile-dynamic|sast|linter|formatter) ;;
      *) echo "$tool: invalid category '$output'" >&2; return 1 ;;
    esac
  done
}

@test "each adapter.json declares 'platforms' (ios|android|both)" {
  for tool in "${ADAPTERS[@]}"; do
    run jq -e '.platforms | type == "array" and length > 0' "$ADAPTERS_DIR/$tool/adapter.json"
    [ "$status" -eq 0 ] || { echo "$tool: missing or empty 'platforms' array" >&2; return 1; }
    run jq -r '.platforms[]' "$ADAPTERS_DIR/$tool/adapter.json"
    while read -r p; do
      [ "$p" = "ios" ] || [ "$p" = "android" ] || { echo "$tool: invalid platform '$p'" >&2; return 1; }
    done <<< "$output"
  done
}

@test "each adapter.json declares 'applies_to_skills' including review-code and review-mobile" {
  for tool in "${ADAPTERS[@]}"; do
    run jq -e '.applies_to_skills | type == "array" and (index("review-code") != null) and (index("review-mobile") != null)' \
      "$ADAPTERS_DIR/$tool/adapter.json"
    [ "$status" -eq 0 ] || { echo "$tool: applies_to_skills missing review-code or review-mobile" >&2; return 1; }
  done
}

# ---------------- AC2 — platform mapping matches the story spec -----------

@test "SwiftLint, SwiftFormat, xcsize declare platforms=[ios]" {
  for tool in swiftlint swiftformat xcsize; do
    run jq -r '.platforms | sort | join(",")' "$ADAPTERS_DIR/$tool/adapter.json"
    [ "$output" = "ios" ] || { echo "$tool platforms: $output" >&2; return 1; }
  done
}

@test "Detekt, ktlint, apkanalyzer declare platforms=[android]" {
  for tool in detekt ktlint apkanalyzer; do
    run jq -r '.platforms | sort | join(",")' "$ADAPTERS_DIR/$tool/adapter.json"
    [ "$output" = "android" ] || { echo "$tool platforms: $output" >&2; return 1; }
  done
}

@test "MobSF declares platforms=[ios, android] (cross-platform)" {
  run jq -r '.platforms | sort | join(",")' "$ADAPTERS_DIR/mobsf/adapter.json"
  [ "$output" = "android,ios" ]
}

# ---------------- AC5 — platform-gated adapter resolver --------------------

@test "adapter-platform-resolver.sh is present and executable" {
  [ -x "$RESOLVER" ]
}

@test "platforms ios returns ios adapters + cross-platform mobsf" {
  run "$RESOLVER" --platforms ios --adapters-dir "$ADAPTERS_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'swiftlint'
  echo "$output" | grep -qx 'swiftformat'
  echo "$output" | grep -qx 'xcsize'
  echo "$output" | grep -qx 'mobsf'
  ! echo "$output" | grep -qx 'detekt'
  ! echo "$output" | grep -qx 'ktlint'
  ! echo "$output" | grep -qx 'apkanalyzer'
}

@test "platforms android returns android adapters + cross-platform mobsf" {
  run "$RESOLVER" --platforms android --adapters-dir "$ADAPTERS_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'detekt'
  echo "$output" | grep -qx 'ktlint'
  echo "$output" | grep -qx 'apkanalyzer'
  echo "$output" | grep -qx 'mobsf'
  ! echo "$output" | grep -qx 'swiftlint'
  ! echo "$output" | grep -qx 'swiftformat'
  ! echo "$output" | grep -qx 'xcsize'
}

@test "platforms ios,android returns both-platform sets" {
  run "$RESOLVER" --platforms ios,android --adapters-dir "$ADAPTERS_DIR"
  [ "$status" -eq 0 ]
  for adapter in swiftlint swiftformat xcsize detekt ktlint apkanalyzer mobsf; do
    echo "$output" | grep -qx "$adapter" || { echo "missing $adapter in output: $output" >&2; return 1; }
  done
}

@test "platforms web returns no mobile-static adapters" {
  run "$RESOLVER" --platforms web --adapters-dir "$ADAPTERS_DIR"
  [ "$status" -eq 0 ]
  for adapter in "${ADAPTERS[@]}"; do
    ! echo "$output" | grep -qx "$adapter" || { echo "$adapter should not be selected for web platforms" >&2; return 1; }
  done
}

# ---------------- AC7 — evidence layer integration ------------------------

@test "each run.sh emits canonical fragment shape with findings array" {
  # Stub the binary on PATH and assert the fragment shape.
  local fakebin; fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  for tool in swiftlint swiftformat detekt ktlint mobsf xcsize apkanalyzer; do
    local provider; provider="$(jq -r '.provider' "$ADAPTERS_DIR/$tool/adapter.json")"
    cat > "$fakebin/$provider" <<'EOF'
#!/usr/bin/env bash
# Emit a benign exit for any args
exit 0
EOF
    chmod +x "$fakebin/$provider"
  done
  local fl; fl="$BATS_TEST_TMPDIR/files.txt"
  : > "$fl"
  for tool in "${ADAPTERS[@]}"; do
    local ext; ext="$(jq -r '.["file-extensions"][0] // ""' "$ADAPTERS_DIR/$tool/adapter.json")"
    local target="$BATS_TEST_TMPDIR/example${ext:-.bin}"
    : > "$target"
    printf '%s\n' "$target" > "$fl"
    PATH="$fakebin:$PATH" run "$ADAPTERS_DIR/$tool/run.sh" --input "$fl"
    # Exit may be 0 or non-zero depending on tool semantics; we only require
    # that stdout (combined with stderr in `output`) contains a fragment with
    # the required keys when stdout is JSON.
    # Pick out the JSON line — first line that parses as JSON.
    local found_json=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if echo "$line" | jq -e 'has("name") and has("status") and has("findings") and (.findings | type == "array")' >/dev/null 2>&1; then
        found_json=1
        break
      fi
    done <<< "$output"
    [ "$found_json" -eq 1 ] || { echo "$tool: no canonical fragment found in output: $output" >&2; return 1; }
  done
}
