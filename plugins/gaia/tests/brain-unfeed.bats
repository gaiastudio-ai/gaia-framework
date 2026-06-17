#!/usr/bin/env bats
# brain-unfeed.bats — coverage for the unfeed removal pipeline
# (scripts/brain/gaia-unfeed.sh).
#
# Behaviour under test:
#   - Happy-path removal: ingested file + index entry both deleted (AC1).
#   - Atomic de-register on validation failure: prior index preserved (AC2).
#   - Non-ingested protection: project-artifact entry never removed (AC3).
#   - Idempotent no-op: absent slug exits 0 with message (AC4).
#   - Containment refusal: adversarial slugs rejected (AC5).
#   - MOC re-render after removal (AC6).
#   - MOC-unavailable degradation: removal succeeds with warning (AC6 edge).
#
# Each test builds an isolated per-test project tree (mktemp -d) and sources
# gaia-unfeed.sh to call gaia_unfeed() directly, so it never touches the real
# .gaia/knowledge/ store.

load 'test_helper.bash'

setup() {
  common_setup
  UNFEED="$SCRIPTS_DIR/brain/gaia-unfeed.sh"
  FEED="$SCRIPTS_DIR/brain/gaia-feed.sh"
  VALIDATE="$SCRIPTS_DIR/brain/validate-brain-index.sh"

  # Build an isolated project tree with a seeded brain-index.
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.gaia/knowledge/ingested"

  export CLAUDE_PROJECT_ROOT="$PROJ"
  KNOW="$PROJ/.gaia/knowledge"
  MANIFEST="$KNOW/brain-index.yaml"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# _seed_ingested SLUG — create a minimal ingested file + brain-index entry.
_seed_ingested() {
  local slug="$1"
  cat > "$KNOW/ingested/${slug}.md" <<MD
---
title: $slug
slug: $slug
ingest_source_kind: file
source_url: null
fetched_at: "2026-01-01T00:00:00Z"
expires_at: "2026-02-01T00:00:00Z"
content_hash: abc123
ttl_days: 30
token_estimate: 10
tags: [ingested, file]
status: current
---
<!-- INGESTED_CONTENT_BEGIN -->
Body of $slug document.
<!-- INGESTED_CONTENT_END -->
MD

  cat > "$MANIFEST" <<YAML
schema_version: 1
entries:
  - key: "$slug"
    source_type: ingested
    path: ".gaia/knowledge/ingested/${slug}.md"
    tags: ["ingested", "file"]
    synopsis: "Ingested document: $slug"
    edges: []
    trust:
      confidence: 0.8
      content_hash: "abc123"
      source_url: null
      fetched_at: "2026-01-01T00:00:00Z"
      expires_at: "2026-02-01T00:00:00Z"
YAML
}

# _seed_project_artifact SLUG — add a project-artifact entry sharing a key.
_seed_project_artifact() {
  local slug="$1"
  # Append a project-artifact entry to the existing manifest.
  cat >> "$MANIFEST" <<YAML
  - key: "$slug"
    source_type: project-artifact
    path: "docs/architecture.md"
    tags: ["architecture"]
    synopsis: "Architecture document"
    edges: []
    trust:
      confidence: 1.0
      content_hash: "def456"
      source_url: null
      fetched_at: null
      expires_at: null
YAML
}

# ---- Test 1: Happy-path removal (AC1) ----------------------------------------

@test "unfeed removes the ingested file and its brain-index entry" {
  _seed_ingested "test-doc"

  # Verify preconditions.
  [ -f "$KNOW/ingested/test-doc.md" ]
  grep -q 'key: "test-doc"' "$MANIFEST"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'test-doc'
  "
  [ "$status" -eq 0 ]

  # The ingested file must be gone.
  [ ! -f "$KNOW/ingested/test-doc.md" ]

  # The index entry must be gone.
  local match_count
  match_count="$(grep -c 'key: "test-doc"' "$MANIFEST" 2>/dev/null || true)"
  [ "$match_count" -eq 0 ]

  # The manifest must still be valid YAML with schema_version.
  grep -q 'schema_version: 1' "$MANIFEST"
}

# ---- Test 2: Atomic de-register on validation failure (AC2) -------------------

@test "atomic de-register preserves prior index when validation fails" {
  _seed_ingested "atomic-test"

  # Capture the byte-identical original manifest.
  local original_hash
  if command -v sha256sum >/dev/null 2>&1; then
    original_hash="$(sha256sum "$MANIFEST" | awk '{print $1}')"
  else
    original_hash="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
  fi

  # Override the validator to always fail (exit 1).
  local fake_validate="$TEST_TMP/fake-validate.sh"
  cat > "$fake_validate" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fake_validate"

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    export _GU_VALIDATE='$fake_validate'
    source '$UNFEED'
    gaia_unfeed 'atomic-test'
  "
  # Should exit non-zero because validation failed.
  [ "$status" -ne 0 ]

  # The manifest must be byte-identical to the original.
  local current_hash
  if command -v sha256sum >/dev/null 2>&1; then
    current_hash="$(sha256sum "$MANIFEST" | awk '{print $1}')"
  else
    current_hash="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
  fi
  [ "$original_hash" = "$current_hash" ]

  # The ingested file must NOT have been deleted (rollback).
  [ -f "$KNOW/ingested/atomic-test.md" ]
}

# ---- Test 3: Non-ingested protection (AC3) ------------------------------------

@test "unfeed never removes a project-artifact entry sharing the slug" {
  # Seed ONLY a project-artifact entry (no ingested entry for this slug).
  cat > "$MANIFEST" <<YAML
schema_version: 1
entries:
  - key: "shared-key"
    source_type: project-artifact
    path: "docs/architecture.md"
    tags: ["architecture"]
    synopsis: "Architecture document"
    edges: []
    trust:
      confidence: 1.0
      content_hash: "def456"
      source_url: null
      fetched_at: null
      expires_at: null
YAML

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'shared-key'
  "
  # Should exit 0 (no ingested entry to remove — idempotent no-op for ingested).
  [ "$status" -eq 0 ]

  # The project-artifact entry MUST still be present.
  grep -q 'source_type: project-artifact' "$MANIFEST"
  grep -q 'key: "shared-key"' "$MANIFEST"
}

# ---- Test 3b: Dual-entry AC3 — ingested removed, project-artifact survives ---

@test "unfeed with dual entries removes ingested and preserves project-artifact" {
  # Seed a manifest with BOTH an ingested AND a project-artifact entry
  # sharing the SAME key.
  cat > "$KNOW/ingested/dual-key.md" <<'MD'
---
title: dual-key
slug: dual-key
---
Body.
MD

  cat > "$MANIFEST" <<YAML
schema_version: 1
entries:
  - key: "dual-key"
    source_type: ingested
    path: ".gaia/knowledge/ingested/dual-key.md"
    tags: ["ingested", "file"]
    synopsis: "Ingested document: dual-key"
    edges: []
    trust:
      confidence: 0.8
      content_hash: "abc123"
      source_url: null
      fetched_at: "2026-01-01T00:00:00Z"
      expires_at: "2026-02-01T00:00:00Z"
  - key: "dual-key"
    source_type: project-artifact
    path: "docs/architecture.md"
    tags: ["architecture"]
    synopsis: "Architecture document"
    edges: []
    trust:
      confidence: 1.0
      content_hash: "def456"
      source_url: null
      fetched_at: null
      expires_at: null
YAML

  # Precondition: both entries present.
  local pre_ingested pre_artifact
  pre_ingested="$(grep -c 'source_type: ingested' "$MANIFEST")"
  pre_artifact="$(grep -c 'source_type: project-artifact' "$MANIFEST")"
  [ "$pre_ingested" -eq 1 ]
  [ "$pre_artifact" -eq 1 ]

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'dual-key'
  "
  [ "$status" -eq 0 ]

  # The ingested file must be gone.
  [ ! -f "$KNOW/ingested/dual-key.md" ]

  # The ingested entry must be gone.
  local post_ingested
  post_ingested="$(grep -c 'source_type: ingested' "$MANIFEST" 2>/dev/null || true)"
  [ "$post_ingested" -eq 0 ]

  # The project-artifact entry MUST still be present.
  grep -q 'source_type: project-artifact' "$MANIFEST"
  # PyYAML may strip quotes from the key; match both quoted and unquoted forms.
  grep -qE 'key: "?dual-key"?' "$MANIFEST"
}

# ---- Test 3c: Dual-entry AC3 on awk fallback path ----------------------------

@test "awk fallback removes only ingested entry when dual entries share a key" {
  # Seed the manifest via PyYAML so it has the REAL on-disk format: column-0
  # list items, unquoted simple scalars, 2-space field indent. Then force the
  # awk fallback to verify it handles this format correctly.
  python3 -c 'import yaml' >/dev/null 2>&1 || skip "python3+PyYAML required to seed the fixture"

  cat > "$KNOW/ingested/awk-dual.md" <<'MD'
---
title: awk-dual
slug: awk-dual
---
Body.
MD

  # Generate the manifest via PyYAML — the EXACT format the production
  # register path (python) produces.
  python3 - "$MANIFEST" <<'PYEOF'
import sys, yaml
out = sys.argv[1]
doc = {
    "schema_version": 1,
    "entries": [
        {
            "key": "awk-dual",
            "source_type": "ingested",
            "path": ".gaia/knowledge/ingested/awk-dual.md",
            "tags": ["ingested", "file"],
            "synopsis": "Ingested document: awk-dual",
            "edges": [],
            "trust": {
                "confidence": 0.8,
                "content_hash": "abc123",
                "source_url": None,
                "fetched_at": "2026-01-01T00:00:00Z",
                "expires_at": "2026-02-01T00:00:00Z",
            },
        },
        {
            "key": "awk-dual",
            "source_type": "project-artifact",
            "path": "docs/architecture.md",
            "tags": ["architecture"],
            "synopsis": "Architecture document",
            "edges": [],
            "trust": {
                "confidence": 1.0,
                "content_hash": "def456",
                "source_url": None,
                "fetched_at": None,
                "expires_at": None,
            },
        },
    ],
}
with open(out, "w") as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF

  # Sanity: the manifest must be in PyYAML column-0 format, NOT 2-space indent.
  grep -q '^- key:' "$MANIFEST"

  # Shadow python3 so 'import yaml' fails, forcing the awk fallback.
  local shadow_dir="$TEST_TMP/shadow-bin"
  mkdir -p "$shadow_dir"
  local real_python3
  real_python3="$(command -v python3)"
  cat > "$shadow_dir/python3" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *'import yaml'*) exit 1 ;;
  esac
done
exec "$real_python3" "\$@"
SHIM
  chmod +x "$shadow_dir/python3"

  run bash -c "
    export PATH=\"$shadow_dir:\$PATH\"
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'awk-dual'
  "
  [ "$status" -eq 0 ]

  # The ingested file must be gone.
  [ ! -f "$KNOW/ingested/awk-dual.md" ]

  # The ingested entry must be gone.
  local post_ingested
  post_ingested="$(grep -c 'source_type: ingested' "$MANIFEST" 2>/dev/null || true)"
  [ "$post_ingested" -eq 0 ]

  # The project-artifact entry MUST survive.
  grep -q 'source_type: project-artifact' "$MANIFEST"
  grep -qE 'key: "?awk-dual"?' "$MANIFEST"
}

