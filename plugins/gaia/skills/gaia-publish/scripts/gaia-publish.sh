#!/usr/bin/env bash
# gaia-publish.sh — Five-step orchestrator for /gaia-publish per FR-525 + ADR-113.
#
# E100-S1. Sequential, no auto-retry, no auto-rollback. Mirrors /gaia-deploy
# semantics — recovery is user-initiated.
#
# Five steps (FR-525 canonical order):
#   (1) pre-publish gate         — verify CI green on source branch (stub for E100-S2)
#   (2) manifest version check   — read distribution.manifest, parse version, confirm == --version
#   (3) trigger publish          — dispatch the channel adapter (stub for E100-S4..S8)
#   (4) post-publish verify      — registry probe via adapter verify action (stub for E100-S3)
#   (5) final verdict            — emit per-step evidence to assessment doc; exit code reflects verdict
#
# Args:
#   --version <semver>      (required) the version to publish
#   --dry-run               exit cleanly after step 3 with steps 4-5 SKIPPED + dry-run marker
#   --skip-verify           bypass step 4 with a WARNING per NFR-082 opt-out
#   --strict-builtin        refuse custom-adapter shadows for sensitive channels per SR-82
#
# Exit codes:
#   0 — verdict PASSED (or dry-run exit after step 3)
#   1 — verdict FAILED (any step recorded FAILED)
#   2 — usage error (missing arg, malformed args, config not found, etc.)

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="$(basename "$0")"

err() { printf '%s: %s\n' "$prog" "$*" >&2; }
die() { err "$*"; exit "${2:-2}"; }

# ---------- Argument parsing ----------

VERSION=""
DRY_RUN=0
SKIP_VERIFY=0
STRICT_BUILTIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version requires an argument"
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#--version=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    --strict-builtin)
      STRICT_BUILTIN=1
      shift
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      die "unknown flag: $1"
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  die "usage: $prog --version <semver> [--dry-run] [--skip-verify] [--strict-builtin]"
fi

# ---------- Config resolution via E99 helpers ----------

# Resolve project-config.yaml path. Default to .gaia/config/project-config.yaml
# under CLAUDE_PROJECT_ROOT or PWD; allow PROJECT_CONFIG env override.
PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-$PWD}}"
PROJECT_CONFIG="${PROJECT_CONFIG:-$PROJECT_ROOT/.gaia/config/project-config.yaml}"

if [ ! -f "$PROJECT_CONFIG" ]; then
  die "project-config.yaml not found: $PROJECT_CONFIG"
fi

if ! command -v yq >/dev/null 2>&1; then
  die "yq required but not on PATH"
fi

# Read distribution fields via yq (single source of truth — yq, not re-parse).
CHANNEL=$(yq eval '.distribution.channel // ""' "$PROJECT_CONFIG" 2>/dev/null)
MANIFEST=$(yq eval '.distribution.manifest // ""' "$PROJECT_CONFIG" 2>/dev/null)
REGISTRY=$(yq eval '.distribution.registry // ""' "$PROJECT_CONFIG" 2>/dev/null)
RELEASE_WORKFLOW=$(yq eval '.distribution.release_workflow // ""' "$PROJECT_CONFIG" 2>/dev/null)

if [ -z "$CHANNEL" ]; then
  die "distribution.channel not set in $PROJECT_CONFIG — see /gaia-config-distribution"
fi

# ---------- Per-step state tracking ----------

STEP1_STATUS="PENDING"; STEP1_DETAIL=""
STEP2_STATUS="PENDING"; STEP2_DETAIL=""
STEP3_STATUS="PENDING"; STEP3_DETAIL=""
STEP4_STATUS="PENDING"; STEP4_DETAIL=""
STEP5_STATUS="PENDING"; STEP5_DETAIL=""

# Internal: emit a one-line progress marker per step.
_progress() {
  local step_num="$1" step_name="$2" status="$3" detail="$4"
  printf '[gaia-publish] step %d/5 (%s): %s%s\n' \
    "$step_num" "$step_name" "$status" \
    "${detail:+ — $detail}"
}

# ---------- Step 1: Pre-publish gate (stub — real impl lands in E100-S2) ----------

_step1_pre_publish_gate() {
  # E100-S2 wires the real ci_cd.promotion_chain[].ci_checks probe here.
  # For now, the stub emits PASSED with the not-yet-implemented marker so
  # downstream bats fixtures can exercise the orchestration shape.
  STEP1_STATUS="PASSED"
  STEP1_DETAIL="stub (E100-S2 will wire ci_cd.promotion_chain[].ci_checks probe)"
  _progress 1 "pre-publish-gate" "$STEP1_STATUS" "$STEP1_DETAIL"
}

