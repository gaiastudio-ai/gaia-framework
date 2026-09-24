#!/usr/bin/env bash
# design-gate.sh — shared design-approval precondition.
#
# Exposes design_gate_check, the sole place the design-approval decision is
# computed. Eight solutioning entry points declare this as a quality_gates
# pre_start predicate; no entry point reimplements the logic.
#
# Returns 0 (pass) or 1 (hard halt with a three-part diagnostic on stderr).
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

# _dg_probe_integration — invoke design-probe.sh once, capture classification.
# Sets _DG_PROBE_STATE (available|missing|unauthorized) in the caller.
#
# Why the probe exists: the halt must distinguish "integration missing" from
# "integration unauthorized" so the user gets the correct remediation.
# Unauthorized says "/design-login"; missing does not.
_dg_probe_integration() {
  local probe_script
  probe_script="$(command -v design-probe.sh 2>/dev/null || true)"
  if [ -z "$probe_script" ]; then
    probe_script="${_DESIGN_GATE_SCRIPT_DIR}/../design-probe.sh"
  fi

  _DG_PROBE_STATE="missing"

  [ -f "$probe_script" ] || return 0

  local stderr_file
  stderr_file="$(mktemp -t dg-probe-stderr.XXXXXX)"

  _DG_PROBE_STATE="$("$probe_script" 2>"$stderr_file")" || true
  rm -f "$stderr_file" 2>/dev/null || true

  _DG_PROBE_STATE="$(printf '%s' "$_DG_PROBE_STATE" | head -1)"
  [ -n "$_DG_PROBE_STATE" ] || _DG_PROBE_STATE="missing"
}

# _dg_halt_with_probe RECORD_PATH STATE STATE_REMEDIATION — probe the
# integration once, then emit the halt with the appropriate remediation.
# Used on every non-approved applicable fail path (not the approved path,
# where zero probe calls are made by design — see AC-EC3).
_dg_halt_with_probe() {
  local record_path="$1" design_state="$2" state_remediation="$3"

  _dg_probe_integration

  if [ "$_DG_PROBE_STATE" = "unauthorized" ]; then
    _dg_halt "$record_path" "$design_state (integration: unauthorized)" \
      "Run /design-login to authorize — this is an interactive step that you must run yourself; the framework cannot run it on your behalf."
  elif [ "$_DG_PROBE_STATE" = "missing" ]; then
    _dg_halt "$record_path" "$design_state (integration: missing)" \
      "Enable the Claude Design integration in this environment. Use a Claude Code session that exposes the DesignSync tool surface."
  else
    _dg_halt "$record_path" "$design_state" "$state_remediation"
  fi
  return 1
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

# _dg_validate_reason REASON — validate override reason after trimming.
# Stdout: trimmed reason. Returns 1 with a message on failure.
_dg_validate_reason() {
  local reason="$1"
  local trimmed
  trimmed="$(printf '%s' "$reason" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$trimmed" ] || [ "${#trimmed}" -lt 10 ]; then
    printf 'Override refused: --reason must be at least 10 characters after trimming whitespace (got %d).\n' "${#trimmed}" >&2
    return 1
  fi
  printf '%s' "$trimmed"
}

# ---------------------------------------------------------------------------
# Condition matrix — the state-specific verdict and remediation
# ---------------------------------------------------------------------------

