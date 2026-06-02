#!/usr/bin/env bats
# e74-s2-mobile-stacks.bats — E74-S2: Four mobile stacks shipped under config/stacks/
#
# Verifies the four mobile-stack definition files (swift.yaml, kotlin.yaml,
# react-native.yaml, flutter.yaml) shipped under
# gaia-framework/plugins/gaia/config/stacks/ per ADR-081.
#
# Acceptance criteria covered:
#   AC1 — swift.yaml exists with required fields           (TC-RSV2-MOBILE-STACK-01)
#   AC2 — kotlin.yaml exists with required fields          (TC-RSV2-MOBILE-STACK-02)
#   AC3 — react-native.yaml exists + bridge field          (TC-RSV2-MOBILE-STACK-03)
#   AC4 — flutter.yaml exists + extends: dart              (TC-RSV2-MOBILE-STACK-04)
#   AC5 — All four declare correct platform association    (TC-RSV2-MOBILE-STACK-05)
#   AC6 — adapters.static references stack-appropriate IDs (TC-RSV2-MOBILE-STACK-06)
#   AC7 — files are loadable / parseable                   (TC-RSV2-MOBILE-STACK-07)
#   AC8 — YAML lint passes                                 (TC-RSV2-MOBILE-STACK-08)

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
STACKS_DIR="$PLUGIN_DIR/config/stacks"

SWIFT_YAML="$STACKS_DIR/swift.yaml"
KOTLIN_YAML="$STACKS_DIR/kotlin.yaml"
RN_YAML="$STACKS_DIR/react-native.yaml"
FLUTTER_YAML="$STACKS_DIR/flutter.yaml"

setup() { common_setup; }
teardown() { common_teardown; }

# --- helpers ---------------------------------------------------------------

_yaml_supported() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import yaml' >/dev/null 2>&1
}

# Parse a top-level scalar (string) field from a YAML file via python+PyYAML.
_yaml_scalar() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
v = doc.get(sys.argv[2])
if v is None:
    sys.exit(1)
print(v)
PY
}

# Print top-level keys present in YAML doc, one per line.
_yaml_top_keys() {
  python3 - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
for k in doc.keys():
    print(k)
PY
}

# Print the platform list (flat, comma-separated, sorted) from a stack file.
_yaml_platforms_csv() {
  python3 - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
pl = doc.get('platform') or []
if isinstance(pl, str):
    pl = [pl]
print(','.join(sorted(pl)))
PY
}

# Print adapters.static list (newline-separated) from a stack file.
_yaml_adapters_static() {
  python3 - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
ad = (doc.get('adapters') or {}).get('static') or []
for a in ad:
    print(a)
PY
}

# Common required-field assertion (six metadata + linters/formatters/test_frameworks/adapters).
_assert_required_fields() {
  local file="$1"
  local keys
  keys=$(_yaml_top_keys "$file") || return 1
  for k in name language platform build_tool package_manager linters formatters test_frameworks adapters; do
    echo "$keys" | grep -qx "$k" || { echo "missing required key '$k' in $file" >&2; return 1; }
  done
}

# --- AC1: swift.yaml -------------------------------------------------------

@test "AC1: swift.yaml exists" {
  [ -f "$SWIFT_YAML" ]
}

@test "AC1: swift.yaml is valid YAML" {
  _yaml_supported || skip "python3+yaml unavailable"
  python3 -c "import yaml; yaml.safe_load(open('$SWIFT_YAML'))"
}

@test "AC1: swift.yaml declares required fields" {
  _yaml_supported || skip "python3+yaml unavailable"
  _assert_required_fields "$SWIFT_YAML"
}

@test "AC1/AC5: swift.yaml platform is [ios]" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_platforms_csv "$SWIFT_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "ios" ]
}

@test "AC1: swift.yaml language is Swift" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_scalar "$SWIFT_YAML" language
  [ "$status" -eq 0 ]
  [ "$output" = "Swift" ]
}

# --- AC2: kotlin.yaml ------------------------------------------------------

@test "AC2: kotlin.yaml exists" {
  [ -f "$KOTLIN_YAML" ]
}

@test "AC2: kotlin.yaml is valid YAML" {
  _yaml_supported || skip "python3+yaml unavailable"
  python3 -c "import yaml; yaml.safe_load(open('$KOTLIN_YAML'))"
}

@test "AC2: kotlin.yaml declares required fields" {
  _yaml_supported || skip "python3+yaml unavailable"
  _assert_required_fields "$KOTLIN_YAML"
}

@test "AC2/AC5: kotlin.yaml platform is [android]" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_platforms_csv "$KOTLIN_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "android" ]
}

@test "AC2: kotlin.yaml language is Kotlin" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_scalar "$KOTLIN_YAML" language
  [ "$status" -eq 0 ]
  [ "$output" = "Kotlin" ]
}

# --- AC3: react-native.yaml ------------------------------------------------

@test "AC3: react-native.yaml exists" {
  [ -f "$RN_YAML" ]
}

@test "AC3: react-native.yaml is valid YAML" {
  _yaml_supported || skip "python3+yaml unavailable"
  python3 -c "import yaml; yaml.safe_load(open('$RN_YAML'))"
}

