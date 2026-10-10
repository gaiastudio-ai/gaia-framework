#!/usr/bin/env bash
# design-gate.sh — shared design-approval precondition.
#
# Exposes design_gate_check, the sole place the design-approval decision is
# computed. Eight solutioning entry points declare this as a quality_gates
# pre_start predicate; no entry point reimplements the logic.
#
# Returns 0 (pass) or 1 (hard halt with a three-part diagnostic on stderr).
#
# Side-effect on override refusal: sets _DG_OVERRIDE_REFUSED=1 in the
# sourced shell. gate-predicates.sh reads this to suppress the quality_gates
# error_message on override-specific refusals. Reset to 0 at gate entry.
#
# Why subprocess, not source:
#   design-record.sh runs `main "$@"` unconditionally at bottom-of-file with
#   no source guard. Sourcing it would execute main against this script's $@.
#   All interactions are subprocess calls to named verbs.
#
# Lock ordering (documented here, enforced by convention):
#   1. Gate-level lock:  ${RECORD_PATH}.gate.lock   (this file, override path only)
#   2. Record lock:      ${RECORD_PATH}.lock         (design-record.sh, inside subprocess)
#   3. Lifecycle lock:   lifecycle-overrides.yaml.lock (lifecycle-overrides.sh, inside sourced fn)
#   No code path acquires these in reverse order.

set -euo pipefail
LC_ALL=C; export LC_ALL

