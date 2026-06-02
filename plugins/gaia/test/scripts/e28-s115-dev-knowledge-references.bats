#!/usr/bin/env bats
# e28-s115-dev-knowledge-references.bats
#
# Story: E28-S115 — Bundle dev knowledge fragments into appropriate skill directories
#
# Validates:
#   - Every `plugins/gaia/knowledge/{stack}/{filename}.md` path declared by a
#     stack dev subagent under `gaia-framework/plugins/gaia/agents/*-dev.md`
#     resolves to an existing, non-empty file (AC3, AC6).
#   - sha256 of every copied target matches the sha256 of its legacy source (AC2).
#   - Zero matches of the legacy path string "_gaia/dev/knowledge/" inside the
#     plugin tree (AC4).
#
# The test iterates *-dev.md subagent files (excluding the _base-dev.md template),
# extracts inline code paths matching `plugins/gaia/knowledge/...md`, and asserts
# each target file exists and is non-empty.

PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
AGENTS_DIR="$PLUGIN_DIR/agents"
KNOWLEDGE_DIR="$PLUGIN_DIR/knowledge"
# Legacy source tree lives outside the gaia-framework repo at the framework root.
LEGACY_KNOWLEDGE_DIR="$REPO_ROOT/../_gaia/dev/knowledge"

# ---------- AC3 / AC6: Every declared knowledge path resolves ----------

@test "AC3/AC6: every stack dev subagent knowledge reference resolves to a non-empty file" {
  local missing=()
  local total=0

  for agent_file in "$AGENTS_DIR"/*-dev.md; do
    # Skip the shared base template — it is not a stack subagent.
    case "$(basename "$agent_file")" in
      _base-dev.md) continue ;;
    esac

    # Extract inline-code paths of the form `plugins/gaia/knowledge/{stack}/{file}.md`.
    # grep -o emits one match per line. The pattern uses a literal backtick guard
    # to match the subagent's inline-code declarations and avoid accidental prose.
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      total=$((total + 1))
      local abs_path="$PLUGIN_DIR/${path#plugins/gaia/}"
      if [ ! -s "$abs_path" ]; then
        missing+=("$(basename "$agent_file") -> $path")
      fi
    done < <(grep -oE '`plugins/gaia/knowledge/[a-z]+/[a-zA-Z0-9_-]+\.md`' "$agent_file" | tr -d '`')
  done

  if [ ${#missing[@]} -ne 0 ]; then
    printf 'Dangling knowledge references:\n'
    printf '  %s\n' "${missing[@]}"
    return 1
  fi

  # Sanity: we MUST have discovered references — otherwise the grep pattern is wrong.
  [ "$total" -gt 0 ]
}

# ---------- AC2: sha256 of each target matches the legacy source ----------

@test "AC2: every target knowledge fragment is a byte-exact mirror of its legacy source" {
  # Skip silently when the legacy tree is unavailable (e.g., CI without framework root).
  if [ ! -d "$LEGACY_KNOWLEDGE_DIR" ]; then
    skip "legacy knowledge tree not available at $LEGACY_KNOWLEDGE_DIR"
  fi

  [ -d "$KNOWLEDGE_DIR" ]

  local mismatches=()
  local checked=0

  while IFS= read -r legacy_file; do
    local rel="${legacy_file#$LEGACY_KNOWLEDGE_DIR/}"
    local target="$KNOWLEDGE_DIR/$rel"
    checked=$((checked + 1))
    if [ ! -f "$target" ]; then
      mismatches+=("MISSING target: $rel")
      continue
    fi
    local src_sha
    local tgt_sha
    src_sha="$(shasum -a 256 "$legacy_file" | awk '{print $1}')"
    tgt_sha="$(shasum -a 256 "$target" | awk '{print $1}')"
    if [ "$src_sha" != "$tgt_sha" ]; then
      mismatches+=("SHA mismatch: $rel (src=$src_sha tgt=$tgt_sha)")
    fi
  done < <(find "$LEGACY_KNOWLEDGE_DIR" -type f -name '*.md')

  if [ ${#mismatches[@]} -ne 0 ]; then
    printf 'Knowledge fragment mirror failures:\n'
    printf '  %s\n' "${mismatches[@]}"
    return 1
  fi

  [ "$checked" -gt 0 ]
}

# ---------- AC4: No legacy path strings remain inside plugin tree ----------

@test "AC4: plugin tree contains zero references to the legacy _gaia/dev/knowledge/ path" {
  # Use grep -r and exclude the knowledge tree content itself (fragments may cite
  # historical paths in their own prose). We only care about subagents / skills /
  # docs under the plugin root referencing the legacy location.
  local matches
  # Exclude this test file itself — it legitimately names the legacy path
  # to assert the zero-reference gate. Also exclude the knowledge tree
  # content since fragment prose may cite historical paths.
  local self="$BATS_TEST_FILENAME"
  matches="$(grep -rE '_gaia/dev/knowledge/' "$PLUGIN_DIR" \
    --include='*.md' \
    --include='*.yaml' \
    --include='*.yml' \
    --include='*.json' \
    --include='*.sh' \
    --include='*.bats' 2>/dev/null \
    | grep -v "^$KNOWLEDGE_DIR" \
    | grep -v "^$self" \
    || true)"

  if [ -n "$matches" ]; then
    printf 'Legacy path references still present:\n%s\n' "$matches"
    return 1
  fi
}