# ---- Test 4: Idempotent no-op (AC4) ------------------------------------------

@test "unfeed on absent slug exits 0 with nothing-to-remove message" {
  cat > "$MANIFEST" <<'YAML'
schema_version: 1
entries: []
YAML

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'nonexistent'
  "
  [ "$status" -eq 0 ]

  # Should contain "nothing to remove" in the output (stderr or stdout).
  [[ "$output" == *"nothing to remove"* ]]

  # Running twice should be identical.
  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'nonexistent'
  "
  [ "$status" -eq 0 ]
}

# ---- Test 5: Containment refusal (AC5) ---------------------------------------

@test "containment guard refuses adversarial slugs with traversal sequences" {
  _seed_ingested "safe-doc"

  # Test slug with path traversal.
  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed '../../etc/x'
  "
  [ "$status" -ne 0 ]

  # Test slug with embedded path separator.
  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'a/b'
  "
  [ "$status" -ne 0 ]

  # Test symlink escape: create a symlink in ingested/ that points outside.
  local escape_target="$TEST_TMP/outside-file.md"
  echo "I should not be deleted" > "$escape_target"
  ln -s "$escape_target" "$KNOW/ingested/symlink-escape.md"

  # Add a matching brain-index entry for the symlink.
  cat >> "$MANIFEST" <<YAML
  - key: "symlink-escape"
    source_type: ingested
    path: ".gaia/knowledge/ingested/symlink-escape.md"
    tags: ["ingested"]
    synopsis: "Symlink escape test"
    edges: []
    trust:
      confidence: 0.8
      content_hash: "xxx"
      source_url: null
      fetched_at: null
      expires_at: null
YAML

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'symlink-escape'
  "
  [ "$status" -ne 0 ]

  # The outside file must NOT have been deleted.
  [ -f "$escape_target" ]

  # The safe-doc must be untouched.
  [ -f "$KNOW/ingested/safe-doc.md" ]
}

