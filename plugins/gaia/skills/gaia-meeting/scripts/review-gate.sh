#!/usr/bin/env bash
# review-gate.sh — gaia-meeting REVIEW-phase disposition router
#
# The CLOSE-phase orchestrator drafts every artifact (action items, per-agent
# memory entries, meeting notes) IN MEMORY. Before any disk write, the REVIEW
# phase asks the user for a disposition per artifact:
#
#   accept | edit | drop
#
# - `accept` — the SAVE write proceeds for that artifact (exit 0).
# - `edit`   — the user supplies a revised payload; the SAVE write proceeds
#              against the revised draft (exit 0).
# - `drop`   — zero bytes are written for that artifact (exit 1).
#
# This helper is a thin classifier. The orchestrator is responsible for
# collecting the disposition (interactive prompt or YOLO-supplied default) and
# then asking this helper whether the SAVE step should proceed.
#
# Subcommands:
#   --classify --draft <path> --disposition <accept|edit|drop>
#       Echoes ACCEPT|EDIT|DROP on stdout for transcript/audit purposes.
#
#   --should-write --disposition <accept|edit|drop>
#       Exit 0 = write should proceed. Exit 1 = drop (suppress write).
#       Exit 2 = invalid disposition.
#
# Exit codes (collective):
#   0 = proceed / classified successfully
#   1 = suppress (drop)
#   2 = invalid disposition or args

set -euo pipefail

mode=""
draft=""
disp=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --classify)     mode="classify"; shift ;;
    --should-write) mode="should-write"; shift ;;
    --draft)        draft="$2"; shift 2 ;;
    --disposition)  disp="$2"; shift 2 ;;
    *) echo "review-gate.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$mode" in
  classify)
    if [[ -z "$draft" || -z "$disp" ]]; then
      echo "review-gate.sh: --classify requires --draft and --disposition" >&2
      exit 2
    fi
    case "$disp" in
      accept) echo "ACCEPT" ;;
      edit)   echo "EDIT" ;;
      drop)   echo "DROP" ;;
      *)
        echo "review-gate.sh: invalid disposition '$disp' (expected accept|edit|drop)" >&2
        exit 2
        ;;
    esac
    ;;
  should-write)
    if [[ -z "$disp" ]]; then
      echo "review-gate.sh: --should-write requires --disposition" >&2
      exit 2
    fi
    case "$disp" in
      accept|edit) exit 0 ;;
      drop)        exit 1 ;;
      *)
        echo "review-gate.sh: invalid disposition '$disp' (expected accept|edit|drop)" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "review-gate.sh: usage: review-gate.sh --classify|--should-write [--draft <path>] --disposition <accept|edit|drop>" >&2
    exit 2
    ;;
esac