# Guard against double-source
if [ "${_DESIGN_GATE_SH_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_DESIGN_GATE_SH_LOADED=1

_DESIGN_GATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies — ONLY libraries with source guards, NEVER design-record.sh
# shellcheck source=acquire-lock.sh
source "$_DESIGN_GATE_SCRIPT_DIR/acquire-lock.sh"
# shellcheck source=lifecycle-overrides.sh
source "$_DESIGN_GATE_SCRIPT_DIR/lifecycle-overrides.sh"

_DESIGN_GATE_LOCK_SUFFIX=".gate.lock"

# ---------------------------------------------------------------------------
# Halt message — single template for every fail path
# ---------------------------------------------------------------------------

# _dg_halt RECORD_PATH STATE REMEDIATION — emit the three-part diagnostic.
# Every halt names the record, the current state, and a user-actionable
# remediation. No internal jargon. Phrasing says "the design needs approval",
# never "the framework is broken".
_dg_halt() {
  local record_path="$1" state="$2" remediation="$3"
  printf 'Design gate: HALT\n' >&2
  printf '  Record:      %s\n' "$record_path" >&2
  printf '  State:       %s\n' "$state" >&2
  printf '  Remediation: %s\n' "$remediation" >&2
  return 1
}

# _dg_halt_inconsistency — distinct halt for dual-ledger disagreement.
# Used only when the override's rollback fails, leaving the two ledgers in
# an inconsistent state. Names both file paths so the user can reconcile.
_dg_halt_inconsistency() {
  local record_path="$1" project_root="$2"
  printf 'Design gate: CRITICAL — dual-ledger inconsistency.\n' >&2
  printf '  Design record: %s (override entry present)\n' "$record_path" >&2
  printf '  Lifecycle ledger: %s (bypass entry missing)\n' "${project_root}/.gaia/state/lifecycle-overrides.yaml" >&2
  printf '  Manual reconciliation required: remove the last overrides[] entry\n' >&2
  printf '  from the design record, or add the missing bypass to the ledger.\n' >&2
  return 1
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_dg_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# _dg_read_config_ui_present PROJECT_ROOT — read compliance.ui_present.
# Returns 0 with the value on stdout (may be empty when the field is absent).
# Returns 1 only when the config file is missing or YAML is malformed —
# those are the fail-closed cases.
_dg_read_config_ui_present() {
  local project_root="$1"
  local config_path="${project_root}/.gaia/config/project-config.yaml"

  [ -f "$config_path" ] || return 1
  yq '.' "$config_path" >/dev/null 2>&1 || return 1

  local val
  val="$(yq '.compliance.ui_present' "$config_path" 2>/dev/null)" || return 1
  # Absent or null field in a valid config — return success with empty value
  # so design_gate_check treats it as not-applicable (anything != "true").
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    printf '%s\n' ""
    return 0
  fi
  printf '%s\n' "$val"
}

# _dg_resolve_sprint_id EXPLICIT PROJECT_ROOT — resolve sprint scope.
# Tries the explicit --sprint-id first, then reads sprint-status.yaml.
# Stdout: sprint id (e.g. sprint-99). Returns 1 if unresolvable.
_dg_resolve_sprint_id() {
  local explicit="$1" project_root="$2"
  if [ -n "$explicit" ]; then
    if ! printf '%s' "$explicit" | grep -Eq '^sprint-[0-9]+$'; then
      printf 'Design gate: override refused — malformed --sprint-id value.\n' >&2
      printf '  Got:      %s\n' "$explicit" >&2
      printf '  Expected: sprint-N (matching ^sprint-[0-9]+$)\n' >&2
      return 1
    fi
    printf '%s\n' "$explicit"
    return 0
  fi
  local ss_file="${project_root}/.gaia/state/sprint-status.yaml"
  if [ -f "$ss_file" ]; then
    local sid
    sid="$(yq '.sprint_id' "$ss_file" 2>/dev/null || true)"
    if [ -n "$sid" ] && [ "$sid" != "null" ] && printf '%s' "$sid" | grep -Eq '^sprint-[0-9]+$'; then
      printf '%s\n' "$sid"
      return 0
    fi
  fi
  return 1
}

# _dg_sanitise_reason TEXT — replace control bytes and invalid UTF-8 with
# visible <0xHH> placeholders. Valid multi-byte UTF-8 passes through
# unchanged. C1 control characters (U+0080–U+009F, encoded as C2 80–C2 9F)
# are shown as two placeholders <0xC2><0xHH>.
# Reads $1. Writes sanitised text to stdout. Pure function, no side effects.
_dg_sanitise_reason() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN {
      # Build byte-to-ordinal lookup for all 256 byte values.
      # The entry for the empty string (byte 0x00) is unreachable:
      # NUL cannot travel through shell argv or awk strings.
      for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i
    }
    # Emit <0x0A> for each newline consumed as a record separator
    NR > 1 { printf "<0x0A>" }
    {
      n = split($0, c, "")
      i = 1
      while (i <= n) {
        v = ord[c[i]]

        # ASCII printable (0x20–0x7E): pass through
        if (v >= 32 && v <= 126) { printf "%s", c[i]; i++; continue }

        # C0 control (0x01–0x1F) or DEL (0x7F): replace
        if ((v >= 1 && v <= 31) || v == 127) {
          printf "<0x%02X>", v; i++; continue
        }

        # 2-byte UTF-8: lead 0xC2–0xDF
        if (v >= 194 && v <= 223) {
          if (i + 1 <= n) {
            v2 = ord[c[i + 1]]
            if (v2 >= 128 && v2 <= 191) {
              # C1 control range: C2 80–C2 9F
              if (v == 194 && v2 >= 128 && v2 <= 159) {
                printf "<0x%02X><0x%02X>", v, v2
              } else {
                printf "%s%s", c[i], c[i + 1]
              }
              i += 2; continue
            }
          }
          printf "<0x%02X>", v; i++; continue
        }

        # 3-byte UTF-8: lead 0xE0–0xEF
        if (v >= 224 && v <= 239) {
          if (i + 2 <= n) {
            v2 = ord[c[i + 1]]; v3 = ord[c[i + 2]]
            ok = 0
            if (v2 >= 128 && v2 <= 191 && v3 >= 128 && v3 <= 191) {
              if (v == 224 && v2 >= 160) ok = 1
              else if (v == 237 && v2 <= 159) ok = 1
              else if (v != 224 && v != 237) ok = 1
            }
            if (ok) {
              printf "%s%s%s", c[i], c[i + 1], c[i + 2]
              i += 3; continue
            }
          }
          printf "<0x%02X>", v; i++; continue
        }

        # 4-byte UTF-8: lead 0xF0–0xF4
        if (v >= 240 && v <= 244) {
          if (i + 3 <= n) {
            v2 = ord[c[i + 1]]; v3 = ord[c[i + 2]]; v4 = ord[c[i + 3]]
            ok = 0
            if (v3 >= 128 && v3 <= 191 && v4 >= 128 && v4 <= 191) {
              if (v == 240 && v2 >= 144 && v2 <= 191) ok = 1
              else if (v == 244 && v2 >= 128 && v2 <= 143) ok = 1
              else if (v >= 241 && v <= 243 && v2 >= 128 && v2 <= 191) ok = 1
            }
            if (ok) {
              printf "%s%s%s%s", c[i], c[i + 1], c[i + 2], c[i + 3]
              i += 4; continue
            }
          }
          printf "<0x%02X>", v; i++; continue
        }

        # Stray continuation (0x80–0xBF), overlong lead (0xC0–0xC1),
        # or out-of-range lead (0xF5–0xFF): replace
        printf "<0x%02X>", v; i++
      }
    }
  '
}

# _dg_strip_controls TEXT — remove control bytes and invalid UTF-8, keeping
# only printable content and valid multi-byte sequences. Used to measure
# real content length before the minimum-length check.
_dg_strip_controls() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i }
    {
      n = split($0, c, "")
      i = 1
      while (i <= n) {
        v = ord[c[i]]
        if (v >= 32 && v <= 126) { printf "%s", c[i]; i++; continue }
        if ((v >= 1 && v <= 31) || v == 127) { i++; continue }
        if (v >= 194 && v <= 223) {
          if (i + 1 <= n) { v2 = ord[c[i + 1]]
            if (v2 >= 128 && v2 <= 191) {
              if (v == 194 && v2 >= 128 && v2 <= 159) { i += 2; continue }
              printf "%s%s", c[i], c[i + 1]; i += 2; continue
            }
          }
          i++; continue
        }
        if (v >= 224 && v <= 239) {
          if (i + 2 <= n) { v2 = ord[c[i + 1]]; v3 = ord[c[i + 2]]; ok = 0
            if (v2 >= 128 && v2 <= 191 && v3 >= 128 && v3 <= 191) {
              if (v == 224 && v2 >= 160) ok = 1
              else if (v == 237 && v2 <= 159) ok = 1
              else if (v != 224 && v != 237) ok = 1
            }
            if (ok) { printf "%s%s%s", c[i], c[i + 1], c[i + 2]; i += 3; continue }
          }
          i++; continue
        }
        if (v >= 240 && v <= 244) {
          if (i + 3 <= n) { v2 = ord[c[i + 1]]; v3 = ord[c[i + 2]]; v4 = ord[c[i + 3]]; ok = 0
            if (v3 >= 128 && v3 <= 191 && v4 >= 128 && v4 <= 191) {
              if (v == 240 && v2 >= 144 && v2 <= 191) ok = 1
              else if (v == 244 && v2 >= 128 && v2 <= 143) ok = 1
              else if (v >= 241 && v <= 243 && v2 >= 128 && v2 <= 191) ok = 1
            }
            if (ok) { printf "%s%s%s%s", c[i], c[i + 1], c[i + 2], c[i + 3]; i += 4; continue }
          }
          i++; continue
        }
        i++
      }
    }
  '
}

