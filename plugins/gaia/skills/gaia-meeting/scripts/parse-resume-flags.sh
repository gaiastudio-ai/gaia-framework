#!/usr/bin/env bash
# parse-resume-flags.sh — gaia-meeting --resume / --continue / --interject /
# --wrap-up parser.
#
# Emits two key=value lines on stdout:
#   resume_id=<id-or-empty>
#   action=<fresh|resume_default|continue|interject|wrap_up>
#
# When action=interject, an additional line is emitted:
#   interject_text=<verbatim-payload>
#
# Validation:
#   - --continue / --interject / --wrap-up REQUIRE --resume.
#   - At most one of {--continue, --interject, --wrap-up} may be supplied.
#
# Exit codes:
#   0 = success
#   2 = mutually-exclusive flags / missing --resume / malformed args

set -euo pipefail

RESUME_ID=""
WANT_CONTINUE=0
WANT_WRAP_UP=0
INTERJECT_TEXT=""
WANT_INTERJECT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)        RESUME_ID="${2-}"; shift 2 ;;
    --resume=*)      RESUME_ID="${1#--resume=}"; shift ;;
    --continue)      WANT_CONTINUE=1; shift ;;
    --wrap-up)       WANT_WRAP_UP=1; shift ;;
    --interject)     WANT_INTERJECT=1; INTERJECT_TEXT="${2-}"; shift 2 ;;
    --interject=*)   WANT_INTERJECT=1; INTERJECT_TEXT="${1#--interject=}"; shift ;;
    *)
      echo "parse-resume-flags.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Mutually-exclusive action flags.
ACTION_COUNT=$((WANT_CONTINUE + WANT_INTERJECT + WANT_WRAP_UP))
if [[ "$ACTION_COUNT" -gt 1 ]]; then
  echo "parse-resume-flags.sh: --continue, --interject, --wrap-up are mutually exclusive" >&2
  exit 2
fi

# --continue / --interject / --wrap-up REQUIRE --resume.
if [[ "$ACTION_COUNT" -eq 1 && -z "$RESUME_ID" ]]; then
  echo "parse-resume-flags.sh: --continue / --interject / --wrap-up require --resume <id>" >&2
  exit 2
fi

# Resolve action.
if [[ -z "$RESUME_ID" && "$ACTION_COUNT" -eq 0 ]]; then
  ACTION="fresh"
elif [[ "$WANT_CONTINUE" -eq 1 ]]; then
  ACTION="continue"
elif [[ "$WANT_INTERJECT" -eq 1 ]]; then
  ACTION="interject"
elif [[ "$WANT_WRAP_UP" -eq 1 ]]; then
  ACTION="wrap_up"
else
  ACTION="resume_default"
fi

printf 'resume_id=%s\n' "$RESUME_ID"
printf 'action=%s\n' "$ACTION"
if [[ "$ACTION" == "interject" ]]; then
  printf 'interject_text=%s\n' "$INTERJECT_TEXT"
fi
exit 0
