#!/usr/bin/env bash
# mobile-detection.sh — E74-S11 mobile signal detector.
#
# Scans a project root for mobile platform signals and emits a JSON
# document with `platforms` (string array) and `device_targets`
# (canonical block per ADR-081 / project-config schema:
#   {os_versions[], form_factors[], screen_sizes[{width,height,density}]}).
#
# Detection rules (FR-RSV2-44, AC6, AC7):
#   - Package.swift                         -> ios
#   - *.xcodeproj / *.xcworkspace dir       -> ios
#   - build.gradle / build.gradle.kts with com.android.{application,library}
#                                           -> android
#   - settings.gradle alone is NOT enough; android plugin marker required
#   - pubspec.yaml with `flutter:` dep      -> ios + android
#   - package.json with react-native dep    -> ios + android
#
# Signals are additive — multiple matches simply union the platform set.
#
# Usage:
#   mobile-detection.sh --project-root <dir> [--format json]
#
# Exit codes:
#   0  success
#   1  argument error or missing dependency
#
# Requires: python3 (json emit). jq is NOT required so this script can be
# invoked from minimal environments and from tests.

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="mobile-detection.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

PROJECT_ROOT=""
FORMAT="json"

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root)
      [ $# -ge 2 ] || { err "--project-root requires a path"; exit 1; }
      PROJECT_ROOT="$2"; shift 2 ;;
    --project-root=*)
      PROJECT_ROOT="${1#--project-root=}"; shift ;;
    --format)
      [ $# -ge 2 ] || { err "--format requires a value"; exit 1; }
      FORMAT="$2"; shift 2 ;;
    --format=*)
      FORMAT="${1#--format=}"; shift ;;
    -h|--help)
      sed -n '1,30p' "$0" >&2; exit 0 ;;
    *)
      err "unknown argument: $1"; exit 1 ;;
  esac
done

[ -n "$PROJECT_ROOT" ] || { err "missing required --project-root <dir>"; exit 1; }
[ -d "$PROJECT_ROOT" ] || { err "project root not a directory: $PROJECT_ROOT"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found in PATH"; exit 1; }

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

has_ios=0
has_android=0

# --- iOS signals ------------------------------------------------------------
if [ -f "$PROJECT_ROOT/Package.swift" ]; then
  has_ios=1
fi
# Any *.xcodeproj or *.xcworkspace at depth <= 4.
if [ "$has_ios" -eq 0 ]; then
  if find "$PROJECT_ROOT" -maxdepth 4 \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print 2>/dev/null | grep -q .; then
    has_ios=1
  fi
fi

# --- Android signals --------------------------------------------------------
_check_gradle_android() {
  local f="$1"
  [ -f "$f" ] || return 1
  # Match com.android.application / com.android.library in plugins block.
  grep -qE 'com\.android\.(application|library|dynamic-feature)' "$f" 2>/dev/null
}
for f in "$PROJECT_ROOT/build.gradle" "$PROJECT_ROOT/build.gradle.kts" \
         "$PROJECT_ROOT/app/build.gradle" "$PROJECT_ROOT/app/build.gradle.kts"; do
  if _check_gradle_android "$f"; then
    has_android=1
    break
  fi
done

# --- Flutter (pubspec.yaml with flutter dep) -------------------------------
_check_flutter() {
  local pub="$PROJECT_ROOT/pubspec.yaml"
  [ -f "$pub" ] || return 1
  # Either `flutter:` top-level under dependencies or sdk: flutter line.
  grep -qE '^[[:space:]]+flutter:|sdk:[[:space:]]*flutter' "$pub" 2>/dev/null
}
if _check_flutter; then
  has_ios=1
  has_android=1
fi

# --- React Native (react-native dep in package.json) -----------------------
_check_react_native() {
  local pj="$PROJECT_ROOT/package.json"
  [ -f "$pj" ] || return 1
  python3 - "$pj" <<'PY' >/dev/null 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for sec in ("dependencies","devDependencies","peerDependencies"):
    if "react-native" in (d.get(sec) or {}):
        sys.exit(0)
sys.exit(1)
PY
}
if _check_react_native; then
  has_ios=1
  has_android=1
fi

# --- Emit JSON --------------------------------------------------------------
case "$FORMAT" in
  json) ;;
  *) err "unsupported --format '$FORMAT' (expected json)"; exit 1 ;;
esac

python3 - "$has_ios" "$has_android" <<'PY'
import json, sys
has_ios = sys.argv[1] == "1"
has_android = sys.argv[2] == "1"
platforms = []
if has_ios: platforms.append("ios")
if has_android: platforms.append("android")

# Default device_targets per ADR-081 — minimal valid block.
def default_ios():
    return {
        "os_versions": ["16.0", "17.0"],
        "form_factors": ["phone", "tablet"],
        "screen_sizes": [
            {"width": 390, "height": 844,  "density": 3.0},
            {"width": 1024,"height": 1366, "density": 2.0},
        ],
    }

def default_android():
    return {
        "os_versions": ["13", "14"],
        "form_factors": ["phone", "tablet"],
        "screen_sizes": [
            {"width": 412, "height": 915, "density": 2.625},
            {"width": 800, "height": 1280,"density": 2.0},
        ],
    }

device_targets = {}
if has_ios:     device_targets["ios"] = default_ios()
if has_android: device_targets["android"] = default_android()

print(json.dumps({"platforms": platforms, "device_targets": device_targets}, indent=2))
PY
