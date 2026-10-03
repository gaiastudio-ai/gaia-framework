#!/usr/bin/env bash
# verify-publication-target.sh — pre-write reference verification helper.
#
# Validates that the publication surface (designsync or artifact) matches
# the reference in the design record, that the caller has write access,
# and that the organisation/owner matches when --expected-owner is given.
#
# Public function:
#   verify_publication_target <surface> <reference> [flags]
#
# Surfaces:
#   designsync — JSON metadata with keys: type, canEdit, organization, reference
#   artifact   — text header with lines: type, access, owner, reference
#
# Flags:
#   --metadata-file PATH     — path to metadata file (required)
#   --design-record PATH     — path to design-record.yaml (required)
#   --expected-owner <owner> — expected organisation/owner (optional)
#
# Exit codes:
#   0 — target verified
#   1 — verification failed (with diagnostic on stderr)
#
# Bash 3.2 safe.

set -euo pipefail
LC_ALL=C; export LC_ALL

_vpt_die() { printf 'verify-publication-target.sh: %s\n' "$1" >&2; return 1; }

verify_publication_target() {
  local surface="${1:-}"
  local reference="${2:-}"
  shift 2 2>/dev/null || true

  local metadata_file="" design_record="" expected_owner=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --metadata-file)   metadata_file="$2";   shift 2 ;;
      --design-record)   design_record="$2";   shift 2 ;;
      --expected-owner)  expected_owner="$2";   shift 2 ;;
      *) _vpt_die "unknown option: $1"; return 1 ;;
    esac
  done

  [ -n "$surface" ]       || { _vpt_die "surface required (designsync | artifact)"; return 1; }
  [ -n "$reference" ]     || { _vpt_die "reference required"; return 1; }
  [ -n "$metadata_file" ] || { _vpt_die "--metadata-file required"; return 1; }
  [ -n "$design_record" ] || { _vpt_die "--design-record required"; return 1; }
  [ -f "$metadata_file" ] || { _vpt_die "metadata file not found: $metadata_file"; return 1; }
  [ -f "$design_record" ] || { _vpt_die "design record not found: $design_record"; return 1; }

  # Read design record to get expected references
  local dr_json
  dr_json="$(yq -o=json '.' "$design_record" 2>/dev/null)" || {
    _vpt_die "failed to parse design record: $design_record"; return 1
  }

  local ds_ref pd_ref
  local schema_version
  schema_version="$(printf '%s' "$dr_json" | jq -r '.schema_version | tostring')"
  case "$schema_version" in
    1.0|1)
      ds_ref="$(printf '%s' "$dr_json" | jq -r '.project.reference // empty')"
      pd_ref=""
      ;;
    *)
      ds_ref="$(printf '%s' "$dr_json" | jq -r '.design_system_project.reference // empty')"
      pd_ref="$(printf '%s' "$dr_json" | jq -r '.product_design_project.reference // empty')"
      ;;
  esac

  case "$surface" in
    designsync)
      _verify_designsync "$reference" "$metadata_file" "$expected_owner" "$ds_ref" "$pd_ref"
      ;;
    artifact)
      _verify_artifact "$reference" "$metadata_file" "$expected_owner" "$ds_ref" "$pd_ref"
      ;;
    *)
      _vpt_die "unknown surface: $surface (must be designsync or artifact)"
      return 1
      ;;
  esac
}

