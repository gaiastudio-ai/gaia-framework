#!/usr/bin/env bash
# qa-test-runner.sh — project-config-driven test execution for
# /gaia-review-qa. Resolves tier placement against GAIA_EXECUTION_CONTEXT,
# runs the configured per-tier command (with timeout enforcement), and writes
# execution-evidence.json into the per-story workdir.
#
# Public API:
#   qa-test-runner.sh --story-key <key> --workdir <dir> --config <yaml> [--context <ctx>] [--story-file <path>]
#   qa-test-runner.sh --help
#
# Output:
#   <workdir>/execution-evidence.json validating against
#   plugins/gaia/schemas/execution-evidence.schema.json.
#
# Exit codes:
#   0  evidence written (regardless of suite pass/fail — verdict resolution
#      is done by verdict-resolver.sh consuming the evidence)
#   1  caller error (missing required flag, unparseable config)
#
# POSIX discipline: bash 3.2 (macOS), set -euo pipefail, LC_ALL=C, no
# associative arrays. jq is optional (used only for the bridge JSON parse
# path and for the final evidence emission); the YAML parsing is awk/grep
# based to keep the runtime free of jq for the core read path.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="qa-test-runner.sh"

err() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { err "$*"; exit 1; }
info() { printf '%s: INFO: %s\n' "$SCRIPT_NAME" "$*" >&2; }

usage() {
  cat <<EOF
$SCRIPT_NAME — project-config-driven test execution for /gaia-review-qa.

Usage:
  $SCRIPT_NAME --story-key <key> --workdir <dir> --config <yaml> [--context <ctx>]
  $SCRIPT_NAME --help

Required:
  --story-key <key>   Story key (e.g., E1-S1) — used for the audit trail.
  --workdir <dir>     Output directory (writes execution-evidence.json here).
  --config <yaml>     Path to project-config.yaml (or a merged equivalent).

Optional:
  --context <ctx>     Override GAIA_EXECUTION_CONTEXT
                      (local | ci_pre_merge | ci_post_merge | deployment | post_deploy).
  --story-file <path> Path to the story markdown file. When provided in a
                      local context, the runner parses the File List section,
                      discovers adjacent test files, and runs only those tests
                      instead of the full-suite tier command.

Behavior:
  - Parses test_execution.tier_{1,2,3}.placement and matches against the
    active context.
  - Runs each matching tier's "command" with "timeout_seconds" enforcement
    (POSIX-portable timeout — perl alarm fallback for macOS bash 3.2).
  - When test_execution_bridge.bridge_enabled=true, delegates execution to
    the configured run_tests_path (Test Execution Bridge).
  - When test_execution is absent, writes a skipped=true evidence document
    and returns exit 0 with an INFO diagnostic.
EOF
}

# ---------- arg parsing ----------

STORY_KEY=""
WORKDIR=""
CONFIG=""
CONTEXT_OVERRIDE=""
STORY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --story-key)
      [ $# -ge 2 ] || die "--story-key requires a value"
      STORY_KEY="$2"; shift 2 ;;
    --workdir)
      [ $# -ge 2 ] || die "--workdir requires a path"
      WORKDIR="$2"; shift 2 ;;
    --config)
      [ $# -ge 2 ] || die "--config requires a path"
      CONFIG="$2"; shift 2 ;;
    --context)
      [ $# -ge 2 ] || die "--context requires a value"
      CONTEXT_OVERRIDE="$2"; shift 2 ;;
    --story-file)
      [ $# -ge 2 ] || die "--story-file requires a path"
      STORY_FILE="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[ -n "$STORY_KEY" ] || die "missing --story-key"
[ -n "$WORKDIR" ] || die "missing --workdir"
[ -n "$CONFIG" ] || die "missing --config"

# Validate story_key shape (keys flow into workdir paths).
case "$STORY_KEY" in
  E*[0-9]*-S*[0-9]*) : ;;
  *) die "invalid --story-key shape '$STORY_KEY' (expected E<N>-S<N>)" ;;
esac

mkdir -p "$WORKDIR"
EVIDENCE="$WORKDIR/execution-evidence.json"

