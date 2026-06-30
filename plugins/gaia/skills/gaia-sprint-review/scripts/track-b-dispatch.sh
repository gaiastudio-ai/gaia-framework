#!/usr/bin/env bash
# track-b-dispatch.sh — Track B per-stack execution-review runner
#
# Real per-stack execution dispatcher (replaces the earlier stub per the
# deferred-wiring contract). Reads the sprint_review:
# matrix from project-config.yaml, iterates each configured stack, invokes
# its command in the FOREGROUND with stdout/stderr streamed to the user's
# terminal, and emits one JSON envelope per stack on stdout.
#
# Threat-model mitigations enforced inline:
#   - env-allowlist (scripts/lib/env-allowlist.sh)
#   - timeout + process-group hard-kill (lib/exec-with-timeout.sh)
#   - foreground execution invariant + GAIA_HEADLESS=1 HALT
#   - literal subprocess exit-code propagation
#   - per-stack transcripts at mode 0600 under
#                       _memory/checkpoints/sprint-review-{sprint_id}/
#
# The per-goal AskUserQuestion gate fires at the MAIN-TURN caller
# (SKILL.md Step 4) — this script is a leaf and MUST NOT call
# AskUserQuestion itself.
#
# Usage:
#   track-b-dispatch.sh --sprint <sprint_id> [--config <project-config.yaml>]
#
# Output (stdout): JSON object with two fields:
#   track_b_verdict — composite verdict (PASSED or FAILED). FAILED iff any
#                     envelope verdict is FAILED or TIMEOUT; SKIPPED and
#                     PENDING are PASSED-equivalent.
#   envelopes       — JSON array, one envelope per configured stack/surface.
#     Envelope shape: {type, stack|surface, verdict, exit_code, stdout, stderr,
#                      transcript_path, duration_seconds, started_at, ended_at}
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

Foreground-mode enforcement:
  - GAIA_HEADLESS=1 HALTs with canonical error.
  - non-TTY stdout emits a WARNING but continues (tmux/script(1) compatible).
USAGE
}

# ---------- Arg parse ----------

sprint_id=""
# Smart-fallback for the default config path — prefer
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

# ---------- Foreground-mode enforcement ----------

if [ "${GAIA_HEADLESS:-0}" = "1" ]; then
  die "HALT: Track B requires foreground execution; GAIA_HEADLESS=1 detected"
fi
# Only warn about non-TTY stdout when we're actually going to run
# something. If the sprint_review matrix is
# empty / absent (the SKIPPED path), there's no foreground assumption to
# violate — emitting the warning here is noise. Defer the check to
# after the config read.

# ---------- Read sprint_review matrix from project-config.yaml ----------
#
# If config file doesn't exist OR the sprint_review: section is missing,
# emit an empty array — the caller treats this as "no Track B stacks
# configured" which folds into the SKIPPED path during composite verdict
# reduction (graceful degradation when section absent).
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

