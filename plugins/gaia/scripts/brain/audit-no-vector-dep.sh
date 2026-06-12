#!/usr/bin/env bash
# audit-no-vector-dep.sh — assert the brain store layer carries NO vector
# database, embedding model, or external search/LLM-API dependency. Retrieval in
# the Brain is grep + tags + manifest only; a vector/embedding dependency is a
# design violation.
#
# Scope: by default the brain store layer rooted at this script's parent — i.e.
# scripts/brain/ (all brain scripts) plus the schema schemas/brain-index.schema.json.
# Pass `--root <dir>` to point the audit at an alternate tree (used by the bats
# coverage to scan a seeded temp fixture).
#
# Exit-code contract:
#   0 — clean (no forbidden token found)
#   non-zero (1) — at least one forbidden token found; the offending matches are
#                  echoed (file:line:match) so the caller can see WHAT was found.
#   2 — usage error (bad --root).
#
# Portability: bash 3.2 (macOS default) clean — no mapfile, no associative
# arrays, no GNU-only flags. LC_ALL=C. set -euo pipefail. The token list is a
# single in-script array.

set -euo pipefail
LC_ALL=C
export LC_ALL

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Forbidden tokens: vector databases, embedding/transformer libraries, and
# external search / hosted-LLM API clients. Matched case-insensitively as
# substrings. Word-ish tokens are anchored loosely; this is an audit, so a
# false positive is preferable to a missed dependency.
_FORBIDDEN_TOKENS="pinecone weaviate qdrant faiss chromadb milvus embedding sentence-transformers openai cohere pgvector"

_anv_die() {
  printf 'audit-no-vector-dep.sh: %s\n' "$1" >&2
  return "${2:-2}"
}

_anv_main() {
  local root=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        shift
        [ "$#" -gt 0 ] || { _anv_die "--root requires a directory argument" 2; return 2; }
        root="$1"
        ;;
      --root=*)
        root="${1#--root=}"
        ;;
      *)
        _anv_die "unknown argument: $1" 2
        return 2
        ;;
    esac
    shift
  done

  # Default scope: the brain script dir + the brain schema.
  local -a scan_paths
  if [ -n "$root" ]; then
    [ -d "$root" ] || { _anv_die "--root is not a directory: $root" 2; return 2; }
    scan_paths=("$root")
  else
    scan_paths=("$_SELF_DIR")
    local schema="$_SELF_DIR/../../schemas/brain-index.schema.json"
    if [ -f "$schema" ]; then
      scan_paths+=("$schema")
    fi
  fi

  # Build an alternation pattern from the token list. grep -i for
  # case-insensitive; -r recurses directories; -n includes line numbers; -E for
  # the alternation. We exclude this audit script itself from the scan so its
  # own token list does not self-trip.
  local pattern token
  pattern=""
  for token in $_FORBIDDEN_TOKENS; do
    if [ -z "$pattern" ]; then
      pattern="$token"
    else
      pattern="$pattern|$token"
    fi
  done

  local self_base
  self_base="$(basename "${BASH_SOURCE[0]:-$0}")"

  local hits
  # grep returns 1 when no match (clean); guard against set -e.
  hits="$(grep -rEin "$pattern" "${scan_paths[@]}" 2>/dev/null | grep -v "/$self_base:" || true)"

  if [ -n "$hits" ]; then
    printf 'audit-no-vector-dep.sh: forbidden vector/embedding/external-service token(s) found:\n' >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi

  return 0
}

_anv_main "$@"
exit $?