# Resolve context.
CONTEXT="${CONTEXT_OVERRIDE:-${GAIA_EXECUTION_CONTEXT:-local}}"
case "$CONTEXT" in
  local|ci_pre_merge|ci_post_merge|deployment|post_deploy) : ;;
  *) die "invalid context '$CONTEXT' (expected one of: local, ci_pre_merge, ci_post_merge, deployment, post_deploy)" ;;
esac

# ---------- YAML helpers (awk-based, bash 3.2 portable) ----------

# Print the indented value of test_execution.<tier>.<key> from $CONFIG.
# Returns empty string when not present.
yaml_get_tier_field() {
  local tier="$1" field="$2"
  awk -v T="$tier" -v F="$field" '
    BEGIN { in_te=0; in_tier=0; in_subtier=0 }
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
      # top-level key; reset.
      if ($0 ~ /^test_execution[[:space:]]*:/) { in_te=1; in_tier=0; next }
      in_te=0; in_tier=0; next
    }
    in_te && /^[[:space:]]+[A-Za-z0-9_]+:/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      indent=length($0) - length(line)
      if (indent == 2) {
        # tier line
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

# Print the value of test_execution_bridge.<key> from $CONFIG.
yaml_get_bridge_field() {
  local field="$1"
  awk -v F="$field" '
    BEGIN { in_b=0 }
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
      if ($0 ~ /^test_execution_bridge[[:space:]]*:/) { in_b=1; next }
      in_b=0; next
    }
    in_b && /^[[:space:]]+[A-Za-z0-9_]+:/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      indent=length($0) - length(line)
      if (indent == 2) {
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

# Map placement (config dialect "ci-pre-merge") to context (env dialect
# "ci_pre_merge"). Done so a single equality check decides if a tier runs.
placement_matches_context() {
  local placement="$1" context="$2"
  local norm
  norm="$(printf '%s' "$placement" | tr '-' '_')"
  [ "$norm" = "$context" ]
}

# ---------- story-scoped test discovery ----------

# Extract the File List section from a story markdown file and return bare
# file paths (one per line). The section begins at a `## File List` or
# `### File List` heading and ends at the next heading of equal or higher
# level. Parenthetical annotations and backtick wrapping are stripped.
extract_story_file_list() {
  local story="$1"
  [ -r "$story" ] || return 1
  awk '
    BEGIN { in_section = 0 }
    /^#{2,}[[:space:]]+[Ff]ile [Ll]ist/ { in_section = 1; next }
    in_section && /^#{1,}[[:space:]]/    { in_section = 0 }
    in_section { print }
  ' "$story" \
    | grep -E '^[[:space:]]*[-*][[:space:]]+' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/`//g' \
    | awk '{
        line = $0
        # Strip trailing parenthetical annotation.
        sub(/[[:space:]]*\(.*\)[[:space:]]*$/, "", line)
        # Strip trailing comment after em-dash or " -- ".
        sub(/[[:space:]]+(—|--|—).*$/, "", line)
        # Trim leading/trailing whitespace.
        sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
        if (length(line) > 0) print line
      }'
}

# Discover test files adjacent to the given source file paths. For each
# source path, looks for:
#   1. An exact test file at tests/<basename-sans-ext>.bats (relative to
#      the project root derived from the config's project_path).
#   2. Glob matches: tests/*<basename-sans-ext>*.bats.
#   3. Test files already present in the source list (pass-through).
# Returns a deduplicated, newline-separated list of absolute test paths.
# Empty output means no tests discovered.
discover_story_tests() {
  local project_root="$1"
  shift
  # "$@" = list of source paths from the File List
  local found=""
  local seen=""
  for src in "$@"; do
    # If the path is already a test file, include it directly.
    case "$src" in
      *.bats|*.test.*|*_test.*|*_spec.*)
        local abs_test
        if [ "${src#/}" = "$src" ]; then
          abs_test="${project_root}/${src}"
        else
          abs_test="$src"
        fi
        if [ -f "$abs_test" ]; then
          case "$seen" in
            *"|${abs_test}|"*) ;;
            *)
              found="${found}${abs_test}