# Collect stack list from backend_commands, frontend_commands (map form)
# AND the legacy frontend_command scalar
# (backward-compat alias for single-web-stack projects), mobile_commands,
# desktop_commands, plugin_commands. yq emits one stack name per line.
stacks_backend=$(yq eval '.sprint_review.backend_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
stacks_frontend=$(yq eval '.sprint_review.frontend_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
stacks_mobile=$(yq eval '.sprint_review.mobile_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
stacks_desktop=$(yq eval '.sprint_review.desktop_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)
stacks_plugin=$(yq eval '.sprint_review.plugin_commands // {} | keys | .[]' "$config_path" 2>/dev/null || true)

# Legacy scalar: merge in as the synthetic stack-id `frontend` only when that
# key is NOT already in frontend_commands (so the map wins on collision,
# matching the schema's documented precedence). Surfaced as a DEPRECATED-USE
# advisory so operators get a nudge toward the canonical map form without a
# hard failure.
has_frontend_scalar=$(yq eval '.sprint_review.frontend_command // "" | length > 0' "$config_path" 2>/dev/null || echo false)
frontend_map_has_frontend_key=$(yq eval '.sprint_review.frontend_commands.frontend // "" | length > 0' "$config_path" 2>/dev/null || echo false)
merge_legacy_frontend_scalar=false
if [ "$has_frontend_scalar" = "true" ] && [ "$frontend_map_has_frontend_key" != "true" ]; then
  merge_legacy_frontend_scalar=true
  log "DEPRECATED: sprint_review.frontend_command (scalar) is set; merging as synthetic stack-id 'frontend'. Prefer sprint_review.frontend_commands map."
fi

all_stacks=""
for s in $stacks_backend; do all_stacks="$all_stacks $s"; done
for s in $stacks_frontend; do all_stacks="$all_stacks $s"; done
[ "$merge_legacy_frontend_scalar" = "true" ] && all_stacks="$all_stacks frontend"
for s in $stacks_mobile; do all_stacks="$all_stacks $s"; done
for s in $stacks_desktop; do all_stacks="$all_stacks $s"; done
for s in $stacks_plugin; do all_stacks="$all_stacks $s"; done

# Trim leading space.
all_stacks="${all_stacks# }"

# Resolve the project-supplied functional smoke command for the api manual-test
# surface up front: it determines whether there is manual-test work to do even
# when no per-stack execution commands are configured. The api surface runs its
# --target as `bash -c "$TARGET"`, so a real command (not the sprint slug) is
# what makes it a meaningful functional check.
api_command=""
if [ -n "$config_path" ] && [ -f "$config_path" ] && command -v yq >/dev/null 2>&1; then
  api_command=$(yq eval '.sprint_review.manual_test.api_command // ""' "$config_path" 2>/dev/null || echo "")
  # Trim surrounding whitespace so a whitespace-only value (which passes the
  # schema's minLength:1) is treated as "not configured" — otherwise it would
  # dispatch as a vacuous no-op command and report a misleading PASSED.
  api_command="$(printf '%s' "$api_command" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

# Early-exit only when there is NOTHING to do — neither per-stack execution
# commands NOR a functional manual-test command. A project may configure only
# the api_command (functional smoke) with no per-stack Playwright runs; that is
# still real Track B work and must reach the manual-test surface loop below.
if [ -z "$all_stacks" ] && [ -z "$api_command" ]; then
  log "no Track B stacks configured in $config_path sprint_review section — emitting empty envelope"
  printf '[]\n'
  exit 0
fi

# TTY check moved here from the top so it only fires when we actually have
# stacks to dispatch. The foreground assumption doesn't matter when there's
# nothing to run.
if [ ! -t 1 ]; then
  log "WARNING: stdout is not a TTY — Track B foreground assumption may not hold (script(1)/tmux is OK; CI is not)"
fi

# ---------- .gitignore pre-flight ----------

assert_gitignored ".gaia/memory/checkpoints/sprint-review-" || exit 1

# ---------- Per-stack execution loop ----------

# Resolve each stack's command via yq.
stack_command_for() {
  local stack="$1"
  local cmd
  cmd=$(yq eval ".sprint_review.backend_commands[\"$stack\"] // \"\"" "$config_path" 2>/dev/null)
  if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then printf '%s' "$cmd"; return; fi
  # frontend_commands (map form) takes precedence over the legacy
  # frontend_command scalar on key collision.
  cmd=$(yq eval ".sprint_review.frontend_commands[\"$stack\"] // \"\"" "$config_path" 2>/dev/null)
  if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then printf '%s' "$cmd"; return; fi
  if [ "$stack" = "frontend" ]; then
    # Legacy scalar — synthetic stack-id `frontend` only when the map has no
    # `frontend` entry (precedence rule enforced by the lookup above).
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
      type: "stack-command",
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

# ---------- Manual-test surface dispatch loop ----------
#
# After the per-stack command loop, iterate the four manual-test surfaces
# (browser, api, mobile, desktop). For each, invoke dispatch-surface.sh
# which calls the surface-adapter to determine whether the surface is
# configured. The dispatch script emits a JSON verdict per surface
# (PASSED, FAILED, PENDING, or SKIPPED). SKIPPED and PENDING are
# PASSED-equivalent — they do NOT fail Track B.

DISPATCH_SURFACE="${DISPATCH_SURFACE_BIN:-$SCRIPT_DIR/../../gaia-test-manual/scripts/dispatch-surface.sh}"

if [ ! -f "$DISPATCH_SURFACE" ]; then
  log "WARNING: dispatch-surface.sh not found at $DISPATCH_SURFACE — skipping manual-test surface loop (graceful degradation)"
else
  evidence_base=".gaia/memory/checkpoints/sprint-review-${sprint_id}/manual-test"

  # Functional-coverage + tracked-skip accounting (set inside the loop):
  #   functional_exercised  — a functional surface produced a real PASSED/FAILED
  #                           verdict (it actually ran).
  #   visual_exercised      — a visual surface was CONFIGURED (a user-facing
  #                           surface is present), so "no functional" is a real
  #                           coverage gap rather than "nothing to test at all".
  #   functional_configured — a functional smoke command (api_command) was
  #                           configured, so the api surface was eligible to run.
  #   env_limited_surfaces  — space-separated list of surfaces that were
  #                           CONFIGURED but could not run because their
  #                           environment was unavailable. This is the
  #                           un-auto-approvable tracked skip (NOT the benign
  #                           "not configured" dormant skip).
  functional_exercised="false"
  visual_exercised="false"
  functional_configured="false"
  env_limited_surfaces=""
  [ -n "$api_command" ] && functional_configured="true"

  for surface in browser api mobile desktop; do
    evidence_dir="${evidence_base}/${surface}"
    mkdir -p "$evidence_dir"

    config_flags=""
    if [ -n "$config_path" ]; then
      config_flags="--config $config_path"
    fi

    # The api surface is the FUNCTIONAL path: it executes its --target as a
    # shell command. Use the configured functional smoke command; if none is
    # configured, skip the api surface (do not run the sprint slug as a
    # command, which would fail with command-not-found and a false verdict).
    surface_target="sprint-review-${sprint_id}"
    if [ "$surface" = "api" ]; then
      if [ -z "$api_command" ]; then
        log "api surface: no sprint_review.manual_test.api_command configured — SKIPPED (no functional smoke command)"
        # Record an explicit SKIPPED envelope (PASSED-equivalent) rather than
        # running the sprint slug as a command. Keeps the audit trail complete.
        envelopes=$(printf '%s' "$envelopes" | jq \
          --arg surface "$surface" \
          '. + [{
            type: "manual-test",
            surface: $surface,
            class: "functional",
            verdict: "SKIPPED",
            raw: "SKIPPED: no sprint_review.manual_test.api_command configured"
          }]')
        continue
      fi
      surface_target="$api_command"
    fi

    set +e
    # shellcheck disable=SC2086
    surface_json=$(bash "$DISPATCH_SURFACE" --surface "$surface" \
      --target "$surface_target" \
      --evidence-dir "$evidence_dir" \
      $config_flags 2>&1)
    surface_rc=$?
    set -e

    # Parse the verdict from the JSON output.
    #
    # dispatch-surface.sh exit-code contract: 0 = dispatched (the JSON verdict
    # is authoritative — PASSED/FAILED/PENDING/SKIPPED/UNVERIFIED), 1 = a hard
    # error (usage / adapter failure / missing sibling script — a real fault,
    # NOT a benign skip). dispatch-surface.sh does NOT emit exit 2 itself (that
    # is the surface-adapter's internal dormant code, which dispatch-surface
    # re-emits as a SKIPPED JSON envelope at exit 0). So a non-zero exit here is
    # a hard error and MUST map to FAILED — never silently downgraded to a
    # benign SKIPPED (which would mask a broken dispatcher as a green run).
    surface_dispatch_error="false"
    if [ "$surface_rc" -ne 0 ]; then
      surface_verdict="FAILED"
      surface_dispatch_error="true"
      log "dispatch-surface.sh for '$surface' exited $surface_rc (hard error) — recording FAILED (not a benign skip)"
    else
      surface_verdict=$(printf '%s' "$surface_json" | grep -o '"verdict"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"verdict"[[:space:]]*:[[:space:]]*"//;s/"//' || echo "SKIPPED")
      if [ -z "$surface_verdict" ]; then
        surface_verdict="SKIPPED"
      fi
    fi

    # Parse the surface CLASS (functional|visual) emitted by dispatch-surface.sh
    # so the reducer can tell whether any FUNCTIONAL verification was exercised.
    # Fall back to the local class map when the JSON omits it (older surface).
    surface_class_val=$(printf '%s' "$surface_json" | grep -o '"class"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"class"[[:space:]]*:[[:space:]]*"//;s/"//' || echo "")
    if [ -z "$surface_class_val" ]; then
      case "$surface" in
        api)                    surface_class_val="functional" ;;
        browser|mobile|desktop) surface_class_val="visual" ;;
        *)                      surface_class_val="unknown" ;;
      esac
    fi

    # Track whether a FUNCTIONAL surface actually RAN (produced a real verdict,
    # not a benign skip). A functional run is api → PASSED or FAILED (it
    # executed; the exit code became the verdict). A FAILED smoke still RAN, so
    # it counts as exercised (the FAILED separately fails Track B). This drives
    # the "no functional surface exercised" signal so a visual-only run is never
    # mistaken for functionally verified. A dispatch hard error (FAILED via
    # surface_dispatch_error) does NOT count as a real functional run.
    if [ "$surface_class_val" = "functional" ] && [ "$surface_dispatch_error" != "true" ]; then
      case "$surface_verdict" in
        PASSED|FAILED) functional_exercised="true" ;;
      esac
    fi
    # Track whether a VISUAL surface was CONFIGURED (present for this project).
    # A benign-dormant SKIPPED (surface not declared) does NOT count; any other
    # verdict (PASSED/FAILED/PENDING/UNVERIFIED) means a user-facing visual
    # surface IS present — so "no functional surface ran" is a real coverage gap,
    # not "nothing to test at all".
    if [ "$surface_class_val" = "visual" ] && [ "$surface_verdict" != "SKIPPED" ]; then
      visual_exercised="true"
    fi

    # Tracked, un-auto-approvable env-limited functional skip (VERDICT-based,
    # not exit-code-based — the real dispatch-surface.sh exits 0 for every
    # dispatched outcome). The case: a configured functional smoke (api_command
    # set) whose verdict is UNVERIFIED — the smoke ran but could not produce a
    # clean pass/fail (an env/tooling gap the command reports as UNVERIFIED).
    # That is NOT a clean pass and MUST NOT auto-approve into green: it is
    # recorded here and drives the composite to UNVERIFIED below. A FAILED smoke
    # is a hard Track-B FAILED (composite reducer); a genuinely-dormant surface
    # (no api_command) is benign and excluded.
    if [ "$surface" = "api" ] && [ -n "$api_command" ] && \
       [ "$surface_dispatch_error" != "true" ] && [ "$surface_verdict" = "UNVERIFIED" ]; then
      env_limited_surfaces="$env_limited_surfaces $surface"
      log "tracked-skip: configured functional smoke for '$surface' was UNVERIFIED (env/tooling could not verify it) — recorded as ENV_LIMITED; composite will be UNVERIFIED (not auto-approved)"
    fi

    # Append manual-test envelope. SKIPPED and PENDING are PASSED-equivalent;
    # only FAILED (or TIMEOUT→FAILED) fails Track B. The class field is additive
    # metadata — it does NOT change the verdict semantics.
    envelopes=$(printf '%s' "$envelopes" | jq \
      --arg surface "$surface" \
      --arg class "$surface_class_val" \
      --arg verdict "$surface_verdict" \
      --arg raw_json "$surface_json" \
      '. + [{
        type: "manual-test",
        surface: $surface,
        class: $class,
        verdict: $verdict,
        raw: $raw_json
      }]')
  done
