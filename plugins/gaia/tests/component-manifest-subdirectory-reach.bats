#!/usr/bin/env bats
# component-manifest-subdirectory-reach.bats — pin that the component tagger
# reaches the WHOLE plugin test tree, not just its top level, and that the
# component runner resolves what the tagger emits.
#
# The failure this guards against
#   The tagger once enumerated `<tests-dir>/*.bats` — a single level — so every
#   bats living in a subdirectory of the test tree was assigned to no component
#   at all and the selective-test matrix could not route it. The manifest looked
#   healthy; it was simply blind below the top level.
#
# Why the writer and the reader are pinned together
#   The manifest is a writer/reader pair: the tagger emits an entry per test
#   file, the runner resolves each entry to a path on disk. If the entry format
#   and the resolver drift apart, the runner's file test simply fails and — in
#   the original code — emitted nothing, with no diagnostic. Widening the
#   tagger without teaching the resolver would have produced a manifest full of
#   rows that route nothing while every guard still reported green. These tests
#   therefore assert the round trip, not either half alone.
#
# Collisions are real
#   Several basenames exist at both the top level and inside a subdirectory, so
#   an entry keyed on basename alone cannot say which file it means. The entry
#   carries a tree-relative path for exactly that reason, and the collision
#   tests below prove each one resolves to its own file.

bats_require_minimum_version 1.5.0

setup() {
  REPO_TESTS="$(cd "$BATS_TEST_DIRNAME" && pwd)"
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  TAGGER="$SCRIPTS/bats-component-tagger.sh"
  RUNNER="$SCRIPTS/run-component-tests.sh"
  MANIFEST="$REPO_TESTS/component-manifest.tsv"
  FIX="$BATS_TEST_TMPDIR/tests"
  mkdir -p "$FIX"
}

# _fresh — emit a fresh manifest for the real test tree.
_fresh() {
  bash "$TAGGER" --tests-dir "$REPO_TESTS" --format tsv
}

# ---- enumeration depth ----

@test "a bats one level below the test root is enumerated" {
  mkdir -p "$FIX/nested"
  printf '%s\n' '@test "x" { run bash "$SCRIPTS_DIR/gen-ci-config.sh"; }' \
    > "$FIX/nested/probe.bats"
  # a top-level file too, so the tagger has something at both depths
  printf '%s\n' '@test "y" { [ 1 -eq 1 ]; }' > "$FIX/top.bats"

  run bash "$TAGGER" --tests-dir "$FIX" --format tsv
  [ "$status" -eq 0 ]
  [[ "$output" == *"nested/probe.bats"* ]]
}

@test "a bats several levels below the test root is enumerated" {
  mkdir -p "$FIX/a/b/c"
  printf '%s\n' '@test "x" { run bash "$SCRIPTS_DIR/gen-ci-config.sh"; }' \
    > "$FIX/a/b/c/deep.bats"

  run bash "$TAGGER" --tests-dir "$FIX" --format tsv
  [ "$status" -eq 0 ]
  [[ "$output" == *"a/b/c/deep.bats"* ]]
}

@test "a newly added nested bats appears without any manual registration" {
  printf '%s\n' '@test "y" { [ 1 -eq 1 ]; }' > "$FIX/top.bats"
  run bash "$TAGGER" --tests-dir "$FIX" --format tsv
  [ "$status" -eq 0 ]
  [[ "$output" != *"late-arrival.bats"* ]]

  mkdir -p "$FIX/newdir"
  printf '%s\n' '@test "x" { [ 1 -eq 1 ]; }' > "$FIX/newdir/late-arrival.bats"
  run bash "$TAGGER" --tests-dir "$FIX" --format tsv
  [ "$status" -eq 0 ]
  [[ "$output" == *"newdir/late-arrival.bats"* ]]
}

@test "every bats on disk under the test tree has a manifest row" {
  local on_disk fresh
  on_disk="$BATS_TEST_TMPDIR/on-disk.txt"
  fresh="$BATS_TEST_TMPDIR/in-manifest.txt"
  ( cd "$REPO_TESTS" && find . -name '*.bats' | sed 's|^\./||' | sort ) > "$on_disk"
  _fresh | cut -f2 | sort > "$fresh"
  diff "$on_disk" "$fresh"
}