# _dg_validate_reason REASON — validate, trim and sanitise the override reason.
# Stdout: sanitised text on success.
# Returns: 0 success, 1 too short (< 10 content bytes), 2 too long (> 500 bytes).
_dg_validate_reason() {
  local reason="$1"

  # (1) Trim ASCII spaces only from both ends (not tab/CR/LF — those become
  #     visible placeholders). sed with literal space, not [[:space:]].
  local trimmed
  trimmed="$(printf '%s' "$reason" | sed 's/^ *//;s/ *$//')"

  # (2a) Minimum on content: strip controls and invalid UTF-8, then trim
  #      spaces, then check >= 10 bytes.
  local content content_trimmed
  content="$(_dg_strip_controls "$trimmed")"
  content_trimmed="$(printf '%s' "$content" | sed 's/^ *//;s/ *$//')"
  if [ -z "$content_trimmed" ] || [ "${#content_trimmed}" -lt 10 ]; then
    printf 'Override refused: --reason must be at least 10 characters after trimming whitespace (got %d).\n' "${#content_trimmed}" >&2
    return 1
  fi

  # (2b) Early maximum on the raw trimmed text (sanitising never shortens,
  #      so this bounds the byte walker).
  if [ "${#trimmed}" -gt 500 ]; then
    printf 'Override refused: --reason is longer than 500 bytes once control characters are shown as <0xHH> placeholders (got %d).\n' "${#trimmed}" >&2
    return 2
  fi

  # (2c) Sanitise: replace control bytes with <0xHH> placeholders.
  local sanitised
  sanitised="$(_dg_sanitise_reason "$trimmed")"

  # (2d) Maximum on the sanitised text (the ledger cap).
  if [ "${#sanitised}" -gt 500 ]; then
    printf 'Override refused: --reason is longer than 500 bytes once control characters are shown as <0xHH> placeholders (got %d).\n' "${#sanitised}" >&2
    return 2
  fi

  printf '%s' "$sanitised"
}

