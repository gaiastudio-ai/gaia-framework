#!/usr/bin/env bash
# close.sh — /gaia-sprint-close skill main orchestrator (E81-S5).
#
# Closes the active sprint:
#   1. Pre-conditions — retro doc present, idempotency check, all-done-or-force.
#   2. Yaml write — `yq -i '.status = "closed" | .closed_at = "<ISO>"'`.
#   3. Archive — copy yaml to .gaia/artifacts/implementation-artifacts/sprint-archive/.
#   4. Lifecycle event — append `sprint_closed` via lifecycle-event.sh.
#
# Per ADR-095 + AF-2026-05-11-7. Lifts the boundary-write restriction from
# feedback_sprint_boundary_yaml_write.md inside this script ONLY.
#
# The skill's separate `finalize.sh` is the generic plugin lifecycle hook
# (write checkpoint, emit `workflow_complete`); this script is the action.
#
# Refs: ADR-095, ADR-069 amendment AF-2026-05-11-7, E81-S5 ACs 1-7.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-sprint-close/close.sh"

# ---------- Path resolution ----------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"
LIFECYCLE_EVENT_SH="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

# PROJECT_PATH defaults to CWD; honor a pre-exported value (used by bats).
PROJECT_PATH="${PROJECT_PATH:-$PWD}"

# AF-2026-05-27-3 (ADR-111): .gaia/memory is the only memory tree; legacy
# _memory fallback removed. Env override wins.
if [ -z "${MEMORY_PATH:-}" ]; then
  MEMORY_PATH="$PROJECT_PATH/.gaia/memory"
fi
export PROJECT_PATH MEMORY_PATH

# Resolve sprint-status.yaml path.
# AF-2026-05-22-6 Bug-10: previously the resolver checked .gaia/state/ +
# docs/implementation-artifacts/ but NOT .gaia/artifacts/implementation-artifacts/
# (the canonical post-ADR-111 location where sprint-state.sh inject actually
# writes). Result: /gaia-sprint-close halted with "file not found at
# .gaia/state/sprint-status.yaml" even on a properly-initialized sprint.
# Resolution order (env override > .gaia/state/ > canonical .gaia/artifacts/
# > legacy docs/ > project-root fallback).
resolve_yaml_path() {
  if [ -n "${SPRINT_STATUS_YAML:-}" ]; then
    printf '%s\n' "$SPRINT_STATUS_YAML"
    return 0
  fi
  local gaia_state="$PROJECT_PATH/.gaia/state/sprint-status.yaml"
  local gaia_artifacts="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts/sprint-status.yaml"
  local legacy_docs="$PROJECT_PATH/docs/implementation-artifacts/sprint-status.yaml"
  local fallback="$PROJECT_PATH/sprint-status.yaml"
  if [ -f "$gaia_state" ]; then
    printf '%s\n' "$gaia_state"
  elif [ -f "$gaia_artifacts" ]; then
    printf '%s\n' "$gaia_artifacts"
  elif [ -f "$legacy_docs" ]; then
    printf '%s\n' "$legacy_docs"
  elif [ -f "$fallback" ]; then
    printf '%s\n' "$fallback"
  else
    # Default to .gaia/artifacts/ (canonical) instead of .gaia/state/ so the
    # file-not-found error points at the location sprint-state.sh inject
    # actually writes to (post-ADR-111 default).
    printf '%s\n' "$gaia_artifacts"
  fi
}

# E96-S8: smart-fallback for ART_DIR (implementation-artifacts root used for
# retro-glob + sprint-archive subdir).
if [ -d "$PROJECT_PATH/.gaia/artifacts/implementation-artifacts" ]; then
  ART_DIR="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
else
  ART_DIR="$PROJECT_PATH/docs/implementation-artifacts"
fi
ARCHIVE_DIR="$ART_DIR/sprint-archive"

# ---------- Helpers ----------

log()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()  { log "$*"; exit 1; }
warn() { log "$*"; }

# Read a top-level scalar YAML field from a file. Returns empty string if absent.
# Disables pipefail locally so a missing key produces an empty string cleanly
# under set -euo pipefail, not a propagated exit-1 from grep-no-match.
yaml_top_scalar() {
  local key="$1" path="$2"
  local line value
  set +o pipefail
  line=$(grep "^${key}:" "$path" 2>/dev/null | head -1)
  set -o pipefail
  [ -z "$line" ] && { printf ''; return 0; }
  value=$(printf '%s' "$line" | sed "s/^${key}:[[:space:]]*//" | tr -d '"')
  printf '%s' "$value"
}

