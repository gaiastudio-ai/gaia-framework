#!/usr/bin/env bash
# revert-skill-tools-field.sh — restores `allowed-tools:` as the canonical
# YAML frontmatter key in SKILL.md, in list form (`[A, B, C]`). The
# official Claude Code skills documentation at
# https://code.claude.com/docs/en/skills confirms `allowed-tools:` is the
# canonical key.
#
# Conversion rules (reverse of fix-skill-tools-field.sh) — applied ONLY
# inside the YAML frontmatter block (between the first two `---` fences):
#   tools: A, B, C       -> allowed-tools: [A, B, C]
#   tools: A B C         -> allowed-tools: [A, B, C]
#   tools: A             -> allowed-tools: [A]
#   tools:               -> (line removed; no tools to declare)
#   allowed-tools: ...   -> left untouched (already reverted)
#
# Idempotent: running the script a second time is a no-op because no file
# contains a top-level `tools:` key after a successful first run.
#
# Usage:
#   revert-skill-tools-field.sh <file> [<file> ...]
# or
#   revert-skill-tools-field.sh --plugin-skills       # operate on the 115 plugin SKILLs
#   revert-skill-tools-field.sh --enterprise-skills   # operate on enterprise mirror SKILLs
#   revert-skill-tools-field.sh --all                 # both of the above
#
# Exit codes:
#   0  success (files converted or already clean)
#   1  usage error
#   2  I/O error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAMEWORK_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

# _rewrite_frontmatter <file>
# Rewrites the file in place, transforming `tools:` lines within the YAML
# frontmatter only. Body content is preserved byte-for-byte.
_rewrite_frontmatter() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "revert-skill-tools-field: not a file: $file" >&2
    return 2
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/skill-tools-revert-XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  awk '
    BEGIN { in_fm = 0; fm_seen = 0 }

    # Detect frontmatter fences. The frontmatter is the region between the
    # first `---` on its own line at the top of the file and the next `---`.
    /^---[[:space:]]*$/ {
      if (fm_seen == 0) { in_fm = 1; fm_seen = 1; print; next }
      else if (in_fm == 1) { in_fm = 0; print; next }
    }

    # Only rewrite while we are inside the frontmatter block.
    in_fm == 1 && /^tools:[[:space:]]*/ {
      line = $0
      # Strip the leading key (with any trailing whitespace).
      sub(/^tools:[[:space:]]*/, "", line)

      # Empty value -> drop the line entirely.
      if (line == "") { next }

      # Defensive: if already bracketed (should not happen on round-trip
      # input, but handle gracefully), strip brackets for normalization.
      if (line ~ /^\[.*\]$/) {
        gsub(/^\[[[:space:]]*/, "", line)
        gsub(/[[:space:]]*\]$/, "", line)
      }

      # Split on comma or whitespace and re-emit in list form.
      n = 0
      delete toks
      count = split(line, raw, /[,[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (raw[i] != "") { n++; toks[n] = raw[i] }
      }
      if (n == 0) { next }

      out = toks[1]
      for (i = 2; i <= n; i++) out = out ", " toks[i]
      print "allowed-tools: [" out "]"
      next
    }

    { print }
  ' "$file" > "$tmp"

  # Only replace the original if content differs (preserves mtime on no-ops).
  if ! cmp -s "$file" "$tmp"; then
    cat "$tmp" > "$file"
  fi
}

_collect_plugin_skills() {
  local base="$REPO_ROOT/plugins/gaia/skills"
  [ -d "$base" ] || return 0
  find "$base" -mindepth 2 -maxdepth 2 -name SKILL.md -type f | sort
}

_collect_enterprise_skills() {
  local base="$FRAMEWORK_ROOT/gaia-enterprise/plugins/gaia-enterprise/skills"
  [ -d "$base" ] || return 0
  find "$base" -mindepth 2 -maxdepth 2 -name SKILL.md -type f | sort
}

_usage() {
  cat >&2 <<EOF
Usage:
  $(basename "$0") <file> [<file> ...]
  $(basename "$0") --plugin-skills
  $(basename "$0") --enterprise-skills
  $(basename "$0") --all
EOF
  exit 1
}

main() {
  [ "$#" -ge 1 ] || _usage

  local -a files=()
  case "$1" in
    --plugin-skills)
      while IFS= read -r f; do files+=("$f"); done < <(_collect_plugin_skills)
      ;;
    --enterprise-skills)
      while IFS= read -r f; do files+=("$f"); done < <(_collect_enterprise_skills)
      ;;
    --all)
      while IFS= read -r f; do files+=("$f"); done < <(_collect_plugin_skills)
      while IFS= read -r f; do files+=("$f"); done < <(_collect_enterprise_skills)
      ;;
    -h|--help) _usage ;;
    *)
      files=("$@")
      ;;
  esac

  local changed=0 total=0
  for f in "${files[@]}"; do
    total=$((total + 1))
    local before after
    before="$(shasum -a 256 "$f" | awk '{print $1}')"
    _rewrite_frontmatter "$f"
    after="$(shasum -a 256 "$f" | awk '{print $1}')"
    if [ "$before" != "$after" ]; then
      changed=$((changed + 1))
    fi
  done

  printf 'revert-skill-tools-field: processed %d file(s), %d rewritten\n' \
    "$total" "$changed"
}

main "$@"
