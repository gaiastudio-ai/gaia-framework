#!/usr/bin/env bats
# e74-s11-brownfield-mobile-detection.bats — E74-S11
#
# Verifies the mobile-detection helper and brownfield detect-signals
# integration under AC6 / AC7. Each signal type is asserted against a
# fixture project tree; no real codebase is touched.

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"

setup() { common_setup; }
teardown() { common_teardown; }

# Helpers --------------------------------------------------------------------

# Fresh fixture project root.
_mk_proj() {
  local dir="$TEST_TMP/proj-$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Run mobile-detection.sh and pretty-print platforms (one per line).
_platforms_of() {
  "$SCRIPTS/mobile-detection.sh" --project-root "$1" --format json \
    | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("platforms", [])))'
}

# AC6 / AC7: signal mapping --------------------------------------------------

@test "Package.swift triggers ios platform" {
  proj="$(_mk_proj swift)"
  : > "$proj/Package.swift"
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"ios"* ]]
}

@test ".xcodeproj triggers ios platform" {
  proj="$(_mk_proj xcode)"
  mkdir -p "$proj/MyApp.xcodeproj"
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"ios"* ]]
}

@test ".xcworkspace triggers ios platform" {
  proj="$(_mk_proj xcw)"
  mkdir -p "$proj/MyApp.xcworkspace"
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"ios"* ]]
}

@test "build.gradle with com.android.application triggers android platform" {
  proj="$(_mk_proj gradle)"
  cat > "$proj/build.gradle" <<'EOF'
plugins {
  id 'com.android.application'
}
EOF
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"android"* ]]
}

@test "build.gradle without android plugin does NOT trigger android" {
  proj="$(_mk_proj gradle-jvm)"
  cat > "$proj/build.gradle" <<'EOF'
plugins {
  id 'java'
}
EOF
  out="$(_platforms_of "$proj")"
  [[ "$out" != *"android"* ]]
}

@test "build.gradle.kts with com.android.application triggers android" {
  proj="$(_mk_proj gradle-kts)"
  cat > "$proj/build.gradle.kts" <<'EOF'
plugins {
  id("com.android.application")
}
EOF
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"android"* ]]
}

@test "settings.gradle alone is not sufficient — needs an android plugin marker" {
  proj="$(_mk_proj settings-only)"
  : > "$proj/settings.gradle"
  out="$(_platforms_of "$proj")"
  [[ "$out" != *"android"* ]]
}

@test "settings.gradle plus build.gradle android plugin triggers android" {
  proj="$(_mk_proj settings-and-android)"
  : > "$proj/settings.gradle"
  cat > "$proj/build.gradle" <<'EOF'
plugins { id 'com.android.library' }
EOF
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"android"* ]]
}

@test "pubspec.yaml with flutter dependency triggers ios AND android" {
  proj="$(_mk_proj flutter)"
  cat > "$proj/pubspec.yaml" <<'EOF'
name: myapp
dependencies:
  flutter:
    sdk: flutter
EOF
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"ios"* ]]
  [[ "$out" == *"android"* ]]
}

@test "package.json with react-native dep triggers ios AND android" {
  proj="$(_mk_proj rn)"
  cat > "$proj/package.json" <<'EOF'
{ "name": "rn-app", "dependencies": { "react-native": "0.74.0" } }
EOF
  out="$(_platforms_of "$proj")"
  [[ "$out" == *"ios"* ]]
  [[ "$out" == *"android"* ]]
}

@test "package.json without react-native does not add mobile platforms" {
  proj="$(_mk_proj webonly)"
  cat > "$proj/package.json" <<'EOF'
{ "name": "web-app", "dependencies": { "react": "18.0.0" } }
EOF
  out="$(_platforms_of "$proj")"
  [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]
}

@test "default device_targets emitted for ios" {
  proj="$(_mk_proj ios-defaults)"
  : > "$proj/Package.swift"
  out="$("$SCRIPTS/mobile-detection.sh" --project-root "$proj" --format json)"
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
dt = d.get("device_targets", {})
assert "ios" in dt, dt
ios = dt["ios"]
for k in ("os_versions","form_factors","screen_sizes"):
    assert k in ios and ios[k], (k, ios)
'
}

@test "default device_targets emitted for android" {
  proj="$(_mk_proj android-defaults)"
  cat > "$proj/build.gradle" <<'EOF'
plugins { id 'com.android.application' }
EOF
  out="$("$SCRIPTS/mobile-detection.sh" --project-root "$proj" --format json)"
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
dt = d.get("device_targets", {})
assert "android" in dt, dt
a = dt["android"]
for k in ("os_versions","form_factors","screen_sizes"):
    assert k in a and a[k], (k, a)
'
}

# Brownfield integration -----------------------------------------------------

@test "detect-signals.sh integrates mobile detection (Package.swift -> ios in platforms[])" {
  proj="$(_mk_proj brownfield-swift)"
  : > "$proj/Package.swift"
  run "$SCRIPTS/detect-signals.sh" --project-root "$proj" --format json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
plats = [p["name"] if isinstance(p, dict) else p for p in d.get("platforms", [])]
assert "ios" in plats, plats
'
}

@test "detect-signals.sh integrates mobile detection (Flutter -> both platforms)" {
  proj="$(_mk_proj brownfield-flutter)"
  cat > "$proj/pubspec.yaml" <<'EOF'
name: myapp
dependencies:
  flutter:
    sdk: flutter
EOF
  run "$SCRIPTS/detect-signals.sh" --project-root "$proj" --format json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
plats = [p["name"] if isinstance(p, dict) else p for p in d.get("platforms", [])]
assert "ios" in plats, plats
assert "android" in plats, plats
'
}