# Enumerate stories[] from sprint-status.yaml as "key=status" pairs on stdout.
# Uses the same bash-regex pattern that sprint-state.sh cmd_detect_auto_close
# uses (lines 2095-2120) — no yq dependency for the parse path.
parse_stories() {
  local path="$1"
  local in_stories=false
  local s_key="" s_status=""
  _flush() {
    if [ -n "$s_key" ]; then
      printf '%s=%s\n' "$s_key" "$s_status"
    fi
    s_key=""; s_status=""
  }
  while IFS= read -r line; do
    if [[ "$line" =~ ^stories: ]]; then
      in_stories=true
      continue
    fi
    if [ "$in_stories" = true ]; then
      if [[ "$line" =~ ^[a-z_] ]]; then
        in_stories=false
        _flush
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*key:[[:space:]]* ]]; then
        _flush
        s_key=$(printf '%s' "$line" | sed 's/.*key:[[:space:]]*//' | tr -d '"')
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]+status:[[:space:]]* ]]; then
        s_status=$(printf '%s' "$line" | sed 's/.*status:[[:space:]]*//' | tr -d '"')
      fi
    fi
  done < "$path"
  if [ "$in_stories" = true ]; then
    _flush
  fi
}

# ISO 8601 UTC timestamp with seconds precision.
iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Date stamp for archive filename (YYYY-MM-DD). Override-able for tests.
close_date_stamp() {
  if [ -n "${GAIA_SPRINT_CLOSE_DATE:-}" ]; then
    printf '%s\n' "$GAIA_SPRINT_CLOSE_DATE"
  else
    date -u +"%Y-%m-%d"
  fi
}

# Render a bash array as a JSON array literal of double-quoted strings.
# Usage: json_string_array key1 key2 ...
# Empty input yields "[]".
json_string_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  printf '['
  local i first=1
  for i in "$@"; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '"%s"' "$i"
  done
  printf ']'
}

usage() {
  cat <<'USAGE' >&2
Usage:
  finalize.sh [--force-with-rollover <key1,key2,...>] [--help]

Closes the active sprint: writes status:closed + closed_at to sprint-status.yaml,
archives the yaml under docs/implementation-artifacts/sprint-archive/, and emits
a sprint_closed lifecycle event to .gaia/memory/lifecycle-events.jsonl.

Pre-conditions:
  - A retro doc must exist at docs/implementation-artifacts/retrospective-{sprint_id}-*.md
  - All stories must be `done`, OR --force-with-rollover must list exactly the non-done keys.
  - Sprint must not already be closed (idempotent re-close exits 0 with warning).

Refs: ADR-095, ADR-069 amendment AF-2026-05-11-7.
USAGE
}

# ---------- Argument parsing ----------

FORCE_ROLLOVER_RAW=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --force-with-rollover)
      [ "$#" -ge 2 ] || die "--force-with-rollover requires a comma-separated key list"
      FORCE_ROLLOVER_RAW="$2"
      shift 2
      ;;
    --force-with-rollover=*)
      FORCE_ROLLOVER_RAW="${1#--force-with-rollover=}"
      shift
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---------- Dependency check ----------

command -v yq >/dev/null 2>&1 || die "yq required (mikefarah v4); install via 'brew install yq' or equivalent"

YAML_PATH="$(resolve_yaml_path)"
[ -f "$YAML_PATH" ] || die "sprint-status.yaml not found at $YAML_PATH"

SPRINT_ID="$(yaml_top_scalar sprint_id "$YAML_PATH")"
[ -n "$SPRINT_ID" ] || die "sprint_id not found in $YAML_PATH"

# ---------- Step 2 — Idempotency short-circuit (AC7) ----------
# Done BEFORE retro check so already-closed sprints don't require an existing
# retro doc (AC7 doesn't require retro presence; only re-close idempotency).

current_status="$(yaml_top_scalar status "$YAML_PATH")"
if [ "$current_status" = "closed" ]; then
  existing_closed_at="$(yaml_top_scalar closed_at "$YAML_PATH")"
  warn "warning: sprint ${SPRINT_ID} already closed at ${existing_closed_at:-(unknown)}"
  exit 0
fi

# ---------- Step 1 — Pre-condition: retro doc exists (AC4) ----------

