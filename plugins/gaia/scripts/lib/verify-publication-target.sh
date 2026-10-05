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
#
#   designsync — --metadata-file is a JSON object the CALLER writes:
#       {"projectId": "<id passed to get_project>",
#        "project": <raw get_project response>}
#     The raw get_project response has the shape:
#       {"method":"get_project","projectId":"<uuid>","name":"...","type":"PROJECT_TYPE_DESIGN_SYSTEM","ownerDisplayName":"...","canEdit":true}
#     The verifier requires:
#       - Outer projectId present, non-empty, and equal to <reference>
#       - project.projectId present and equal to the outer projectId
#         (the inner id is the response's own echo of the id; its absence
#         or a mismatch means the response does not describe the project
#         the caller asked for)
#       - project.type == PROJECT_TYPE_DESIGN_SYSTEM
#       - project.canEdit == true (strict boolean, not string "true")
#     Owner check (only when --expected-owner is given):
#       - project.ownerDisplayName must be present and equal to the expected
#         value. The old "owner" field is not used; a response that carries
#         only "owner" (no ownerDisplayName) fails the owner check.
#     Fail closed on anything else. The get_project response itself
#     does NOT contain a reference field — do not expect one.
#
#   artifact — --metadata-file is a text file the CALLER writes:
#     Line 1: "reference: <URL the caller read>"
#     Remaining lines: the verbatim header lines the caller received from
#     (a) the page read and (b) the per-file read of the same artifact.
#     The per-file-read header has the form:
#       Files saved under "..." from version <v> of <URL>, an Artifact of type "<T>".
#     The page-read header starts with "[Artifact " and contains "— owned by you"
#     (em dash) when the caller has write access.
#     The verifier requires:
#       - first reference: line present on line 1 and equal to <reference>
#       - exactly one per-file-read header whose URL matches <reference>
#         exactly (not a prefix) and whose type is exactly "Design"
#       - exactly one page-read header containing the "owned by you" proof
#       - --expected-owner fails closed: real Artifact reads report no named
#         owner, only "owned by you", so a named owner check is impossible
#     A file that carries only the old type/access/owner key-value lines
#     (no real header lines) fails.
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

  # Fail closed: require exactly one JSON object (reject concatenated values,
  # arrays, strings, or empty files).
  if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$metadata_file" >/dev/null 2>&1; then
    _vpt_die "designsync metadata must be exactly one JSON object"
    return 1
  fi

  # The metadata file is a wrapper: {"projectId": "...", "project": {...}}
  # Require the projectId field and match it against the reference.
  # Compare via jq --arg to avoid trailing-newline mismatches.
  local project_id
  project_id="$(printf '%s' "$meta_json" | jq -r '.projectId // empty')"
  if [ -z "$project_id" ]; then
    _vpt_die "designsync metadata missing projectId — raw get_project response not accepted"
    return 1
  fi
  # Compare via jq --arg so a trailing newline cannot match
  if ! printf '%s' "$meta_json" | jq -e --arg ref "$reference" '.projectId == $ref' >/dev/null 2>&1; then
    _vpt_die "designsync projectId ($project_id) does not match target reference ($reference)"
    return 1
  fi

  # Inner cross-check: the raw response echoes the project id back as
  # project.projectId. It must be present and equal to the outer projectId.
  local inner_id
  inner_id="$(printf '%s' "$meta_json" | jq -r '.project.projectId // empty')"
  if [ -z "$inner_id" ]; then
    _vpt_die "designsync response missing project.projectId — cannot confirm the response describes the requested project"
    return 1
  fi
  if ! printf '%s' "$meta_json" | jq -e --arg ref "$project_id" '.project.projectId == $ref' >/dev/null 2>&1; then
    _vpt_die "designsync project.projectId ($inner_id) does not match outer projectId ($project_id)"
    return 1
  fi

  # Type check: project.type must be PROJECT_TYPE_DESIGN_SYSTEM
  local proj_type
  proj_type="$(printf '%s' "$meta_json" | jq -r '.project.type // empty')"
  if [ "$proj_type" != "PROJECT_TYPE_DESIGN_SYSTEM" ]; then
    _vpt_die "designsync type mismatch: expected PROJECT_TYPE_DESIGN_SYSTEM, got $proj_type"
    return 1
  fi

  # canEdit check: project.canEdit must be boolean true (not string "true")
  if ! printf '%s' "$meta_json" | jq -e '.project.canEdit == true' >/dev/null 2>&1; then
    _vpt_die "designsync canEdit is false — no write access"
    return 1
  fi

  # Fail closed: the design record MUST have a DS reference for designsync
  if [ -z "$ds_ref" ]; then
    _vpt_die "design_system_project.reference is not set in design record"
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

  # Owner check: reads project.ownerDisplayName ONLY (the real get_project
  # field). A response with only "owner" (no ownerDisplayName) fails.
  # Compare via jq --arg so a trailing newline cannot match.
  if [ -n "$expected_owner" ]; then
    local actual_owner
    actual_owner="$(printf '%s' "$meta_json" | jq -r '.project.ownerDisplayName // empty')"
    if [ -z "$actual_owner" ]; then
      _vpt_die "expected owner $expected_owner but metadata has no ownerDisplayName field"
      return 1
    fi
    if ! printf '%s' "$meta_json" | jq -e --arg o "$expected_owner" '.project.ownerDisplayName == $o' >/dev/null 2>&1; then
      _vpt_die "owner mismatch: expected $expected_owner, got $actual_owner"
      return 1
    fi
  fi

  return 0
}

