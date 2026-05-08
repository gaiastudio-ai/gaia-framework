#!/usr/bin/env bash
# scratchpad-detect-type.sh — gaia-meeting content-type detection (E76-S4)
#
# AC7 / FR-MTG-13.
#
# Reads scratchpad content from stdin and emits a one-token content-type tag:
#   json | ts | py | sh | md | go | swift | kt | rs | java
#
# Detection probes the FIRST non-blank line (trimmed) with the following
# heuristics (in order). Ambiguous content defaults to `md`.

set -euo pipefail
LC_ALL=C
export LC_ALL

content="$(cat)"

# Pull the first non-blank line and strip leading whitespace
first_line=""
while IFS= read -r line || [[ -n "$line" ]]; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  if [[ -n "$trimmed" ]]; then
    first_line="$trimmed"
    break
  fi
done <<EOF
$content
EOF

if [[ -z "$first_line" ]]; then
  printf 'md\n'
  exit 0
fi

# Probe in this order (specific patterns first, generic last)

# Shebangs first — definitive
case "$first_line" in
  '#!/usr/bin/env bash'*|'#!/bin/bash'*|'#!/bin/sh'*|'#!/usr/bin/env sh'*)
    printf 'sh\n'; exit 0
    ;;
esac

# JSON: starts with { or [
case "$first_line" in
  '{'*|'['*) printf 'json\n'; exit 0 ;;
esac

# Markdown heading (#, ##, ###, etc.) — must come before generic '# comment'
case "$first_line" in
  '#'[[:space:]]*) printf 'md\n'; exit 0 ;;
esac

# TypeScript: interface / type / export / function (also matches "function foo" alone)
case "$first_line" in
  'interface '*|'type '*'='*|'type '*' '*'='*|'export '*|'function '*)
    printf 'ts\n'; exit 0
    ;;
esac

# Python: def / import (Python's `import x` is also seen in Java/Go/Swift —
# additional checks below disambiguate by first token).
case "$first_line" in
  'def '*) printf 'py\n'; exit 0 ;;
esac

# Go
case "$first_line" in
  'package '*) printf 'go\n'; exit 0 ;;
  'func '*) printf 'go\n'; exit 0 ;;
esac

# Rust: fn name(
case "$first_line" in
  'fn '*'('*) printf 'rs\n'; exit 0 ;;
esac

# Kotlin: fun name
case "$first_line" in
  'fun '*) printf 'kt\n'; exit 0 ;;
esac

# Java: public class | public static void main
case "$first_line" in
  'public class '*|'public static '*|'class '*'{'*|'class '*' {'*)
    printf 'java\n'; exit 0
    ;;
esac

# Swift: import Foundation / import UIKit / struct / class with Swift idioms
case "$first_line" in
  'import Foundation'*|'import UIKit'*|'import SwiftUI'*|'import Combine'*)
    printf 'swift\n'; exit 0
    ;;
esac

# Generic Python `import` — must come after Swift's specific imports above
case "$first_line" in
  'import '*|'from '*' import '*) printf 'py\n'; exit 0 ;;
esac

# Default fallback
printf 'md\n'
