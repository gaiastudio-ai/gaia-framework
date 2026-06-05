#!/usr/bin/env bash
# finalize.sh — /gaia-infra-design skill finalize
#
# Extends the finalize scaffolding with a 25-item post-completion checklist
# (15 script-verifiable + 10 LLM-checkable) derived from the V1
# infrastructure-design checklist.
#
# Responsibilities:
#   1. Run the script-verifiable subset of the 25 checklist items
#      against the infrastructure-design.md artifact. Validation runs
#      FIRST.
#   2. Emit an LLM-checkable payload listing the semantic-judgment items.
#   3. Write a checkpoint via the shared checkpoint.sh helper.
#   4. Emit a lifecycle event via lifecycle-event.sh.
#
# The observability side effects (3 + 4) MUST run on every invocation —
# the checklist outcome never suppresses the checkpoint/event write.
#
# Exit codes:
#   0 — finalize succeeded; all 15 script-verifiable items PASS (or
#       no artifact was requested — checklist skipped, observability runs).
#   1 — one or more script-verifiable checklist items FAIL; the
#       AC4 "no artifact to validate" violation; or a
#       checkpoint/lifecycle-event failure. Failed item names are
#       listed on stderr under a "Checklist violations:" header
#       followed by a one-line remediation hint.
#
# Environment:
#   INFRA_DESIGN_ARTIFACT  Absolute path to the infrastructure-design
#                          artifact to validate. When set, the script
#                          runs the 25-item checklist against it. When
#                          set but the file does not exist or is empty,
#                          AC4 fires — a single "no artifact to
#                          validate" violation is emitted and the
#                          script exits non-zero. When unset, the
#                          script looks for
#                          .gaia/artifacts/planning-artifacts/infrastructure-design.md
#                          relative to the current working directory.
#                          If neither is present, the checklist run is
#                          skipped (checklist omitted; observability still
#                          runs, exit 0).

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="gaia-infra-design/finalize.sh"
WORKFLOW_NAME="infrastructure-design"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../../scripts" && pwd)"

CHECKPOINT="$PLUGIN_SCRIPTS_DIR/checkpoint.sh"
LIFECYCLE_EVENT="$PLUGIN_SCRIPTS_DIR/lifecycle-event.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

# ---------- 0. Resolve artifact paths ----------
# INFRA_DESIGN_ARTIFACT wins when set (test fixtures + explicit
# invocation). If it is set but the file is missing or empty, AC4
# fires. If unset, fall back to
# .gaia/artifacts/planning-artifacts/infrastructure-design.md. If neither is
# present the checklist is simply skipped (observability still runs).
ARTIFACT=""
ARTIFACT_REQUESTED=0
# Three-tier idiom: env-var → positive-evidence legacy → canonical default.
if [ -n "${INFRA_DESIGN_ARTIFACT:-}" ]; then
  ARTIFACT_REQUESTED=1
  ARTIFACT="$INFRA_DESIGN_ARTIFACT"
elif [ -f "docs/planning-artifacts/infrastructure-design.md" ] && [ ! -d ".gaia/artifacts/planning-artifacts" ]; then
  ARTIFACT="docs/planning-artifacts/infrastructure-design.md"
elif [ -f ".gaia/artifacts/planning-artifacts/infrastructure-design.md" ]; then
  ARTIFACT=".gaia/artifacts/planning-artifacts/infrastructure-design.md"
fi

# ---------- 1. Run the 25-item checklist ----------
VIOLATIONS=()
CHECKED=0
PASSED=0
CHECKLIST_STATUS=0

# item_check <id> <description> <boolean-result>
# boolean-result: "pass" or "fail".
item_check() {
  local id="$1" desc="$2" result="$3"
  CHECKED=$((CHECKED + 1))
  if [ "$result" = "pass" ]; then
    printf '  [PASS] %s — %s\n' "$id" "$desc" >&2
    PASSED=$((PASSED + 1))
  else
    printf '  [FAIL] %s — %s\n' "$id" "$desc" >&2
    VIOLATIONS+=("$id — $desc")
  fi
}

# file_nonempty <file>
file_nonempty() {
  [ -s "$1" ] && echo "pass" || echo "fail"
}