# ---------------------------------------------------------------------------
# Condition matrix — the state-specific verdict and remediation
# ---------------------------------------------------------------------------

# _dg_evaluate_state DESIGN_STATE DREC_SCRIPT PROJECT_ROOT — evaluate the
# state and convergence. Returns 0 (pass) or 1 (fail with state_remediation
# printed to stdout). Vacuous convergence returns 1 (fail closed).
_dg_evaluate_state() {
  local design_state="$1" drec_script="$2" project_root="$3"

  case "$design_state" in
    draft)
      printf '%s' "The design is in draft. Run /gaia-design-review to begin the approval process."
      return 1
      ;; # MUTANT-ANCHOR: draft-fail (documents the branch for static analysis)
    review)
      printf '%s' "The design is under review. Run /gaia-design-review to complete the approval round, or use --force-design with a reason to override."
      return 1
      ;;
    in-dev)
      printf '%s' "The design state is in-dev — it was approved but has since moved to active development."
      return 1
      ;;
    stale)
      # MUTANT-ANCHOR: stale-fail-branch
      printf '%s' "The design has gone stale. Run /gaia-design-review to start a new approval round."
      return 1
      ;;
    approved)
      # Convergence checked via subprocess. design-record.sh check-convergence
      # is a read-only path (no lock acquisition) and returns quickly.
      local conv_output conv_rc=0
      conv_output="$("$drec_script" check-convergence 2>&1)" || conv_rc=$?

      # MUTANT-ANCHOR: iteration-check
      # Vacuous convergence tested first — it is a distinct failure mode with
      # its own remediation (create a design/ux-tagged stakeholder).
      if printf '%s\n' "$conv_output" | grep -q "vacuous-convergence"; then
        printf '%s' "The design approval is vacuous — no design/ux-tagged stakeholder in the roster. Create one with /gaia-create-stakeholder using a design or ux tag, then re-run the review."
        return 1
      elif [ "$conv_rc" -ne 0 ]; then
        printf '%s' "The design is approved but not all required stakeholders have approved the current iteration. Complete approvals, or use --force-design with a reason to override."
        return 1
      fi
      # Approved and converged — pass. The common approved case is a pure
      # local read with no external dependency.
      return 0
      ;;
    *)
      # MUTANT-ANCHOR: default-fail-branch
      printf '%s' "Unknown design state: ${design_state}. The design record may be corrupt."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