"
              seen="${seen}|${abs_test}|"
              ;;
          esac
        fi
        continue
        ;;
    esac

    local basename
    basename="$(printf '%s' "$src" | sed 's|.*/||')"
    local stem
    stem="$(printf '%s' "$basename" | sed 's/\.[^.]*$//')"

    # Resolve the directory structure. The project may have:
    #   src/foo.sh  -> tests/foo.bats
    #   scripts/bar.sh -> tests/bar.bats or tests/*bar*.bats
    local src_dir
    src_dir="$(printf '%s' "$src" | sed 's|/[^/]*$||')"
    # If src_dir == src (no slash), clear it.
    [ "$src_dir" != "$src" ] || src_dir=""

    # Strategy 1: tests/ sibling directory relative to project root.
    local search_base="${project_root}/tests"
    if [ -d "$search_base" ]; then
      # Exact match: tests/<stem>.bats
      if [ -f "${search_base}/${stem}.bats" ]; then
        local t="${search_base}/${stem}.bats"
        case "$seen" in
          *"|${t}|"*) ;;
          *) found="${found}${t}
"; seen="${seen}|${t}|" ;;
        esac
      fi
      # Glob match: tests/*<stem>*.bats (finds e.g. tests/qa-test-runner.bats
      # for stem=qa-test-runner).
      for t in "${search_base}/"*"${stem}"*.bats; do
        [ -f "$t" ] || continue
        case "$seen" in
          *"|${t}|"*) ;;
          *) found="${found}${t}
"; seen="${seen}|${t}|" ;;
        esac
      done
    fi

    # Strategy 2: tests/ directory adjacent to the source directory.
    if [ -n "$src_dir" ]; then
      local parent_test_dir="${project_root}/${src_dir}/../tests"
      if [ -d "$parent_test_dir" ]; then
        for t in "${parent_test_dir}/"*"${stem}"*.bats; do
          [ -f "$t" ] || continue
          local abs_t
          abs_t="$(cd "$(dirname "$t")" && pwd)/$(basename "$t")"
          case "$seen" in
            *"|${abs_t}|"*) ;;
            *) found="${found}${abs_t}
"; seen="${seen}|${abs_t}|" ;;
          esac
        done
      fi
    fi

    # Strategy 3: recursive find under tests/ for the stem.
    if [ -d "$search_base" ]; then
      while IFS= read -r t; do
        [ -f "$t" ] || continue
        case "$seen" in
          *"|${t}|"*) ;;
          *) found="${found}${t}
"; seen="${seen}|${t}|" ;;
        esac
      done <<EOF
$(find "$search_base" -name "*${stem}*.bats" -type f 2>/dev/null || true)
EOF
    fi
  done

  printf '%s' "$found"
}

# Decide whether a configured tier command runs the SAME test runner the
# story-scoped command uses (bats), and may therefore be narrowed to the
# story's own test files.
#
# Returns 0 (same runner → narrow) when the command invokes bats directly or
# through a project wrapper script whose name marks it as a bats runner —
# anywhere in the command, so a compound `cd … && ENV=… bash <wrapper>`
# invocation is recognized. Returns 1 (different runner → keep the tier's own
# command) otherwise, which is what preserves honest per-tier evidence for a
# tier configured with pytest / jest / eslint or any other runner.
_runs_same_runner() {
  local candidate="$1"
  # Normalize separators that can precede a command word so the token scan
  # below sees the runner as its own word: shell operators and path segments.
  local normalized
  normalized="$(printf '%s' "$candidate" | tr '&|;()/' '       ')"
  local word
  for word in $normalized; do
    case "$word" in
      # Direct invocation of the runner binary.
      bats) return 0 ;;
      # A project wrapper script that runs the bats suite. Matched on the
      # script's own basename so an env prefix or a `bash <path>` form is
      # recognized without widening the match to unrelated commands.
      *bats*.sh|run-tests.sh|run-with-coverage.sh|run-stack-tests.sh) return 0 ;;
    esac
  done
  return 1
}

# ---------- timeout helper (POSIX-portable) ----------

