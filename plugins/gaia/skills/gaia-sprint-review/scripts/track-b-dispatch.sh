#!/usr/bin/env bash
# track-b-dispatch.sh — Track B per-stack execution-review runner (E93-S4)
#
# Real per-stack execution dispatcher (replaces the E93-S3 stub per the
# E88-S2 / FR-DPD-2 deferred-wiring contract). Reads the sprint_review:
# matrix from project-config.yaml, iterates each configured stack, invokes
# its command in the FOREGROUND with stdout/stderr streamed to the user's
# terminal, and emits one JSON envelope per stack on stdout.
#
# Threat-model mitigations enforced inline:
#   - T-SGR-1 / SR-63 : env-allowlist (scripts/lib/env-allowlist.sh)
#   - T-SGR-2 / SR-66 : timeout + process-group hard-kill (lib/exec-with-timeout.sh)
#   - T-SGR-4 / NFR-069 : foreground execution invariant + GAIA_HEADLESS=1 HALT
#   - T-SGR-5         : literal subprocess exit-code propagation
#   - T-SGR-7 / SR-65 : per-stack transcripts at mode 0600 under
#                       _memory/checkpoints/sprint-review-{sprint_id}/
#
# The per-goal AskUserQuestion gate (FR-490) fires at the MAIN-TURN caller
# (SKILL.md Step 4) per NFR-067 — this script is a leaf and MUST NOT call
# AskUserQuestion itself.
#
# Usage:
#   track-b-dispatch.sh --sprint <sprint_id> [--config <project-config.yaml>]
#
# Output (stdout): JSON array, one envelope per configured stack.
#   Envelope shape: {stack, verdict, exit_code, stdout, stderr,
#                    transcript_path, duration_seconds, started_at, ended_at}
#
# Exit codes:
#   0 — all stacks dispatched (verdicts in envelopes; even FAILED is exit 0
#       at the script level — the composite verdict is the caller's concern).
#   1 — usage error, missing sprint_review section, or pre-flight HALT
#       (GAIA_HEADLESS=1, .gitignore missing).
#
# POSIX discipline: bash with [[ ]] only. macOS /bin/bash 3.2 compatible.

set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-review/track-b-dispatch.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve lib helpers. The script may be invoked from a cache path or from
# the source tree; the lib/ dir lives at ../../../scripts/lib/ from this
# script.
LIB_DIR="$(cd "$SCRIPT_DIR/../../../scripts/lib" 2>/dev/null && pwd)"
if [ -z "${LIB_DIR:-}" ] || [ ! -d "$LIB_DIR" ]; then
  printf '%s: cannot resolve lib/ directory\n' "$SCRIPT_NAME" >&2
  exit 1
fi

# shellcheck source=../../../scripts/lib/env-allowlist.sh
. "$LIB_DIR/env-allowlist.sh"
# shellcheck source=../../../scripts/lib/exec-with-timeout.sh
. "$LIB_DIR/exec-with-timeout.sh"
# shellcheck source=../../../scripts/lib/transcript-writer.sh
. "$LIB_DIR/transcript-writer.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

usage() {
  cat >&2 <<'USAGE'
Usage:
  track-b-dispatch.sh --sprint <sprint_id> [--config <project-config.yaml>]

Reads sprint_review: from project-config.yaml, iterates the per-stack
matrix, invokes each command in the foreground with stdout/stderr streamed
live, and emits a JSON array of per-stack envelopes on stdout.

Foreground-mode enforcement (NFR-069):
  - GAIA_HEADLESS=1 HALTs with canonical error.
  - non-TTY stdout emits a WARNING but continues (tmux/script(1) compatible).
USAGE
}

# ---------- Arg parse ----------

sprint_id=""
# E96-S7 AC3: smart-fallback for the default config path — prefer
# .gaia/config/project-config.yaml when present (post-migration layout),
# fall back to the legacy config/project-config.yaml. Explicit --config wins.
config_path=""
if [ -f ".gaia/config/project-config.yaml" ]; then
  config_path=".gaia/config/project-config.yaml"
elif [ -f "config/project-config.yaml" ]; then
  config_path="config/project-config.yaml"