# design_gate_check [--force-design] [--reason "..."] [--entry-point "..."]
#                   [--sprint-id "..."]
#
# Returns 0 on pass, 1 on fail (hard halt).
design_gate_check() {
  local force_design="" reason="" entry_point="" sprint_id_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force-design) force_design=1; shift ;;
      --reason) reason="$2"; shift 2 ;;
      --entry-point) entry_point="$2"; shift 2 ;;
      --sprint-id) sprint_id_arg="$2"; shift 2 ;;
      *) shift ;;  # ignore unknown args for forward compat
    esac
  done

  # Reset the override-refusal signal for this gate call. The variable is
  # read by _gate_evaluate_entry (gate-predicates.sh) to suppress the
  # quality_gates error_message on override-specific refusals.
  _DG_OVERRIDE_REFUSED=0

  # Honour an existing PROJECT_ROOT from the caller; fall back through the
  # framework's standard chain. Export so the record writer subprocess
  # inherits it without per-call env overrides.
  PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-.}}}"
  export PROJECT_ROOT
  local record_path="${PROJECT_ROOT}/.gaia/state/design-record.yaml"
  local drec_script="${_DESIGN_GATE_SCRIPT_DIR}/../design-record.sh"

  # ---- Config: is the project UI-bearing? ----

  local ui_present=""
  ui_present="$(_dg_read_config_ui_present "$PROJECT_ROOT")" || {
    _dg_halt "$record_path" "unreadable config" \
      "Ensure .gaia/config/project-config.yaml exists, is valid YAML, and has a compliance.ui_present field."
    return 1
  }

  # ---- Not-applicable path ----
  # YAML boolean true renders as "true" in yq v4 (case-preserving), but the
  # spec allows True and TRUE as well. A case statement lists the three
  # canonical YAML boolean-true spellings; everything else (false, "yes",
  # "1", "on", empty, absent) is not-applicable — record via the sole writer.

  local _dg_is_ui=false
  case "$ui_present" in
    true|True|TRUE) _dg_is_ui=true ;;
  esac

  if [ "$_dg_is_ui" = false ]; then
    "$drec_script" init-not-applicable --actor "design-gate" >/dev/null 2>&1 || true
    return 0
  fi

  # ---- Symlink check ----
  # Refuse to read through a symlink. This matches the write-path discipline
  # in design-record.sh and prevents symlink-based bypass attacks.

  if [ -L "$record_path" ]; then
    _dg_halt "$record_path" "symlink detected" \
      "The design record is a symlink — refusing to follow. Remove the symlink and use a real file."
    return 1
  fi

  # ---- Record existence ----

  if [ ! -f "$record_path" ]; then
    # MUTANT-ANCHOR: absent-fail-branch
    local _dg_absent_remediation="Create the design record with /gaia-create-ux. If the design integration is not connected in this session: for the design-system project, enable the DesignSync surface. For the product design project, ensure the Design artifact surface is available. Run /design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)."
    _dg_halt "$record_path" "absent" "$_dg_absent_remediation"
    return 1
  fi

  # ---- Parse and validate ----

  if ! yq '.' "$record_path" >/dev/null 2>&1; then
    _dg_halt "$record_path" "unreadable or corrupt" \
      "The design record exists but cannot be parsed. Check the file for YAML syntax errors."
    return 1
  fi

  if [ ! -r "$record_path" ]; then
    _dg_halt "$record_path" "unreadable (permission denied)" \
      "The design record exists but is not readable. Check file permissions."
    return 1
  fi

  local schema_version
  schema_version="$(yq '.schema_version' "$record_path" 2>/dev/null || true)"
  if [ "$schema_version" != "1.0" ] && [ "$schema_version" != "2.0" ]; then
    _dg_halt "$record_path" "schema-invalid (version: ${schema_version:-unknown})" \
      "The design record has an unsupported schema version. Update the framework or migrate the record."
    return 1
  fi

  # ---- Applicability ----

  local applicability
  applicability="$(yq '.applicability' "$record_path" 2>/dev/null || true)"
  if [ "$applicability" = "not-applicable" ]; then
    # A not-applicable record on a UI-bearing project is stale — the project
    # now requires design approval but the record was created when it did not.
    # Fail closed so the user re-initializes the design record.
    if [ "$ui_present" = "true" ]; then
      _dg_halt "$record_path" "not-applicable record on UI-bearing project" \
        "The design record says not-applicable but the project has ui_present: true. Run: design-record.sh reopen-applicable --reference <ref> --discovered-via <how> [--questionnaire-record <path>], then drive the review with /gaia-design-review."
      return 1
    fi
    return 0
  fi

  # ---- Design state and convergence ----

  local design_state
  design_state="$(yq '.design_state' "$record_path" 2>/dev/null || true)"
  if [ -z "$design_state" ] || [ "$design_state" = "null" ]; then
    _dg_halt "$record_path" "schema-invalid (missing design_state)" \
      "The design record is missing its design_state field."
    return 1
  fi

  local verdict="fail"
  local state_remediation=""
  state_remediation="$(_dg_evaluate_state "$design_state" "$drec_script" "$PROJECT_ROOT")" && verdict="pass"

  if [ "$verdict" = "pass" ]; then
    # ---- Review coverage check ----
    # MUTANT-ANCHOR: coverage-check-begin
    local _dg_cov_json _dg_cov_type _dg_pdp_ref _dg_pdp_type _dg_dsp_ref
    _dg_cov_json="$(yq -o=json '{"rc": .review_coverage, "pdp": .product_design_project, "dsp": (.design_system_project.reference // .project.reference)}' "$record_path" 2>/dev/null || true)"

    _dg_cov_type="$(jq -r '.rc | type' <<<"$_dg_cov_json" 2>/dev/null || printf 'null')"
    _dg_pdp_ref="$(jq -r '.pdp.reference // empty' <<<"$_dg_cov_json" 2>/dev/null || true)"
    _dg_pdp_type="$(jq -r '.pdp | type' <<<"$_dg_cov_json" 2>/dev/null || printf 'null')"
    _dg_dsp_ref="$(jq -r '.dsp // empty' <<<"$_dg_cov_json" 2>/dev/null || true)"

    local _dg_cov_clause="If the design integration is not connected in this session: for the design-system project, enable the DesignSync surface. For the product design project, ensure the Design artifact surface is available. Run /design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)."

    # Validate product_design_project type: must be null, absent, or a map
    if [ -n "$_dg_pdp_type" ] && [ "$_dg_pdp_type" != "null" ] && [ "$_dg_pdp_type" != "object" ]; then
      _dg_halt "$record_path" "malformed-record" \
        "product_design_project must be a map or null, but is $_dg_pdp_type. Fix the design record or re-run /gaia-create-ux."
      return 1
    fi

    if [ "$_dg_cov_type" = "null" ]; then
      # Absent coverage field
      if [ -n "$_dg_pdp_ref" ]; then
        _dg_halt "$record_path" "coverage-incomplete" \
          "The design review did not cover the product design project. Run /gaia-design-review to review both projects. This halt cannot be overridden with --force-design. $_dg_cov_clause"
        return 1
      fi
      # product_design_project null — treat as design-system only, pass through
    elif [ "$_dg_cov_type" = "array" ]; then
      # Coverage is present and is a list — compare elements exactly
      local _dg_has_ds=0 _dg_has_pd=0
      local _dg_cov_item
      while IFS= read -r _dg_cov_item; do
        [ -n "$_dg_cov_item" ] || continue
        if [ "$_dg_cov_item" = "design-system" ]; then _dg_has_ds=1; fi
        if [ "$_dg_cov_item" = "product-design" ]; then _dg_has_pd=1; fi
      done <<COVEOF