# ---- Test 6: MOC re-render after removal (AC6) -------------------------------

@test "MOC is re-rendered after successful removal and entry is gone" {
  # Seed TWO ingested entries so the manifest is non-empty after removal.
  _seed_ingested "moc-test"
  # Add a second entry so the manifest still has content after removing moc-test.
  cat >> "$MANIFEST" <<YAML
  - key: "moc-keeper"
    source_type: ingested
    path: ".gaia/knowledge/ingested/moc-keeper.md"
    tags: ["ingested", "file"]
    synopsis: "Ingested document: moc-keeper"
    edges: []
    trust:
      confidence: 0.8
      content_hash: "keeper123"
      source_url: null
      fetched_at: "2026-01-01T00:00:00Z"
      expires_at: "2026-02-01T00:00:00Z"
YAML
  cat > "$KNOW/ingested/moc-keeper.md" <<'MD'
---
title: moc-keeper
slug: moc-keeper
---
Keeper body.
MD

  # Create a minimal brain-index.md (MOC) containing both entries.
  cat > "$KNOW/brain-index.md" <<'MD'
# Brain Index

## Ingested

- [[moc-test]]
- [[moc-keeper]]
MD

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    source '$UNFEED'
    gaia_unfeed 'moc-test'
  "
  [ "$status" -eq 0 ]

  # The ingested file must be gone.
  [ ! -f "$KNOW/ingested/moc-test.md" ]

  # Concrete assertion: the MOC file MUST exist (non-vacuous) and the
  # removed slug must be absent from it.
  [ -f "$KNOW/brain-index.md" ]
  local moc_match
  moc_match="$(grep -c 'moc-test' "$KNOW/brain-index.md" 2>/dev/null || true)"
  [ "$moc_match" -eq 0 ]
}

# ---- Test 7: MOC-unavailable degradation (AC6 edge) --------------------------

@test "removal succeeds with warning when render-moc.sh is unavailable" {
  _seed_ingested "no-moc"

  # Hide the render-moc.sh so it cannot be found.
  local real_render="$SCRIPTS_DIR/brain/render-moc.sh"
  local hidden_render="$TEST_TMP/render-moc.sh.hidden"
  if [ -f "$real_render" ]; then
    cp "$real_render" "$hidden_render"
    # We don't move the real file — instead override the path lookup.
  fi

  run bash -c "
    export CLAUDE_PROJECT_ROOT='$PROJ'
    export _GU_RENDER_MOC='/nonexistent/render-moc.sh'
    source '$UNFEED'
    gaia_unfeed 'no-moc'
  "
  # The removal must succeed even though MOC rendering failed.
  [ "$status" -eq 0 ]

  # The ingested file must be gone.
  [ ! -f "$KNOW/ingested/no-moc.md" ]

  # A warning about MOC rendering should appear in the output.
  [[ "$output" == *"render"* ]] || [[ "$output" == *"MOC"* ]] || [[ "$output" == *"moc"* ]] || [[ "$output" == *"warning"* ]]
}
