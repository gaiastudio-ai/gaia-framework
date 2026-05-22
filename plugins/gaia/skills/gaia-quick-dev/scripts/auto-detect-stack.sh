#!/usr/bin/env bash
# auto-detect-stack.sh — gaia-quick-dev stack auto-detection (E28-S117)
#
# Reads the quick spec body and scans the project path for stack signals.
# Emits exactly one of the seven supported stacks on stdout:
#   typescript | angular | flutter | java | python | mobile | go
#
# Exit codes:
#   0 — exactly one stack detected (emitted on stdout)
#   1 — ambiguous or zero signals (AC-EC2) — caller must prompt user
#
# Detection signals (deterministic per ADR-042):
#   package.json + angular.json          → angular
#   package.json (no angular.json)       → typescript
#   pubspec.yaml                         → flutter
#   pom.xml or build.gradle              → java
#   requirements.txt or pyproject.toml   → python
#   go.mod                               → go
#   ios/ or android/ directories only    → mobile
#
# Spec-body hints (keywords in the quick spec) augment the signal when the
# filesystem scan is ambiguous but deliberately never override it.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-quick-dev/auto-detect-stack.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ $# -lt 1 ]; then
  die "usage: auto-detect-stack.sh <spec_name>"
fi

SPEC_NAME="$1"
WORK_DIR="${PROJECT_PATH:-$PWD}"
# AF-2026-05-21-27 canonical-first SPEC_PATH (mirrors load-spec.sh).
if [ -f "$WORK_DIR/.gaia/artifacts/implementation-artifacts/quick-spec-${SPEC_NAME}.md" ]; then
  SPEC_PATH="$WORK_DIR/.gaia/artifacts/implementation-artifacts/quick-spec-${SPEC_NAME}.md"
else
  SPEC_PATH="$WORK_DIR/docs/implementation-artifacts/quick-spec-${SPEC_NAME}.md"
fi

declare -a stacks=()

# Filesystem scan — the primary signal source.
if [ -f "$WORK_DIR/angular.json" ] && [ -f "$WORK_DIR/package.json" ]; then
  stacks+=("angular")
elif [ -f "$WORK_DIR/package.json" ]; then
  stacks+=("typescript")
fi
if [ -f "$WORK_DIR/pubspec.yaml" ]; then
  stacks+=("flutter")
fi
if [ -f "$WORK_DIR/pom.xml" ] || [ -f "$WORK_DIR/build.gradle" ] || [ -f "$WORK_DIR/build.gradle.kts" ]; then
  stacks+=("java")
fi
if [ -f "$WORK_DIR/requirements.txt" ] || [ -f "$WORK_DIR/pyproject.toml" ] || [ -f "$WORK_DIR/setup.py" ]; then
  stacks+=("python")
fi
if [ -f "$WORK_DIR/go.mod" ]; then
  stacks+=("go")
fi
# Mobile is native ios/android directories without a package.json at the root.
if [ -d "$WORK_DIR/ios" ] && [ -d "$WORK_DIR/android" ] && [ ! -f "$WORK_DIR/package.json" ] && [ ! -f "$WORK_DIR/pubspec.yaml" ]; then
  stacks+=("mobile")
fi

# Deduplicate.
unique_stacks=()
for s in "${stacks[@]:-}"; do
  [ -z "$s" ] && continue
  seen=0
  for u in "${unique_stacks[@]:-}"; do
    [ "$u" = "$s" ] && seen=1 && break
  done
  [ "$seen" -eq 0 ] && unique_stacks+=("$s")
done

count="${#unique_stacks[@]}"

if [ "$count" -eq 1 ]; then
  echo "${unique_stacks[0]}"
  exit 0
fi

if [ "$count" -eq 0 ]; then
  log "No stack signals detected in $WORK_DIR — ambiguous (AC-EC2)"
  exit 1
fi

# More than one signal — try to disambiguate via spec-body hint.
if [ -f "$SPEC_PATH" ]; then
  body_lower=$(tr '[:upper:]' '[:lower:]' < "$SPEC_PATH")
  for candidate in "${unique_stacks[@]}"; do
    if printf '%s' "$body_lower" | grep -qE "\\b${candidate}\\b"; then
      echo "$candidate"
      exit 0
    fi
  done
fi

log "Multiple stacks detected (${unique_stacks[*]}) — ambiguous (AC-EC2)"
exit 1
