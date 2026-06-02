#!/usr/bin/env bash
# smoke-plugin-cache-recovery.sh — manual smoke test harness for
# plugin-cache-recovery.sh (E28-S25).
#
# Covers every AC until the full bats-core suite lands in E28-S17.
#
# Usage: bash plugins/gaia/scripts/tests/smoke-plugin-cache-recovery.sh

set -uo pipefail
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PCR="$SCRIPT_DIR/plugin-cache-recovery.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { printf "  ok  %s\n" "$1"; PASS=$((PASS + 1)); }
bad()  { printf "  FAIL %s\n     %s\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

run() {
  # run <expected_exit> <desc> -- <cmd...>
  local expected="$1"; shift
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  local out err rc
  out=$(mktemp); err=$(mktemp)
  set +e
  "$@" >"$out" 2>"$err"
  rc=$?
  set -e
  if [ "$rc" -ne "$expected" ]; then
    bad "$desc" "exit $rc, expected $expected. stdout: $(cat "$out") stderr: $(cat "$err")"
  else
    ok "$desc"
  fi
  rm -f "$out" "$err"
}

make_polluted() {
  local slug="$1"
  mkdir -p "$CACHE/$slug"
  # non-git clutter
  : > "$CACHE/$slug/partial.tar"
}

make_healthy() {
  local slug="$1"
  local d="$CACHE/$slug"
  mkdir -p "$d/.git"
  printf 'ref: refs/heads/main\n' > "$d/.git/HEAD"
  : > "$d/README.md"
}

make_empty() {
  local slug="$1"
  mkdir -p "$CACHE/$slug"
}

CACHE="$TMP/cache"
mkdir -p "$CACHE"

echo "== plugin-cache-recovery.sh =="

# --help exits 0.
run 0 "--help exits 0" -- "$PCR" --help

# Missing --slug fails with usage error.
run 1 "missing --slug exits 1" -- "$PCR"

# Invalid slug (slash → path traversal).
run 1 "slash in slug rejected" -- "$PCR" --slug "evil/../../etc" --cache-root "$CACHE"

# Invalid slug (leading dash).
run 1 "leading dash rejected" -- "$PCR" --slug "-bad" --cache-root "$CACHE"

# Invalid slug (double dot).
run 1 "double-dot rejected" -- "$PCR" --slug ".." --cache-root "$CACHE"

# Invalid slug (space).
run 1 "space rejected" -- "$PCR" --slug "has space" --cache-root "$CACHE"

# Absent entry → clear is a no-op, exit 0.
run 0 "clear on absent entry exits 0" -- "$PCR" --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --quiet

# Absent entry → detect exits 0.
run 0 "detect on absent entry exits 0" -- "$PCR" --detect --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --quiet

# Polluted entry: empty dir.
make_empty "gaiastudio-ai-gaia-framework"
run 2 "detect empty dir → polluted (exit 2)" -- "$PCR" --detect --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --quiet

# Clear removes the polluted empty dir.
run 0 "clear polluted empty dir exits 0" -- "$PCR" --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --quiet
[ ! -e "$CACHE/gaiastudio-ai-gaia-framework" ] && ok "empty dir removed" || bad "empty dir removed" "still present"

# Polluted entry: non-git files.
make_polluted "gaiastudio-ai-gaia-enterprise"
run 2 "detect non-git files → polluted (exit 2)" -- "$PCR" --detect --slug "gaiastudio-ai-gaia-enterprise" --cache-root "$CACHE" --quiet

# Dry-run must not touch filesystem.
run 0 "dry-run exits 0" -- "$PCR" --slug "gaiastudio-ai-gaia-enterprise" --cache-root "$CACHE" --dry-run --quiet
[ -e "$CACHE/gaiastudio-ai-gaia-enterprise" ] && ok "dry-run preserved polluted entry" || bad "dry-run preserve" "entry was removed"

# Real clear now removes it.
run 0 "clear polluted non-git dir" -- "$PCR" --slug "gaiastudio-ai-gaia-enterprise" --cache-root "$CACHE" --quiet
[ ! -e "$CACHE/gaiastudio-ai-gaia-enterprise" ] && ok "non-git dir removed" || bad "non-git dir removed" "still present"

# Healthy entry: detect exits 0, clear refuses without --force.
make_healthy "gaiastudio-ai-gaia-framework"
run 0 "detect healthy exits 0" -- "$PCR" --detect --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --quiet
run 1 "clear healthy without --force exits 1" -- "$PCR" --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --quiet
[ -e "$CACHE/gaiastudio-ai-gaia-framework/.git/HEAD" ] && ok "healthy entry preserved without --force" || bad "healthy preserved" "removed anyway"

# With --force, healthy entry is removed.
run 0 "clear healthy with --force exits 0" -- "$PCR" --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --force --quiet
[ ! -e "$CACHE/gaiastudio-ai-gaia-framework" ] && ok "healthy entry removed with --force" || bad "healthy removed" "still present"

# --list when cache root absent.
run 0 "--list on absent cache root exits 0" -- "$PCR" --list --cache-root "$TMP/does-not-exist" --quiet

# --list on populated cache root prints one line per entry.
make_polluted "gaiastudio-ai-gaia-framework"
make_healthy  "gaiastudio-ai-other"
out="$("$PCR" --list --cache-root "$CACHE" 2>/dev/null || true)"
count="$(printf '%s\n' "$out" | grep -c 'gaiastudio-ai-' || true)"
[ "$count" -ge 2 ] && ok "--list reports both entries" || bad "--list reports both" "got: $out"

# Cache root under HOME override.
HOME="$TMP/fakehome" run 0 "HOME override treated as absent" -- "$PCR" --slug "gaiastudio-ai-gaia-framework" --quiet

# Unknown flag rejected.
run 1 "unknown flag rejected" -- "$PCR" --slug "gaiastudio-ai-gaia-framework" --cache-root "$CACHE" --banana

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