else
  config_path=".gaia/config/project-config.yaml"  # canonical default for the missing-file diagnostic
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --sprint)        [ $# -ge 2 ] || die "--sprint requires an argument"
                     sprint_id="$2"; shift 2 ;;
    --sprint=*)      sprint_id="${1#--sprint=}"; shift ;;
    --config)        [ $# -ge 2 ] || die "--config requires an argument"
                     config_path="$2"; shift 2 ;;
    --config=*)      config_path="${1#--config=}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown flag: $1" ;;
  esac
done

[ -n "$sprint_id" ] || { usage; die "--sprint is required"; }

# ---------- Foreground-mode enforcement (NFR-069) ----------

if [ "${GAIA_HEADLESS:-0}" = "1" ]; then
  die "HALT: Track B requires foreground execution (NFR-069); GAIA_HEADLESS=1 detected"
fi
# AF-2026-05-24-14 / Test02 F-31: only warn about non-TTY stdout when
# we're actually going to run something. If the sprint_review matrix is
# empty / absent (the SKIPPED path), there's no foreground assumption to
# violate — emitting the warning here is noise. Defer the check to
# after the config read.

# ---------- Read sprint_review matrix from project-config.yaml ----------
#
# If config file doesn't exist OR the sprint_review: section is missing,
# emit an empty array — the caller treats this as "no Track B stacks
# configured" which folds into the SKIPPED path during composite verdict
# reduction. This matches FR-494 AC6 (graceful degradation when section
# absent) and preserves E93-S3 stub soft-fail behavior.
if [ ! -f "$config_path" ]; then
  log "config file not found at '$config_path' — emitting empty Track B envelope"
  printf '[]\n'
  exit 0
fi

if ! command -v yq >/dev/null 2>&1; then
  log "yq not available — emitting empty Track B envelope"
  printf '[]\n'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  die "jq is required to construct the Track B envelope"
fi

# Read timeout_per_stack with default 300.
timeout_per_stack=$(yq eval '.sprint_review.timeout_per_stack // 300' "$config_path" 2>/dev/null || echo 300)
case "$timeout_per_stack" in
  ''|*[!0-9]*) timeout_per_stack=300 ;;
esac

