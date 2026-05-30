#!/usr/bin/env bash
# bridge-stub-scaffold.sh — deterministically append the minimal
# test_execution_bridge stub block to project-config.yaml.
#
# AF-2026-05-24-7 / Test02 F-2 fix: replaces the LLM-prose "append this
# block" instruction in gaia-bridge-enable/SKILL.md Step 2 with a real
# helper. The original prose contract was fragile under Mode A subagent
# dispatch — a subagent might paraphrase the block or skip the append
# entirely. This script is deterministic and idempotent.
#
# Behavior:
#   - If the target file already contains a `test_execution_bridge:` key
#     at column 0, exit 0 silently (idempotent — nothing to do).
#   - Otherwise append the canonical minimal stub:
#       test_execution_bridge:
#         bridge_enabled: false
#         # AF-2026-05-22-9 Bug-7 (seeded by gaia-bridge-enable / AF-2026-05-24-7 F-2)
#         # /gaia-ci-setup or /gaia-config-ci populates the full block.
#   - Resolution order for the target file:
#       1. Explicit positional argument (if given)
#       2. .gaia/config/project-config.yaml (canonical post-ADR-111)
#       3. config/project-config.yaml (legacy fallback)
#
# Usage:
#   bridge-stub-scaffold.sh [<path-to-project-config.yaml>]
#
# Exit codes:
#   0  Stub appended OR section already present (idempotent success)
#   1  Target file not found
#   2  Usage error
#   3  Write failed

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-bridge-enable/bridge-stub-scaffold.sh"
log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }

target=""
if [ "$#" -ge 1 ]; then
  target="$1"
fi

if [ -z "$target" ]; then
  if [ -f ".gaia/config/project-config.yaml" ]; then
    target=".gaia/config/project-config.yaml"
  elif [ -f "config/project-config.yaml" ]; then
    target="config/project-config.yaml"
  else
    log "no project-config.yaml found at .gaia/config/ or config/"
    exit 1
  fi
fi

if [ ! -f "$target" ]; then
  log "target file not found: $target"
  exit 1
fi

# Idempotency check — exact column-0 `test_execution_bridge:` match
if grep -qE '^test_execution_bridge:' "$target"; then
  log "test_execution_bridge: section already present in $target — no-op"
  exit 0
fi

# Append the canonical minimal stub. Use a heredoc to a tempfile + mv for
# atomicity, so a concurrent reader never observes a partial write.
tmp_appended="$(mktemp "${target}.XXXXXX")"
trap 'rm -f -- "$tmp_appended" 2>/dev/null || true' EXIT

cat "$target" > "$tmp_appended"

# Ensure trailing newline before appending
if [ -s "$tmp_appended" ] && [ "$(tail -c 1 "$tmp_appended" | wc -l | tr -d ' ')" = "0" ]; then
  printf '\n' >> "$tmp_appended"
fi

cat >> "$tmp_appended" <<'STUB'

test_execution_bridge:
  bridge_enabled: false
  # AF-2026-05-22-9 Bug-7 (seeded by /gaia-bridge-enable / AF-2026-05-24-7 F-2)
  # /gaia-ci-setup or /gaia-config-ci populates the full block (workflow, secrets, runners).
STUB

mv "$tmp_appended" "$target" || {
  log "write failed: could not move tempfile into place at $target"
  exit 3
}

log "appended test_execution_bridge stub to $target"
exit 0
