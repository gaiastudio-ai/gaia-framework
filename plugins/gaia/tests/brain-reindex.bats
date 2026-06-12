#!/usr/bin/env bats
# brain-reindex.bats — coverage for the reindex sweep
# (scripts/brain/gaia-brain-reindex.sh), the sole writer of
# .gaia/knowledge/brain-index.yaml.
#
# Behaviour under test:
#   - The sweep walks ONLY the artifacts + state roots, builds project-artifact
#     entries IN PLACE (no copying), and writes the manifest atomically via a
#     sibling tempfile + rename (no partial manifest visible to a reader).
#   - Content-hash stamping: each entry carries the sha256 of its source file.
#     An unchanged file on re-sweep short-circuits — the prior synopsis and edges
#     are carried forward byte-identical and the harvester is NOT re-invoked.
#   - A changed file restamps the hash and regenerates the synopsis.
#   - Three story layouts (per-story nested, legacy nested, flat) are all
#     discovered and keyed; a story present in two tiers de-dupes to the highest.
#   - Read-only boundary: a decoy under memory/ is never read or referenced; the
#     sweep writes only under knowledge/; the script + SKILL.md never name a
#     memory literal.
#   - The output validates against the entry schema.
#   - Sprint-close best-effort: a forced-fail reindex never aborts the close;
#     a successful reindex refreshes the manifest.
#
# Each test builds an isolated per-test project tree and points the path helper
# at it via CLAUDE_PROJECT_ROOT + the GAIA_*_PATH overrides, so the sweep runs
# on a fixture project and never touches the real .gaia/ tree.

load 'test_helper.bash'

# _mtime FILE — print a file's modification time as an epoch integer, portably.
# GNU coreutils stat (Linux/CI) uses `-c %Y`; BSD stat (macOS) uses `-f %m`.
# GNU's `-f` means --file-system and does NOT error, so the GNU form MUST be
# tried first; the BSD form is the fallback for hosts where `-c` is rejected.
_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