# Collect stack list from backend_commands, frontend_command, mobile_commands,
# desktop_commands, plugin_commands. yq emits one stack name per line.
stacks_backend=$(yq eval '.sprint_review.backend_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
stacks_mobile=$(yq eval '.sprint_review.mobile_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
stacks_desktop=$(yq eval '.sprint_review.desktop_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
stacks_plugin=$(yq eval '.sprint_review.plugin_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
has_frontend=$(yq eval '.sprint_review.frontend_command // "" | length > 0' "$config_path" 2>/dev/null || echo false)

all_stacks=""
for s in $stacks_backend; do all_stacks="$all_stacks $s"; done
[ "$has_frontend" = "true" ] && all_stacks="$all_stacks frontend"
for s in $stacks_mobile; do all_stacks="$all_stacks $s"; done
for s in $stacks_desktop; do all_stacks="$all_stacks $s"; done
for s in $stacks_plugin; do all_stacks="$all_stacks $s"; done

# Trim leading space.
all_stacks="${all_stacks# }"

if [ -z "$all_stacks" ]; then
  log "no Track B stacks configured in $config_path sprint_review section — emitting empty envelope"
  printf '[]\n'
  exit 0
fi

# AF-2026-05-24-14 / Test02 F-31: TTY check moved here from the top so
# it only fires when we actually have stacks to dispatch. The foreground
# assumption doesn't matter when there's nothing to run.
if [ ! -t 1 ]; then
  log "WARNING: stdout is not a TTY — Track B foreground assumption may not hold (script(1)/tmux is OK; CI is not)"
fi

# ---------- .gitignore pre-flight (T-SGR-7 / SR-65) ----------

assert_gitignored ".gaia/memory/checkpoints/sprint-review-" || exit 1

# ---------- Per-stack execution loop ----------

# Resolve each stack's command via yq.
stack_command_for() {
  local stack="$1"
  local cmd
  cmd=$(yq eval ".sprint_review.backend_commands[\"$stack\"] // \"\"" "$config_path" 2>/dev/null)
  if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then printf '%s' "$cmd"; return; fi
  if [ "$stack" = "frontend" ]; then
    cmd=$(yq eval '.sprint_review.frontend_command // ""' "$config_path" 2>/dev/null)
    printf '%s' "$cmd"; return
  fi
  cmd=$(yq eval ".sprint_review.mobile_commands[\"$stack\"] // \"\"" "$config_path" 2>/dev/null)
  if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then printf '%s' "$cmd"; return; fi
  cmd=$(yq eval ".sprint_review.desktop_commands[\"$stack\"] // \"\"" "$config_path" 2>/dev/null)
  if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then printf '%s' "$cmd"; return; fi
  cmd=$(yq eval ".sprint_review.plugin_commands[\"$stack\"] // \"\"" "$config_path" 2>/dev/null)
  printf '%s' "$cmd"
}

# Build env-allowlist argv fragment once (same for all stacks).
ENV_ARGS=$(build_env_args)

# Accumulate per-stack envelopes.
envelopes='[]'

for stack in $all_stacks; do
  cmd=$(stack_command_for "$stack")
  if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
    log "stack '$stack' has no configured command — skipping"
    continue
  fi

  transcript_path=$(transcript_path_for "$sprint_id" "$stack")

  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_epoch=$(date +%s)

  # Execute under env -i with the allowlist, with timeout + process-group kill,
  # and tee both stdout and stderr to the transcript file. The tee path is
  # under _memory/checkpoints/ at mode 0600 (umask 077 inside write_transcript).
  # Capture stdout in $captured_stdout, stderr in $captured_stderr, exit code.
  tmp_stdout="$(mktemp -t track-b-stdout.XXXXXX)"
  tmp_stderr="$(mktemp -t track-b-stderr.XXXXXX)"

  # Run the child:
  #   - exec_with_timeout (parent shell function) wraps the invocation in the
  #     three-tier timeout cascade + process-group kill.
  #   - The wrapped invocation uses `env -i` with the allowlist to spawn a
  #     fresh shell that sees ONLY the 7 allowlisted env vars, then runs the
  #     configured command via `sh -c "$cmd"`.
  #   - Output flows in foreground: tee to user's terminal AND to tmp files
  #     for envelope construction (preserves the stakeholder-demo invariant).
  #
  # The function ordering matters: exec_with_timeout is a parent shell function
  # and is NOT visible across `env -i`. So exec_with_timeout wraps env, not
  # the other way around.
  set +e
  eval exec_with_timeout "$timeout_per_stack" env -i $ENV_ARGS sh -c "'$cmd'" \
    > >(tee "$tmp_stdout") 2> >(tee "$tmp_stderr" >&2)
  exit_code=$?
  set -e

  end_epoch=$(date +%s)
  ended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  duration=$((end_epoch - start_epoch))

  # Map exit code to verdict.
  case "$exit_code" in
    0)         verdict="PASSED" ;;
    124|137)   verdict="TIMEOUT" ;;
    *)         verdict="FAILED" ;;
  esac

  # Write transcript (stdout + stderr concatenated) at mode 0600.
  { cat "$tmp_stdout"; cat "$tmp_stderr"; } | write_transcript "$transcript_path"

  # Capture first 10KB of stdout/stderr for the envelope.
  stdout_excerpt=$(head -c 10240 "$tmp_stdout")
  stderr_excerpt=$(head -c 10240 "$tmp_stderr")

  rm -f "$tmp_stdout" "$tmp_stderr"

  # Append envelope.
  envelopes=$(printf '%s' "$envelopes" | jq \
    --arg stack "$stack" \
    --arg verdict "$verdict" \
    --argjson exit_code "$exit_code" \
    --arg stdout "$stdout_excerpt" \
    --arg stderr "$stderr_excerpt" \
    --arg transcript_path "$transcript_path" \
    --argjson duration_seconds "$duration" \
    --arg started_at "$started_at" \
    --arg ended_at "$ended_at" \
    '. + [{
      stack: $stack,
      verdict: $verdict,
      exit_code: $exit_code,
      stdout: $stdout,
      stderr: $stderr,
      transcript_path: $transcript_path,
      duration_seconds: $duration_seconds,
      started_at: $started_at,
      ended_at: $ended_at
    }]')
done

printf '%s\n' "$envelopes"
log "Track B: ran $(printf '%s' "$envelopes" | jq 'length') stack(s)"
exit 0
