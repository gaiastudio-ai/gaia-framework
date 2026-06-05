#!/usr/bin/env bash
# rewrite-agent-memory-injection.sh
#
# Rewrites each subagent .md file under plugins/gaia/agents/ so that:
#   1. The existing `## Memory` section's loader line switches from the `all`
#      tier to the `ground-truth` tier.
#   2. The `## Memory` block is relocated to sit AFTER the agent's
#      persona/identity block and BEFORE the first behavioural section
#      (`## Rules` by convention, falling back to the next `## ` heading).
#
# Surgical: only the `## Memory` section and loader line are touched; all
# other content (persona prose, rules, skills, scope, DoD) is preserved.
#
# Idempotent: safe to re-run — if the Memory section is already in the
# correct position with the ground-truth tier, no change is made.
#
# Scope: runs on every *.md file in plugins/gaia/agents/ except _SCHEMA.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AGENTS_DIR="${REPO_ROOT}/plugins/gaia/agents"

if [ ! -d "$AGENTS_DIR" ]; then
  echo "error: agents dir not found at $AGENTS_DIR" >&2
  exit 1
fi

# Rewrite a single file in place.
rewrite_file() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"

  # Extract agent name from filename (e.g., architect.md -> architect).
  local base
  base="$(basename "$file" .md)"

  python3 - "$file" "$tmp" "$base" <<'PY'
import io, re, sys

src_path, dst_path, agent = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src_path, 'r', encoding='utf-8') as f:
    text = f.read()

lines = text.split('\n')

# 1. Locate existing ## Memory section bounds.
mem_start = None
for i, line in enumerate(lines):
    if line.rstrip() == '## Memory':
        mem_start = i
        break

if mem_start is None:
    # No existing ## Memory section. Leave file untouched; the file will
    # fall out of AC1 and surface as a test failure — a cleaner signal than
    # silently injecting into an unknown structure.
    with open(dst_path, 'w', encoding='utf-8') as f:
        f.write(text)
    sys.exit(0)

# Find end of current ## Memory section (next `## ` heading or EOF).
mem_end = len(lines)
for j in range(mem_start + 1, len(lines)):
    if lines[j].startswith('## ') and lines[j].rstrip() != '## Memory':
        mem_end = j
        break

# Slice out the block (includes trailing blank lines up to the next heading).
memory_block = lines[mem_start:mem_end]

# 2. Rewrite the loader line within the block from `all` -> `ground-truth`.
#    Any tier token after the agent name is replaced with `ground-truth`.
loader_re = re.compile(
    r'^(!\$\{PLUGIN_DIR\}/scripts/memory-loader\.sh\s+\S+)\s+\S+\s*$'
)
new_memory_block = []
for ln in memory_block:
    m = loader_re.match(ln)
    if m:
        new_memory_block.append(f'{m.group(1)} ground-truth')
    else:
        new_memory_block.append(ln)
memory_block = new_memory_block

# Strip the memory block from the body.
body = lines[:mem_start] + lines[mem_end:]

# 3. Pick the insertion anchor:
#    - Prefer the line immediately before `## Rules`.
#    - Fall back to the line before the first `## ` heading that appears
#      after the persona anchor (## Persona / ## Identity / ## Expertise).
def find_heading(body_lines, heading):
    for i, ln in enumerate(body_lines):
        if ln.rstrip() == heading:
            return i
    return None

rules_idx = find_heading(body, '## Rules')

# Persona-side anchor: last of ## Expertise / ## Persona / ## Identity
# (whichever appears last). This gives us a floor so we never insert above
# the persona block.
persona_anchors = [find_heading(body, h) for h in
                   ('## Expertise', '## Persona', '## Identity')]
persona_floor = max([a for a in persona_anchors if a is not None] or [-1])

insertion_idx = None
if rules_idx is not None and rules_idx > persona_floor:
    insertion_idx = rules_idx
else:
    # Find the first `## ` heading strictly after persona_floor.
    for i in range(persona_floor + 1, len(body)):
        if body[i].startswith('## ') and body[i].rstrip() != '## Memory':
            insertion_idx = i
            break

if insertion_idx is None:
    # Couldn't determine placement — append to EOF rather than corrupting.
    insertion_idx = len(body)

# 4. Normalize spacing: the memory block should start with `## Memory` and
#    end with a single trailing blank line so the heading that follows keeps
#    its usual blank-line gap. Trim trailing blanks, then add exactly one.
while memory_block and memory_block[-1].strip() == '':
    memory_block.pop()
memory_block.append('')

# Also make sure there's a blank line immediately BEFORE the inserted block.
if insertion_idx > 0 and body[insertion_idx - 1].strip() != '':
    memory_block = [''] + memory_block

new_lines = body[:insertion_idx] + memory_block + body[insertion_idx:]

with open(dst_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(new_lines))
PY

  mv "$tmp" "$file"
}

# Iterate every *.md except _SCHEMA.md.
shopt -s nullglob
for f in "$AGENTS_DIR"/*.md; do
  case "$(basename "$f")" in
    _SCHEMA.md) continue ;;
  esac
  rewrite_file "$f"
done

echo "Rewrite complete across $(ls "$AGENTS_DIR"/*.md | wc -l | tr -d ' ') files (excluding _SCHEMA.md)."