$(jq -r '.rc[]' <<<"$_dg_cov_json" 2>/dev/null || true)
COVEOF

      if [ -n "$_dg_dsp_ref" ] && [ "$_dg_has_ds" -eq 0 ]; then
        _dg_halt "$record_path" "coverage-incomplete" \
          "The design review did not cover the design-system project. Run /gaia-design-review to review both projects. This halt cannot be overridden with --force-design. $_dg_cov_clause"
        return 1
      fi
      if [ -n "$_dg_pdp_ref" ] && [ "$_dg_has_pd" -eq 0 ]; then
        _dg_halt "$record_path" "coverage-incomplete" \
          "The design review did not cover the product design project. Run /gaia-design-review to review both projects. This halt cannot be overridden with --force-design. $_dg_cov_clause"
        return 1
      fi
    else
      # review_coverage is present but not a list — fail closed
      _dg_halt "$record_path" "malformed-record" \
        "review_coverage must be a list, but is $_dg_cov_type. Fix the design record or re-run /gaia-design-review."
      return 1
    fi
    # MUTANT-ANCHOR: coverage-check-end

    return 0
  fi

  # ---- Override path ----

  if [ "$force_design" = "1" ]; then
    _dg_handle_override "$PROJECT_ROOT" "$record_path" "$drec_script" \
      "$reason" "$entry_point" "$sprint_id_arg" "$design_state"
    return $?
  fi

  # ---- Halt on non-approved applicable paths ----

  local _dg_halt_remediation="${state_remediation} If the design integration is not connected in this session: for the design-system project, enable the DesignSync surface. For the product design project, ensure the Design artifact surface is available. Run /design-login (API-token sessions), or grant design access when prompted (claude.ai sessions)."
  _dg_halt "$record_path" "$design_state" "$_dg_halt_remediation"  # MUTANT-ANCHOR: probe-fail-branch
  return 1
}