# _dg_evaluate_state DESIGN_STATE DREC_SCRIPT PROJECT_ROOT — evaluate the
# state and convergence. Returns 0 (pass), 1 (fail with state_remediation
# printed to stdout), or exits the caller on vacuous-convergence pass.
_dg_evaluate_state() {
  local design_state="$1" drec_script="$2" project_root="$3"

  case "$design_state" in
    draft)
      printf '%s' "The design is in draft. Transition to review to begin the approval process."
      return 1
      ;; # MUTANT-ANCHOR: draft-fail (documents the branch for static analysis)
    review)
      printf '%s' "The design is under review, awaiting stakeholder approval. Complete the review via the design review skill, or use --force-design with a reason to override."
      return 1
      ;;
    in-dev)
      printf '%s' "The design state is in-dev — it was approved but has since moved to active development."
      return 1
      ;;
    stale)
      # MUTANT-ANCHOR: stale-fail-branch
      printf '%s' "The design has gone stale. Transition back to review to start a new approval round."
      return 1
      ;;
    approved)
      # Convergence checked via subprocess. design-record.sh check-convergence
      # is a read-only path (no lock acquisition) and returns quickly.
      local conv_output conv_rc=0
      conv_output="$("$drec_script" check-convergence 2>&1)" || conv_rc=$?

      # MUTANT-ANCHOR: iteration-check
      if [ "$conv_rc" -ne 0 ]; then
        printf '%s' "The design is approved but not all required stakeholders have approved the current iteration. Complete approvals, or use --force-design with a reason to override."
        return 1
      elif printf '%s\n' "$conv_output" | grep -q "vacuous-convergence"; then
        # Vacuous convergence: no design/ux-tagged stakeholders in the roster.
        # Pass with a warning so the condition is surfaced, not silent.
        printf '%s\n' "$conv_output" >&2
        return 0
      fi
      # Approved and converged — pass. The probe is skipped entirely on this
      # path: the common approved case is a pure local read. A transient
      # probe failure must not halt workflows that have a valid local approval.
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

  # Honour an existing PROJECT_ROOT from the caller; fall back through the
  # framework's standard chain. Export so subprocesses (design-record.sh,
  # design-probe.sh) inherit it without per-call env overrides.
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
  # YAML boolean true renders as "true" in yq. Anything else (false, "yes",
  # "1", "True", empty) is not-applicable — record via the sole writer.

  if [ "$ui_present" != "true" ]; then
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
    _dg_halt_with_probe "$record_path" "absent" \
      "Create the design record with the UX design skill, or run: design-record.sh init --reference ... --discovered-via ... --questionnaire-record ..."
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
  if [ "$schema_version" != "1.0" ]; then
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
        "The design record says not-applicable but the project has ui_present: true. Run: design-record.sh reopen-applicable --reference <ref> --discovered-via <how> --questionnaire-record <path>, then drive the review with /gaia-design-review."
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
    return 0
  fi

  # ---- Override path ----

  if [ "$force_design" = "1" ]; then
    _dg_handle_override "$PROJECT_ROOT" "$record_path" "$drec_script" \
      "$reason" "$entry_point" "$sprint_id_arg" "$design_state"
    return $?
  fi

  # ---- Probe + halt on non-approved applicable paths ----
  # Exactly one probe call per evaluation (zero on approved — handled above).

  _dg_halt_with_probe "$record_path" "$design_state" "$state_remediation"  # MUTANT-ANCHOR: probe-fail-branch
  return 1
}

# ---------------------------------------------------------------------------
# Override handler — dual-ledger write with rollback
# ---------------------------------------------------------------------------

_dg_handle_override() {
  local project_root="$1" record_path="$2" drec_script="$3"
  local reason="$4" entry_point="$5" sprint_id_arg="$6" design_state="$7"

  local actor
  actor="$(git config user.name 2>/dev/null || true)"
  actor="${actor:-${USER:-unknown}}"

  # ---- Validate reason ----

  _dg_validate_reason "$reason" >/dev/null || {
    _dg_halt "$record_path" "$design_state" \
      "Override refused: --reason must be at least 10 characters after trimming whitespace."
    return 1
  }

  # ---- Resolve sprint scope ----

  local sprint_id=""
  sprint_id="$(_dg_resolve_sprint_id "$sprint_id_arg" "$project_root")" || {
    printf 'Design gate: override refused — no active sprint scope.\n' >&2
    printf '  Either approve the design via /gaia-design-review,\n' >&2
    printf '  or plan a sprint with /gaia-sprint-plan,\n' >&2
    printf '  or pass --sprint-id sprint-N explicitly.\n' >&2
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
    >/dev/null 2>&1 || drec_rc=$?

  if [ "$drec_rc" -ne 0 ]; then
    rm -f "$backup_path" 2>/dev/null || true
    release_lock "$gate_lock_fd" 2>/dev/null || true
    _dg_halt "$record_path" "$design_state" \
      "Override failed: design-record.sh add-override returned exit $drec_rc."
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
    return 1
  fi

  # Note: iteration is re-evaluated on the next gate call. The override does
  # not affect iteration or approval state, so no explicit check here.

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

  if [ "$rollback_ok" = "1" ]; then
    _dg_halt "$record_path" "$design_state" \
      "Override failed: lifecycle-overrides ledger write failed; design record rolled back successfully."
  else
    _dg_halt_inconsistency "$record_path" "$project_root"
  fi
  return 1
}
