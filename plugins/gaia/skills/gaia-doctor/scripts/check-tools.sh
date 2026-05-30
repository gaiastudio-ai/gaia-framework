#!/usr/bin/env bash
# gaia-doctor — check-tools.sh
#
# Deterministic preflight scanner. Reads the bundled tool-readiness registry,
# detects declared stacks from project-config.yaml (or detect-signals.sh in
# signal-only fallback), probes each applicable tool, and renders the Test10
# §7 readiness table + scan-tier verdict.
#
# Usage:
#   check-tools.sh [--json] [--stack NAME] [--project-root DIR]
#
# Exit codes:
#   0  always (this is a read-only diagnostic, not a gate)
#   1  argument / IO error
#
# Internal helper functions are underscore-prefixed per NFR-052.

set -euo pipefail
LC_ALL=C
export LC_ALL

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${SKILL_DIR}/knowledge/tool-readiness.json"

_die() {
  echo "gaia-doctor/check-tools: $*" >&2
  exit 1
}

_have() {
  command -v "$1" >/dev/null 2>&1
}

_host_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

# Default flags
JSON_OUT="false"
STACK_OVERRIDE=""
PROJECT_ROOT_ARG="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${GAIA_PROJECT_ROOT:-$PWD}}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --json)         JSON_OUT="true"; shift ;;
    --stack)        STACK_OVERRIDE="${2:-}"; shift 2 ;;
    --project-root) PROJECT_ROOT_ARG="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
gaia-doctor check-tools.sh — preflight readiness scan

Usage:
  $0 [--json] [--stack NAME] [--project-root DIR]

Flags:
  --json           Emit machine-readable JSON
  --stack NAME     Override stack auto-detect with a single named stack
  --project-root D Override project root (default: \$PROJECT_ROOT or skill-relative)
EOF
      exit 0
      ;;
    *) _die "unknown argument: $1" ;;
  esac
done

_have jq || _die "jq is required to read the readiness registry"
[ -r "$REGISTRY" ] || _die "registry not found at $REGISTRY"

#
# Stack detection
#
_detect_stacks() {
  local cfg="$PROJECT_ROOT_ARG/.gaia/config/project-config.yaml"
  local stacks=""

  if [ -n "$STACK_OVERRIDE" ]; then
    echo "$STACK_OVERRIDE"
    return 0
  fi

  if [ -r "$cfg" ] && _have yq; then
    # Best-effort yq read; tolerate missing stacks block.
    # AF-2026-05-30-4 / Test11 F-23: also accept `.name` and `.id` as the
    # stack identifier so config shapes like `{name: python, test_runner: pytest}`
    # (the Test11 repro) resolve correctly. Prior to this fix the reader
    # only looked at `.language`; the falsey fallthrough sent the resolver
    # to detect-signals, which on a Python-only repo returned [] and
    # check-tools then marked vulture/pip-audit/cyclonedx-bom as 'no
    # matching stack' even on Python projects. The accumulator unions
    # the three sources; downstream consumers see one canonical
    # whitespace-separated list.
    stacks="$(yq eval '.stacks[] | (.language // .name // .id // "")' "$cfg" 2>/dev/null | sed '/^$/d' | sort -u | tr '\n' ' ')"
  fi

  if [ -z "${stacks// /}" ]; then
    # Fallback: detect-signals.sh signal-only mode (no merge, no write).
    local detect="${SKILL_DIR}/../../scripts/detect-signals.sh"
    if [ -x "$detect" ]; then
      local sig_json
      sig_json="$(PROJECT_ROOT="$PROJECT_ROOT_ARG" "$detect" --project-root "$PROJECT_ROOT_ARG" --format json 2>/dev/null || true)"
      if [ -n "$sig_json" ]; then
        stacks="$(printf '%s' "$sig_json" | jq -r '.stacks[]?' 2>/dev/null | sort -u | tr '\n' ' ')"
      fi
    fi
  fi

  if [ -z "${stacks// /}" ]; then
    # Last resort: register a sentinel "any" so universal tools still probe.
    stacks="any"
  fi

  echo "$stacks"
}

