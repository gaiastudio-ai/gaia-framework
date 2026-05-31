#!/usr/bin/env bash
# run-tests.sh — Reference Test Execution Bridge entry point (E17 / ADR-044).
#
# Story: E67-S6 — Land reference run-tests.sh in plugin tree.
# Refs:  AC1, AC2, AC3, AC4, AC5, FR-RSV2-11, FR-RSV2-19, ADR-044, ADR-077.
#
# ────────────────────────────────────────────────────────────────────────────
# Public API (FR-RSV2-19 adapter-contract style header-comment block).
# ────────────────────────────────────────────────────────────────────────────
#
# Forms:
#   run-tests.sh --story-key <key> --context <ctx>          # bridge form (ADR-044)
#   run-tests.sh --story     <key> --tier    <unit|integration|e2e>   # AC1 alias
#   run-tests.sh --detect-runner <project_path>             # AC3 detector probe
#   run-tests.sh --help                                     # AC5
#
# Required (one of the two run forms):
#   --story-key <key>    Story key (e.g., E67-S6) used for the audit trail.
#                        Validated against ^E[0-9]+-S[0-9]+$ (T-37 mitigation).
#   --story     <key>    Alias for --story-key per story AC1.
#
#   --context  <ctx>     Active execution context — drives tier-placement match.
#                        Enum: local | ci_pre_merge | ci_post_merge | deployment
#                              | post_deploy.
#                        When omitted, falls back to $GAIA_EXECUTION_CONTEXT or
#                        defaults to "local".
#   --tier     <name>    AC1 alias for --context, with tier-name → tier_N mapping:
#                        unit→tier_1, integration→tier_2, e2e→tier_3. The active
#                        context is then derived from the matching tier's
#                        placement field — i.e., this form binds the run to one
#                        specific tier rather than the placement-match search.
#
# Optional:
#   --config   <yaml>    Path to project-config.yaml. When omitted, falls back
#                        to $GAIA_TESTS_CONFIG, then config/project-config.yaml
#                        relative to cwd.
#
# Behavior:
#   • Reads test_execution.tier_{1,2,3}.{placement,command,timeout_seconds} from
#     the config (FR-RSV2-11). Selects the tier(s) whose placement matches the
#     active context. Refuses to run with a clear error when the requested tier
#     is bound (via --tier) and its placement does NOT match the active context
#     (e.g., placement=ci-pre-merge while context=local).
#   • For each active tier, executes the configured command with
#     timeout_seconds enforcement (POSIX-portable; `timeout` when present, perl
#     alarm fallback for macOS bash 3.2). Emits JSON {"suites":[...]} on stdout.
#   • When test_execution is absent, emits a graceful-skip JSON document
#     ({"suites":[]}) and exits 0 (parity with qa-test-runner.sh AC7).
#   • --detect-runner inspects a project directory for stack signatures and
#     prints one of: vitest | junit | pytest | go | maestro. Returns non-zero
#     with a clear error when no detector matches.
#
# Exit codes:
#   0   evidence emitted (regardless of suite pass/fail; verdict resolution is
#       done by the caller — qa-test-runner.sh / verdict-resolver.sh).
#   1   caller error (missing required flag, unparseable config, invalid story
#       key shape, placement mismatch, unknown stack on --detect-runner).
#
# Callers (the three skills that converge on this reference per AC4):
#   • /gaia-test-run                (E72-S1)
#   • /gaia-review-qa Phase 3C      (E67-S4 — qa-test-runner.sh delegates here)
#   • /gaia-test-automate Phase 2   (E67-S2)
#
# POSIX discipline: bash 3.2 (macOS), set -euo pipefail, LC_ALL=C, no
# associative arrays. jq is OPTIONAL (used only for the bridge JSON parse path
# in callers; this script emits hand-rolled JSON via awk).
#
# ────────────────────────────────────────────────────────────────────────────

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="run-tests.sh"