fi

# ---------- Functional-coverage signal (no-functional advisory) ----------
#
# A manual-test run that exercised only VISUAL surfaces (pixel-diff / appearance)
# is NOT functionally verified. Surface that distinctly: when a user-facing
# visual surface was present but no functional surface actually ran, emit an
# explicit advisory and record it on the result so a visual-only run is never
# mistaken for an unqualified green. This is a SURFACED state, not a hard fail —
# a project may legitimately have no functional surface — but it must not be
# silent. The variables default to "false"/empty when the surface loop did not
# run (dispatch-surface.sh absent).
functional_exercised="${functional_exercised:-false}"
visual_exercised="${visual_exercised:-false}"
functional_configured="${functional_configured:-false}"
env_limited_surfaces="${env_limited_surfaces:-}"

no_functional_surface="false"
if [ "$visual_exercised" = "true" ] && [ "$functional_exercised" != "true" ]; then
  no_functional_surface="true"
  if [ "$functional_configured" = "true" ]; then
    log "FUNCTIONAL-COVERAGE: a user-facing surface ran but the configured functional smoke did not complete — this run is NOT functionally verified (visual-only)"
  else
    log "FUNCTIONAL-COVERAGE: a user-facing visual surface ran but NO functional surface was exercised (no sprint_review.manual_test.api_command configured) — this run is visual-only, not functionally verified"
  fi