#
# Tool applicability filter (stack-vs-applies_to_stacks intersection)
#
_tool_applies() {
  # $1 = tool id, $2..$N = detected stacks
  local tool="$1"; shift
  local stacks=("$@")
  local applies
  applies="$(jq -r --arg t "$tool" '.tools[$t].applies_to_stacks[]' "$REGISTRY" 2>/dev/null || true)"
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    if [ "$app" = "any" ]; then
      return 0
    fi
    for s in "${stacks[@]}"; do
      if [ "$s" = "$app" ]; then
        return 0
      fi
    done
  done <<< "$applies"
  return 1
}

#
# Probe one tool: returns "STATE|VERSION" (tab-free, pipe-separated).
# STATE in {present, missing, warning}
#
_probe_one() {
  local tool="$1"
  local probe ver_cmd min_ver env_warn
  probe="$(jq -r --arg t "$tool" '.tools[$t].probe_cmd // empty' "$REGISTRY")"
  ver_cmd="$(jq -r --arg t "$tool" '.tools[$t].version_cmd // empty' "$REGISTRY")"
  min_ver="$(jq -r --arg t "$tool" '.tools[$t].min_version // empty' "$REGISTRY")"
  env_warn="$(jq -r --arg t "$tool" '.tools[$t].environment_warning // empty' "$REGISTRY")"

  if [ -z "$probe" ]; then
    echo "missing|"
    return
  fi

  if ! bash -c "$probe" >/dev/null 2>&1; then
    echo "missing|"
    return
  fi

  local ver=""
  if [ -n "$ver_cmd" ]; then
    ver="$(bash -c "$ver_cmd" 2>/dev/null | head -n1 | tr -d '\r' || true)"
  fi

  # Bash environment-warning special case
  if [ "$tool" = "bash" ] && [ -n "$min_ver" ] && [ -n "$ver" ]; then
    local major
    major="${ver%%.*}"
    if [ -n "$major" ] && [ "$major" -lt 4 ] 2>/dev/null; then
      # AF-2026-05-30-4 / Test11 F-26: report as `outdated` (not just
      # `warning`) so install-tools.sh's missing-OR-outdated filter
      # picks it up and offers the upgrade command.
      echo "outdated|$ver"
      return
    fi
  fi

  echo "present|$ver"
}

#
# Render one stack block (plain-text).
#
_render_block() {
  local stack="$1"; shift
  local -a tool_ids=("$@")

  echo ""
  echo "GAIA deterministic tools — readiness for stack: $stack"

  local present_core=()
  for tid in "${tool_ids[@]}"; do
    local cat
    cat="$(jq -r --arg t "$tid" '.tools[$t].category' "$REGISTRY")"
    if [ "$cat" = "core" ]; then
      local state ver
      IFS='|' read -r state ver <<< "$(_probe_one "$tid")"
      if [ "$state" = "present" ]; then
        present_core+=("$tid")
      fi
    fi
  done
  if [ "${#present_core[@]}" -gt 0 ]; then
    echo "  ✓ $(IFS=,; echo "${present_core[*]}")            (core, present)"
  fi

  for tid in "${tool_ids[@]}"; do
    local cat desc state ver os install_cmd
    cat="$(jq -r --arg t "$tid" '.tools[$t].category' "$REGISTRY")"
    [ "$cat" = "core" ] && continue
    desc="$(jq -r --arg t "$tid" '.tools[$t].description' "$REGISTRY")"
    IFS='|' read -r state ver <<< "$(_probe_one "$tid")"
    os="$(_host_os)"
    install_cmd="$(jq -r --arg t "$tid" --arg o "$os" '.tools[$t].install[$o] // .tools[$t].install.macos // empty' "$REGISTRY")"

    case "$state" in
      present)
        printf "  ✓ %-14s %-40s (version: %s)\n" "$tid" "$desc" "${ver:-unknown}"
        ;;
      missing)
        printf "  ✗ %-14s %-40s →  %s\n" "$tid" "$desc" "${install_cmd:-#}"
        ;;
      warning|outdated)
        # AF-2026-05-30-4 / Test11 F-26: `outdated` rendered with the same
        # ⚠ glyph + environment-warning text as `warning`. The install-
        # tools.sh missing-OR-outdated filter picks `outdated` up while
        # check-tools.sh continues to display the row identically.
        local env_warn
        env_warn="$(jq -r --arg t "$tid" '.tools[$t].environment_warning // .tools[$t].description' "$REGISTRY")"
        printf "  ⚠ %-14s %-40s →  %s\n" "$tid" "$env_warn" "${install_cmd:-#}"
        ;;
    esac
  done

  # Surface not-applicable for diagnostic clarity (tools registered but stack out)
  local applicable_set=" $(printf '%s ' "${tool_ids[@]}")"
  while IFS= read -r other; do
    [ -z "$other" ] && continue
    case "$applicable_set" in
      *" $other "*) continue ;;
    esac
    local other_desc
    other_desc="$(jq -r --arg t "$other" '.tools[$t].description' "$REGISTRY")"
    printf "  – %-14s %-40s (not needed: no matching stack)\n" "$other" "$other_desc"
  done < <(jq -r '.tools | to_entries[] | select(.value.category != "core") | .key' "$REGISTRY")
}