# Sanitize the environment for child processes so a nested bats invocation
# does not inherit the parent bats runner's internal state. The critical
# variable is PATH: the parent bats prepends BATS_LIBEXEC (its own libexec/
# directory) to PATH, making bare `bats` resolve to the internal
# libexec/bats-core/bats script instead of the bin/bats wrapper. That
# internal script calls the exported bash function `bats_readlinkf`, which
# is NOT propagated through dash (Ubuntu's /bin/sh) — so the nested bats
# exits 1. Restoring PATH from BATS_SAVED_PATH (the pre-bats PATH exported
# by bin/bats) makes `bats` resolve to the system-installed wrapper binary
# which bootstraps correctly.
_sanitize_bats_env() {
  if [ -n "${BATS_SAVED_PATH:-}" ]; then
    _RT_ORIG_PATH="$PATH"
    export PATH="$BATS_SAVED_PATH"
  elif [ -n "${BATS_LIBEXEC:-}" ]; then
    _RT_ORIG_PATH="$PATH"
    local _cleaned
    _cleaned="$(printf '%s' "$PATH" | awk -v drop="$BATS_LIBEXEC" '
      BEGIN { RS=":"; ORS="" }
      { if ($0 != drop) { if (NR>1 && printed) printf ":"; printf "%s", $0; printed=1 } }
    ')"
    export PATH="$_cleaned"
  fi
}

_restore_bats_env() {
  if [ -n "${_RT_ORIG_PATH:-}" ]; then
    export PATH="$_RT_ORIG_PATH"
    unset _RT_ORIG_PATH
  fi
}

# Project-root variables that must NOT reach the spawned suite. A caller
# session (an editor, an agent runtime, a wrapper script) commonly exports a
# project root; a suite that asserts canonical-path resolution then sees that
# ambient root instead of its own fixture root and reports failures that a
# clean CI checkout would never produce. The runner has already resolved
# everything it needs from the config by the time a tier command is spawned,
# so the child is given the environment CI would give it.
#
# `env -u NAME` is a no-op when NAME is unset, and is portable across BSD and
# GNU userland — no guard needed for variables the caller never set.
_RT_CLEAN_ENV_VARS="PROJECT_ROOT CLAUDE_PROJECT_ROOT PROJECT_PATH CLAUDE_PLUGIN_ROOT"

# Print the `env -u ...` prefix (argv words, space separated) used to spawn a
# tier command with the project-root variables cleared.
_clean_env_prefix_args() {
  local v
  printf 'env'
  for v in $_RT_CLEAN_ENV_VARS; do
    printf ' -u %s' "$v"
  done
}

# Run "$1" (full command string) with a wall-clock cap of "$2" seconds.
# Records into globals: RT_EXIT, RT_DURATION, RT_TIMEOUT, RT_OUTPUT.
run_with_timeout() {
  local cmd="$1" timeout_seconds="$2"
  local start_ns end_ns out_file
  out_file="$(mktemp 2>/dev/null || mktemp -t qatestrun)"

  # Prefer GNU/BSD `timeout` when present; fall back to perl alarm.
  start_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null \
              || awk 'BEGIN{srand(); print systime()}')"

  # Sanitize PATH so nested bats invocations resolve the wrapper binary, not
  # the internal libexec script (see _sanitize_bats_env header).
  _sanitize_bats_env
  # Clear the caller's project-root variables from the child environment on
  # BOTH spawn paths — a machine without `timeout` must not keep the leaky
  # behavior (see _RT_CLEAN_ENV_VARS header).
  local _clean_env
  _clean_env="$(_clean_env_prefix_args)"
  set +e
  if command -v timeout >/dev/null 2>&1; then
    # SC2086: _clean_env is a fixed, space-separated `env -u NAME` argv prefix
    # built by _clean_env_prefix_args — word splitting is intended here.
    # shellcheck disable=SC2086
    $_clean_env timeout --preserve-status "${timeout_seconds}" sh -c "$cmd" >"$out_file" 2>&1
    RT_EXIT=$?
  else
    # SC2086 as above. SC2016: the single-quoted block is perl source, not a
    # shell string — its `$SIG` / `$ARGV` sigils must reach perl unexpanded.
    # shellcheck disable=SC2086,SC2016
    $_clean_env perl -e '
      $SIG{ALRM}=sub{ kill(9, -$$); exit 124 };
      alarm($ARGV[0]);
      exec("/bin/sh","-c",$ARGV[1]);
    ' "$timeout_seconds" "$cmd" >"$out_file" 2>&1
    RT_EXIT=$?
  fi
  set -e
  _restore_bats_env

  end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null \
            || awk 'BEGIN{srand(); print systime()}')"
  RT_DURATION="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

  # `timeout` exits 124 on timeout; perl alarm path also returns 124.
  if [ "$RT_EXIT" = "124" ] || [ "$RT_EXIT" = "137" ] || [ "$RT_EXIT" = "143" ]; then
    RT_TIMEOUT=true
  else
    RT_TIMEOUT=false
  fi
  RT_OUTPUT_FILE="$out_file"
}