err()  { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { printf '%s: INFO: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  # Print the header-comment block down to the first non-comment, non-shebang
  # line. This satisfies AC5 (FR-RSV2-19 adapter-contract documentation) by
  # treating the comment header as the canonical public-API doc.
  awk '
    NR==1 && /^#!/ { next }
    /^#/ { sub(/^# ?/, "", $0); print; next }
    { exit }
  ' "$0"
}

# ---------- arg parsing ----------

STORY_KEY=""
CONTEXT_OVERRIDE=""
TIER_ALIAS=""
CONFIG=""
DETECT_RUNNER_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --story-key|--story)
      [ $# -ge 2 ] || die "$1 requires a value"
      STORY_KEY="$2"; shift 2 ;;
    --context)
      [ $# -ge 2 ] || die "--context requires a value"
      CONTEXT_OVERRIDE="$2"; shift 2 ;;
    --tier)
      [ $# -ge 2 ] || die "--tier requires a value"
      TIER_ALIAS="$2"; shift 2 ;;
    --config)
      [ $# -ge 2 ] || die "--config requires a path"
      CONFIG="$2"; shift 2 ;;
    --detect-runner)
      [ $# -ge 2 ] || die "--detect-runner requires a path"
      DETECT_RUNNER_PATH="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

# ---------- per-stack runner detector (AC3) ----------

detect_runner() {
  local proj="$1"
  if [ ! -d "$proj" ]; then
    err "detect-runner: not a directory: $proj"
    return 1
  fi
  # Vitest: package.json with vitest dep OR vitest.config.{ts,js,mjs,cjs}
  if [ -f "$proj/package.json" ] && grep -q '"vitest"' "$proj/package.json" 2>/dev/null; then
    printf 'vitest\n'; return 0
  fi
  if [ -f "$proj/vitest.config.ts" ] || [ -f "$proj/vitest.config.js" ] \
     || [ -f "$proj/vitest.config.mjs" ] || [ -f "$proj/vitest.config.cjs" ]; then
    printf 'vitest\n'; return 0
  fi
  # JUnit: pom.xml OR build.gradle / build.gradle.kts
  if [ -f "$proj/pom.xml" ] || [ -f "$proj/build.gradle" ] || [ -f "$proj/build.gradle.kts" ]; then
    printf 'junit\n'; return 0
  fi
  # pytest: pyproject.toml [tool.pytest.*] OR pytest.ini OR setup.cfg [tool:pytest]
  if [ -f "$proj/pyproject.toml" ] && grep -q 'tool\.pytest' "$proj/pyproject.toml" 2>/dev/null; then
    printf 'pytest\n'; return 0
  fi
  if [ -f "$proj/pytest.ini" ]; then
    printf 'pytest\n'; return 0
  fi
  if [ -f "$proj/setup.cfg" ] && grep -q '\[tool:pytest\]' "$proj/setup.cfg" 2>/dev/null; then
    printf 'pytest\n'; return 0
  fi
  # Go: go.mod
  if [ -f "$proj/go.mod" ]; then
    printf 'go\n'; return 0
  fi
  # Maestro: .maestro/ directory
  if [ -d "$proj/.maestro" ]; then
    printf 'maestro\n'; return 0
  fi
  err "no runner detected for $proj (unknown stack)"
  return 1
}

if [ -n "$DETECT_RUNNER_PATH" ]; then
  detect_runner "$DETECT_RUNNER_PATH"
  exit $?
fi

# ---------- run-form arg validation ----------

[ -n "$STORY_KEY" ] || die "missing --story-key (or --story)"

# T-37 mitigation: validate story-key shape before any path construction.
case "$STORY_KEY" in
  E*[0-9]*-S*[0-9]*) : ;;
  *) die "invalid story key shape '$STORY_KEY' (expected ^E[0-9]+-S[0-9]+$)" ;;
