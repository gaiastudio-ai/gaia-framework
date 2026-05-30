#!/usr/bin/env bash
# gaia-doctor — install-tools.sh
#
# Install dispatcher for MISSING applicable tools. Reads the JSON output
# of check-tools.sh, prompts per tool (skips prompt under --yes), runs the
# OS-appropriate install command from the registry, and re-probes at end.
#
# Usage:
#   install-tools.sh [--yes] [--stack NAME] [--project-root DIR]
#
# Exit codes:
#   0  every attempted install succeeded (or user skipped all)
#   1  one or more attempted installs failed
#   2  argument / IO error

set -euo pipefail
LC_ALL=C
export LC_ALL

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_TOOLS="${SKILL_DIR}/scripts/check-tools.sh"

_die() {
  echo "gaia-doctor/install-tools: $*" >&2
  exit 2
}

_host_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

YES_FLAG="false"
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES_FLAG="true"; shift ;;
    --stack)  EXTRA_ARGS+=("--stack" "${2:-}"); shift 2 ;;
    --project-root) EXTRA_ARGS+=("--project-root" "${2:-}"); shift 2 ;;
    -h|--help)
      cat <<EOF
gaia-doctor install-tools.sh — interactive install dispatcher

Usage:
  $0 [--yes] [--stack NAME] [--project-root DIR]

Flags:
  --yes, -y      Non-interactive; auto-accept every prompt
  --stack NAME   Limit to a single named stack
  --project-root D Override project root
EOF
      exit 0
      ;;
    *) _die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || _die "jq is required"
[ -x "$CHECK_TOOLS" ] || _die "check-tools.sh not found or not executable"

_prompt_yn() {
  # $1 = question; returns 0 on yes, 1 on no
  if [ "$YES_FLAG" = "true" ]; then
    return 0
  fi
  local reply
  printf '%s [Y/n] ' "$1" >&2
  read -r reply || reply="n"
  case "$reply" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

_run_install() {
  # $1 = tool id, $2 = command string
  local tid="$1" cmd="$2"
  echo "→ installing $tid via: $cmd" >&2
  if bash -c "$cmd"; then
    echo "✓ $tid installed" >&2
    return 0
  else
    echo "✗ $tid install failed" >&2
    return 1
  fi
}

main() {
  local host
  host="$(_host_os)"

  local probe_json
  probe_json="$("$CHECK_TOOLS" --json "${EXTRA_ARGS[@]}")"

  local missing
  missing="$(echo "$probe_json" | jq -r '.tools[] | select(.state == "missing") | .id')"

  if [ -z "$missing" ]; then
    echo "gaia-doctor: no missing tools — nothing to install." >&2
    exit 0
  fi

  local failed=0 attempted=0
  while IFS= read -r tid; do
    [ -z "$tid" ] && continue
    local cmd
    cmd="$(echo "$probe_json" | jq -r --arg t "$tid" --arg o "$host" \
      '(.tools[] | select(.id == $t) | .registry.install[$o]) // (.tools[] | select(.id == $t) | .registry.install.macos) // empty')"
    if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
      echo "– $tid: no install command for host=$host; skipping" >&2
      continue
    fi
    if _prompt_yn "Install $tid via '$cmd'?"; then
      attempted=$((attempted + 1))
      if ! _run_install "$tid" "$cmd"; then
        failed=$((failed + 1))
      fi
    else
      echo "– $tid: skipped by user" >&2
    fi
  done <<< "$missing"

  echo "" >&2
  echo "gaia-doctor: re-probing after install pass…" >&2
  "$CHECK_TOOLS" "${EXTRA_ARGS[@]}"

  if [ "$failed" -gt 0 ]; then
    echo "gaia-doctor: ${failed}/${attempted} installs failed" >&2
    exit 1
  fi
  exit 0
}

main
