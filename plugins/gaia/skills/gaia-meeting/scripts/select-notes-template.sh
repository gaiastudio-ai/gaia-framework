#!/usr/bin/env bash
# select-notes-template.sh — gaia-meeting bias-to-template mapper
#
# Given a closing-artifact bias, emits the absolute path to the matching
# notes-drafting prompt template under the skill's `knowledge/` subtree.
# The bias-to-template mapping is sourced from the canonical mode registry
# (each mode has a `notes_template_ref` that maps one-to-one to its bias).
#
# Usage:
#   select-notes-template.sh --bias <bias-name>
#
# Stdout: absolute path to the template file (one line).
# Exit codes:
#   0 = success
#   2 = invalid args
#   3 = unknown bias
#   4 = template ref missing on disk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/load-mode-registry.sh
. "$SCRIPT_DIR/lib/load-mode-registry.sh"

BIAS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bias) BIAS="$2"; shift 2 ;;
    *) echo "select-notes-template.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BIAS" ]]; then
  echo "select-notes-template.sh: --bias is required" >&2
  exit 2
fi

KNOWLEDGE_DIR="$SCRIPT_DIR/../knowledge"

# Walk every mode in the registry; the first one whose
# closing_artifact_bias matches is the template owner.
match_ref=""
while IFS= read -r mode; do
  [[ -z "$mode" ]] && continue
  this_bias="$(mode_registry_field "$mode" closing_artifact_bias)"
  if [[ "$this_bias" == "$BIAS" ]]; then
    match_ref="$(mode_registry_field "$mode" notes_template_ref)"
    break
  fi
done < <(mode_registry_known_modes)

if [[ -z "$match_ref" ]]; then
  echo "select-notes-template.sh: unknown bias '$BIAS'" >&2
  exit 3
fi

template_path="$KNOWLEDGE_DIR/$match_ref"
if [[ ! -f "$template_path" ]]; then
  echo "select-notes-template.sh: template ref missing on disk: $template_path" >&2
  exit 4
fi

echo "$template_path"
exit 0