@test "the real test tree's subdirectory files reach the manifest" {
  # Guards the specific regression: subdirectory files silently absent.
  local nested_on_disk nested_tagged
  nested_on_disk="$( cd "$REPO_TESTS" && find . -mindepth 2 -name '*.bats' | wc -l | tr -d ' ' )"
  [ "$nested_on_disk" -gt 0 ]
  nested_tagged="$( _fresh | cut -f2 | grep -c '/' || true )"
  [ "$nested_tagged" -eq "$nested_on_disk" ]
}

# ---- entry format and collisions ----

@test "manifest entries are tree-relative paths, not bare basenames" {
  # Every entry must resolve as <tests-dir>/<entry>; a bare basename for a
  # nested file could not.
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -f "$REPO_TESTS/$entry" ] || {
      printf 'unresolvable manifest entry: %s\n' "$entry" >&2
      return 1
    }
  done < <(cut -f2 "$MANIFEST")
}

@test "basenames that exist at two depths resolve to distinct files" {
  # Two files sharing a basename, one top-level and one nested, with DIFFERENT
  # component references, so a basename-keyed format would visibly mis-route.
  printf '%s\n' '@test "x" { run bash "$SCRIPTS_DIR/gen-ci-config.sh"; }' \
    > "$FIX/twin.bats"
  mkdir -p "$FIX/sub"
  printf '%s\n' '@test "x" { run bash "$SCRIPTS_DIR/lib/resolve-config.sh"; }' \
    > "$FIX/sub/twin.bats"

  local out
  out="$(bash "$TAGGER" --tests-dir "$FIX" --format tsv)"
  [ "$(printf '%s\n' "$out" | awk -F'\t' '$2=="twin.bats" {print $1}')" = "scripts-core" ]
  [ "$(printf '%s\n' "$out" | awk -F'\t' '$2=="sub/twin.bats" {print $1}')" = "scripts-lib" ]
  # exactly two rows for the pair — neither substituted for the other
  [ "$(printf '%s\n' "$out" | grep -c 'twin\.bats$')" -eq 2 ]
}

@test "the real tree's duplicated basenames each carry their own row" {
  local dupes bn rows
  dupes="$( cd "$REPO_TESTS" && find . -name '*.bats' | awk -F/ '{print $NF}' | sort | uniq -d )"
  [ -n "$dupes" ]
  while IFS= read -r bn; do
    [ -n "$bn" ] || continue
    rows="$( cut -f2 "$MANIFEST" | awk -F/ -v b="$bn" '$NF==b' | sort -u | wc -l | tr -d ' ' )"
    local on_disk
    on_disk="$( cd "$REPO_TESTS" && find . -name "$bn" | wc -l | tr -d ' ' )"
    [ "$rows" -eq "$on_disk" ]
  done <<< "$dupes"
}

# ---- the runner resolves what the tagger emits ----

@test "the runner resolves a nested entry to its nested path" {
  local tdir="$BATS_TEST_TMPDIR/runner-tests"
  mkdir -p "$tdir/sub"
  printf '%s\n' '@test "x" { [ 1 -eq 1 ]; }' > "$tdir/sub/nested.bats"
  printf 'demo\tsub/nested.bats\n' > "$tdir/component-manifest.tsv"

  run env GAIA_COMPONENT_TESTS_DIR="$tdir" bash "$RUNNER" demo --list
  [ "$status" -eq 0 ]
  [ "$output" = "$tdir/sub/nested.bats" ]
}

@test "the runner keeps colliding basenames apart" {
  local tdir="$BATS_TEST_TMPDIR/collide-tests"
  mkdir -p "$tdir/sub"
  printf '%s\n' '@test "top" { [ 1 -eq 1 ]; }' > "$tdir/twin.bats"
  printf '%s\n' '@test "nested" { [ 1 -eq 1 ]; }' > "$tdir/sub/twin.bats"
  printf 'alpha\ttwin.bats\nbeta\tsub/twin.bats\n' > "$tdir/component-manifest.tsv"

  run env GAIA_COMPONENT_TESTS_DIR="$tdir" bash "$RUNNER" alpha --list
  [ "$status" -eq 0 ]
  [ "$output" = "$tdir/twin.bats" ]

  run env GAIA_COMPONENT_TESTS_DIR="$tdir" bash "$RUNNER" beta --list
  [ "$status" -eq 0 ]
  [ "$output" = "$tdir/sub/twin.bats" ]
}