# ---------- Step 2: Manifest version check ----------

_step2_manifest_version_check() {
  if [ -z "$MANIFEST" ]; then
    STEP2_STATUS="FAILED"
    STEP2_DETAIL="distribution.manifest is empty — cannot resolve version"
    _progress 2 "manifest-version-check" "$STEP2_STATUS" "$STEP2_DETAIL"
    return
  fi

  local manifest_path="$PROJECT_ROOT/$MANIFEST"
  if [ ! -f "$manifest_path" ]; then
    STEP2_STATUS="FAILED"
    STEP2_DETAIL="manifest file not found: $manifest_path"
    _progress 2 "manifest-version-check" "$STEP2_STATUS" "$STEP2_DETAIL"
    return
  fi

  # Best-effort version extraction across common manifest shapes:
  #   plugin.json / package.json — JSON: .version
  #   pyproject.toml             — TOML: project.version (loose grep)
  #   Cargo.toml                 — TOML: package.version
  #   pom.xml                    — XML:  /project/version
  local manifest_version=""
  case "$manifest_path" in
    *.json)
      if command -v jq >/dev/null 2>&1; then
        manifest_version=$(jq -r '.version // ""' "$manifest_path" 2>/dev/null)
      else
        manifest_version=$(grep -E '"version"[[:space:]]*:' "$manifest_path" | head -1 \
          | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
      fi
      ;;
    *.toml)
      manifest_version=$(grep -E '^version[[:space:]]*=' "$manifest_path" | head -1 \
        | sed -E 's/version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')
      ;;
    *.xml)
      manifest_version=$(grep -oE '<version>[^<]+</version>' "$manifest_path" | head -1 \
        | sed -E 's|<version>([^<]+)</version>|\1|')
      ;;
    *)
      # Generic: try the JSON path then TOML.
      manifest_version=$(grep -E '"version"[[:space:]]*:' "$manifest_path" 2>/dev/null | head -1 \
        | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
      [ -z "$manifest_version" ] && manifest_version=$(grep -E '^version[[:space:]]*=' "$manifest_path" 2>/dev/null | head -1 \
        | sed -E 's/version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')
      ;;
  esac

  # Normalize: strip leading 'v' from requested version for comparison.
  local req_version="${VERSION#v}"
  local mfst_version="${manifest_version#v}"

  if [ -z "$mfst_version" ]; then
    STEP2_STATUS="FAILED"
    STEP2_DETAIL="could not extract version from manifest $MANIFEST"
  elif [ "$mfst_version" != "$req_version" ]; then
    STEP2_STATUS="FAILED"
    STEP2_DETAIL="manifest version ($mfst_version) does not match --version ($req_version)"
  else
    STEP2_STATUS="PASSED"
    STEP2_DETAIL="manifest version $mfst_version matches --version"
  fi
  _progress 2 "manifest-version-check" "$STEP2_STATUS" "$STEP2_DETAIL"
}

# ---------- Step 3: Trigger publish (stub — real impl lands in E100-S4..S8) ----------

_step3_trigger_publish() {
  # E100-S4..S8 wire the real per-channel adapter dispatch here. For now,
  # the stub emits PASSED in dispatch mode (and DRY-RUN mode if --dry-run)
  # so the orchestration shape is testable.
  if [ "$DRY_RUN" = "1" ]; then
    STEP3_STATUS="PASSED"
    STEP3_DETAIL="dry-run dispatch (would publish channel=$CHANNEL version=$VERSION)"
  else
    STEP3_STATUS="PASSED"
    STEP3_DETAIL="stub (E100-S4..S8 will wire adapter dispatch for channel=$CHANNEL)"
  fi
  _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
}

# ---------- Step 4: Post-publish verify (stub — real impl lands in E100-S3) ----------

_step4_post_publish_verify() {
  if [ "$DRY_RUN" = "1" ]; then
    STEP4_STATUS="SKIPPED"
    STEP4_DETAIL="dry-run mode — verify/post-publish skipped"
    _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
    return
  fi
  if [ "$SKIP_VERIFY" = "1" ]; then
    STEP4_STATUS="SKIPPED"
    STEP4_DETAIL="WARNING: --skip-verify passed; post-publish registry probe bypassed (NFR-082 opt-out)"
    _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
    return
  fi
  # E100-S3 wires the real registry probe + retry-window logic here.
  STEP4_STATUS="PASSED"
  STEP4_DETAIL="stub (E100-S3 will wire registry verify probe + retry-window)"
  _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
}

# ---------- Step 5: Final verdict + assessment-doc emit ----------

