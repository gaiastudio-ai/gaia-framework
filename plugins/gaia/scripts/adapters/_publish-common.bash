#!/usr/bin/env bash
# _publish-common.bash — shared helpers for publish-* adapters per FR-526 + ADR-113.
# Source this file; do not invoke directly.

set -euo pipefail
LC_ALL=C
export LC_ALL

# Standard arg parser. Sets: ACTION, MANIFEST, VERSION, REGISTRY, OUTPUT,
# plus DRY_RUN (default 0). Extra channel-specific flags are deferred to
# the calling adapter (it must `case` on them and call `die_unknown` for
# any unmatched arg per FR-526 fail-closed contract).
# shellcheck disable=SC2034  # MANIFEST/REGISTRY consumed by caller adapters
publish_parse_common_args() {
  ACTION=""
  MANIFEST=""
  VERSION=""
  REGISTRY=""
  OUTPUT=""
  DRY_RUN=0
  EXTRA_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --action)   ACTION="$2"; shift 2 ;;
      --manifest) MANIFEST="$2"; shift 2 ;;
      --version)  VERSION="$2"; shift 2 ;;
      --registry) REGISTRY="$2"; shift 2 ;;
      --output)   OUTPUT="$2"; shift 2 ;;
      --dry-run)  DRY_RUN=1; shift ;;
      *)          EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
  case "$ACTION" in
    trigger|verify) ;;
    *) printf 'adapter: --action must be trigger|verify, got: %s\n' "$ACTION" >&2; exit 2 ;;
  esac
  [ -n "$OUTPUT" ] || { printf 'adapter: --output is required\n' >&2; exit 2; }
  [ -n "$VERSION" ] || { printf 'adapter: --version is required\n' >&2; exit 2; }
}

# Write a minimal ADR-037 envelope to $OUTPUT.
# Args: verdict, channel, action, summary, [evidence-json-array, default "[]"]
publish_write_envelope() {
  local verdict="$1" channel="$2" action="$3" summary="$4"
  local evidence="${5:-[]}"
  local adapter_name="publish-$channel"
  jq -n \
    --arg v "$verdict" \
    --arg name "$adapter_name" \
    --arg ch "$channel" \
    --arg act "$action" \
    --arg sum "$summary" \
    --argjson ev "$evidence" \
    '{verdict:$v, evidence:$ev, summary:$sum, adapter_metadata:{adapter_name:$name, adapter_version:"1.0.0", channel:$ch, action:$act}}' \
    > "$OUTPUT"
}

# Fail-closed on unknown extra arg.
publish_die_unknown_extra() {
  if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
    printf 'adapter: unknown flag(s): %s\n' "${EXTRA_ARGS[*]}" >&2
    exit 2
  fi
}

# Render a stderr-string into a single-entry evidence array.
publish_evidence_log_excerpt() {
  local content="$1" source="${2:-cli-stderr}"
  jq -n --arg t "log-excerpt" --arg c "$content" --arg s "$source" \
    '[{type:$t, content:$c, source:$s}]'
}
