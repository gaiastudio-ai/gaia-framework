#!/usr/bin/env bash
# sprint-status-dashboard.sh — deterministic sprint status dashboard formatter (E28-S61)
#
# Reads sprint-status.yaml (located at ${PROJECT_PATH}/docs/implementation-artifacts/
# sprint-status.yaml) and renders a plain-text dashboard table to stdout. This script
# is the read-only rendering peer to sprint-state.sh (E28-S11) — it NEVER opens
# sprint-status.yaml for write under any code path.
#
# Refs: FR-323, FR-325, NFR-048, NFR-053, ADR-041, ADR-042
# Brief: P8-S2 (docs/creative-artifacts/gaia-native-conversion-feature-brief-2026-04-14.md)
#
# Invocation:
#   sprint-status-dashboard.sh [--help]
#
# Environment:
#   PROJECT_PATH  — root of the project (defaults to ".")
#
# Exit codes:
#   0 — dashboard rendered successfully
#   1 — sprint-status.yaml not found, parse error, or missing dependencies
#
# POSIX discipline: bash with set -euo pipefail. macOS /bin/bash 3.2 compatible.
# READ-ONLY: This script NEVER writes to sprint-status.yaml. It opens the file
# with read access only and produces output exclusively on stdout.

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="sprint-status-dashboard.sh"

# ---------- Help ----------
if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
sprint-status-dashboard.sh — render sprint status dashboard from sprint-status.yaml

Usage: sprint-status-dashboard.sh [--help]

Environment:
  PROJECT_PATH  Root of the project (default: ".")

Reads sprint-status.yaml and renders a deterministic plain-text dashboard to stdout.
This script is read-only — it NEVER modifies sprint-status.yaml.
USAGE
  exit 0
fi

# ---------- Resolve paths ----------
PROJECT_PATH="${PROJECT_PATH:-.}"
# Canonical yaml location. Honor pre-exported SPRINT_STATUS_YAML (E38-S1) so
# bats fixtures that place the yaml at the project-path root can be used
# without restructuring the fixture tree.
YAML_PATH="${SPRINT_STATUS_YAML:-}"
if [[ -z "$YAML_PATH" ]]; then
  CANONICAL_YAML="$PROJECT_PATH/docs/implementation-artifacts/sprint-status.yaml"
  FALLBACK_YAML="$PROJECT_PATH/sprint-status.yaml"
  if [[ -f "$CANONICAL_YAML" ]]; then
    YAML_PATH="$CANONICAL_YAML"
  elif [[ -f "$FALLBACK_YAML" ]]; then
    YAML_PATH="$FALLBACK_YAML"
  else
    YAML_PATH="$CANONICAL_YAML"
  fi
fi

# Implementation-artifacts directory — used to locate story files for
# risk-surfacing frontmatter lookup (E38-S1).
IMPLEMENTATION_ARTIFACTS="${IMPLEMENTATION_ARTIFACTS:-$PROJECT_PATH/docs/implementation-artifacts}"

# Mitigation catalog path (E38-S1, ADR-055 FR-SPQG-5). Defaults to the
# plugin-bundled catalog sibling to this script. Honors an env override so
# tests or alternate bundles can point at a different file.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MITIGATION_CATALOG="${MITIGATION_CATALOG:-$SCRIPT_DIR/../skills/gaia-sprint-status/mitigation-catalog.yaml}"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------- Validate input ----------
if [[ ! -f "$YAML_PATH" ]]; then
  die "sprint-status.yaml not found at $YAML_PATH"
fi

# ---------- Check dependencies ----------
# We use grep/sed/awk for pure-bash parsing (no yq dependency required).
# Validate the file is parseable YAML by checking for the sprint_id key.
if ! grep -q "^sprint_id:" "$YAML_PATH" 2>/dev/null; then
  die "malformed or empty sprint-status.yaml — missing sprint_id key"
fi

# ---------- Parse header fields ----------
# Helper: extract a top-level YAML scalar. Returns empty string if key is absent.
yaml_val() {
  grep "^${1}:" "$YAML_PATH" 2>/dev/null | sed "s/^${1}:[[:space:]]*//" | tr -d '"' || true
}