_step5_final_verdict() {
  local verdict
  if [ "$DRY_RUN" = "1" ]; then
    STEP5_STATUS="SKIPPED"
    STEP5_DETAIL="dry-run mode — verify/post-publish skipped"
    _progress 5 "final-verdict" "$STEP5_STATUS" "$STEP5_DETAIL"
    verdict="DRY_RUN"
  else
    # PASSED only when all gating steps recorded PASSED.
    # Step 4 SKIPPED via --skip-verify is non-gating (operator opt-out).
    if [ "$STEP1_STATUS" = "PASSED" ] \
       && [ "$STEP2_STATUS" = "PASSED" ] \
       && [ "$STEP3_STATUS" = "PASSED" ] \
       && { [ "$STEP4_STATUS" = "PASSED" ] || [ "$STEP4_STATUS" = "SKIPPED" ]; }; then
      STEP5_STATUS="PASSED"
      verdict="PASSED"
    else
      STEP5_STATUS="FAILED"
      verdict="FAILED"
    fi
    STEP5_DETAIL="verdict: $verdict"
    _progress 5 "final-verdict" "$STEP5_STATUS" "$STEP5_DETAIL"
  fi

  # Emit assessment doc.
  local ts
  ts="$(date -u +'%Y%m%dT%H%M%SZ')"
  local artifacts_dir="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  # Fallback to legacy docs/ path on projects without the canonical .gaia/ tree.
  [ -d "$artifacts_dir" ] || artifacts_dir="$PROJECT_ROOT/docs/implementation-artifacts"
  mkdir -p "$artifacts_dir" 2>/dev/null || true
  local doc="$artifacts_dir/assessment-publish-$CHANNEL-$ts.md"

  cat > "$doc" <<EOF
# /gaia-publish Assessment — $CHANNEL — $ts

**Channel:** $CHANNEL
**Version:** $VERSION
**Manifest:** $MANIFEST
**Registry:** $REGISTRY
**Release workflow:** $RELEASE_WORKFLOW
**Dry-run:** $([ "$DRY_RUN" = "1" ] && echo "yes" || echo "no")
**Skip-verify:** $([ "$SKIP_VERIFY" = "1" ] && echo "yes" || echo "no")
**Strict-builtin:** $([ "$STRICT_BUILTIN" = "1" ] && echo "yes" || echo "no")

## Per-step evidence

| # | Step | Status | Detail |
|---|------|--------|--------|
| 1 | pre-publish-gate       | $STEP1_STATUS | $STEP1_DETAIL |
| 2 | manifest-version-check | $STEP2_STATUS | $STEP2_DETAIL |
| 3 | trigger-publish        | $STEP3_STATUS | $STEP3_DETAIL |
| 4 | post-publish-verify    | $STEP4_STATUS | $STEP4_DETAIL |
| 5 | final-verdict          | $STEP5_STATUS | $STEP5_DETAIL |

**Verdict:** $verdict
EOF
  printf '[gaia-publish] assessment doc: %s\n' "$doc"

  # Set process exit code from verdict.
  case "$verdict" in
    PASSED|DRY_RUN) return 0 ;;
    *)              return 1 ;;
  esac
}

# ---------- Orchestrate ----------

_step1_pre_publish_gate
# Short-circuit: if step 1 failed, downstream steps record SKIPPED.
if [ "$STEP1_STATUS" != "PASSED" ]; then
  STEP2_STATUS="SKIPPED"; STEP2_DETAIL="upstream step 1 did not PASS"
  STEP3_STATUS="SKIPPED"; STEP3_DETAIL="upstream step 1 did not PASS"
  STEP4_STATUS="SKIPPED"; STEP4_DETAIL="upstream step 1 did not PASS"
  _progress 2 "manifest-version-check" "$STEP2_STATUS" "$STEP2_DETAIL"
  _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
  _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
  _step5_final_verdict
  exit 1
fi

_step2_manifest_version_check
if [ "$STEP2_STATUS" != "PASSED" ]; then
  STEP3_STATUS="SKIPPED"; STEP3_DETAIL="upstream step 2 did not PASS"
  STEP4_STATUS="SKIPPED"; STEP4_DETAIL="upstream step 2 did not PASS"
  _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
  _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
  _step5_final_verdict
  exit 1
fi

_step3_trigger_publish
if [ "$STEP3_STATUS" != "PASSED" ]; then
  STEP4_STATUS="SKIPPED"; STEP4_DETAIL="upstream step 3 did not PASS"
  _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
  _step5_final_verdict
  exit 1
fi

_step4_post_publish_verify
_step5_final_verdict