esac
# Defensive: also reject any path-traversal payload that snuck through the glob.
case "$STORY_KEY" in
  */*|*..*|*\\*) die "invalid story key shape '$STORY_KEY' (rejected)" ;;
esac

# Resolve --tier alias → tier_N + bind context to that tier's placement.
BOUND_TIER=""
case "${TIER_ALIAS:-}" in
  "")            : ;;
  unit)          BOUND_TIER="tier_1" ;;
  integration)   BOUND_TIER="tier_2" ;;
  e2e)           BOUND_TIER="tier_3" ;;
  *) die "invalid --tier '${TIER_ALIAS}' (expected one of: unit, integration, e2e)" ;;
esac

# Resolve config path (--config > $GAIA_TESTS_CONFIG > cwd default).
# E96-S1 / ADR-111: prefer `.gaia/config/` over legacy `config/`. Legacy
# fallback retained during the transition window (removed in E96-S5).
if [ -z "$CONFIG" ]; then
  if [ -n "${GAIA_TESTS_CONFIG:-}" ]; then
    CONFIG="$GAIA_TESTS_CONFIG"
  elif [ -f ".gaia/config/project-config.yaml" ]; then
    CONFIG=".gaia/config/project-config.yaml"
  else
    CONFIG="config/project-config.yaml"
  fi
fi

# Resolve context.
CONTEXT="${CONTEXT_OVERRIDE:-${GAIA_EXECUTION_CONTEXT:-local}}"
case "$CONTEXT" in
  local|ci_pre_merge|ci_post_merge|deployment|post_deploy) : ;;
  *) die "invalid context '$CONTEXT' (expected one of: local, ci_pre_merge, ci_post_merge, deployment, post_deploy)" ;;
esac

# ---------- YAML helpers (awk-based, bash 3.2 portable) ----------
# Mirrors qa-test-runner.sh's idioms — avoids a yq runtime dependency.

yaml_get_tier_field() {
  local tier="$1" field="$2"
  awk -v T="$tier" -v F="$field" '
    BEGIN { in_te=0; in_tier=0 }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_quotes(s) {
      if (length(s) >= 2) {
        first=substr(s,1,1); last=substr(s,length(s),1)
        if ((first=="\"" && last=="\"") || (first=="'\''" && last=="'\''")) {
          return substr(s, 2, length(s)-2)
        }
      }
      return s
    }
    /^[^[:space:]#]/ {
      if ($0 ~ /^test_execution[[:space:]]*:/) { in_te=1; in_tier=0; next }
      in_te=0; in_tier=0; next
    }
    in_te && /^[[:space:]]+[A-Za-z0-9_]+:/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      indent=length($0) - length(line)
      if (indent == 2) {
        key=line; sub(/:.*$/, "", key)
        if (key == T) { in_tier=1 } else { in_tier=0 }
        next
      }
      if (indent == 4 && in_tier) {
        key=line; sub(/:.*$/, "", key)
        val=line; sub(/^[^:]*:[[:space:]]*/, "", val)
        if (key == F) {
          val=trim(val)
          val=strip_quotes(val)
          print val
          exit
        }
      }
    }
  ' "$CONFIG"
}

# AF-2026-05-31-1 / Test12 F-18 — read a top-level test_execution_bridge.<field>
# value from $CONFIG. Mirrors yaml_get_tier_field's awk shape so we don't
# pull in a yq runtime dependency for the bridge_used telemetry probe.
yaml_get_bridge_field() {
  local field="$1"
  awk -v F="$field" '
    BEGIN { in_teb=0 }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_quotes(s) {
      if (length(s) >= 2) {
        first=substr(s,1,1); last=substr(s,length(s),1)
        if ((first=="\"" && last=="\"") || (first=="'\''" && last=="'\''")) {
          return substr(s, 2, length(s)-2)
        }
      }
      return s
    }
    /^[^[:space:]#]/ {
      if ($0 ~ /^test_execution_bridge[[:space:]]*:/) { in_teb=1; next }
      in_teb=0; next
    }
    in_teb && /^[[:space:]]+[A-Za-z0-9_]+:/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      key=line; sub(/:.*$/, "", key)
      val=line; sub(/^[^:]*:[[:space:]]*/, "", val)
      if (key == F) {
        val=trim(val)
        val=strip_quotes(val)
        print val
        exit
      }
    }
  ' "$CONFIG"
}

# Map placement (config dialect "ci-pre-merge") to context (env dialect
# "ci_pre_merge"). Done so a single equality check decides if a tier runs.
placement_matches_context() {
  local placement="$1" context="$2"
  local norm
  norm="$(printf '%s' "$placement" | tr '-' '_')"
  [ "$norm" = "$context" ]
}

# ---------- timeout helper (POSIX-portable) ----------

