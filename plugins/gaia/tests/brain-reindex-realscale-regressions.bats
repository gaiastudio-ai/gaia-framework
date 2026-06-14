#!/usr/bin/env bats
# brain-reindex-realscale-regressions.bats — regression coverage for three
# defects that only manifest at real-repo scale and were missed by the
# short-synthetic-key fixtures in brain-reindex.bats:
#
#   1. Deep-path filename overflow. The per-entry synopsis/edge carry-forward
#      scratch files were named by flattening the entry key path into a single
#      filename (slash -> "__"). For a deeply nested artifact (epic-/story-/
#      reviews- path) that filename exceeds the 255-byte OS limit, so the sweep
#      aborted mid-harvest with "File name too long" and produced zero entries.
#      Fixed by hashing the key to a fixed 64-char digest (_brx_keyfile).
#
#   2. Unquoted edge target breaks the manifest YAML. Edge `target:` values are
#      harvested prose (epic/story titles) and routinely contain a `: ` — which
#      a bare YAML scalar reads as a mapping separator, corrupting the whole
#      manifest so it fails validation and is never installed. Fixed by
#      quote+escaping the target in both the harvest and carry-forward paths.
#
#   3. The generated manifest must parse as YAML end to end (the umbrella
#      assertion that ties 1 and 2 together against a real-shaped fixture).
#
# Each test builds an isolated per-test project tree and points the path helper
# at it via CLAUDE_PROJECT_ROOT, so the sweep runs on a fixture and never
# touches the real .gaia/ tree.

load 'test_helper.bash'

