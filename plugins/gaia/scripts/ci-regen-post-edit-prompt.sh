#!/usr/bin/env bash
# ci-regen-post-edit-prompt.sh — three-option post-edit prompt for /gaia-config-* editors.
#
# After a config-mutating /gaia-config-* command (env, stack, ci, etc.) writes a
# CI-relevant section, the editor invokes this helper to render and resolve the
# regenerate-now / defer / show-diff prompt. The helper is split across two
# subcommands so the LLM owns the user interaction (subcommand `print`) and the
# script owns the deterministic side-effects (subcommand `handle`).
#
# Subcommands:
#   print          Render the three-option prompt to stdout.
#   handle <ans>   Apply the side-effect for answer <ans>. Valid answers:
#                    y — caller proceeds to /gaia-config-ci --regenerate now.
#                    n — write the .gaia/memory/.config-stale marker.
#                    d — emit a hint pointing the caller at the diff command.
#                  Any other answer exits non-zero (caller re-asks).
#

set -euo pipefail
LC_ALL=C
export LC_ALL

cmd="${1:-}"
shift || true

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
STALE_FLAG="$SELF_DIR/ci-regen-stale-flag.sh"

print_prompt() {
  cat <<'EOF'
CI-relevant config sections were modified. Choose how to handle the generated
CI workflow files:

  (y) regenerate now    — run /gaia-config-ci --regenerate immediately.
  (n) defer to later    — leave generated workflows untouched (sets stale flag).
  (d) show diff first   — preview changes before deciding.

[y/n/d] (default: y):
EOF
}

handle_answer() {
  local ans="${1:-}"
  case "$ans" in
    y|Y)
      echo "regenerate: caller should now invoke /gaia-config-ci --regenerate."
      ;;
    n|N)
      bash "$STALE_FLAG" write
      echo "deferred: .gaia/memory/.config-stale flag written. Subsequent /gaia-* commands will warn."
      ;;
    d|D)
      echo "diff hint: run /gaia-config-show ci_cd to inspect the new ci_cd block, then re-prompt."
      ;;
    *)
      echo "ci-regen-post-edit-prompt.sh: unknown answer: $ans (expected y|n|d)" >&2
      exit 64
      ;;
  esac
}

case "$cmd" in
  print)  print_prompt ;;
  handle) handle_answer "$@" ;;
  ""|-h|--help)
    sed -n '1,20p' "$0"
    ;;
  *)
    echo "ci-regen-post-edit-prompt.sh: unknown subcommand: $cmd" >&2
    exit 64
    ;;
esac