# Glob accepts both `retrospective-{id}-{date}.md` and
# `retrospective-{id}-{date}-{HHMM}.md` clobber-avoidance variants.
# E102-S6 / ADR-119: route through the shared three-tier resolver at
# `gaia-framework/plugins/gaia/scripts/lib/artifact-three-tier-resolve.sh`
# (env-var → legacy-flat-positive-evidence → canonical-nested-default)
# so both legacy `implementation-artifacts/retrospective-*.md` AND the new
# `implementation-artifacts/retrospective/retrospective-*.md` resolve.
SCRIPT_DIR_S6="$(cd "$(dirname "$0")" && pwd)"
RESOLVER_HELPER="${SCRIPT_DIR_S6}/../../../scripts/lib/artifact-three-tier-resolve.sh"

# Always search the existing $ART_DIR (the canonical location the existing
# tests + production wiring already pass in). When the new resolver is
# available, ALSO probe its result so the dual-path layout (legacy flat +
# canonical nested per ADR-119) is honored. Preserves backward-compat
# verbatim while adding new-layout support.
retro_match_count=$(find "$ART_DIR" -maxdepth 1 -type f \
  -name "retrospective-${SPRINT_ID}-*.md" 2>/dev/null | wc -l | tr -d ' ')

if [ "${retro_match_count:-0}" -eq 0 ] && [ -x "$RESOLVER_HELPER" ]; then
  resolver_dir="$(bash "$RESOLVER_HELPER" --family retro --id "$SPRINT_ID" --project-root "${PROJECT_PATH:-${PROJECT_ROOT:-$PWD}}" 2>/dev/null || true)"
  if [ -n "$resolver_dir" ] && [ -d "$resolver_dir" ] && [ "$resolver_dir" != "$ART_DIR" ]; then
    retro_match_count=$(find "$resolver_dir" -maxdepth 1 -type f \
      -name "retrospective-${SPRINT_ID}-*.md" 2>/dev/null | wc -l | tr -d ' ')
  fi
fi

if [ "${retro_match_count:-0}" -eq 0 ]; then
  die "error: retro doc not found for ${SPRINT_ID}; run /gaia-retro first"
fi

# ---------- Step 3 — Pre-condition: all-done or force (AC5, AC6) ----------

stories_done_count=0
stories_total_count=0
non_done_keys=()
while IFS='=' read -r k s; do
  [ -n "$k" ] || continue
  stories_total_count=$((stories_total_count + 1))
  if [ "$s" = "done" ]; then
    stories_done_count=$((stories_done_count + 1))
  else
    non_done_keys+=("$k")
  fi
done < <(parse_stories "$YAML_PATH")

# Build rollover key array from --force-with-rollover (comma-separated).
rollover_keys=()
if [ -n "$FORCE_ROLLOVER_RAW" ]; then
  IFS=',' read -r -a rollover_keys <<<"$FORCE_ROLLOVER_RAW"
fi

if [ "${#non_done_keys[@]}" -gt 0 ]; then
  if [ "${#rollover_keys[@]}" -eq 0 ]; then
    die "error: sprint ${SPRINT_ID} has non-done stories: ${non_done_keys[*]}; pass --force-with-rollover to proceed"
  fi
  # Validate the provided keys are exactly the non-done set (sorted comparison).
  expected_sorted=$(printf '%s\n' "${non_done_keys[@]}" | LC_ALL=C sort -u)
  provided_sorted=$(printf '%s\n' "${rollover_keys[@]}" | LC_ALL=C sort -u)
  if [ "$expected_sorted" != "$provided_sorted" ]; then
    die "error: --force-with-rollover key mismatch; non-done stories are: ${non_done_keys[*]}; got: ${rollover_keys[*]}"
  fi
elif [ "${#rollover_keys[@]}" -gt 0 ]; then
  # All stories done but caller passed rollover keys — refuse (mismatch).
  die "error: --force-with-rollover key mismatch; no non-done stories but got: ${rollover_keys[*]}"
fi

# ---------- Step 4 — Yaml write (AC1) ----------
# AF-2026-05-30-2 / Test10 F-31: route the status flip through
# sprint-state.sh transition (the sanctioned ADR-108 review→closed boundary
# writer) rather than direct yq -i. The yq path bypassed the transition
# validator and the lifecycle-event emit; routing through sprint-state.sh
# means a single audit trail covers all status changes. When sprint-state.sh
# is not available (e.g., legacy fixtures or tests), fall back to the
# legacy yq -i path with the closed_at write tacked on afterward.

CLOSED_AT="$(iso_now)"
SPRINT_STATE_SH="${SPRINT_STATE_SH:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../../../.." && pwd)}/plugins/gaia/scripts/sprint-state.sh}"