fi

# Normalise the env-limited surface list (trim, dedupe-preserve-order not needed
# — each surface is visited once).
env_limited_surfaces="${env_limited_surfaces# }"
if [ -n "$env_limited_surfaces" ]; then
  log "TRACKED-SKIP: the following surfaces were configured but their environment was unavailable and were NOT auto-approved: ${env_limited_surfaces}. Acknowledge via review or provide a hermetic/staging smoke path."
fi

# ---------- Compute Track B composite verdict ----------
#
# Precedence: FAILED > UNVERIFIED > PASSED.
#  - FAILED if ANY envelope verdict is FAILED or TIMEOUT (a real regression or a
#    dispatch hard error). TIMEOUT already maps to FAILED in the per-stack loop.
#  - UNVERIFIED (fail-CLOSED) if no hard FAILED but functional verification did
#    not actually happen where it should have: a configured functional smoke was
#    UNVERIFIED (env_limited), OR a user-facing surface ran visual-only with no
#    functional surface exercised (no_functional_surface). This routes the
#    sprint-review composite through the existing UNVERIFIED operator-
#    acknowledgement bypass path (PM explanation + Val) — so an "env not
#    available → skip" or a "visual-only run" can NEVER silently auto-approve
#    into a green PASSED. This is the un-auto-approvable contract, enforced.
#  - PASSED only when functional verification either passed or was genuinely not
#    applicable (no user-facing surface to verify).