_verify_designsync() {
  local reference="$1" metadata_file="$2" expected_owner="$3"
  local ds_ref="$4" pd_ref="$5"

  local meta_json
  meta_json="$(jq '.' "$metadata_file" 2>/dev/null)" || {
    _vpt_die "failed to parse designsync metadata: $metadata_file"; return 1
  }

  # Type check: must be PROJECT_TYPE_DESIGN_SYSTEM
  local proj_type
  proj_type="$(printf '%s' "$meta_json" | jq -r '.type // empty')"
  if [ "$proj_type" != "PROJECT_TYPE_DESIGN_SYSTEM" ]; then
    _vpt_die "designsync type mismatch: expected PROJECT_TYPE_DESIGN_SYSTEM, got $proj_type"
    return 1
  fi

  # canEdit check
  local can_edit
  can_edit="$(printf '%s' "$meta_json" | jq -r '.canEdit // "false"')"
  if [ "$can_edit" != "true" ]; then
    _vpt_die "designsync canEdit is false — no write access"
    return 1
  fi

  # Fail closed: the design record MUST have a DS reference for designsync
  if [ -z "$ds_ref" ]; then
    _vpt_die "design_system_project.reference is not set in design record"
    return 1
  fi

  # Compare the reference in the metadata to the target reference (mandatory)
  local meta_ref
  meta_ref="$(printf '%s' "$meta_json" | jq -r '.reference // empty')"
  if [ -z "$meta_ref" ]; then
    _vpt_die "designsync metadata has no reference field — cannot verify target"
    return 1
  fi
  if [ "$meta_ref" != "$reference" ]; then
    _vpt_die "metadata reference ($meta_ref) does not match target reference ($reference)"
    return 1
  fi

  # Cross-wire detection: designsync surface should match DS reference, not PD
  if [ "$reference" != "$ds_ref" ]; then
    if [ -n "$pd_ref" ] && [ "$reference" = "$pd_ref" ]; then
      _vpt_die "cross-wire: designsync surface using product_design reference ($reference)"
      return 1
    fi
    _vpt_die "reference mismatch: designsync reference ($reference) does not match design_system_project.reference ($ds_ref)"
    return 1
  fi

  # Owner check
  if [ -n "$expected_owner" ]; then
    local actual_owner
    actual_owner="$(printf '%s' "$meta_json" | jq -r '.organization // empty')"
    if [ -z "$actual_owner" ]; then
      _vpt_die "expected owner $expected_owner but metadata has no organization field"
      return 1
    fi
    if [ "$actual_owner" != "$expected_owner" ]; then
      _vpt_die "owner mismatch: expected $expected_owner, got $actual_owner"
      return 1
    fi
  fi

  return 0
}

_verify_artifact() {
  local reference="$1" metadata_file="$2" expected_owner="$3"
  local ds_ref="$4" pd_ref="$5"

  # Parse text header — key: value lines
  local art_type="" art_access="" art_owner="" art_ref=""

  while IFS= read -r line; do
    case "$line" in
      type:*|Type:*|TYPE:*)
        art_type="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
        ;;
      access:*|Access:*|ACCESS:*)
        art_access="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
        ;;
      owner:*|Owner:*|OWNER:*)
        art_owner="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
        ;;
      reference:*|Reference:*|REFERENCE:*)
        art_ref="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
        ;;
    esac
  done < "$metadata_file"

  # Type check: must be exactly "Design" (case-insensitive), not "Design System"
  if [ -z "$art_type" ]; then
    _vpt_die "missing type line in Artifact header"
    return 1
  fi
  local art_type_lower
  art_type_lower="$(printf '%s' "$art_type" | tr '[:upper:]' '[:lower:]')"
  if [ "$art_type_lower" != "design" ]; then
    _vpt_die "Artifact type must be 'Design', got '$art_type'"
    return 1
  fi

  # Access check: must be "writer"
  if [ -z "$art_access" ]; then
    _vpt_die "missing access line in Artifact header"
    return 1
  fi
  local art_access_lower
  art_access_lower="$(printf '%s' "$art_access" | tr '[:upper:]' '[:lower:]')"
  if [ "$art_access_lower" != "writer" ]; then
    _vpt_die "Artifact access must be 'writer', got '$art_access'"
    return 1
  fi

  # Compare the reference in the Artifact header to the target reference (mandatory)
  if [ -z "$art_ref" ]; then
    _vpt_die "Artifact header has no reference line — cannot verify target"
    return 1
  fi
  if [ "$art_ref" != "$reference" ]; then
    _vpt_die "Artifact header reference ($art_ref) does not match target reference ($reference)"
    return 1
  fi

  # Fail closed: the design record MUST have a PD reference for artifact surface
  if [ -z "$pd_ref" ]; then
    _vpt_die "product_design_project.reference is not set in design record"
    return 1
  fi

  # Cross-wire detection: artifact surface should match PD reference, not DS
  if [ "$reference" != "$pd_ref" ]; then
    if [ -n "$ds_ref" ] && [ "$reference" = "$ds_ref" ]; then
      _vpt_die "cross-wire: artifact surface using design_system reference ($reference)"
      return 1
    fi
    _vpt_die "reference mismatch: artifact reference ($reference) does not match product_design_project.reference ($pd_ref)"
    return 1
  fi

  # Owner check
  if [ -n "$expected_owner" ]; then
    if [ -z "$art_owner" ]; then
      _vpt_die "expected owner $expected_owner but Artifact header has no owner field"
      return 1
    fi
    if [ "$art_owner" != "$expected_owner" ]; then
      _vpt_die "owner mismatch: expected $expected_owner, got $art_owner"
      return 1
    fi
  fi

  return 0
}

# Main guard: running the file directly invokes the public function.
# Does not fire when sourced (BASH_SOURCE[0] != $0) or via bash -c
# (BASH_SOURCE is empty or "bash").
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  verify_publication_target "$@"
fi
