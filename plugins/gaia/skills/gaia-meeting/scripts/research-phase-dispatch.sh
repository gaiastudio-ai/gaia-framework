#!/usr/bin/env bash
# research-phase-dispatch.sh — gaia-meeting RESEARCH-phase fork dispatch
#
# Implements the four-step research contract:
#   1. Per-agent sidecar load via §4.10 tier-aware contract (read-only)
#   2. Source-of-truth file reads under canonical fork allowlist
#   3. WebSearch / WebFetch invocation (gated by --no-web)
#   4. Cited prelude emission (deterministic format)
#
# This helper is a deterministic CLI rather than the live LLM dispatcher — the
# LLM-side procedure is documented in SKILL.md and consumes the data exposed by
# this script (allowlist source-of-truth, sidecar canonical path, frontmatter
# audit fields). Bats tests assert the contract from this single location.
#
# Usage:
#   research-phase-dispatch.sh --print-allowlist [--no-web]
#   research-phase-dispatch.sh --check-web-flag [--no-web]
#   research-phase-dispatch.sh --check-research-flag [--skip-research]
#   research-phase-dispatch.sh --sidecar-path <agent-name>
#   research-phase-dispatch.sh --emit-frontmatter [--no-web] [--skip-research]
#
# Exit codes:
#   0 = success
#   2 = invalid argument value
#   3 = malformed args / missing required argument

set -euo pipefail
export LC_ALL=C

# Canonical state-tree root.
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"

# Memory-tree segment, resolved through the shared segment library rather than
# spelled out here, so a move of the tree is picked up automatically.
# `--sidecar-path` emits a PROJECT-RELATIVE path when PROJECT_ROOT is unset
# (callers prefix their own root), so the segment alone is what this script
# needs.
# shellcheck source=../../../scripts/lib/gaia-tree-segments.sh
# shellcheck disable=SC1091  # resolved at runtime from the plugin root.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/lib/gaia-tree-segments.sh"

MEMORY_SEGMENT=""
{ IFS= read -r _; IFS= read -r MEMORY_SEGMENT; } < <(gaia_tree_segments || true)
if [[ -z "$MEMORY_SEGMENT" ]]; then
  echo "research-phase-dispatch.sh: could not resolve the memory tree via the shared paths helper" >&2
  exit 3
fi

NO_WEB=0
SKIP_RESEARCH=0
MODE=""
SIDECAR_AGENT=""

usage() {
  cat <<'EOF' >&2
research-phase-dispatch.sh — gaia-meeting RESEARCH-phase fork dispatch

Modes:
  --print-allowlist           Print the canonical research-phase fork tool
                              allowlist as a comma-separated list. Honors
                              --no-web. This is the SINGLE source-of-truth
                              consumed by SKILL.md and bats tests.
  --check-web-flag            Print 'enabled' (default) or 'disabled' (--no-web).
  --check-research-flag       Print 'enabled' (default) or 'skipped' (--skip-research).
  --sidecar-path <agent>      Print the canonical sidecar path
                              `_memory/<agent>-sidecar`. Rejects the
                              intake shorthand `_memory/agent-decisions/<agent>/`.
  --emit-frontmatter          Print the meeting frontmatter audit fields:
                                  research_phase: enabled|skipped
                                  web_search:    enabled|disabled

Modifiers:
  --no-web                    Disable web tools in the research fork.
  --skip-research             Skip the research phase entirely.
EOF
}

# Single source-of-truth allowlists for the research-phase fork.
ALLOWLIST_BASE="Read,Grep,Glob,Bash"
ALLOWLIST_WEB="Read,Grep,Glob,Bash,WebSearch,WebFetch"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-allowlist)
      MODE="print-allowlist"
      shift
      ;;
    --check-web-flag)
      MODE="check-web-flag"
      shift
      ;;
    --check-research-flag)
      MODE="check-research-flag"
      shift
      ;;
    --sidecar-path)
      MODE="sidecar-path"
      SIDECAR_AGENT="${2-}"
      if [[ -z "$SIDECAR_AGENT" ]]; then
        echo "research-phase-dispatch.sh: --sidecar-path requires an agent name." >&2
        exit 3
      fi
      shift 2
      ;;
    --sidecar-path=*)
      MODE="sidecar-path"
      SIDECAR_AGENT="${1#--sidecar-path=}"
      shift
      ;;
    --emit-frontmatter)
      MODE="emit-frontmatter"
      shift
      ;;
    --no-web)
      NO_WEB=1
      shift
      ;;
    --skip-research)
      SKIP_RESEARCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "research-phase-dispatch.sh: unknown argument: $1" >&2
      usage
      exit 3
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "research-phase-dispatch.sh: a mode flag is required (see --help)." >&2
  exit 3
fi

case "$MODE" in
  print-allowlist)
    if [[ "$NO_WEB" -eq 1 ]]; then
      echo "$ALLOWLIST_BASE"
    else
      echo "$ALLOWLIST_WEB"
    fi
    ;;
  check-web-flag)
    if [[ "$NO_WEB" -eq 1 ]]; then
      echo "disabled"
    else
      echo "enabled"
    fi
    ;;
  check-research-flag)
    if [[ "$SKIP_RESEARCH" -eq 1 ]]; then
      echo "skipped"
    else
      echo "enabled"
    fi
    ;;
  sidecar-path)
    # Reject the intake-shorthand form.
    if [[ "$SIDECAR_AGENT" == agent-decisions/* ]] || [[ "$SIDECAR_AGENT" == */* ]]; then
      echo "research-phase-dispatch.sh: refusing intake-shorthand path '$SIDECAR_AGENT'." >&2
      echo "Use the canonical agent name only; expected form is <memory-root>/<agent>-sidecar/." >&2
      exit 2
    fi
    if [[ -z "$SIDECAR_AGENT" ]]; then
      echo "research-phase-dispatch.sh: agent name is empty." >&2
      exit 2
    fi
    # The memory tree is the canonical sidecar tree; the legacy fallback was
    # removed with the consolidation migration. With the default tree this
    # resolves to `<root>/.gaia/memory/<agent>-sidecar` — the segment comes
    # from the shared paths helper so a tree move is picked up without
    # editing this line.
    # shellcheck disable=SC2031  # the segment probe's PROJECT_ROOT is scoped to
    # its own subshell; this reads the caller's value, which is unchanged.
    echo "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}${MEMORY_SEGMENT}/${SIDECAR_AGENT}-sidecar"
    ;;
  emit-frontmatter)
    if [[ "$SKIP_RESEARCH" -eq 1 ]]; then
      echo "research_phase: skipped"
    else
      echo "research_phase: enabled"
    fi
    if [[ "$NO_WEB" -eq 1 ]]; then
      echo "web_search: disabled"
    else
      echo "web_search: enabled"
    fi
    ;;
  *)
    echo "research-phase-dispatch.sh: internal error — unknown mode '$MODE'." >&2
    exit 3
    ;;
esac

exit 0