run_with_timeout() {
  local cmd="$1" timeout_seconds="$2"
  local start_ns end_ns out_file
  out_file="$(mktemp 2>/dev/null || mktemp -t runtests)"

  start_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null \
              || awk 'BEGIN{srand(); print systime()}')"

  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status "${timeout_seconds}" sh -c "$cmd" >"$out_file" 2>&1
    RT_EXIT=$?
  else
    perl -e '
      $SIG{ALRM}=sub{ kill(9, -$$); exit 124 };
      alarm($ARGV[0]);
      exec("/bin/sh","-c",$ARGV[1]);
    ' "$timeout_seconds" "$cmd" >"$out_file" 2>&1
    RT_EXIT=$?
  fi
  set -e

  end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null \
            || awk 'BEGIN{srand(); print systime()}')"
  RT_DURATION="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

  if [ "$RT_EXIT" = "124" ] || [ "$RT_EXIT" = "137" ] || [ "$RT_EXIT" = "143" ]; then
    RT_TIMEOUT=true
  else
    RT_TIMEOUT=false
  fi
  RT_OUTPUT_FILE="$out_file"
}

# ---------- JSON string escaper (bash 3.2 + awk only) ----------

json_str() {
  printf '%s' "$1" | awk '
    BEGIN { ORS=""; printf "\"" }
    {
      line=$0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      if (NR>1) printf "\\n"
      printf "%s", line
    }
    END { printf "\"" }
  '
}

emit_skipped() {
  local reason="$1"
  printf '{"tier":"none","context":'
  json_str "$CONTEXT"
  printf ',"wall_clock_seconds":0,"skipped":true,"bridge_used":false,"suites":[],"diagnostics":['
  json_str "$reason"
  printf ']}\n'
}

# ---------- main run path ----------

# Config presence — soft skip if absent.
if [ ! -f "$CONFIG" ]; then
  info "config not found at '$CONFIG'; emitting skipped evidence"
  emit_skipped "config not found at '$CONFIG'"
  exit 0
fi

# Detect test_execution presence.
TIER1_PLACEMENT="$(yaml_get_tier_field tier_1 placement || true)"
TIER2_PLACEMENT="$(yaml_get_tier_field tier_2 placement || true)"
TIER3_PLACEMENT="$(yaml_get_tier_field tier_3 placement || true)"

if [ -z "$TIER1_PLACEMENT" ] && [ -z "$TIER2_PLACEMENT" ] && [ -z "$TIER3_PLACEMENT" ]; then
  info "test_execution not configured; skipping test execution"
  emit_skipped "test_execution not configured; skipping test execution"
  exit 0
fi

# Build the active-tier list.
ACTIVE_TIERS=()

if [ -n "$BOUND_TIER" ]; then
  # --tier alias mode: bind to one specific tier; placement MUST match the
  # active context — otherwise refuse with a clear AC2 error.
  case "$BOUND_TIER" in
    tier_1) plc="$TIER1_PLACEMENT" ;;
    tier_2) plc="$TIER2_PLACEMENT" ;;
    tier_3) plc="$TIER3_PLACEMENT" ;;
  esac
  if [ -z "$plc" ]; then
    die "tier '$BOUND_TIER' (--tier $TIER_ALIAS) is not configured in $CONFIG"
  fi
  if ! placement_matches_context "$plc" "$CONTEXT"; then
    die "tier '$BOUND_TIER' (--tier $TIER_ALIAS) placement '$plc' does not match active context '$CONTEXT' — refusing to run"
  fi
  ACTIVE_TIERS+=("$BOUND_TIER")
else
  # --context mode: pick every tier whose placement matches the active context.
  for tier in tier_1 tier_2 tier_3; do
    case "$tier" in
      tier_1) plc="$TIER1_PLACEMENT" ;;
      tier_2) plc="$TIER2_PLACEMENT" ;;
      tier_3) plc="$TIER3_PLACEMENT" ;;
    esac
    if [ -n "$plc" ] && placement_matches_context "$plc" "$CONTEXT"; then
      ACTIVE_TIERS+=("$tier")
    fi
  done
  # AC2 enforcement (context mode): if at least one tier is configured but
  # NONE matches the active context, AND every configured tier has a non-local
  # placement, refuse with a clear error rather than silently skipping. This
  # catches the explicit ci-pre-merge-while-running-locally case the story AC2
  # calls out.
  if [ "${#ACTIVE_TIERS[@]}" -eq 0 ] && [ "$CONTEXT" = "local" ]; then
    for plc in "$TIER1_PLACEMENT" "$TIER2_PLACEMENT" "$TIER3_PLACEMENT"; do
      if [ -n "$plc" ] && [ "$plc" != "local" ]; then
        die "all configured tier placements are non-local (e.g., '$plc') — refusing to run while context='local'"
      fi
    done
  fi