# ---------------------------------------------------------------------------
# Override handler — dual-ledger write with rollback
# ---------------------------------------------------------------------------

_dg_handle_override() {
  local project_root="$1" record_path="$2" drec_script="$3"
  local reason="$4" entry_point="$5" sprint_id_arg="$6" design_state="$7"

  local actor
  actor="${USER:-unknown}"

  # ---- Validate and sanitise reason ----

  local _dg_vr_rc=0
  reason="$(_dg_validate_reason "$reason")" || _dg_vr_rc=$?
  if [ "$_dg_vr_rc" -ne 0 ]; then
    local _dg_vr_remediation
    if [ "$_dg_vr_rc" -eq 1 ]; then
      _dg_vr_remediation="Override refused: --reason must be at least 10 characters after trimming whitespace."
    else
      _dg_vr_remediation="Override refused: --reason is longer than 500 bytes once control characters are shown as <0xHH> placeholders."
    fi
    _dg_halt "$record_path" "$design_state" "$_dg_vr_remediation"
    _DG_OVERRIDE_REFUSED=1
    return 1
  fi

  # ---- Resolve sprint scope ----

  local sprint_id=""
  sprint_id="$(_dg_resolve_sprint_id "$sprint_id_arg" "$project_root")" || {
    printf 'Design gate: override refused — no active sprint scope.\n' >&2
    printf '  Either approve the design via /gaia-design-review,\n' >&2
    printf '  or plan a sprint with /gaia-sprint-plan,\n' >&2
    printf '  or pass --sprint-id sprint-N explicitly.\n' >&2
    _DG_OVERRIDE_REFUSED=1
    return 1
  }

  # ---- Acquire gate-level lock ----
  # Serializes override sequences. design-record.sh add-override takes its
  # own record lock inside the subprocess; the lifecycle writer takes its own
  # lock. The gate lock prevents interleaving of the two writes by concurrent
  # gate callers.

  local gate_lock_path="${record_path}${_DESIGN_GATE_LOCK_SUFFIX}"
  local gate_lock_fd=8
  if ! acquire_lock "$gate_lock_path" 30 "$gate_lock_fd"; then
    _dg_halt "$record_path" "$design_state" \
      "Override refused: could not acquire the gate-level lock at $gate_lock_path."
    _DG_OVERRIDE_REFUSED=1
    return 1
  fi

  # ---- Pre-override captures ----
  # Two separate captures: whole-file hash for rollback verification,
  # string-valued design_state for the state-unchanged assertion.

  local backup_hash pre_state backup_path
  backup_hash="$(_dg_sha256_file "$record_path")"
  pre_state="$(yq '.design_state' "$record_path")"
  backup_path="${record_path}.gate-backup"
  ( umask 077; cp "$record_path" "$backup_path"; chmod 600 "$backup_path" )

  # ---- Write to design record (subprocess) ----

  local drec_rc=0
  "$drec_script" add-override \
    --actor "$actor" --reason "$reason" --entry-point "${entry_point:-unknown}" \
    --sprint-id "$sprint_id" \
    >/dev/null 2>&1 || drec_rc=$?

  if [ "$drec_rc" -ne 0 ]; then
    rm -f "$backup_path" 2>/dev/null || true
    release_lock "$gate_lock_fd" 2>/dev/null || true
    _dg_halt "$record_path" "$design_state" \
      "Override failed: design-record.sh add-override returned exit $drec_rc."
    _DG_OVERRIDE_REFUSED=1
    return 1
  fi

  # ---- Write to lifecycle-overrides ledger (sourced function) ----
  # Run in a subshell: lifecycle_append_bypass sets a RETURN trap on $tmp
  # that leaks into the caller's scope on bash 5.x (Linux). A subshell
  # contains the trap. The function handles its own locking internally.

  local lo_rc=0
  ( lifecycle_append_bypass --skill "design-gate" --reason "$reason" --sprint-id "$sprint_id" ) || lo_rc=$?

  if [ "$lo_rc" -ne 0 ]; then
    _dg_rollback_override "$record_path" "$backup_path" "$backup_hash" \
      "$project_root" "$design_state" "$gate_lock_fd"
    return 1
  fi

  rm -f "$backup_path" 2>/dev/null || true

  # ---- Verify design_state is unchanged ----
  # The override must never set design_state to approved. String compare on
  # the short enum value (not sha256 of the whole file, which add-override
  # legitimately changes by appending to overrides[] and audit[]).

  local post_state
  post_state="$(yq '.design_state' "$record_path")"
  if [ "$post_state" != "$pre_state" ]; then
    release_lock "$gate_lock_fd" 2>/dev/null || true
    _dg_halt "$record_path" "$post_state" \
      "Override changed design_state from '$pre_state' to '$post_state' — this is a bug in the override verb."
    _DG_OVERRIDE_REFUSED=1
    return 1
  fi

  # Note: iteration is re-evaluated on the next gate call. The override does
  # not affect iteration or approval state, so no explicit check here.

  # ---- Override notice (surfaced to developer via stderr) ----
  printf '\n' >&2
  printf 'Design gate: OVERRIDE ACCEPTED\n' >&2
  printf '  Design state:  %s\n' "$design_state" >&2
  printf '  Reason:        %s\n' "$reason" >&2
  printf '  Warning:       ux-design.md may be outdated — the design is not approved.\n' >&2

  release_lock "$gate_lock_fd" 2>/dev/null || true
  return 0
}

# _dg_rollback_override — restore the design record from backup after a
# failed lifecycle-overrides write. Verifies the rollback via sha256 and
# emits a CRITICAL halt if the two ledgers are left inconsistent.
_dg_rollback_override() {
  local record_path="$1" backup_path="$2" backup_hash="$3"
  local project_root="$4" design_state="$5" gate_lock_fd="$6"

  local rollback_ok=0
  if mv -f "$backup_path" "$record_path" 2>/dev/null; then
    local post_rollback_hash
    post_rollback_hash="$(_dg_sha256_file "$record_path")"
    [ "$post_rollback_hash" = "$backup_hash" ] && rollback_ok=1
  fi

  release_lock "$gate_lock_fd" 2>/dev/null || true

  _DG_OVERRIDE_REFUSED=1
  if [ "$rollback_ok" = "1" ]; then
    _dg_halt "$record_path" "$design_state" \
      "Override failed: lifecycle-overrides ledger write failed; design record rolled back successfully."
  else
    _dg_halt_inconsistency "$record_path" "$project_root"
  fi
  return 1
}
