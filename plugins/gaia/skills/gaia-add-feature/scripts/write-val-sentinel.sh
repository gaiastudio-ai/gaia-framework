#!/usr/bin/env bash
# write-val-sentinel.sh — atomic Val-gate sentinel writer
#
# Writes the structured Val return as a JSON sentinel under
# $CHECKPOINT_PATH/add-feature-{feature_id}-val-dispatched.json. The sentinel
# is the script-verifiable post-fact proof that Step 2 (Val Review Gate) of
# the /gaia-add-feature skill actually dispatched a Val subagent and received
# a structured verdict. finalize.sh validates the sentinel before allowing
# cascade completion.
#
# Why this script and not a heredoc-JSON inline in finalize.sh?
#   - Hand-rolled JSON via `cat <<EOF` is forbidden — the defect surface for
#     inline heredoc JSON is high. We use jq -n instead.
#   - Writes MUST be atomic so concurrent readers never see a partial-file
#     parse error. The implementation is sibling-tempfile + mv, which is
#     POSIX-atomic on the same filesystem.
#
# Invocation:
#   write-val-sentinel.sh --feature-id <id> [--payload-stdin] < <(payload-json)
#   write-val-sentinel.sh --feature-id <id>                   < <(payload-json)
#
#   The payload on stdin is the structured return from Val. The
#   minimum required keys are: status, summary, findings, agent. status MUST
#   be one of {PASS, WARNING, CRITICAL, UNVERIFIED}. agent MUST be "val".
#
# Config:
#   CHECKPOINT_PATH — directory the sentinel is written under. Resolved via
#     the shared resolve-config.sh foundation script when not pre-set, so the
#     skill picks up the project's `_memory/checkpoints/` automatically.
#
# Exit codes:
#   0 — sentinel written
#   1 — usage error, missing payload, malformed JSON, jq absent, or write
#       failure
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="write-val-sentinel.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
RESOLVE_CONFIG="$PLUGIN_SCRIPTS_DIR/resolve-config.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  write-val-sentinel.sh --feature-id <AF-YYYY-MM-DD-N> [--payload-stdin]

The Val return payload is read from stdin (structured return).
Required keys: status, summary, findings, agent.
USAGE
}

# ---------- Arg parse ----------

feature_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --feature-id)        [ $# -ge 2 ] || die "--feature-id requires an argument"
                         feature_id="$2"; shift 2 ;;
    --feature-id=*)      feature_id="${1#--feature-id=}"; shift ;;
    --payload-stdin)     shift ;;  # advisory marker — payload is always stdin
    -h|--help)           usage; exit 0 ;;
    *)                   die "unknown flag: $1" ;;
  esac
done

[ -n "$feature_id" ] || { usage; die "--feature-id is required"; }

# Path-traversal guard on feature_id — must match AF-YYYY-MM-DD-N or a similar
# safe identifier. We accept the conservative regex used by /gaia-add-feature.
case "$feature_id" in
  */*|*..*|.*) die "feature_id rejected (path traversal): $feature_id" ;;
esac

# ---------- Resolve CHECKPOINT_PATH ----------

if [ -z "${CHECKPOINT_PATH:-}" ]; then
  if [ -x "$RESOLVE_CONFIG" ]; then
    while IFS= read -r line; do
      case "$line" in
        checkpoint_path=*)
          v="${line#checkpoint_path=}"
          v="${v#\'}"; v="${v%\'}"
          CHECKPOINT_PATH="$v"
          ;;
        CHECKPOINT_PATH=*)
          v="${line#CHECKPOINT_PATH=}"
          v="${v#\'}"; v="${v%\'}"
          CHECKPOINT_PATH="$v"
          ;;
      esac
    done < <("$RESOLVE_CONFIG" 2>/dev/null || true)
  fi
fi
[ -n "${CHECKPOINT_PATH:-}" ] || die "CHECKPOINT_PATH is unset and resolve-config.sh did not provide one"

mkdir -p "$CHECKPOINT_PATH"

# ---------- Read + validate payload ----------

command -v jq >/dev/null 2>&1 || die "jq is required for sentinel construction"

payload="$(cat)"
[ -n "$payload" ] || die "empty payload on stdin"

# Validate the payload is parseable JSON before we touch the destination.
if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
  die "payload is not valid JSON"
fi

# Validate required keys. status enum is enforced HERE so the sentinel never
# lands on disk with a malformed enum value.
if ! printf '%s' "$payload" | jq -e '
    .status and .summary and .findings and .agent
    and (.status | IN("PASS","WARNING","CRITICAL","UNVERIFIED"))
    and (.agent == "val")
    and (.findings | type == "array")
  ' >/dev/null 2>&1; then
  die "payload is missing required keys (status enum/summary/findings/agent==val)"
fi

# ---------- Atomic write: jq pretty-print -> tempfile -> mv ----------

target="$CHECKPOINT_PATH/add-feature-${feature_id}-val-dispatched.json"
tmpfile="${target}.tmp.$$"

# Augment the payload with audit-trail metadata. We use jq itself (no heredoc)
# so the JSON construction is structural — never string-concatenation.
dispatched_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! printf '%s' "$payload" \
  | jq --arg fid "$feature_id" \
       --arg dispatched_at "$dispatched_at" \
       '. + {
          schema_version: (.schema_version // "1.0"),
          feature_id: ($fid),
          skill: "gaia-add-feature",
          dispatched_at: ($dispatched_at)
        }' \
  > "$tmpfile" 2>/dev/null; then
  rm -f "$tmpfile"
  die "jq failed to construct sentinel JSON"
fi

mv -f "$tmpfile" "$target"

log "sentinel written: $target"
exit 0