fi

if [ "${#ACTIVE_TIERS[@]}" -eq 0 ]; then
  info "no test tier matches context '$CONTEXT'; skipping"
  emit_skipped "no test tier matches context '$CONTEXT'"
  exit 0
fi

# Run each active tier.
RUN_START="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
SUITES_PARTS=()
for i in $(seq 0 $((${#ACTIVE_TIERS[@]} - 1))); do
  tier="${ACTIVE_TIERS[$i]}"
  cmd="$(yaml_get_tier_field "$tier" command || true)"
  to="$(yaml_get_tier_field "$tier" timeout_seconds || true)"
  [ -n "$to" ] || to=300
  if [ -z "$cmd" ]; then
    suite="$(printf '{"name":%s,"command":"","exit_code":0,"duration_seconds":0,"pass_count":0,"fail_count":0,"timeout":false,"skip_reason":"no command declared"}' \
      "$(json_str "$tier")")"
    SUITES_PARTS+=("$suite")
    continue
  fi
  run_with_timeout "$cmd" "$to"
  # AF-2026-05-31-1 / Test12 F-16 — parse the framework output for real
  # per-test pass/fail counts before discarding the file. The prior
  # implementation set `pass_count = (RT_EXIT == 0 ? 1 : 0)` and
  # `fail_count = (RT_EXIT != 0 && !timeout ? 1 : 0)`, which made the
  # execution-evidence telemetry report `pass_count: 1` for a 100-test
  # pytest run — useless for any consumer trying to confirm test volume.
  # The supported regex families cover pytest ("100 passed, 2 failed in
  # 0.18s"), bats ("ok 7" / "not ok 3"), and go-test ("--- PASS:" /
  # "--- FAIL:"); other frameworks fall back to the exit-code heuristic
  # so the AC1 evidence contract stays intact. Run twice — once to count
  # individual `not ok` / `--- FAIL:` lines, once to read pytest's
  # summary line — whichever yields a non-zero count wins.
  # AF-2026-05-31-2 / Test13 F-28 — every framework-output grep below MUST
  # be terminated with `|| true` to survive the no-match case under `set -e`
  # + pipefail. A fully-GREEN suite produces `100 passed in 0.18s` but
  # NO `N failed` line at all: `grep -Eo '[0-9]+ failed' | tail | awk` then
  # exits non-zero, pipefail propagates, set -e aborts the assignment
  # BEFORE the `${var:-0}` default applies — so run-tests.sh crashed on
  # exactly the suite state a review gate needs (all-PASS) and could not
  # emit execution-evidence. Same applies to bats / go-test paths below.
  pass_count=0; fail_count=0
  if [ -f "$RT_OUTPUT_FILE" ]; then
    # pytest: "===== 100 passed, 2 failed in 0.18s ====="  (also handles xfailed/skipped suffixes)
    _pytest_pass="$(grep -Eo '[0-9]+ passed' "$RT_OUTPUT_FILE" 2>/dev/null | tail -n1 | awk '{print $1}' || true)"
    _pytest_fail="$(grep -Eo '[0-9]+ failed' "$RT_OUTPUT_FILE" 2>/dev/null | tail -n1 | awk '{print $1}' || true)"
    if [ -n "$_pytest_pass" ] || [ -n "$_pytest_fail" ]; then
      pass_count="${_pytest_pass:-0}"
      fail_count="${_pytest_fail:-0}"
    else
      # bats TAP: "ok 7 desc" / "not ok 3 desc"
      _bats_pass="$(grep -cE '^ok [0-9]+' "$RT_OUTPUT_FILE" 2>/dev/null | head -n1 || true)"
      _bats_fail="$(grep -cE '^not ok [0-9]+' "$RT_OUTPUT_FILE" 2>/dev/null | head -n1 || true)"
      if [ "${_bats_pass:-0}" -gt 0 ] || [ "${_bats_fail:-0}" -gt 0 ]; then
        pass_count="$_bats_pass"
        fail_count="$_bats_fail"
      else
        # go test: "--- PASS:" / "--- FAIL:"
        _go_pass="$(grep -cE '^--- PASS:' "$RT_OUTPUT_FILE" 2>/dev/null | head -n1 || true)"
        _go_fail="$(grep -cE '^--- FAIL:' "$RT_OUTPUT_FILE" 2>/dev/null | head -n1 || true)"
        if [ "${_go_pass:-0}" -gt 0 ] || [ "${_go_fail:-0}" -gt 0 ]; then
          pass_count="$_go_pass"
          fail_count="$_go_fail"
        fi
      fi
    fi
  fi
  # Exit-code fallback when no framework pattern matched (preserves the
  # legacy "did the suite pass at all" signal so unknown-framework callers
  # still see meaningful pass_count/fail_count).
  if [ "$pass_count" = "0" ] && [ "$fail_count" = "0" ]; then
    if [ "$RT_EXIT" -ne 0 ] && [ "$RT_TIMEOUT" = "false" ]; then
      fail_count=1
    elif [ "$RT_EXIT" -eq 0 ]; then
      pass_count=1
    fi
  fi
  rm -f "$RT_OUTPUT_FILE" || true
  suite="$(printf '{"name":%s,"command":%s,"exit_code":%s,"duration_seconds":%s,"pass_count":%s,"fail_count":%s,"timeout":%s}' \
    "$(json_str "$tier")" \
    "$(json_str "$cmd")" \
    "$RT_EXIT" \
    "$RT_DURATION" \
    "$pass_count" \
    "$fail_count" \
    "$RT_TIMEOUT")"
  SUITES_PARTS+=("$suite")
done

RUN_END="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
WALL="$(awk -v a="$RUN_START" -v b="$RUN_END" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

if [ "${#ACTIVE_TIERS[@]}" -eq 1 ]; then
  TIER_LABEL="${ACTIVE_TIERS[0]}"
else
  TIER_LABEL="multi"
fi

# Join suites JSON parts.
suites_json="["
for i in $(seq 0 $((${#SUITES_PARTS[@]} - 1))); do
  if [ "$i" -gt 0 ]; then suites_json="${suites_json},"; fi
  suites_json="${suites_json}${SUITES_PARTS[$i]}"
done
suites_json="${suites_json}]"

printf '{"tier":'
json_str "$TIER_LABEL"
printf ',"context":'
json_str "$CONTEXT"
# AF-2026-05-31-1 / Test12 F-18 — `bridge_used` reflects whether the
# Test Execution Bridge indirection was actually taken on this invocation.
# Truth conditions (any of):
#   (a) the script was reached through `test_execution_bridge.run_tests_path`
#       (callers like /gaia-review-qa Phase 3C set GAIA_BRIDGE_INVOKE=1 to
#        signal this before exec'ing the configured run_tests_path),
#   (b) the script's resolved path matches the run_tests_path value declared
#       in the active project-config.yaml — i.e. THIS file IS the bridge.
# Prior to this fix `bridge_used` was hard-coded `false` in the JSON literal,
# so the telemetry never flipped even when the bridge was correctly wired
# (run_tests_path populated + the gate-bearing review skills dispatching
# through it). Without the flip, downstream consumers (FR-EXBR-3 audits)
# could not tell a bridge-mediated run from a direct invocation.
_bridge_used="false"
if [ "${GAIA_BRIDGE_INVOKE:-}" = "1" ]; then
  _bridge_used="true"
else
  _self_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  _wired_path="$(yaml_get_bridge_field 'run_tests_path' 2>/dev/null || true)"
  if [ -n "$_wired_path" ]; then
    # Expand any ${CLAUDE_PLUGIN_ROOT} reference before comparing.
    _expanded="$(printf '%s' "$_wired_path" | sed "s|\${CLAUDE_PLUGIN_ROOT}|${CLAUDE_PLUGIN_ROOT:-}|g")"
    if [ "$_expanded" = "$_self_path" ]; then
      _bridge_used="true"
    fi
  fi
fi
printf ',"wall_clock_seconds":%s,"skipped":false,"bridge_used":%s,"suites":%s,"diagnostics":[],"story_key":' \
  "$WALL" "$_bridge_used" "$suites_json"
json_str "$STORY_KEY"
printf '}\n'

exit 0