setup() {
  common_setup
  REINDEX="$SCRIPTS_DIR/brain/gaia-brain-reindex.sh"

  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia/artifacts/planning-artifacts" \
           "$PROJ/.gaia/state" \
           "$PROJ/.gaia/memory/validator-sidecar" \
           "$PROJ/.gaia/knowledge"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  KNOW="$PROJ/.gaia/knowledge"
  MANIFEST="$KNOW/brain-index.yaml"

  # A decoy under memory/ so the read-only-boundary stays observable.
  printf 'decoy\n' > "$PROJ/.gaia/memory/validator-sidecar/ground-truth.md"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# Skip cleanly when PyYAML is absent — the manifest-parse assertions need it.
_require_pyyaml() {
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "no python3+PyYAML on host"
}

# ---- Regression 1: deep-path key must not overflow the scratch filename -----

@test "a deeply nested non-story artifact does not overflow the scratch filename and is indexed" {
  # The overflow vector is a NON-story (generic-keyed) artifact — e.g. a review
  # report — whose key is its FULL project-relative path. Flattening that path
  # (slash -> "__") into a single scratch filename `edges-<flattened>.txt`
  # overflows the 255-byte OS basename limit when the path is deep enough, so
  # the sweep aborts with "File name too long". (A story.md gets a SHORT key
  # from its parent dir, so it does NOT trigger this — the bug is specific to
  # path-keyed artifacts.) Build a deep reviews/ path whose flattened key is
  # well over 245 chars.
  local deep="epic-E700-an-intentionally-very-long-epic-directory-slug-component-padding-aaaaaaaa/E700-S1-an-intentionally-very-long-story-directory-slug-component-padding-bbbbbbbb/reviews"
  local rdir="$PROJ/.gaia/artifacts/implementation-artifacts/$deep"
  mkdir -p "$rdir"
  cat > "$rdir/security-review-E700-S1-with-a-long-report-basename-cccccccc.md" <<'EOF'
# Security review
Verdict: PASSED
EOF

  # Sanity: the flattened key (relpath sans extension, slash->__) must exceed
  # the safe basename budget so this fixture genuinely exercises the overflow.
  local relpath=".gaia/artifacts/implementation-artifacts/$deep/security-review-E700-S1-with-a-long-report-basename-cccccccc.md"
  local flat="${relpath%.md}"; flat="${flat//\//__}"
  [ "${#flat}" -gt 245 ]

  run bash "$REINDEX"
  [ "$status" -eq 0 ]
  # The sweep must NOT have aborted with the overflow error.
  ! printf '%s' "$output" | grep -q 'File name too long'
  # The manifest installed and the deep artifact is indexed by its path key.
  [ -f "$MANIFEST" ]
  grep -q 'security-review-E700-S1-with-a-long-report-basename-cccccccc' "$MANIFEST"
  # No orphan scratch tempfile survived under the knowledge store.
  run bash -c "ls \"$KNOW\"/*.tmp.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

# ---- Regression 2: a ': ' in an edge target must not break the manifest -----

@test "an edge target containing a colon-space round-trips through valid YAML" {
  _require_pyyaml

  # A story whose `epic:` frontmatter value carries a ': ' (the real epic-title
  # shape "GAIA Review System v2: Tool Adapter Framework"). The harvester emits
  # this verbatim as a `decomposes` edge target; emitted BARE it reads as a YAML
  # mapping separator and corrupts the manifest.
  local sdir="$PROJ/.gaia/artifacts/implementation-artifacts/epic-E701-demo/E701-S1-colon-title-node"
  mkdir -p "$sdir"
  cat > "$sdir/story.md" <<'EOF'
---
key: "E701-S1"
epic: "E701 — Review System v2: Tool Adapter Framework"
status: backlog
traces_to: ["FR-701"]
---
# Colon title story
A node whose decompose edge target carries a colon-space.
EOF

  run bash "$REINDEX"
  [ "$status" -eq 0 ]
  [ -f "$MANIFEST" ]

  # The manifest MUST parse as YAML — a bare unescaped target would raise a
  # ScannerError ("mapping values are not allowed here") here.
  run python3 -c "import yaml,sys; yaml.safe_load(open('$MANIFEST')); print('PARSED')"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'PARSED'
  # And the colon-laden target is present and intact in the manifest.
  grep -q 'Review System v2: Tool Adapter Framework' "$MANIFEST"
}

# ---- Regression 3: the generated manifest parses as YAML end to end ---------

@test "the generated manifest is valid YAML for a real-shaped multi-entry fixture" {
  _require_pyyaml

  # Mixed fixture: a colon-titled epic + a normal story + a deeply nested one.
  cat > "$PROJ/.gaia/artifacts/planning-artifacts/epics-and-stories.md" <<'EOF'
# Epics and Stories

## E702 — Platform: Adapter & Bridge v3

### Story E702-S1: First node

- **Allocates:** FR-702 (a requirement: with a colon)
- **Blocks:** [E702-S2]

### Story E702-S2: Second node

- **Allocates:** ADR-702 (a decision: also colon-laden)
- **Blocks:** []
EOF

  local d1="$PROJ/.gaia/artifacts/implementation-artifacts/epic-E702-demo/E702-S1-first-node"
  local d2="$PROJ/.gaia/artifacts/implementation-artifacts/epic-E702-demo/E702-S2-second-node"
  mkdir -p "$d1" "$d2"
  # Colon-laden epic titles in frontmatter → colon-laden decompose targets.
  printf -- '---\nkey: "E702-S1"\nepic: "E702 — Platform: Adapter & Bridge v3"\nstatus: backlog\ntraces_to: ["FR-702"]\n---\n# First\nNode one.\n' > "$d1/story.md"
  printf -- '---\nkey: "E702-S2"\nepic: "E702 — Platform: Adapter & Bridge v3"\nstatus: backlog\ntraces_to: []\n---\n# Second\nNode two.\n' > "$d2/story.md"

  run bash "$REINDEX"
  [ "$status" -eq 0 ]
  [ -f "$MANIFEST" ]

  run python3 -c "import yaml; d=yaml.safe_load(open('$MANIFEST')); print(len(d.get('entries',[])))"
  [ "$status" -eq 0 ]
  # At least the two stories plus the epics file itself were indexed.
  [ "$output" -ge 2 ]
}