# ---------- bridge delegation ----------

run_bridge() {
  local run_tests_path="$1"
  if [ ! -x "$run_tests_path" ]; then
    info "bridge enabled but run_tests_path not executable: $run_tests_path — falling back to direct execution"
    return 1
  fi
  local start_ns end_ns out_file
  out_file="$(mktemp 2>/dev/null || mktemp -t qabridge)"
  start_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
  set +e
  "$run_tests_path" --story-key "$STORY_KEY" --context "$CONTEXT" >"$out_file" 2>&1
  local rc=$?
  set -e
  end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
  local dur
  dur="$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

  # Try to parse the bridge's stdout as JSON; fall back to a synthetic suite.
  if command -v jq >/dev/null 2>&1 && jq empty "$out_file" >/dev/null 2>&1; then
    BRIDGE_SUITES_JSON="$(jq -c '.suites // []' "$out_file" 2>/dev/null || printf '[]')"
  else
    BRIDGE_SUITES_JSON='[]'
  fi
  BRIDGE_EXIT="$rc"
  BRIDGE_DURATION="$dur"
  rm -f "$out_file"
  return 0
}

# ---------- main ----------

run_start_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"

# Detect bridge.
BRIDGE_ENABLED="$(yaml_get_bridge_field bridge_enabled || true)"
BRIDGE_PATH="$(yaml_get_bridge_field run_tests_path || true)"

# Detect test_execution presence.
TIER1_PLACEMENT="$(yaml_get_tier_field tier_1 placement || true)"
TIER2_PLACEMENT="$(yaml_get_tier_field tier_2 placement || true)"
TIER3_PLACEMENT="$(yaml_get_tier_field tier_3 placement || true)"

# JSON string escaper — bash 3.2 + awk only. Escapes backslash, double-quote,
# tab, CR, and joins multi-line input with literal "\n".
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

emit_skipped_evidence() {
  local reason="$1"
  cat > "$EVIDENCE" <<EOF
{
  "tier": "none",
  "context": $(json_str "$CONTEXT"),
  "wall_clock_seconds": 0,
  "skipped": true,
  "bridge_used": false,
  "suites": [],
  "diagnostics": [$(json_str "$reason")]
}
EOF
}

# Test execution absent — split path:
#   - bridge_enabled=true + no tier configured → HARD FAIL with actionable
#     error. The prior behavior emitted skip-green evidence even though the
#     operator had explicitly enabled the bridge — producing false-PASS test
#     reviews where tests never ran. This is the "silently defeats the gate"
#     defect class.
#   - bridge_enabled=false (or unset) + no tier configured → graceful
#     skip preserved (test execution is genuinely opt-in for this project).
if [ -z "$TIER1_PLACEMENT" ] && [ -z "$TIER2_PLACEMENT" ] && [ -z "$TIER3_PLACEMENT" ]; then
  if [ "$BRIDGE_ENABLED" = "true" ]; then
    err "Test Execution Bridge is ENABLED but test_execution tier_N.{placement,command} is not configured."
    err "  → Run: /gaia-config-test set tier_1.placement unit  &&  /gaia-config-test set tier_1.command 'python3 -m pytest tests/ -q'"
    err "  → Or:  /gaia-bridge-disable  (if you didn't mean to enable the bridge)"
    err "  → See: documentation/commands/gaia-bridge-enable.html (gap #3 — bridge wiring requirement)"
    emit_skipped_evidence "HARD FAIL: bridge enabled but no test_execution tier resolves"
    exit 1
  fi
  info "test_execution not configured; skipping test execution"
  emit_skipped_evidence "test_execution not configured; skipping test execution"
  exit 0