#
# Tier verdict: highest fully-satisfied tier across applicable tools.
#
_compute_tier() {
  local -a tool_ids=("$@")
  local tier1_total=0 tier1_present=0
  local tier2_total=0 tier2_present=0
  local tier0_ok=1

  for tid in "${tool_ids[@]}"; do
    local tier state ver cat
    tier="$(jq -r --arg t "$tid" '.tools[$t].tier' "$REGISTRY")"
    cat="$(jq -r --arg t "$tid" '.tools[$t].category' "$REGISTRY")"
    IFS='|' read -r state ver <<< "$(_probe_one "$tid")"
    case "$tier" in
      0)
        if [ "$cat" = "core" ] && [ "$state" != "present" ]; then
          tier0_ok=0
        fi
        ;;
      1)
        tier1_total=$((tier1_total + 1))
        [ "$state" = "present" ] && tier1_present=$((tier1_present + 1))
        ;;
      2)
        tier2_total=$((tier2_total + 1))
        [ "$state" = "present" ] && tier2_present=$((tier2_present + 1))
        ;;
    esac
  done

  # AF-2026-05-30-4 / Test11 F-24: the prior gate required ALL tier-2 AND
  # ALL tier-1 tools present. On a real Python project that meant
  # installing grype + syft did not credit the tier even though the
  # operative tier-2 scanners were fully covered (sarif-multitool is
  # opt-in, pip tools are tier 1). The verdict dropped to TIER 0 —
  # defeating the whole point of --install. Promote when MAJORITY of
  # tier-2 scanners are present AND tier 0 core is intact; tier-1
  # coverage is reported in the reason but doesn't block the verdict.
  # Operators who want strict full-tier verdict can read .tier_reason in
  # --json and gate on it; the human-facing tier promotes once the
  # heavyweight scanners are actually invocable.
  if [ "$tier2_total" -gt 0 ] && [ "$tier2_present" -gt 0 ] && [ "$((tier2_present * 2))" -ge "$tier2_total" ] && [ "$tier0_ok" = "1" ]; then
    if [ "$tier2_present" -eq "$tier2_total" ] && [ "$tier1_present" -eq "$tier1_total" ]; then
      echo "2|all heavy/native tools present + all pure-pip tools present"
    else
      printf '2|%d/%d heavy/native tools present (%d/%d tier-1 tools also installed)\n' \
        "$tier2_present" "$tier2_total" "$tier1_present" "$tier1_total"
    fi
    return
  fi

  # AF-2026-05-30-3 / Test10 §7 C2 — docker runner promotion.
  # When brownfield.tools.runner == docker AND the gaia-tools image is
  # available locally, all Tier 2 tools are achievable via the bundled
  # image regardless of host-PATH presence. Promote the verdict so the
  # consolidated-gaps banner reflects the achievable fidelity.
  local _runner_helper="${SKILL_DIR}/../../scripts/lib/docker-runner.sh"
  if [ -f "$_runner_helper" ]; then
    local _runner_mode
    _runner_mode=$(bash "$_runner_helper" mode 2>/dev/null || echo native)
    if [ "$_runner_mode" = "docker" ] && bash "$_runner_helper" available >/dev/null 2>&1; then
      echo "2|via docker runner (gaia-tools image cached)"
      return
    fi
  fi

  # AF-2026-05-30-4 / Test11 F-24: also promote to TIER 1 when MOST
  # (>= half of applicable) tier-1 tools are present and tier 0 is intact.
  # Pure-strict ("all tier-1 present") was leaving operators at TIER 0 when
  # one pip install failed on a stock host (the F-22 macOS-pip class). Half-
  # majority captures "deterministic scanners are mostly working" without
  # over-promoting to "tier 1 = clean".
  if [ "$tier1_total" -gt 0 ] && [ "$tier1_present" -eq "$tier1_total" ] && [ "$tier0_ok" = "1" ]; then
    echo "1|all pure-pip tools present; heavy/native partial"
    return
  fi
  if [ "$tier1_total" -gt 0 ] && [ "$tier1_present" -gt 0 ] && [ "$((tier1_present * 2))" -ge "$tier1_total" ] && [ "$tier0_ok" = "1" ]; then
    printf '1|majority pure-pip tools present (%d/%d); heavy/native partial\n' \
      "$tier1_present" "$tier1_total"
    return
  fi
  echo "0|LLM-only (deterministic tools missing — heuristic fidelity)"
}