if [ -x "$SPRINT_STATE_SH" ]; then
  # AF-2026-06-01-1 / Test15 F-11 — capture stderr from sprint-state.sh so
  # we can tell "refused because review→closed needs a Val sentinel"
  # apart from "refused because the live yaml is not in review state"
  # (the legitimate active→closed legacy path). The prior implementation
  # swallowed BOTH refusals into the same `else` branch and then wrote
  # status=closed directly via yq -i — defeating the AF-31-3 F-13 Val
  # sentinel guard in sprint-state.sh entirely. Sprint-1 (status: review,
  # no /gaia-sprint-review ever run, no Val sentinel) closed cleanly via
  # this path. Now the fallback path is restricted to NON-review states
  # (e.g. active→closed); a review→closed refusal is FATAL with the
  # canonical "run /gaia-sprint-review first" guidance.
  _ss_stderr="$("$SPRINT_STATE_SH" transition --sprint "$SPRINT_ID" --to closed 2>&1 >/dev/null)"
  _ss_rc=$?
  if [ "$_ss_rc" -eq 0 ]; then
    # Stamp closed_at — sprint-state.sh's transition path doesn't set it.
    yq -i ".closed_at = \"${CLOSED_AT}\"" "$YAML_PATH" \
      || die "yq closed_at write failed on $YAML_PATH after sprint-state.sh transition"
  else
    # Detect the sentinel-refusal case via the canonical stderr substring
    # from the sprint-state.sh F-13 guard. When matched, REFUSE here too —
    # the close ceremony cannot proceed past the sentinel gate.
    case "$_ss_stderr" in
      *"refuse review→closed for sprint"*|*"run /gaia-sprint-review first"*)
        die "sprint-close refused: review→closed requires a Val sentinel. Run /gaia-sprint-review for sprint ${SPRINT_ID} first, OR set GAIA_ALLOW_SPRINT_REVIEW_TO_CLOSED_WITHOUT_SENTINEL=1 for the documented correct-course bypass. (sprint-state.sh stderr: ${_ss_stderr})"
        ;;
    esac
    # Refusal was NOT about the Val sentinel — fall back to direct yq for
    # the legacy non-review active→closed path the SKILL description
    # documents.
    yq -i ".status = \"closed\" | .closed_at = \"${CLOSED_AT}\"" "$YAML_PATH" \
      || die "yq write failed on $YAML_PATH"
  fi
else
  yq -i ".status = \"closed\" | .closed_at = \"${CLOSED_AT}\"" "$YAML_PATH" \
    || die "yq write failed on $YAML_PATH"
fi

# ---------- Step 5 — Archive (AC2) ----------

mkdir -p "$ARCHIVE_DIR"
ARCHIVE_PATH="$ARCHIVE_DIR/${SPRINT_ID}-closed-$(close_date_stamp).yaml"

# Build the rollover JSON array literal once — reused for both the archived
# yaml record and the lifecycle event data payload.
rollover_array="$(json_string_array "${rollover_keys[@]:-}")"
# Guard: json_string_array of an unset/empty array via the "[@]:-" idiom can
# inject a single empty argument on bash 3.2; normalize to "[]" if so.
[ "$rollover_array" = '[""]' ] && rollover_array='[]'

# If the operator passed --force-with-rollover, record the rollover list in
# the archived yaml (the live yaml stays clean — rollover is sprint-plan
# territory per E81-S6).
cp "$YAML_PATH" "$ARCHIVE_PATH"
if [ "${#rollover_keys[@]}" -gt 0 ]; then
  yq -i ".rollover_keys = ${rollover_array}" "$ARCHIVE_PATH" \
    || die "yq write of rollover_keys failed on $ARCHIVE_PATH"
fi

# ---------- Step 6 — Lifecycle event (AC3) ----------

# Source total_points from the yaml (already validated to exist).
total_points_raw="$(yaml_top_scalar total_points "$YAML_PATH")"
# Default to 0 if absent — keeps the JSON valid.
total_points="${total_points_raw:-0}"

# Compose data payload. Use printf to avoid shell-escaping landmines.
data_payload=$(printf '{"sprint_id":"%s","closed_at":"%s","total_points":%s,"stories_done":%s,"stories_rolled_over":%s,"rollover_target_sprint":null}' \
  "$SPRINT_ID" "$CLOSED_AT" "$total_points" "$stories_done_count" "$rollover_array")