fi

# Build the list of tiers whose placement matches the active context.
ACTIVE_TIERS=()
ACTIVE_PLACEMENTS=()
for tier in tier_1 tier_2 tier_3; do
  case "$tier" in
    tier_1) plc="$TIER1_PLACEMENT" ;;
    tier_2) plc="$TIER2_PLACEMENT" ;;
    tier_3) plc="$TIER3_PLACEMENT" ;;
  esac
  if [ -n "$plc" ] && placement_matches_context "$plc" "$CONTEXT"; then
    ACTIVE_TIERS+=("$tier")
    ACTIVE_PLACEMENTS+=("$plc")
  fi
done

# No tier matched the context — INFO + skipped.
if [ "${#ACTIVE_TIERS[@]}" -eq 0 ]; then
  info "no test tier matches context '$CONTEXT'; skipping"
  emit_skipped_evidence "no test tier matches context '$CONTEXT'"
  exit 0
fi

# Bridge delegation — single bridge call covers all active tiers.
if [ "$BRIDGE_ENABLED" = "true" ] && [ -n "$BRIDGE_PATH" ]; then
  if run_bridge "$BRIDGE_PATH"; then
    # Build evidence from bridge response.
    run_end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
    wall="$(awk -v a="$run_start_ns" -v b="$run_end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"
    # Use the suites the bridge returned; if empty, synthesize one from the bridge exit.
    if [ "$BRIDGE_SUITES_JSON" = "[]" ] || [ -z "$BRIDGE_SUITES_JSON" ]; then
      BRIDGE_SUITES_JSON="$(printf '[{"name":"bridge","command":"%s","exit_code":%s,"duration_seconds":%s,"pass_count":0,"fail_count":0,"timeout":false,"required":true}]' \
        "$BRIDGE_PATH" "$BRIDGE_EXIT" "$BRIDGE_DURATION")"
    fi
    tier_label="bridge"
    cat > "$EVIDENCE" <<EOF
{
  "tier": $(json_str "$tier_label"),
  "context": $(json_str "$CONTEXT"),
  "wall_clock_seconds": $wall,
  "skipped": false,
  "bridge_used": true,
  "suites": $BRIDGE_SUITES_JSON,
  "diagnostics": []
}
EOF
    exit 0
  fi
fi

# ---------- story-scoped command resolution ----------
# When --story-file is provided and context is local, attempt to build a
# scoped test command from the story's File List. CI/promotion contexts
# always run the full-suite tier command.