# file_exists <file>
file_exists() {
  [ -f "$1" ] && echo "pass" || echo "fail"
}

# heading_present <file> <heading-regex>
# Pass when an H2 heading matching the pattern exists.
# heading_present() is now a single shared implementation
# (plugins/gaia/scripts/lib/heading-present.sh) with one uniform, permissive
# regex accepting optional numbered+lettered outline prefixes (11, 11b, 1.2.3).
# Previously finalize.sh scripts carried divergent inline copies, so the same
# heading passed one skill's check and failed another's. Sourced via a
# $0-relative path so it works whether or not this script defines PLUGIN_SCRIPTS_DIR.
_GAIA_HEADING_LIB="$(cd "$(dirname "$0")" && pwd)/../../../scripts/lib/heading-present.sh"
if [ -r "$_GAIA_HEADING_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_GAIA_HEADING_LIB"
else
  # Fallback inline definition (kept byte-equivalent to the shared lib) so the
  # checklist still runs if the lib is somehow unreadable.
  heading_present() {
    local f="$1" text="$2"
    if grep -Ei "^##[[:space:]]+([0-9]+[a-z]?(\.[0-9]+[a-z]?)*\.?[[:space:]]+)?${text}([[:space:]]|\$|[[:punct:]])" "$f" >/dev/null 2>&1; then
      echo "pass"
    else
      echo "fail"
    fi
  }
fi

# pattern_present <file> <extended-regex>
pattern_present() {
  local f="$1" pattern="$2"
  grep -Eiq "$pattern" "$f" 2>/dev/null && echo "pass" || echo "fail"
}

# environments_triad_present <file>
# Pass when the document names all three of dev|development, staging,
# and production. Case-insensitive.
environments_triad_present() {
  local f="$1"
  local has_dev has_staging has_prod
  has_dev="$(pattern_present "$f" '(\bdev\b|\bdevelopment\b)')"
  has_staging="$(pattern_present "$f" '\bstaging\b')"
  has_prod="$(pattern_present "$f" '(\bproduction\b|\bprod\b)')"
  if [ "$has_dev" = "pass" ] && [ "$has_staging" = "pass" ] && [ "$has_prod" = "pass" ]; then
    echo "pass"
  else
    echo "fail"
  fi
}

if [ "$ARTIFACT_REQUESTED" -eq 1 ] && { [ ! -f "$ARTIFACT" ] || [ ! -s "$ARTIFACT" ]; }; then
  # AC4 — Caller explicitly pointed at an artifact path but it does
  # not exist on disk or is empty (0 bytes).
  log "no artifact to validate at $ARTIFACT"
  printf '\nChecklist violations:\n' >&2
  printf '  - no artifact to validate (expected %s)\n' "$ARTIFACT" >&2
  printf 'Remediation: rerun /gaia-infra-design to produce .gaia/artifacts/planning-artifacts/infrastructure-design.md, then rerun finalize.sh.\n' >&2
  CHECKLIST_STATUS=1
elif [ -n "$ARTIFACT" ] && [ -f "$ARTIFACT" ] && [ -s "$ARTIFACT" ]; then
  log "running 25-item checklist against $ARTIFACT"
  printf '\nChecklist: /gaia-infra-design (25 items — 15 script-verifiable, 10 LLM-checkable)\n' >&2

  # --- Script-verifiable items (15) ---

  # Output Verification (SV-01..SV-02)
  item_check "SV-01" "Output file saved to resolved path ($ARTIFACT)" \
    "$(file_exists "$ARTIFACT")"
  item_check "SV-02" "Output artifact is non-empty" "$(file_nonempty "$ARTIFACT")"

  # Environments (SV-03..SV-05)
  item_check "SV-03" "Environments section present (## Environments heading)" \
    "$(heading_present "$ARTIFACT" "Environments")"
  item_check "SV-04" "Environments include dev, staging, and production" \
    "$(environments_triad_present "$ARTIFACT")"
  item_check "SV-05" "Environment parity strategy specified (parity keyword present)" \
    "$(pattern_present "$ARTIFACT" '\bparity\b')"

  # Deployment (SV-06..SV-08)
  item_check "SV-06" "Deployment section present (## Deployment heading)" \
    "$(heading_present "$ARTIFACT" "Deployment")"
  # The scaling allowlist was extended beyond cloud-biased patterns.
  # Local/on-prem single-host topologies scale via process supervisors
  # (systemd, supervisor, pm2), worker/replica counts, or document an explicit
  # single-instance/vertical-only posture. Accept those idioms too.
  item_check "SV-07" "Load balancing and scaling approach specified (scaling keyword present)" \
    "$(pattern_present "$ARTIFACT" '(auto-?scal(e|ing)|horizontal[[:space:]]+scal|vertical[[:space:]]+scal|load[[:space:]]+balanc|\bsystemd\b|\bsupervisor\b|\bpm2\b|process[[:space:]]+manager|worker[[:space:]]+(count|pool)|\breplicas?\b|single[[:space:]-]instance)')"
  # The networking allowlist was extended beyond cloud-biased patterns. Single-host
  # topologies document firewall / loopback / localhost rather than VPC/subnet/CDN.
  item_check "SV-08" "Networking design documented (VPC/subnet/CDN/security-group/firewall/loopback/localhost keyword present)" \
    "$(pattern_present "$ARTIFACT" '(\bVPC\b|\bsubnet(s)?\b|\bCDN\b|security[[:space:]]+group|\bfirewall\b|\bloopback\b|\blocalhost\b)')"

  # IaC (SV-09..SV-11)
  # Accept the spelled-out "Infrastructure as Code" heading, not only the
  # "## IaC" abbreviation. heading_present interpolates the arg into an -E
  # regex anchored as ^## <text>(...), so the alternation works.
  item_check "SV-09" "IaC section present (## IaC OR ## Infrastructure as Code heading)" \
    "$(heading_present "$ARTIFACT" "(IaC|Infrastructure as Code)")"
  # Config-management single-host projects use Chef/Puppet rather than
  # Terraform/Pulumi/etc. Word-anchored to match the existing style.
  item_check "SV-10" "IaC tool named (Terraform/Pulumi/CloudFormation/CDK/Bicep/OpenTofu/Ansible/Chef/Puppet)" \
    "$(pattern_present "$ARTIFACT" '(\bTerraform\b|\bPulumi\b|\bCloudFormation\b|\bCDK\b|\bBicep\b|\bOpenTofu\b|\bAnsible\b|\bChef\b|\bPuppet\b)')"
  # The state allowlist was extended beyond Terraform-centric patterns.
  # Local/on-prem config-management projects (Ansible/Docker Compose) have no
  # remote state — they document a local state file, a stateless posture, or
  # idempotent/declarative convergence. Accept those idioms too.
  item_check "SV-11" "State management strategy specified (state keyword present)" \
    "$(pattern_present "$ARTIFACT" '(state[[:space:]]+(management|backend|locking|storage|file)|remote[[:space:]]+state|terraform[[:space:]]+state|local[[:space:]]+state|\bstateless\b|idempotent[[:space:]]+(converg|appl)|declarative[[:space:]]+converg)')"

  # Observability (SV-12..SV-14)
  item_check "SV-12" "Observability section present (## Observability heading)" \
    "$(heading_present "$ARTIFACT" "Observability")"
  item_check "SV-13" "Alerting and escalation policies specified (alert/escalation keyword present)" \
    "$(pattern_present "$ARTIFACT" '(alert(ing|s)?|escalation|on-?call)')"
  item_check "SV-14" "Distributed tracing / correlation IDs planned (tracing keyword present)" \
    "$(pattern_present "$ARTIFACT" '(distributed[[:space:]]+tracing|correlation[[:space:]]+id|\btrace(s|ing)?\b)')"

  # Sidecar reference (SV-15)
  item_check "SV-15" "Decisions recorded in devops-sidecar (sidecar reference present)" \
    "$(pattern_present "$ARTIFACT" '(devops-sidecar|sidecar_decision[[:space:]]*:)')"

  # --- LLM-checkable items (10) ---
  printf '\n[LLM-CHECK] The following 10 items require semantic review by the host LLM:\n' >&2
  cat >&2 <<'EOF'
  LLM-01 — Every environment has a defined purpose and access policy
  LLM-02 — Environment parity strategy is coherent for the architecture
  LLM-03 — Container/compute strategy matches workload characteristics
  LLM-04 — Load balancing and scaling approach is technically sound
  LLM-05 — IaC module structure aligns with service boundaries
  LLM-06 — Logging strategy covers retention and aggregation for declared services
  LLM-07 — Metrics and dashboards cover the declared services
  LLM-08 — Alerting thresholds and escalation policies are realistic
  LLM-09 — Promotion gates between environments are defined and sensible
  LLM-10 — Infrastructure decisions traceable to architecture components they serve
EOF

  TOTAL_ITEMS=25
  LLM_ITEMS=10
  printf '\nChecklist summary: %d/%d script-verifiable items PASS; %d LLM-checkable items deferred to host review. Total items: %d.\n' \
    "$PASSED" "$CHECKED" "$LLM_ITEMS" "$TOTAL_ITEMS" >&2

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    printf '\nChecklist violations:\n' >&2
    for v in "${VIOLATIONS[@]}"; do
      printf '  - %s\n' "$v" >&2
    done
    printf 'Remediation: amend the infrastructure-design artifact to satisfy the failed items, then rerun /gaia-infra-design.\n' >&2
    CHECKLIST_STATUS=1
  else
    printf 'Checklist: all %d script-verifiable items PASS.\n' "$PASSED" >&2
    CHECKLIST_STATUS=0
  fi
else
  log "no infrastructure-design artifact found (INFRA_DESIGN_ARTIFACT unset and no infrastructure-design.md at .gaia/artifacts/planning-artifacts/ or docs/planning-artifacts/) — skipping checklist run"
  CHECKLIST_STATUS=0
fi

# ---------- 2. Write checkpoint (observability — never suppressed) ----------
if [ -x "$CHECKPOINT" ]; then
  if ! "$CHECKPOINT" write --workflow "$WORKFLOW_NAME" --step 6 >/dev/null 2>&1; then
    die "checkpoint.sh write failed for $WORKFLOW_NAME"
  fi
  log "checkpoint written for $WORKFLOW_NAME"
else
  log "checkpoint.sh not found at $CHECKPOINT — skipping checkpoint write (non-fatal)"
fi

# ---------- 3. Emit lifecycle event (observability — never suppressed) ----------
if [ -x "$LIFECYCLE_EVENT" ]; then
  if ! "$LIFECYCLE_EVENT" --type workflow_complete --workflow "$WORKFLOW_NAME" >/dev/null 2>&1; then
    die "lifecycle-event.sh emit failed for $WORKFLOW_NAME"
  fi
  log "lifecycle event emitted for $WORKFLOW_NAME"
else
  log "lifecycle-event.sh not found at $LIFECYCLE_EVENT — skipping event emission (non-fatal)"
fi

# ---------- 4. Auto-save session memory ----------
# Phase 1-3 skills auto-save a session summary to the agent sidecar via
# the shared lib helper. Phase 4 skills (e.g. /gaia-dev-story) short-
# circuit to a no-op so the interactive prompt is preserved. Failure is
# non-blocking — the auto-save helper itself logs warnings to stderr but
# never affects this script's exit code. SKILL_NAME is resolved from the
# parent directory name so the wire-in is identical across all Phase 1-3
# finalize.sh files.
AUTOSAVE_LIB="$PLUGIN_SCRIPTS_DIR/lib/auto-save-memory.sh"
SKILL_NAME="$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")"
if [ -f "$AUTOSAVE_LIB" ]; then
  # shellcheck disable=SC1090
  . "$AUTOSAVE_LIB"
  if ! _auto_save_memory "$SKILL_NAME" "${ARTIFACT:-}"; then
    AUTOSAVE_RC=$?
    if [ "$AUTOSAVE_RC" -eq 64 ]; then
      log "auto-save aborted: cannot resolve agent sidecar for skill $SKILL_NAME"
    fi
  fi
else
  log "auto-save-memory.sh not found at $AUTOSAVE_LIB — skipping auto-save (non-fatal)"
fi

log "finalize complete for $WORKFLOW_NAME"
exit "$CHECKLIST_STATUS"
