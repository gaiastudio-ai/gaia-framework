#!/usr/bin/env bash
# prelude-format.sh — gaia-meeting prelude-turn renderer
#
# Emits the fixed prelude format:
#
#   [Prelude] {Name} ({Role}) — {tokens} tokens
#   Sources consulted:
#     <source 1>
#     <source 2>
#     ...
#   What I know:
#     - <bullet 1>
#     - <bullet 2>
#     ...
#
# The header reuses the round/turn/cost frame emitted upstream by
# turn-header.sh — this script renders only the prelude *body*. The DISCUSS-
# phase gate holds DISCUSS until every invited agent's prelude lands;
# that gate is enforced by the orchestrator, not this renderer.
#
# Usage:
#   prelude-format.sh --name <name> --role <role> --tokens <int> \
#                     --sources "<newline-separated sources>" \
#                     --bullets "<newline-separated bullets>"
#
# Exit codes:
#   0 = prelude emitted
#   3 = missing or malformed argument

set -euo pipefail
export LC_ALL=C

NAME=""
ROLE=""
TOKENS=""
SOURCES=""
BULLETS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)    NAME="${2-}"; shift 2 ;;
    --name=*)  NAME="${1#--name=}"; shift ;;
    --role)    ROLE="${2-}"; shift 2 ;;
    --role=*)  ROLE="${1#--role=}"; shift ;;
    --tokens)  TOKENS="${2-}"; shift 2 ;;
    --tokens=*) TOKENS="${1#--tokens=}"; shift ;;
    --sources) SOURCES="${2-}"; shift 2 ;;
    --sources=*) SOURCES="${1#--sources=}"; shift ;;
    --bullets) BULLETS="${2-}"; shift 2 ;;
    --bullets=*) BULLETS="${1#--bullets=}"; shift ;;
    *)
      echo "prelude-format.sh: unknown argument: $1" >&2
      exit 3
      ;;
  esac
done

if [[ -z "$NAME" ]];  then echo "prelude-format.sh: --name is required."  >&2; exit 3; fi
if [[ -z "$ROLE" ]];  then echo "prelude-format.sh: --role is required."  >&2; exit 3; fi
if [[ -z "$TOKENS" ]]; then echo "prelude-format.sh: --tokens is required." >&2; exit 3; fi

# Tokens MUST be a non-negative integer.
if ! [[ "$TOKENS" =~ ^[0-9]+$ ]]; then
  echo "prelude-format.sh: --tokens must be a non-negative integer (got: '$TOKENS')." >&2
  exit 3
fi

# Header line (em-dash between role and token count).
printf '[Prelude] %s (%s) — %s tokens\n' "$NAME" "$ROLE" "$TOKENS"

# Sources block — one source per line, two-space indent for readability.
printf 'Sources consulted:\n'
if [[ -n "$SOURCES" ]]; then
  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    printf '  %s\n' "$src"
  done <<< "$SOURCES"
fi

# What-I-know block — one bullet per line, "- " prefix.
printf 'What I know:\n'
if [[ -n "$BULLETS" ]]; then
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    printf '  - %s\n' "$b"
  done <<< "$BULLETS"
fi

exit 0
