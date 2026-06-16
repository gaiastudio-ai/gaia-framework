#!/usr/bin/env bats
# brain-user-docs.bats — guards for Brain user-facing documentation and the
# Obsidian .gitignore seed.
#
# Ensures the developer guide (CLAUDE.md), the public doc-site page
# (gaia-brain.html), and the /gaia-init gitignore seed stay consistent
# with the Brain's capability surface.

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
  DOC_SITE="$REPO_ROOT/documentation"
  GENERATE_CONFIG="$REPO_ROOT/plugins/gaia/skills/gaia-init/scripts/generate-config.sh"
}
teardown() { common_teardown; }

# --- CLAUDE.md Brain section ------------------------------------------------

@test "CLAUDE.md: has a GAIA Brain heading" {
  grep -qE '^## GAIA Brain' "$CLAUDE_MD"
}

@test "CLAUDE.md: Brain section mentions .gaia/knowledge/" {
  grep -qF '.gaia/knowledge/' "$CLAUDE_MD"
}

@test "CLAUDE.md: Brain section mentions /gaia-feed" {
  grep -qF '/gaia-feed' "$CLAUDE_MD"
}

@test "CLAUDE.md: Brain section mentions /gaia-brain-query" {
  grep -qF '/gaia-brain-query' "$CLAUDE_MD"
}

@test "CLAUDE.md: Brain section mentions Obsidian browsing" {
  grep -qi 'obsidian' "$CLAUDE_MD"
}

# --- Doc-site gaia-brain.html surface coverage ------------------------------

@test "gaia-brain.html: exists and is non-empty" {
  [ -s "$DOC_SITE/gaia-brain.html" ]
}

@test "gaia-brain.html: mentions .gaia/knowledge/" {
  grep -qF '.gaia/knowledge/' "$DOC_SITE/gaia-brain.html"
}

@test "gaia-brain.html: mentions /gaia-feed" {
  grep -qF '/gaia-feed' "$DOC_SITE/gaia-brain.html"
}

@test "gaia-brain.html: mentions /gaia-brain-query" {
  grep -qF '/gaia-brain-query' "$DOC_SITE/gaia-brain.html"
}

@test "gaia-brain.html: has an Obsidian section" {
  grep -qF 'id="obsidian"' "$DOC_SITE/gaia-brain.html"
}

@test "gaia-brain.html: mentions governance envelope" {
  grep -qi 'governance envelope' "$DOC_SITE/gaia-brain.html"
}

# --- generate-config.sh gitignore seed: .obsidian/ rule ---------------------

@test "generate-config.sh: seed block ignores .gaia/knowledge/.obsidian/" {
  grep -qF '.gaia/knowledge/.obsidian/' "$GENERATE_CONFIG"
}

@test "generate-config.sh: seed block does NOT ignore .gaia/knowledge/ wholesale" {
  # A bare '.gaia/knowledge/' line (without the .obsidian/ qualifier) would
  # suppress brain content from version control. The seed must never contain
  # such a line.
  run grep -Fx '.gaia/knowledge/' "$GENERATE_CONFIG"
  [ "$status" -ne 0 ]
}

@test "generate-config.sh: back-fill loop includes .gaia/knowledge/.obsidian/" {
  # The back-fill for-loop must reference the .obsidian/ ignore so that
  # re-running /gaia-init on an older project picks up the new entry.
  grep -qF "'.gaia/knowledge/.obsidian/'" "$GENERATE_CONFIG"
}