if [ -x "$LIFECYCLE_EVENT_SH" ]; then
  "$LIFECYCLE_EVENT_SH" \
      --type sprint_closed \
      --workflow gaia-sprint-close \
      --data "$data_payload" \
    || die "lifecycle-event.sh failed for sprint ${SPRINT_ID} close"
else
  # Fallback: write JSONL line directly. Same nested-data schema as the helper.
  mkdir -p "$MEMORY_PATH"
  lc_file="$MEMORY_PATH/lifecycle-events.jsonl"
  ts="$(iso_now)"
  printf '{"timestamp":"%s","event_type":"sprint_closed","workflow":"gaia-sprint-close","pid":%d,"data":%s}\n' \
    "$ts" "$$" "$data_payload" >> "$lc_file"
fi

# ---------- Step 6b — Advisory checklist (ADR-120 / E103-S4) ----------
# Append a non-blocking "Lifecycle Skill Checklist (advisory)" section to the
# sprint-close summary, enumerating canonical artifact-producing skills and
# their on-disk state. Consumes the E103-S2 lifecycle-overrides helper for
# the [~] bypassed-row case. Non-blocking — never affects exit status.

LIFECYCLE_LIB_S4="$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/lifecycle-overrides.sh"
SUMMARY_FILE="${ARCHIVE_PATH%.yaml}-close-summary.md"

# Resolve sprint-scoped bypasses (defensive against helper absence).
bypass_json='{"bypasses":[]}'
if [ -f "$LIFECYCLE_LIB_S4" ]; then
  bypass_json="$(bash "$LIFECYCLE_LIB_S4" read --sprint-id "$SPRINT_ID" 2>/dev/null || echo '{"bypasses":[]}')"
fi

# Canonical skill → artifact map. Each entry: skill|artifact-path-relative-to-.gaia/artifacts
declare -a SKILL_ARTIFACT_MAP=(
  "gaia-trace|test-artifacts/traceability-matrix.md"
  "gaia-readiness-check|../state/readiness-check-ledger.yaml"
  "gaia-threat-model|planning-artifacts/threat-model.md"
  "gaia-create-prd|planning-artifacts/prd.md"
  "gaia-create-arch|planning-artifacts/architecture.md"
  "gaia-create-epics|planning-artifacts/epics-and-stories.md"
  "gaia-test-strategy|test-artifacts/test-plan.md"
)

ART_BASE="${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}"
checklist_tmp="$(mktemp)"
missing_count=0
bypass_count=0
present_count=0
{
  printf '\n## Lifecycle Skill Checklist (advisory)\n\n'
  for row in "${SKILL_ARTIFACT_MAP[@]}"; do
    skill="${row%%|*}"
    relpath="${row##*|}"
    artpath="$ART_BASE/$relpath"
    is_bypassed=0
    if printf '%s' "$bypass_json" | jq -e --arg s "$skill" '.bypasses | any(.skill == $s or .skill == ("/" + $s))' >/dev/null 2>&1; then
      is_bypassed=1
    fi
    if [ "$is_bypassed" -eq 1 ]; then
      reason="$(printf '%s' "$bypass_json" | jq -r --arg s "$skill" '[.bypasses[] | select(.skill == $s or .skill == ("/" + $s))][0].reason')"
      printf -- '- [~] %s — bypassed: %s\n' "$skill" "$reason"
      bypass_count=$((bypass_count + 1))
    elif [ -f "$artpath" ]; then
      printf -- '- [x] %s — %s present\n' "$skill" "$relpath"
      present_count=$((present_count + 1))
    else
      printf -- '- [ ] %s — %s MISSING (no bypass recorded)\n' "$skill" "$relpath"
      missing_count=$((missing_count + 1))
    fi
  done
  if [ "$missing_count" -eq 0 ] && [ "$bypass_count" -eq 0 ]; then
    printf '\nAll lifecycle skills produced their canonical artifacts; no bypasses recorded for %s.\n' "$SPRINT_ID"
  fi
} > "$checklist_tmp"

# Append to summary file (create if absent).
if [ ! -f "$SUMMARY_FILE" ]; then
  printf '# Sprint %s close summary\n\nClosed at %s.\n' "$SPRINT_ID" "$CLOSED_AT" > "$SUMMARY_FILE"
fi
cat "$checklist_tmp" >> "$SUMMARY_FILE"
rm -f "$checklist_tmp"

# ---------- Step 7 — Confirmation ----------

printf 'sprint %s closed at %s; archive: %s; lifecycle event recorded\n' \
  "$SPRINT_ID" "$CLOSED_AT" "$ARCHIVE_PATH"

exit 0
