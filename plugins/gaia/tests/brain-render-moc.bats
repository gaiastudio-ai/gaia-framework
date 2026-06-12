#!/usr/bin/env bats
# brain-render-moc.bats — pure-function coverage for the MOC renderer
# (scripts/brain/render-moc.sh). The renderer turns the brain-index.yaml manifest
# into a human-browsable, Obsidian-native Map-of-Content markdown file.
#
# Behaviour under test:
#   - Renders valid, non-empty markdown with a stable H1 and no embedded
#     timestamp/wall-clock/random token (so re-renders are byte-identical).
#   - Groups entries by artifact type in a fixed canonical order; within a type
#     group the entries are key-sorted under LC_ALL=C.
#   - Each entry carries an Obsidian [[wikilink]] whose target is the entry path
#     relative to .gaia/knowledge/ (strip the leading .gaia/, prepend ../), a
#     synopsis, its tags, and an edge summary.
#   - Determinism: rendering the same manifest twice yields byte-identical output.
#   - Additions and removals across an A/B manifest pair are reflected.
#   - An empty manifest renders a valid MOC with a "no entries" line, exit 0.
#   - A synopsis with markdown/special characters renders without aborting.
#
# The renderer is a pure function of the on-disk YAML — no project tree, no path
# helper writes — so the tests run it directly against fixture manifests.

load 'test_helper.bash'

setup() {
  common_setup
  RENDER="$SCRIPTS_DIR/brain/render-moc.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-render-moc"
  OUT="$TEST_TMP/brain-index.md"
}

teardown() {
  common_teardown
}

_render() {
  run bash "$RENDER" "$1" "$2"
}

@test "the renderer produces a non-empty markdown file with a stable H1" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  [ -s "$OUT" ]
  # First content line is the stable H1 — no date, no run-specific token.
  run head -n 1 "$OUT"
  [ "${output:0:1}" = "#" ]
  grep -q '^# ' "$OUT"
}

@test "the rendered MOC carries no timestamp, wall-clock, or random token" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  # No ISO-8601 date, no HH:MM:SS clock, no 4-digit year stamp.
  ! grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$OUT"
  ! grep -Eq '[0-9]{2}:[0-9]{2}:[0-9]{2}' "$OUT"
}

@test "entries are grouped by artifact type under section headings" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  # Each represented type appears as a section heading.
  grep -qi '^## .*[Aa]rchitecture' "$OUT"
  grep -qi '^## .*[Ee]pics' "$OUT"
  grep -qi '^## .*[Ii]mplementation' "$OUT"
  grep -qi '^## .*[Ss]tate' "$OUT"
}

@test "artifact-type sections appear in a fixed canonical order" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  # Architecture must precede epics, epics precede implementation, implementation
  # precede state (lifecycle order, type-stable across renders).
  local arch epics impl state
  arch="$(grep -ni '^## .*architecture' "$OUT" | head -n1 | cut -d: -f1)"
  epics="$(grep -ni '^## .*epics' "$OUT" | head -n1 | cut -d: -f1)"
  impl="$(grep -ni '^## .*implementation' "$OUT" | head -n1 | cut -d: -f1)"
  state="$(grep -ni '^## .*state' "$OUT" | head -n1 | cut -d: -f1)"
  [ "$arch" -lt "$epics" ]
  [ "$epics" -lt "$impl" ]
  [ "$impl" -lt "$state" ]
}

@test "entries within a type group are key-sorted" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  # Implementation group has E777-S2 and E777-S7; S2 must come before S7.
  local s2 s7
  s2="$(grep -n 'E777-S2' "$OUT" | head -n1 | cut -d: -f1)"
  s7="$(grep -n 'E777-S7' "$OUT" | head -n1 | cut -d: -f1)"
  [ "$s2" -lt "$s7" ]
}

@test "each entry carries an Obsidian wikilink to its relative artifact path" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  # The .gaia/ prefix is stripped and ../ prepended so the link resolves from
  # .gaia/knowledge/. The visible alias is the entry key.
  grep -qF '[[../artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md|E777-S2]]' "$OUT"
}

@test "wikilink targets never retain the leading .gaia/ prefix" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  # No wikilink target should start with .gaia/ (it must be relative via ../).
  ! grep -q '\[\[\.gaia/' "$OUT"
}

@test "each entry renders its synopsis" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  grep -qF 'Primary reindex node' "$OUT"
  grep -qF 'Flat-layout reindex node' "$OUT"
}

@test "each entry renders an edge summary" {
  _render "$FIX/multi.yaml" "$OUT"
  [ "$status" -eq 0 ]
  # The primary node has 3 edges; the renderer surfaces an edge count/summary.
  # A node with edges names at least one edge type or an edge count.
  grep -qiE 'edge|implements|traces-to|link' "$OUT"
}

@test "rendering the same manifest twice yields byte-identical output" {
  local a="$TEST_TMP/a.md" b="$TEST_TMP/b.md"
  run bash "$RENDER" "$FIX/multi.yaml" "$a"
  [ "$status" -eq 0 ]
  run bash "$RENDER" "$FIX/multi.yaml" "$b"
  [ "$status" -eq 0 ]
  # Content comparison (NOT mtime) — deterministic, hardware-independent.
  run cmp -s "$a" "$b"
  [ "$status" -eq 0 ]
}

@test "the A manifest names the to-be-removed node and the B manifest does not" {
  local a="$TEST_TMP/a.md" b="$TEST_TMP/b.md"
  run bash "$RENDER" "$FIX/pair-a.yaml" "$a"
  [ "$status" -eq 0 ]
  run bash "$RENDER" "$FIX/pair-b.yaml" "$b"
  [ "$status" -eq 0 ]
  # A has the removed node, B does not; B has the added node, A does not.
  grep -q 'E777-S9' "$a"
  ! grep -q 'E777-S9' "$b"
  grep -q 'E777-S8' "$b"
  ! grep -q 'E777-S8' "$a"
  # The shared node is present in both.
  grep -q 'E777-S2' "$a"
  grep -q 'E777-S2' "$b"
}

@test "an empty manifest renders a valid MOC with a no-entries line and exit 0" {
  _render "$FIX/empty.yaml" "$OUT"
  [ "$status" -eq 0 ]
  [ -s "$OUT" ]
  grep -q '^# ' "$OUT"
  grep -qi 'no entries' "$OUT"
}

@test "a synopsis with special characters renders without aborting" {
  _render "$FIX/special-chars.yaml" "$OUT"
  [ "$status" -eq 0 ]
  [ -s "$OUT" ]
  # The node key still appears; the renderer did not choke on the pipe/brackets.
  grep -q 'E777-S3' "$OUT"
  # The prd-tagged entry lands under the Product Requirements section.
  grep -qi '^## .*[Pp]roduct [Rr]equirements' "$OUT"
  grep -q 'tags: prd' "$OUT"
}

@test "the renderer is invocable as a sourceable library exposing render_moc" {
  run bash -c ". \"$RENDER\"; type render_moc"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'render_moc'
}