_verify_artifact() {
  local reference="$1" metadata_file="$2" expected_owner="$3"
  local ds_ref="$4" pd_ref="$5"

  # --expected-owner is not supported on the artifact surface: real Artifact
  # reads report "owned by you" in the page header, not a named owner.
  if [ -n "$expected_owner" ]; then
    _vpt_die "the Artifact surface cannot check a named owner — ownership is proven by the 'owned by you' header, not a named owner field"
    return 1
  fi

  # Parse text header.
  # Line 1 MUST be "reference: <URL>" (caller-written). No other reference:
  # lines are allowed (duplicates rejected). Remaining lines carry the
  # verbatim header lines from the Artifact page read and per-file read.
  local art_ref=""
  local line_num=0 ref_count=0
  local per_file_header_count=0
  local page_header_count=0
  local per_file_url="" per_file_type=""
  local has_owned_by_you=false

  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    # Reject BOM on line 1
    case "$line" in
      $'\xef\xbb\xbf'*)
        if [ "$line_num" -eq 1 ]; then
          _vpt_die "Artifact header line 1 has a UTF-8 BOM (bytes EF BB BF) — remove the BOM"
          return 1
        fi
        ;;
    esac
    # Reject CRLF line endings
    case "$line" in
      *$'\r')
        _vpt_die "Artifact header line $line_num has CRLF ending (trailing CR byte 0x0d) — convert to LF"
        return 1
        ;;
    esac

    # Line 1: reference line
    case "$line" in
      reference:*|Reference:*|REFERENCE:*)
        ref_count=$((ref_count + 1))
        if [ "$line_num" -eq 1 ]; then
          art_ref="$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')"
        fi
        ;;
    esac

    # Per-file-read header: Files saved under "..." from version <v> of <URL>, an Artifact of type "<T>".
    # The line must match the full anchored form and end right after the closing
    # period — no trailing text. Version must be digits only. We use the LAST
    # "from version N of " occurrence for URL extraction (greedy sed), so a
    # crafted dir name that embeds the form cannot override the real tail.
    case "$line" in
      "Files saved under "*)
        per_file_header_count=$((per_file_header_count + 1))
        # Validate the full form is anchored: must end with type "...".
        # Reject if there is anything after the closing '".'.
        if ! printf '%s' "$line" | grep -qE '^Files saved under ".*" from version [0-9]+ of .+, an Artifact of type "[^"]+"\.$'; then
          _vpt_die "per-file-read header does not match the expected form: $line"
          return 1
        fi
        # Extract URL: after the last "from version <digits> of " and before ", an Artifact"
        per_file_url="$(printf '%s' "$line" | sed 's/.*from version [0-9][0-9]* of //' | sed 's/, an Artifact of type .*//')"
        # Extract type: between the last 'an Artifact of type "' and '".'
        per_file_type="$(printf '%s' "$line" | sed 's/.*an Artifact of type "//' | sed 's/"\.$//')"
        ;;
    esac

    # Page-read header: starts with "[Artifact " and contains "— owned by you"
    case "$line" in
      "[Artifact "*)
        page_header_count=$((page_header_count + 1))
        case "$line" in
          *"— owned by you"*)
            has_owned_by_you=true
            ;;
        esac
        ;;
    esac
  done < "$metadata_file"

  # Reference MUST be on line 1
  if [ -z "$art_ref" ]; then
    _vpt_die "Artifact header has no reference line — cannot verify target"
    return 1
  fi
  # Reject duplicate reference: lines (only one allowed)
  if [ "$ref_count" -gt 1 ]; then
    _vpt_die "Artifact header has $ref_count reference lines (expected exactly 1)"
    return 1
  fi
  if [ "$art_ref" != "$reference" ]; then
    _vpt_die "Artifact header reference ($art_ref) does not match target reference ($reference)"
    return 1
  fi

  # Require exactly one per-file-read header line
  if [ "$per_file_header_count" -eq 0 ]; then
    _vpt_die "Artifact header has no per-file-read header line — a file with only key-value lines is not accepted"
    return 1
  fi
  if [ "$per_file_header_count" -gt 1 ]; then
    _vpt_die "Artifact header has $per_file_header_count per-file-read header lines (expected exactly 1)"
    return 1
  fi

  # Per-file URL must match the reference exactly (not a prefix)
  if [ "$per_file_url" != "$reference" ]; then
    _vpt_die "per-file-read header URL ($per_file_url) does not match target reference ($reference)"
    return 1
  fi

  # Type must be exactly "Design" (case-sensitive)
  if [ "$per_file_type" != "Design" ]; then
    _vpt_die "Artifact type must be exactly 'Design', got '$per_file_type'"
    return 1
  fi

  # Require exactly one page-read header with "owned by you"
  if [ "$page_header_count" -eq 0 ]; then
    _vpt_die "Artifact header has no page-read header line — write access could not be confirmed from the read header"
    return 1
  fi
  if [ "$page_header_count" -gt 1 ]; then
    _vpt_die "Artifact header has $page_header_count page-read header lines (expected exactly 1)"
    return 1
  fi
  if [ "$has_owned_by_you" = false ]; then
    _vpt_die "Artifact page-read header does not contain 'owned by you' — write access could not be confirmed from the read header"
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

  return 0
}

# Main guard: running the file directly invokes the public function.
# Does not fire when sourced (BASH_SOURCE[0] != $0) or via bash -c
# (BASH_SOURCE is empty or "bash").
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  verify_publication_target "$@"
fi