SCOPED_TEST_CMD=""
if [ -n "$STORY_FILE" ] && [ "$CONTEXT" = "local" ]; then
  # Resolve project_path from the config (used as base for test discovery).
  _project_path="$(awk '
    /^project_path[[:space:]]*:/ {
      sub(/^project_path[[:space:]]*:[[:space:]]*/, "")
      sub(/[[:space:]]*$/, "")
      gsub(/"/, "")
      gsub(/'\''/, "")
      print
      exit
    }
  ' "$CONFIG")"
  [ -n "$_project_path" ] || _project_path="$(dirname "$CONFIG")"

  if [ -r "$STORY_FILE" ]; then
    _file_list="$(extract_story_file_list "$STORY_FILE" || true)"
    if [ -n "$(printf '%s' "$_file_list" | tr -d '[:space:]')" ]; then
      # Convert newline-separated list to positional args for discover_story_tests.
      _files=()
      while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        _files+=("$_line")
      done <<EOF
$_file_list
EOF
      if [ "${#_files[@]}" -gt 0 ]; then
        _test_paths="$(discover_story_tests "$_project_path" "${_files[@]}" || true)"
        if [ -n "$(printf '%s' "$_test_paths" | tr -d '[:space:]')" ]; then
          # Build a bats command from the discovered test files.
          _scoped_args=""
          while IFS= read -r _tp; do
            [ -n "$_tp" ] || continue
            if [ -n "$_scoped_args" ]; then
              _scoped_args="${_scoped_args} ${_tp}"
            else
              _scoped_args="$_tp"
            fi
          done <<EOF
$_test_paths
EOF
          SCOPED_TEST_CMD="bats ${_scoped_args}"
          # No announcement here — whether a scoped command is actually used
          # is a per-tier decision made below. Announcing it at discovery time
          # stated an intent that a fallback tier never honored.
        else
          info "no story-scoped tests discovered from File List; falling back to full-suite tier command"
        fi
      fi
    else
      info "no File List in story file; falling back to full-suite tier command"
    fi
  else
    info "story file not readable: $STORY_FILE; falling back to full-suite tier command"
  fi
fi

# Direct execution path — run each active tier with its own timeout.
SUITES_JSON_PARTS=()
for i in $(seq 0 $((${#ACTIVE_TIERS[@]} - 1))); do
  tier="${ACTIVE_TIERS[$i]}"
  cmd="$(yaml_get_tier_field "$tier" command || true)"
  to="$(yaml_get_tier_field "$tier" timeout_seconds || true)"
  required="$(yaml_get_tier_field "$tier" required || true)"
  [ -n "$to" ] || to=300
  [ -n "$required" ] || required=true
  if [ -z "$cmd" ]; then
    # No command declared for an active tier — record as skipped suite.
    suite_json="$(printf '{"name":%s,"command":"","exit_code":0,"duration_seconds":0,"pass_count":0,"fail_count":0,"timeout":false,"required":%s,"skip_reason":"no command declared"}' \
      "$(json_str "$tier")" "$required")"
    SUITES_JSON_PARTS+=("$suite_json")
    continue
  fi
  # Story-scoped substitution: narrow a full-suite bats tier to story-
  # relevant tests only. The scoped command is always "bats <files>", so a
  # tier is narrowed ONLY when its configured command genuinely runs the same
  # runner. Tiers that run a different runner (pytest, jest, eslint ...) keep
  # their own command unchanged — attributing a bats invocation to a tier that
  # configured "pytest ..." would produce misleading per-tier evidence.
  #
  # Same-runner detection is not limited to a command that STARTS with the
  # runner: a real tier command is frequently compound — a directory change,
  # an environment prefix, and a project wrapper script that ultimately calls
  # the same runner. Matching only the leading token left such a tier running
  # its full suite while the log announced a scoped run. The detection below
  # recognizes the runner anywhere in the command while still excluding a
  # genuinely different runner.
  _tier_narrowed=false
  if [ -n "$SCOPED_TEST_CMD" ] && _runs_same_runner "$cmd"; then
    cmd="$SCOPED_TEST_CMD"
    _tier_narrowed=true
  fi
  # Announce per tier, after the decision, so the log states what ran.
  if [ -n "$SCOPED_TEST_CMD" ]; then
    if [ "$_tier_narrowed" = "true" ]; then
      info "story-scoped test execution: ${cmd}"
    else
      info "$tier runs a different test runner; it keeps its own command: ${cmd}"
    fi
  fi
  run_with_timeout "$cmd" "$to"
  # Best-effort case-count parse from runner stdout/stderr before deleting
  # the output buffer (prior behavior recorded 1-per-suite counts even when
  # the real suite was 83 cases — producing misleading evidence in code
  # reviews). Common shapes:
  #   pytest:        "83 passed, 0 failed in 1.20s"
  #   jest/vitest:   "Tests: 1 failed, 12 passed, 13 total"
  #   bats:          "ok 12 ..." / "not ok 3 ..." (per-line)
  #   go test:       "PASS / FAIL" lines (suite-level — fall through to 1)
  # Failures to parse fall back to the legacy 1-per-suite shape.
  pass_count=0
  fail_count=0
  _case_parse_out=""
  if [ -f "$RT_OUTPUT_FILE" ]; then
    # Summary-line parse only — a summary runner prints its totals once, at
    # the end, so reading a bounded tail is both correct and cheap here. The
    # per-result tally below deliberately does NOT use this slice.
    _case_parse_out=$(tail -200 "$RT_OUTPUT_FILE" 2>/dev/null || true)
  fi
  # Summary-line runners: "<N> passed" / "<N> failed" — last match wins.
  _pytest_pass=$(printf '%s' "$_case_parse_out" | sed -nE 's/.*(^|[^[:digit:]])([[:digit:]]+) passed.*/\2/p' | tail -1)
  _pytest_fail=$(printf '%s' "$_case_parse_out" | sed -nE 's/.*(^|[^[:digit:]])([[:digit:]]+) failed.*/\2/p' | tail -1)
  if [ -n "$_pytest_pass" ] || [ -n "$_pytest_fail" ]; then
    pass_count=${_pytest_pass:-0}
    fail_count=${_pytest_fail:-0}
  else
    # Per-result tally — counted over the WHOLE captured stream, never a tail
    # slice. A large suite prints thousands of result lines and then a
    # trailing report; a fixed tail window would count the report instead of
    # the results and record counts that contradict the recorded exit code.
    # `grep -c` reads the file directly so a very large output never has to be
    # materialized into a shell variable, and exits 1 on zero matches (hence
    # the `|| true` guard under `set -e`).
    _bats_pass=0
    _bats_fail=0
    if [ -f "$RT_OUTPUT_FILE" ]; then
      _bats_pass=$(grep -cE '^ok [0-9]+' "$RT_OUTPUT_FILE" 2>/dev/null || true)
      _bats_fail=$(grep -cE '^not ok [0-9]+' "$RT_OUTPUT_FILE" 2>/dev/null || true)
    fi
    if [ "${_bats_pass:-0}" -gt 0 ] || [ "${_bats_fail:-0}" -gt 0 ]; then
      pass_count=${_bats_pass:-0}
      fail_count=${_bats_fail:-0}
    else
      # Final fallback — suite-level 1-per-suite (legacy shape).
      if [ "$RT_EXIT" -ne 0 ] && [ "$RT_TIMEOUT" = "false" ]; then
        fail_count=1
      elif [ "$RT_EXIT" -eq 0 ]; then
        pass_count=1
      fi
    fi
  fi
  rm -f "$RT_OUTPUT_FILE" || true
  suite_json="$(printf '{"name":%s,"command":%s,"exit_code":%s,"duration_seconds":%s,"pass_count":%s,"fail_count":%s,"timeout":%s,"required":%s}' \
    "$(json_str "$tier")" \
    "$(json_str "$cmd")" \
    "$RT_EXIT" \
    "$RT_DURATION" \
    "$pass_count" \
    "$fail_count" \
    "$RT_TIMEOUT" \
    "$required")"
  SUITES_JSON_PARTS+=("$suite_json")
done

# Wall clock.
run_end_ns="$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()' 2>/dev/null || date +%s)"
wall="$(awk -v a="$run_start_ns" -v b="$run_end_ns" 'BEGIN{ d=b-a; if (d<0) d=0; printf "%.3f", d }')"

# Resolve the "tier" top-level field — single-tier label, multi-tier "multi".
if [ "${#ACTIVE_TIERS[@]}" -eq 1 ]; then
  TIER_LABEL="${ACTIVE_TIERS[0]}"
else
  TIER_LABEL="multi"
fi

# Join suites JSON parts.
suites_json="["
for i in $(seq 0 $((${#SUITES_JSON_PARTS[@]} - 1))); do
  if [ "$i" -gt 0 ]; then suites_json="${suites_json},"; fi
  suites_json="${suites_json}${SUITES_JSON_PARTS[$i]}"
done
suites_json="${suites_json}]"

cat > "$EVIDENCE" <<EOF
{
  "tier": $(json_str "$TIER_LABEL"),
  "context": $(json_str "$CONTEXT"),
  "wall_clock_seconds": $wall,
  "skipped": false,
  "bridge_used": false,
  "suites": $suites_json,
  "diagnostics": []
}
EOF

exit 0
