#!/usr/bin/env bash
# flake-detect.sh — Phase 3B infrastructure-flake heuristic for gaia-test-run.
#
# Reads runner output from STDIN. Emits a single line to STDOUT:
#   flake_suspected=true reason=<short-tag>
#   flake_suspected=false
#
# Recognised infrastructure-flake patterns (case-insensitive):
#   - timeout / timed out / Timeout
#   - ECONNREFUSED / ECONNRESET / ETIMEDOUT
#   - Out of memory / OOMKilled / OOM / java.lang.OutOfMemoryError
#   - Network error / network is unreachable / Connection refused / DNS lookup
#   - Could not resolve host
#
# Story: E72-S1 (AC8, ADR-077 Phase 3B)

set -euo pipefail
LC_ALL=C
export LC_ALL

INPUT="$(cat)"

if printf '%s' "$INPUT" | grep -qiE 'timeout|timed out'; then
  echo "flake_suspected=true reason=timeout"
  exit 0
fi
if printf '%s' "$INPUT" | grep -qE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT'; then
  echo "flake_suspected=true reason=connection-refused"
  exit 0
fi
if printf '%s' "$INPUT" | grep -qiE 'out of memory|OOMKilled|java\.lang\.OutOfMemoryError|\bOOM\b'; then
  echo "flake_suspected=true reason=oom"
  exit 0
fi
if printf '%s' "$INPUT" | grep -qiE 'network error|network is unreachable|connection refused|could not resolve host|dns lookup failed'; then
  echo "flake_suspected=true reason=network"
  exit 0
fi

echo "flake_suspected=false"