sprint_id=$(yaml_val sprint_id)
duration=$(yaml_val duration)
velocity=$(yaml_val velocity_capacity)
total_points=$(yaml_val total_points)
started=$(yaml_val started)
end_date=$(yaml_val end_date)
capacity_util=$(yaml_val capacity_utilization)
epic_focus=$(yaml_val epic_focus)

# ---------- Load mitigation catalog (E38-S1, FR-SPQG-5) ----------
# The catalog is a YAML file with a `mitigations:` array, each entry having
# `id`, `label`, and `description`. We extract labels for inline annotation.
# Missing or empty catalog → degrade gracefully with a warning, do not halt.
catalog_labels=()
catalog_missing=false
catalog_warning=""
if [[ ! -s "$MITIGATION_CATALOG" ]]; then
  catalog_missing=true
  catalog_warning="WARNING: mitigation catalog not found at $MITIGATION_CATALOG — risk surfacing degraded"
else
  # Parse `label: "..."` lines under the `mitigations:` section.
  while IFS= read -r label_line; do
    [[ -n "$label_line" ]] && catalog_labels+=("$label_line")
  done < <(awk '
    BEGIN { in_mitigations = 0 }
    /^mitigations:/ { in_mitigations = 1; next }
    in_mitigations && /^[^[:space:]#-]/ { in_mitigations = 0 }
    in_mitigations && /^[[:space:]]+label:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]+label:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print v
    }
  ' "$MITIGATION_CATALOG")
  if [[ ${#catalog_labels[@]} -eq 0 ]]; then
    catalog_missing=true
    catalog_warning="WARNING: mitigation catalog empty at $MITIGATION_CATALOG — risk surfacing degraded"
  fi
fi

# ---------- Story risk lookup helper ----------
# Given a story key, locate its story file under IMPLEMENTATION_ARTIFACTS and
# read the `risk:` frontmatter field. Returns the lowercased risk value to
# stdout ("high", "medium", "low", "") — empty string when the story file is
# missing, unreadable, or has no risk field. Case-insensitive glob so bats
# fixtures with lowercase {slug}-story.md filenames match upper-cased keys.
story_risk() {
  local key="$1"
  local matches=()
  shopt -s nullglob nocaseglob
  # shellcheck disable=SC2206
  matches=( "${IMPLEMENTATION_ARTIFACTS}/${key}-"*.md "${IMPLEMENTATION_ARTIFACTS}"/epic-*/stories/"${key}-"*.md )
  shopt -u nullglob nocaseglob
  [[ ${#matches[@]} -eq 0 ]] && return 0
  local story_file="${matches[0]}"
  [[ -r "$story_file" ]] || return 0
  awk '
    BEGIN { in_fm = 0; seen = 0 }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm && /^[[:space:]]*risk:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]*risk:[[:space:]]*/, "", v)
      gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
      print tolower(v)
      exit
    }
  ' "$story_file"
}

# ---------- Render header ----------
printf '=%.0s' {1..72}; printf '\n'
printf '  SPRINT STATUS DASHBOARD\n'
printf '=%.0s' {1..72}; printf '\n'
printf '  Sprint:     %s\n' "${sprint_id:-N/A}"
printf '  Duration:   %s\n' "${duration:-N/A}"
printf '  Dates:      %s → %s\n' "${started:-N/A}" "${end_date:-N/A}"
printf '  Velocity:   %s pts (capacity: %s)\n' "${total_points:-0}" "${velocity:-N/A}"
if [[ -n "$capacity_util" ]]; then
  printf '  Utilization: %s\n' "$capacity_util"
fi
if [[ -n "$epic_focus" ]]; then
  printf '  Focus:      %s\n' "$epic_focus"
fi
printf -- '-%.0s' {1..72}; printf '\n'

# ---------- Sprint auto-close banner (E81-S3, AC2) ----------
#
# Advisory banner — fires when every story under the active sprint has
# status=done. Detection is delegated to `sprint-state.sh detect-auto-close`
# so the rule is centralized (per E81-S3 Dev Notes — reusable beyond this
# dashboard). When detection returns empty stdout, the banner is suppressed.
#
# READ-ONLY: this block never mutates sprint-status.yaml. The boundary write
# (flipping status:closed and seeding the next sprint) remains a manual
# operator action per feedback_sprint_boundary_yaml_write.md — the banner
# only signals intent, never acts.
auto_close_json=""
SPRINT_STATE_SCRIPT="$SCRIPT_DIR/sprint-state.sh"
if [[ -x "$SPRINT_STATE_SCRIPT" ]]; then
  # Inherit the same SPRINT_STATUS_YAML / PROJECT_PATH the dashboard
  # already resolved so the subcommand reads the identical file. Errors are
  # swallowed (advisory only) — never block the dashboard.
  auto_close_json=$(SPRINT_STATUS_YAML="$YAML_PATH" \
    PROJECT_PATH="$PROJECT_PATH" \
    "$SPRINT_STATE_SCRIPT" detect-auto-close 2>/dev/null || true)
fi
if [[ -n "$auto_close_json" ]]; then
  # Parse the four canonical fields. We avoid a jq dependency — bats
  # environments don't always have it — and the JSON shape is fixed
  # (single-line, four keys). Use bash regex to pull each value.
  ac_sprint_id=""
  ac_done=""
  ac_total=""
  ac_end_date=""
  if [[ "$auto_close_json" =~ \"sprint_id\":\"([^\"]*)\" ]]; then
    ac_sprint_id="${BASH_REMATCH[1]}"
  fi
  if [[ "$auto_close_json" =~ \"done\":([0-9]+) ]]; then
    ac_done="${BASH_REMATCH[1]}"
  fi
  if [[ "$auto_close_json" =~ \"total\":([0-9]+) ]]; then
    ac_total="${BASH_REMATCH[1]}"
  fi
  if [[ "$auto_close_json" =~ \"end_date\":\"([^\"]*)\" ]]; then
    ac_end_date="${BASH_REMATCH[1]}"
  fi
  printf '  [SPRINT AUTO-CLOSE] %s — %s/%s stories done (end_date: %s)\n' \
    "${ac_sprint_id:-?}" "${ac_done:-?}" "${ac_total:-?}" "${ac_end_date:-(unset)}"
  printf '    Every story under this sprint is done, but sprint-status.yaml\n'
  printf '    still reads status: active. Boundary write is overdue.\n'
  printf '    Remediation (manual operator action — never auto-flipped):\n'
  printf '      yq -i %s.status = \"closed\"%s docs/implementation-artifacts/sprint-status.yaml\n' "'" "'"
  printf '    Then seed the next sprint per feedback_sprint_boundary_yaml_write.md.\n'
  printf -- '-%.0s' {1..72}; printf '\n'
fi

# ---------- Parse stories ----------
# Extract story blocks from the YAML. Each story starts with "  - key:" under stories:.
# Pure-bash approach: read lines after "stories:" and parse key/value pairs per block.

in_stories=false
story_count=0

# Column headers
printf '  %-12s %-38s %-14s %s\n' "Story" "Title" "Status" "Pts"
printf '  %-12s %-38s %-14s %s\n' "-----" "-----" "------" "---"

# Track story data
s_key="" s_title="" s_status="" s_points=""

high_risk_story_count=0

flush_story() {
  if [[ -n "$s_key" ]]; then
    # Truncate title to 36 chars
    local display_title="$s_title"
    if [[ ${#display_title} -gt 36 ]]; then
      display_title="${display_title:0:33}..."
    fi
    printf '  %-12s %-38s %-14s %s' "$s_key" "$display_title" "$s_status" "$s_points"

    # Risk-surfacing annotation (E38-S1, FR-SPQG-5) — inline mitigation label
    # for HIGH-risk stories. Suppressed entirely when the catalog is missing
    # or empty (AC-EC6 degrades gracefully); rendered verbatim from catalog
    # to preserve unknown/new entries (AC-EC7).
    local risk
    risk="$(story_risk "$s_key")"
    if [[ "$risk" == "high" ]]; then
      high_risk_story_count=$((high_risk_story_count + 1))
      if [[ "$catalog_missing" != true ]] && [[ ${#catalog_labels[@]} -gt 0 ]]; then
        # Rotate through catalog labels to surface variety across stories.
        local idx=$(( (high_risk_story_count - 1) % ${#catalog_labels[@]} ))
        printf '  [HIGH-risk: mitigation — %s]' "${catalog_labels[$idx]}"
      fi
    fi
    printf '\n'
    story_count=$((story_count + 1))
  fi
  s_key="" s_title="" s_status="" s_points=""
}

while IFS= read -r line; do
  # Detect the stories: key
  if [[ "$line" =~ ^stories: ]]; then
    in_stories=true
    continue
  fi

  if [[ "$in_stories" == true ]]; then
    # A new top-level key (not indented) ends the stories block
    if [[ "$line" =~ ^[a-z_] ]]; then
      in_stories=false
      flush_story
      continue
    fi

    # New story block starts with "  - key:"
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*key:[[:space:]]* ]]; then
      flush_story
      s_key=$(echo "$line" | sed 's/.*key:[[:space:]]*//' | tr -d '"')
      continue
    fi

    # Parse fields within a story block
    if [[ "$line" =~ ^[[:space:]]+title:[[:space:]]* ]]; then
      s_title=$(echo "$line" | sed 's/.*title:[[:space:]]*//' | tr -d '"')
    elif [[ "$line" =~ ^[[:space:]]+status:[[:space:]]* ]]; then
      s_status=$(echo "$line" | sed 's/.*status:[[:space:]]*//' | tr -d '"')
    elif [[ "$line" =~ ^[[:space:]]+points:[[:space:]]* ]]; then
      s_points=$(echo "$line" | sed 's/.*points:[[:space:]]*//' | tr -d '"')
    fi
  fi
done < "$YAML_PATH"

# Flush last story if still in stories block
if [[ "$in_stories" == true ]]; then
  flush_story
fi

# ---------- Footer ----------
printf -- '-%.0s' {1..72}; printf '\n'
printf '  Total: %d stories | %s points\n' "$story_count" "${total_points:-0}"

# Risk-surfacing block (E38-S1, FR-SPQG-5).
# When the current sprint contains at least one HIGH-risk story, list every
# mitigation catalog entry verbatim so reviewers see the full set of
# suggested mitigations (AC5, AC-EC7 — unknown entries are rendered
# verbatim without enum validation). When no HIGH-risk stories exist the
# block is suppressed entirely (AC6 — clean output, no-op default).
# When the catalog is missing or empty, emit the warning line (AC-EC6).
if [[ "$high_risk_story_count" -gt 0 ]]; then
  if [[ "$catalog_missing" == true ]]; then
    printf '  %s\n' "$catalog_warning"
  else
    printf '  Recommended mitigations for HIGH-risk stories:\n'
    label_iter=""
    for label_iter in "${catalog_labels[@]}"; do
      printf '    - %s\n' "$label_iter"
    done
    # Also surface raw ids so AC-EC7 can assert either `label` or `id`
    # shows up verbatim when a reviewer extends the catalog with a
    # never-before-cataloged mitigation.
    while IFS= read -r id_line; do
      [[ -n "$id_line" ]] && printf '      (id: %s)\n' "$id_line"
    done < <(awk '
      BEGIN { in_mitigations = 0 }
      /^mitigations:/ { in_mitigations = 1; next }
      in_mitigations && /^[^[:space:]#-]/ { in_mitigations = 0 }
      in_mitigations && /^[[:space:]]+-[[:space:]]+id:[[:space:]]*/ {
        v = $0
        sub(/^[[:space:]]+-[[:space:]]+id:[[:space:]]*/, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        print v
      }
    ' "$MITIGATION_CATALOG")
  fi
fi
printf '=%.0s' {1..72}; printf '\n'

exit 0