track_b_verdict="PASSED"
envelope_count=$(printf '%s' "$envelopes" | jq 'length')
idx=0
while [ "$idx" -lt "$envelope_count" ]; do
  v=$(printf '%s' "$envelopes" | jq -r ".[$idx].verdict")
  case "$v" in
    FAILED|TIMEOUT) track_b_verdict="FAILED"; break ;;
  esac
  idx=$((idx + 1))
done

# Fail-closed downgrade to UNVERIFIED when functional verification did not
# happen (and nothing hard-FAILED). Never an auto-approved green.
if [ "$track_b_verdict" = "PASSED" ]; then
  if [ -n "$env_limited_surfaces" ] || [ "$no_functional_surface" = "true" ]; then
    track_b_verdict="UNVERIFIED"
    log "Track B → UNVERIFIED (fail-closed): functional verification did not complete (env_limited=[${env_limited_surfaces}] no_functional_surface=${no_functional_surface}); routing to the operator-acknowledgement path rather than auto-approving."
  fi
fi

# Build the env-limited surfaces as a JSON array (space-separated → array).
env_limited_json='[]'
if [ -n "$env_limited_surfaces" ]; then
  env_limited_json=$(printf '%s\n' $env_limited_surfaces | jq -R . | jq -s .)
fi

# Wrap envelopes + verdict into a top-level object so the caller can read
# track_b_verdict without re-deriving it. The functional-coverage + tracked-skip
# signals ride alongside as distinct fields (NOT folded into the verdict) so the
# review step surfaces them as findings to acknowledge:
#   functional_exercised  — a functional surface actually ran (true/false)
#   no_functional_surface — a user-facing surface ran but nothing functional did
#   env_limited_surfaces  — configured surfaces whose env was unavailable
#                           (un-auto-approvable tracked skip; [] when none)
result=$(printf '%s' "$envelopes" | jq \
  --arg track_b_verdict "$track_b_verdict" \
  --arg functional_exercised "$functional_exercised" \
  --arg no_functional_surface "$no_functional_surface" \
  --argjson env_limited_surfaces "$env_limited_json" \
  '{
    track_b_verdict: $track_b_verdict,
    functional_exercised: ($functional_exercised == "true"),
    no_functional_surface: ($no_functional_surface == "true"),
    env_limited_surfaces: $env_limited_surfaces,
    envelopes: .
  }')

printf '%s\n' "$result"
log "Track B: $track_b_verdict ($(printf '%s' "$envelopes" | jq 'length') envelope(s)); functional_exercised=$functional_exercised no_functional_surface=$no_functional_surface env_limited=[${env_limited_surfaces}]"
exit 0