setup() {
  common_setup
  REINDEX="$SCRIPTS_DIR/brain/gaia-brain-reindex.sh"
  VALIDATE="$SCRIPTS_DIR/brain/validate-brain-index.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brain-reindex"

  # Build an isolated project tree by copying the fixture into a temp project.
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia"
  cp -R "$FIX/artifacts" "$PROJ/.gaia/artifacts"
  cp -R "$FIX/state"     "$PROJ/.gaia/state"
  cp -R "$FIX/memory"    "$PROJ/.gaia/memory"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  KNOW="$PROJ/.gaia/knowledge"
  MANIFEST="$KNOW/brain-index.yaml"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# sha256 of a file, first field only — mirrors the script's dual idiom.
_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

_run_reindex() {
  run bash "$REINDEX" "$@"
}

# ---- AC1: walk + in-place + atomic write ----------------------------------

@test "the sweep writes the manifest under the knowledge store" {
  _run_reindex
  [ "$status" -eq 0 ]
  [ -f "$MANIFEST" ]
}

@test "the manifest entries point at source files in place and never copy bytes" {
  _run_reindex
  [ "$status" -eq 0 ]
  # The primary story's relative path appears; no path resolves inside knowledge/.
  grep -q 'path:.*implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md' "$MANIFEST"
  ! grep -q 'path:.*knowledge/' "$MANIFEST"
}

@test "no sibling tempfile survives a completed sweep" {
  _run_reindex
  [ "$status" -eq 0 ]
  run bash -c "ls \"$KNOW\"/*.tmp.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "the tempfile is a sibling of the manifest on the same store" {
  # The atomic-write contract requires the staging tempfile to be a SIBLING of
  # the manifest (same filesystem → POSIX-atomic rename), not a $TMPDIR file.
  # Assert by construction: the script stages via mktemp on the manifest path
  # with a .tmp suffix template.
  grep -q 'mktemp "${out_manifest}.tmp' "$REINDEX"
}

@test "an injected mid-write failure leaves the prior manifest unchanged and no partial" {
  # First successful sweep establishes a prior manifest.
  _run_reindex
  [ "$status" -eq 0 ]
  local before
  before="$(_sha "$MANIFEST")"

  # Inject a failure: make validate-brain-index.sh report INVALID by pointing the
  # sweep at a stub validator that always exits 1. The sweep must abort, remove
  # the tempfile, and leave the prior manifest byte-identical.
  local stub="$TEST_TMP/bad-validate.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub"
  chmod +x "$stub"
  run bash "$REINDEX" --validator "$stub"
  [ "$status" -ne 0 ]

  # Prior manifest intact.
  local after
  after="$(_sha "$MANIFEST")"
  [ "$before" = "$after" ]
  # No partial tempfile left behind.
  run bash -c "ls \"$KNOW\"/*.tmp.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

# ---- AC2 (write-time C1): hash stamping + short-circuit -------------------

@test "each project-artifact entry carries a content_hash" {
  _run_reindex
  [ "$status" -eq 0 ]
  grep -q 'content_hash:' "$MANIFEST"
  # The stamped hash matches the real sha256 of the primary story file.
  local real
  real="$(_sha "$PROJ/.gaia/artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md")"
  grep -q "content_hash: \"$real\"" "$MANIFEST"
}

@test "an unchanged file on re-sweep carries the prior synopsis byte-identical" {
  # First sweep.
  _run_reindex
  [ "$status" -eq 0 ]

  # Inject a sentinel synopsis the deterministic generator would never produce
  # into the primary entry, preserving its (correct) content_hash, then re-sweep.
  # The short-circuit must carry the sentinel forward verbatim (proving it did
  # NOT regenerate the synopsis for the unchanged file).
  local sentinel="SENTINEL-CARRY-FORWARD-DO-NOT-REGENERATE"
  # Replace the primary entry's synopsis line with the sentinel.
  awk -v s="$sentinel" '
    /key: "E777-S2"/ { inprimary=1 }
    inprimary && /synopsis:/ && !done {
      sub(/synopsis:.*/, "synopsis: \"" s "\"")
      done=1
    }
    { print }
  ' "$MANIFEST" > "$MANIFEST.edited"
  mv "$MANIFEST.edited" "$MANIFEST"
  grep -q "$sentinel" "$MANIFEST"

  _run_reindex
  [ "$status" -eq 0 ]
  # Sentinel survived → the unchanged file short-circuited.
  grep -q "$sentinel" "$MANIFEST"
}

@test "a changed file restamps the content_hash and regenerates the synopsis" {
  _run_reindex
  [ "$status" -eq 0 ]
  local story="$PROJ/.gaia/artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md"
  local oldhash
  oldhash="$(_sha "$story")"
  grep -q "content_hash: \"$oldhash\"" "$MANIFEST"

  # Inject a sentinel synopsis, then CHANGE the source file. The changed hash
  # must force regeneration → the sentinel is overwritten and the hash updates.
  local sentinel="SENTINEL-SHOULD-BE-REPLACED-ON-CHANGE"
  awk -v s="$sentinel" '
    /key: "E777-S2"/ { inprimary=1 }
    inprimary && /synopsis:/ && !done {
      sub(/synopsis:.*/, "synopsis: \"" s "\"")
      done=1
    }
    { print }
  ' "$MANIFEST" > "$MANIFEST.edited"
  mv "$MANIFEST.edited" "$MANIFEST"

  printf '\nA new appended line changes the bytes.\n' >> "$story"
  local newhash
  newhash="$(_sha "$story")"
  [ "$oldhash" != "$newhash" ]

  _run_reindex
  [ "$status" -eq 0 ]
  grep -q "content_hash: \"$newhash\"" "$MANIFEST"
  ! grep -q "$sentinel" "$MANIFEST"
}

# ---- AC3: three-tier story layout tolerance -------------------------------

@test "stories in all three layouts are discovered and keyed" {
  _run_reindex
  [ "$status" -eq 0 ]
  grep -q 'key: "E777-S2"' "$MANIFEST"   # per-story nested
  grep -q 'key: "E777-S4"' "$MANIFEST"   # legacy nested
  grep -q 'key: "E777-S7"' "$MANIFEST"   # flat
}

@test "a story present in two layout tiers de-dupes to a single entry" {
  # Add a flat-layout shadow of E777-S2 (the highest-precedence per-story tier).
  cp "$PROJ/.gaia/artifacts/implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md" \
     "$PROJ/.gaia/artifacts/implementation-artifacts/E777-S2-shadow.md"
  _run_reindex
  [ "$status" -eq 0 ]
  local count
  count="$(grep -c 'key: "E777-S2"' "$MANIFEST")"
  [ "$count" -eq 1 ]
  # De-dup alone proves a single entry; assert WHICH layout survived so a
  # precedence inversion (flat shadowing per-story-nested) can't pass silently.
  # The surviving entry must point at the highest-precedence per-story-nested
  # path, and the flat-shadow path must NOT appear for this key.
  grep -q 'path:.*implementation-artifacts/epic-E777-demo/E777-S2-primary/story.md' "$MANIFEST"
  ! grep -q 'path:.*implementation-artifacts/E777-S2-shadow.md' "$MANIFEST"
}

# ---- AC4: read-only boundary ----------------------------------------------

@test "the manifest never references a memory path" {
  _run_reindex
  [ "$status" -eq 0 ]
  ! grep -q 'memory/' "$MANIFEST"
  ! grep -q 'ground-truth' "$MANIFEST"
}

# bats test_tags=hardware-dependent
@test "the reindex leaves memory mtimes untouched" {
  local decoy="$PROJ/.gaia/memory/validator-sidecar/ground-truth.md"
  # Backdate the decoy so any read-with-atime or accidental write is detectable
  # via mtime change.
  local before
  before="$(_mtime "$decoy")"
  _run_reindex
  [ "$status" -eq 0 ]
  local after
  after="$(_mtime "$decoy")"
  [ "$before" = "$after" ]
}

# bats test_tags=hardware-dependent
@test "the reindex writes only under the knowledge store" {
  # Snapshot mtimes of artifacts + state; they must be unchanged after a sweep.
  # GNU stat (-c %Y) is tried first; the BSD form (-f %m) is the macOS fallback.
  local art_before state_before
  art_before="$(find "$PROJ/.gaia/artifacts" "$PROJ/.gaia/state" -type f -exec stat -c %Y {} \; 2>/dev/null | sort || \
    find "$PROJ/.gaia/artifacts" "$PROJ/.gaia/state" -type f -exec stat -f %m {} \; | sort)"
  _run_reindex
  [ "$status" -eq 0 ]
  local art_after
  art_after="$(find "$PROJ/.gaia/artifacts" "$PROJ/.gaia/state" -type f -exec stat -c %Y {} \; 2>/dev/null | sort || \
    find "$PROJ/.gaia/artifacts" "$PROJ/.gaia/state" -type f -exec stat -f %m {} \; | sort)"
  [ "$art_before" = "$art_after" ]
  # And the knowledge dir is the only new write location.
  [ -d "$KNOW" ]
}

@test "the reindex script never references a memory literal" {
  ! grep -q '\.gaia/memory' "$REINDEX"
  ! grep -q 'GAIA_MEMORY_DIR' "$REINDEX"
}

@test "the reindex SKILL.md never references a memory literal as a source root" {
  local skill="$SCRIPTS_DIR/../skills/gaia-brain-reindex/SKILL.md"
  [ -f "$skill" ]
  # The SKILL.md may NAME the boundary in prose ("never reads memory") but must
  # not list a .gaia/memory path as a source root. Assert no bare path literal.
  ! grep -q '\.gaia/memory/' "$skill"
}

# ---- schema validity ------------------------------------------------------

@test "the swept manifest validates against the entry schema" {
  _run_reindex
  [ "$status" -eq 0 ]
  run bash "$VALIDATE" "$MANIFEST"
  # 0 = valid, 3 = SKIP (no JSON-schema backend on host) — both acceptable.
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}

# ---- AC4: sprint-close best-effort integration ----------------------------

@test "sprint-close finalize continues when the reindex fails" {
  local finalize="$SCRIPTS_DIR/../skills/gaia-sprint-close/scripts/finalize.sh"
  [ -f "$finalize" ]
  # Force the reindex to fail by overriding the resolved binary with a failing
  # stub via the documented env hook.
  local stub="$TEST_TMP/fail-reindex.sh"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$stub"
  chmod +x "$stub"
  GAIA_BRAIN_REINDEX_BIN="$stub" run bash "$finalize"
  [ "$status" -eq 0 ]
  # log() writes to stderr; bats `run` (no --separate-stderr) merges stderr into
  # $output, so the failure notice is captured there.
  printf '%s\n' "$output" | grep -qi 'reindex'
}

@test "sprint-close finalize refreshes the manifest on a successful reindex" {
  local finalize="$SCRIPTS_DIR/../skills/gaia-sprint-close/scripts/finalize.sh"
  GAIA_BRAIN_REINDEX_BIN="$REINDEX" run bash "$finalize"
  [ "$status" -eq 0 ]
  [ -f "$MANIFEST" ]
}
