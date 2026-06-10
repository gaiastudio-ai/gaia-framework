#!/usr/bin/env bats
# e39-s4-sprint-scope.bats — sprint-scoped triage default vs --all opt-in.
# TC-STCL-1 (sprint-scoped default), TC-STCL-2 (--all full sweep).

bats_require_minimum_version 1.5.0

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVE="$PLUGIN/skills/gaia-triage-findings/scripts/resolve-sprint-stories.sh"
  TMP="$BATS_TEST_TMPDIR/work"
  IMPL="$TMP/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IMPL"
  # Use synthetic keys (E900-S*) that do NOT exist in the real project tree,
  # so the shared resolver's project-root search never interferes and the
  # glob fallback against --impl-dir is exercised deterministically.
  # 3 committed stories (this sprint) + 2 older stories (prior sprints).
  for k in E900-S1 E900-S2 E900-S3 E901-S1 E902-S2; do
    mkdir -p "$IMPL/epic-x/${k}-slug"
    printf -- '---\nkey: "%s"\nstatus: "done"\n---\n# %s\n' "$k" "$k" \
      > "$IMPL/epic-x/${k}-slug/story.md"
  done
  SS="$TMP/sprint-status.yaml"
  cat > "$SS" <<'EOF'
sprint_id: "sprint-99"
status: active
stories:
  - key: "E900-S1"
    title: "a"
  - key: "E900-S2"
    title: "b"
  - key: "E900-S3"
    title: "c"
EOF
}

# Stub the shared resolver onto PATH-independent absolute resolution: the
# helper falls back to a glob when resolve-story-file.sh is not executable in
# this temp tree, so we point --impl-dir at the temp tree and rely on the glob
# fallback (resolve-story-file.sh resolves against the real project root).
_run_default() {
  # Force the glob fallback by running with a resolver that won't match the
  # temp keys: we override by making the real resolver invisible via a
  # non-existent SCRIPT_DIR sibling is not possible, so instead assert on the
  # COUNT of sprint keys the helper parses, which is layout-independent.
  "$RESOLVE" --impl-dir "$IMPL" --sprint-status "$SS" "$@"
}

# TC-STCL-2 — --all emits every story file (full historical sweep).
@test "TC-STCL-2: --all scans every story file in the tree" {
  run _run_default --all
  [ "$status" -eq 0 ]
  count=$(printf '%s\n' "$output" | grep -c 'story.md')
  [ "$count" -eq 5 ]
}

# TC-STCL-1 — sprint-scoped default parses ONLY the 3 committed keys (not 5).
# The helper resolves via the real resolve-story-file.sh against the project
# root; in the temp tree it uses the glob fallback. Either way it must yield
# at most the 3 sprint keys, never the 2 out-of-sprint keys.
@test "TC-STCL-1: sprint-scoped default scopes to committed stories only" {
  run _run_default
  [ "$status" -eq 0 ]
  # Exactly the 3 committed stories resolve...
  count=$(printf '%s\n' "$output" | grep -c 'story.md')
  [ "$count" -eq 3 ]
  # ...and no out-of-sprint key (E901-S1 / E902-S2) ever appears.
  [[ "$output" != *"E901-S1"* ]]
  [[ "$output" != *"E902-S2"* ]]
}

# Gating: a closed sprint emits nothing + an informational stderr message.
@test "TC-STCL-1b: closed sprint emits nothing with an informational message" {
  cat > "$TMP/closed.yaml" <<'EOF'
sprint_id: "sprint-98"
status: closed
stories:
  - key: "E39-S4"
EOF
  # Check stdout only (the informational message is on stderr).
  run --separate-stderr "$RESOLVE" --impl-dir "$IMPL" --sprint-status "$TMP/closed.yaml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]                       # no story paths on stdout
  [[ "$stderr" == *"active sprint not found"* ]]
}
