#!/usr/bin/env bash
# sample-script.sh — fixture script for mutation adapter tests.
set -euo pipefail

check_value() {
  local val="$1"
  if [ "$val" -eq 0 ]; then
    return 0
  fi
  if [ "$val" -lt 10 ] && [ "$val" -gt 0 ]; then
    echo "small"
    return 0
  fi
  if [ "$val" -ge 10 ] || [ "$val" -le -10 ]; then
    echo "large"
    return 1
  fi
  return 0
}

compare_strings() {
  local a="$1"
  local b="$2"
  if [ "$a" == "$b" ]; then
    echo "equal"
    exit 0
  fi
  if [ "$a" != "$b" ]; then
    echo "different"
    exit 1
  fi
}

is_valid() {
  if true; then
    echo "valid"
  fi
  if false; then
    echo "invalid"
  fi
}