#
# JSON output mode
#
_render_json() {
  # $1 = stacks JSON array, remaining = tool ids
  local stacks_json="$1"; shift
  local -a tool_ids=("$@")
  local tier_line tier reason
  tier_line="$(_compute_tier "${tool_ids[@]}")"
  tier="${tier_line%%|*}"
  reason="${tier_line#*|}"

  local tools_json="[]"
  for tid in "${tool_ids[@]}"; do
    local state ver
    IFS='|' read -r state ver <<< "$(_probe_one "$tid")"
    tools_json="$(echo "$tools_json" | jq --arg id "$tid" --arg state "$state" --arg ver "$ver" \
      --argjson reg "$(jq --arg t "$tid" '.tools[$t]' "$REGISTRY")" \
      '. + [{id: $id, state: $state, version: $ver, registry: $reg}]')"
  done

  jq -n \
    --arg tier "$tier" \
    --arg reason "$reason" \
    --argjson stacks "$stacks_json" \
    --argjson tools "$tools_json" \
    '{stacks: $stacks, tier: ("tier-" + $tier), tier_reason: $reason, tools: $tools}'
}

#
# Main
#
main() {
  local stacks_str
  stacks_str="$(_detect_stacks)"
  read -r -a stacks <<< "$stacks_str"

  # Build applicable tool list
  local applicable=()
  while IFS= read -r tid; do
    [ -z "$tid" ] && continue
    if _tool_applies "$tid" "${stacks[@]}"; then
      applicable+=("$tid")
    fi
  done < <(jq -r '.tools | keys[]' "$REGISTRY")

  if [ "$JSON_OUT" = "true" ]; then
    local stacks_json
    stacks_json="$(printf '%s\n' "${stacks[@]}" | jq -R . | jq -s .)"
    _render_json "$stacks_json" "${applicable[@]}"
    return 0
  fi

  # Human-readable: one block per detected stack, tools are de-duplicated.
  for s in "${stacks[@]}"; do
    _render_block "$s" "${applicable[@]}"
  done

  # Summary + verdict
  local m=0 n=0
  for tid in "${applicable[@]}"; do
    local state ver
    IFS='|' read -r state ver <<< "$(_probe_one "$tid")"
    m=$((m + 1))
    [ "$state" = "present" ] && n=$((n + 1))
  done

  local tier_line tier reason
  tier_line="$(_compute_tier "${applicable[@]}")"
  tier="${tier_line%%|*}"
  reason="${tier_line#*|}"

  echo ""
  echo "Result: ${n}/${m} applicable tools available. CVE + SBOM + dead-code will fall back to LLM heuristics. Run gaia-doctor --install to fix, or proceed."
  echo "Achievable scan tier: TIER ${tier} (${reason})"
}

main
exit 0