@test "AC3: react-native.yaml declares required fields" {
  _yaml_supported || skip "python3+yaml unavailable"
  _assert_required_fields "$RN_YAML"
}

@test "AC3: react-native.yaml has bridge field" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_scalar "$RN_YAML" bridge
  [ "$status" -eq 0 ]
  # bridge field must document JSI and/or Bridge
  [[ "$output" == *"JSI"* || "$output" == *"Bridge"* ]]
}

@test "AC3/AC5: react-native.yaml platform is [android, ios]" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_platforms_csv "$RN_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "android,ios" ]
}

# --- AC4: flutter.yaml + extends ------------------------------------------

@test "AC4: flutter.yaml exists" {
  [ -f "$FLUTTER_YAML" ]
}

@test "AC4: flutter.yaml is valid YAML" {
  _yaml_supported || skip "python3+yaml unavailable"
  python3 -c "import yaml; yaml.safe_load(open('$FLUTTER_YAML'))"
}

@test "AC4: flutter.yaml declares required fields" {
  _yaml_supported || skip "python3+yaml unavailable"
  _assert_required_fields "$FLUTTER_YAML"
}

@test "AC4: flutter.yaml has 'extends: dart'" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_scalar "$FLUTTER_YAML" extends
  [ "$status" -eq 0 ]
  [ "$output" = "dart" ]
}

@test "AC4: flutter.yaml language is Dart" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_scalar "$FLUTTER_YAML" language
  [ "$status" -eq 0 ]
  [ "$output" = "Dart" ]
}

@test "AC4/AC5: flutter.yaml platform is [android, ios]" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_platforms_csv "$FLUTTER_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "android,ios" ]
}

# --- AC6: adapter references match stack language -------------------------

@test "AC6: swift.yaml adapters.static contains SwiftLint and SwiftFormat" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_adapters_static "$SWIFT_YAML"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'swiftlint'
  echo "$output" | grep -qi 'swiftformat'
}

@test "AC6: swift.yaml adapters.static does NOT include kotlin/js tools" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_adapters_static "$SWIFT_YAML"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi 'detekt'
  ! echo "$output" | grep -qi 'ktlint'
  ! echo "$output" | grep -qi 'eslint'
}

@test "AC6: kotlin.yaml adapters.static contains Detekt and ktlint" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_adapters_static "$KOTLIN_YAML"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'detekt'
  echo "$output" | grep -qi 'ktlint'
}

@test "AC6: kotlin.yaml adapters.static does NOT include swift/js tools" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_adapters_static "$KOTLIN_YAML"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi 'swiftlint'
  ! echo "$output" | grep -qi 'swiftformat'
  ! echo "$output" | grep -qi 'eslint'
}

@test "AC6: react-native.yaml adapters.static contains ESLint" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_adapters_static "$RN_YAML"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'eslint'
}

@test "AC6: flutter.yaml adapters.static references dart analyzer / flutter lints" {
  _yaml_supported || skip "python3+yaml unavailable"
  run _yaml_adapters_static "$FLUTTER_YAML"
  [ "$status" -eq 0 ]
  # Either "dart_analyzer" / "dart-analyzer" or "flutter_lints" / "flutter-lints" must appear
  echo "$output" | grep -qiE 'dart[-_]?analyzer|flutter[-_]?lints'
}

# --- AC7: resolve-config.sh / parser load --------------------------------

@test "AC7: all four stack files parse without YAML errors" {
  _yaml_supported || skip "python3+yaml unavailable"
  for f in "$SWIFT_YAML" "$KOTLIN_YAML" "$RN_YAML" "$FLUTTER_YAML"; do
    python3 -c "import yaml; doc = yaml.safe_load(open('$f')); assert isinstance(doc, dict), '$f did not parse as a mapping'"
  done
}

# --- AC8: YAML lint -------------------------------------------------------

@test "AC8: no tab characters in any stack file (YAML disallows tabs for indent)" {
  for f in "$SWIFT_YAML" "$KOTLIN_YAML" "$RN_YAML" "$FLUTTER_YAML"; do
    [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
    if grep -qP '^\t' "$f" 2>/dev/null; then
      echo "tab indent found in $f" >&2
      return 1
    fi
  done
}

@test "AC8: no trailing whitespace in any stack file" {
  for f in "$SWIFT_YAML" "$KOTLIN_YAML" "$RN_YAML" "$FLUTTER_YAML"; do
    [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
    if grep -nE ' +$' "$f"; then
      echo "trailing whitespace found in $f" >&2
      return 1
    fi
  done
}

@test "AC8: no duplicate top-level keys (PyYAML strict load)" {
  _yaml_supported || skip "python3+yaml unavailable"
  for f in "$SWIFT_YAML" "$KOTLIN_YAML" "$RN_YAML" "$FLUTTER_YAML"; do
    python3 - "$f" <<'PY'
import sys, yaml
class StrictLoader(yaml.SafeLoader):
    pass
def no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found duplicate key %r" % key,
                key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping
StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)
yaml.load(open(sys.argv[1]), Loader=StrictLoader)
PY
  done
}