# ---- unresolvable entries are reported, never dropped ----

@test "an unresolvable manifest entry is named on stderr" {
  local tdir="$BATS_TEST_TMPDIR/missing-tests"
  mkdir -p "$tdir"
  printf '%s\n' '@test "x" { [ 1 -eq 1 ]; }' > "$tdir/present.bats"
  printf 'demo\tpresent.bats\ndemo\tghost/absent.bats\n' \
    > "$tdir/component-manifest.tsv"

  run --separate-stderr env GAIA_COMPONENT_TESTS_DIR="$tdir" bash "$RUNNER" demo --list
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"ghost/absent.bats"* ]]
}

@test "an unresolvable entry fails the run rather than silently shrinking the set" {
  # The silent-drop failure mode: the resolver emitted nothing for a missing
  # entry and the run reported green over a smaller set. It must be fatal.
  local tdir="$BATS_TEST_TMPDIR/fatal-tests"
  mkdir -p "$tdir"
  printf '%s\n' '@test "x" { [ 1 -eq 1 ]; }' > "$tdir/present.bats"
  printf 'demo\tpresent.bats\ndemo\tabsent.bats\n' > "$tdir/component-manifest.tsv"

  run --separate-stderr env GAIA_COMPONENT_TESTS_DIR="$tdir" bash "$RUNNER" demo --list
  [ "$status" -ne 0 ]
  # It must fail BECAUSE of the missing entry — named on stderr — not for some
  # unrelated reason, and it must not print a partial set as though it were the
  # whole one.
  [[ "$stderr" == *"absent.bats"* ]]
  [[ "$output" != *"present.bats"* ]]
}

@test "a fully resolvable manifest produces no stderr complaint" {
  local tdir="$BATS_TEST_TMPDIR/clean-tests"
  mkdir -p "$tdir/sub"
  printf '%s\n' '@test "x" { [ 1 -eq 1 ]; }' > "$tdir/a.bats"
  printf '%s\n' '@test "y" { [ 1 -eq 1 ]; }' > "$tdir/sub/b.bats"
  printf 'demo\ta.bats\ndemo\tsub/b.bats\n' > "$tdir/component-manifest.tsv"

  run --separate-stderr env GAIA_COMPONENT_TESTS_DIR="$tdir" bash "$RUNNER" demo --list
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
}

# ---- determinism and classification stability ----

@test "the widened enumeration stays deterministic" {
  local a="$BATS_TEST_TMPDIR/a.tsv" b="$BATS_TEST_TMPDIR/b.tsv"
  _fresh > "$a"
  _fresh > "$b"
  diff "$a" "$b"
}

@test "the emitted manifest is sorted on the whole row" {
  local fresh="$BATS_TEST_TMPDIR/fresh.tsv" sorted="$BATS_TEST_TMPDIR/sorted.tsv"
  _fresh > "$fresh"
  sort "$fresh" > "$sorted"
  diff "$fresh" "$sorted"
}

@test "top-level classifications are unchanged by the widened enumeration" {
  # Only NEW rows may appear. Every row whose entry has no directory separator
  # must carry the same component it carried before the widening — the
  # committed manifest is the reference for that.
  local fresh="$BATS_TEST_TMPDIR/fresh-top.tsv" committed="$BATS_TEST_TMPDIR/committed-top.tsv"
  _fresh | awk -F'\t' '$2 !~ /\//' > "$fresh"
  awk -F'\t' '$2 !~ /\//' "$MANIFEST" > "$committed"
  diff "$committed" "$fresh"
}

@test "the catch-all component still claims unresolved and cross-cutting tests" {
  local n
  n="$( _fresh | awk -F'\t' '$1=="core"' | wc -l | tr -d ' ' )"
  [ "$n" -gt 0 ]
}

@test "every component the widened manifest names resolves a runnable set" {
  local comps c
  comps="$( cut -f1 "$MANIFEST" | sort -u )"
  [ -n "$comps" ]
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    run bash "$RUNNER" "$c" --list
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done <<< "$comps"
}
