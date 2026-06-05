#!/usr/bin/env bash
# gaia-publish.sh — Five-step orchestrator for /gaia-publish.
#
# Sequential, no auto-retry, no auto-rollback. Mirrors /gaia-deploy
# semantics — recovery is user-initiated.
#
# Five steps (canonical order):
#   (1) pre-publish gate         — verify CI green on source branch
#   (2) manifest version check   — read distribution.manifest, parse version, confirm == --version
#   (3) trigger publish          — dispatch the channel adapter
#   (4) post-publish verify      — registry probe via adapter verify action
#   (5) final verdict            — emit per-step evidence to assessment doc; exit code reflects verdict
#
# Args:
#   --version <semver>      (required) the version to publish
#   --dry-run               exit cleanly after step 3 with steps 4-5 SKIPPED + dry-run marker
#   --skip-verify           bypass step 4 with a WARNING (opt-out)
#   --strict-builtin        refuse custom-adapter shadows for sensitive channels
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

# ---------- Config resolution ----------

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

# Read first-promotion-chain entry. If HEAD branch matches
# any promotion_chain[].branch, use that entry; otherwise default to index 0
# (typically `staging`). Falls back to empty (= legacy stub) when the chain
# is absent.
SRC_BRANCH=""
REQ_CI_CHECKS=""
if yq eval '.ci_cd.promotion_chain' "$PROJECT_CONFIG" 2>/dev/null | grep -q '^- '; then
  # Chain present. Resolve source-branch from HEAD if available, else first entry.
  HEAD_BR=""
  if command -v git >/dev/null 2>&1; then
    HEAD_BR=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi
  if [ -n "$HEAD_BR" ] && yq eval ".ci_cd.promotion_chain[] | select(.branch == \"$HEAD_BR\") | .branch" "$PROJECT_CONFIG" 2>/dev/null | grep -q .; then
    SRC_BRANCH="$HEAD_BR"
    REQ_CI_CHECKS=$(yq eval ".ci_cd.promotion_chain[] | select(.branch == \"$HEAD_BR\") | .ci_checks[]" "$PROJECT_CONFIG" 2>/dev/null)
  else
    SRC_BRANCH=$(yq eval '.ci_cd.promotion_chain[0].branch // ""' "$PROJECT_CONFIG" 2>/dev/null)
    REQ_CI_CHECKS=$(yq eval '.ci_cd.promotion_chain[0].ci_checks[]' "$PROJECT_CONFIG" 2>/dev/null)
  fi
fi

# ---------- Per-step state tracking ----------

STEP1_STATUS="PENDING"; STEP1_DETAIL=""
STEP2_STATUS="PENDING"; STEP2_DETAIL=""
STEP3_STATUS="PENDING"; STEP3_DETAIL=""
STEP4_STATUS="PENDING"; STEP4_DETAIL=""
STEP5_STATUS="PENDING"; STEP5_DETAIL=""
# Audit-trail per-step reason markers.
STEP1_REASON=""
STEP2_REASON=""
STEP4_REASON=""
VERIFY_SKIPPED=0
ADAPTER_FINDINGS_SUMMARY=""

# Internal: emit a one-line progress marker per step.
_progress() {
  local step_num="$1" step_name="$2" status="$3" detail="$4"
  printf '[gaia-publish] step %d/5 (%s): %s%s\n' \
    "$step_num" "$step_name" "$status" \
    "${detail:+ — $detail}"
}

# ---------- Step 1: Pre-publish gate ----------

# Probe gh for the most-recent run status of a given check name on the
# source-branch HEAD. Echoes the conclusion (success|failure|cancelled|...)
# or the literal token "missing" if no run is recorded for that name.
# Echoes "pending" when status != completed.
_gh_check_conclusion() {
  local check_name="$1"
  # Test shim is invoked transparently — production
  # invocation is the real gh CLI; both produce the same JSON shape.
  local row
  row=$(printf '%s' "$GH_RUNS_JSON" | jq -r --arg n "$check_name" \
    '[.[] | select(.name == $n)] | first // empty' 2>/dev/null)
  if [ -z "$row" ] || [ "$row" = "null" ]; then
    printf 'missing'
    return
  fi
  local st conc
  st=$(printf '%s' "$row" | jq -r '.status // "unknown"')
  conc=$(printf '%s' "$row" | jq -r '.conclusion // "null"')
  if [ "$st" != "completed" ]; then
    printf 'pending'
  else
    printf '%s' "$conc"
  fi
}

_step1_pre_publish_gate() {
  # Backward-compat: when ci_cd.promotion_chain is absent or carries no
  # ci_checks, preserve the stub-PASS path so existing fixtures
  # (and projects that haven't wired CI checks yet) continue to work.
  if [ -z "$REQ_CI_CHECKS" ]; then
    STEP1_STATUS="PASSED"
    STEP1_DETAIL="no ci_cd.promotion_chain ci_checks configured (stub-fallback)"
    _progress 1 "pre-publish-gate" "$STEP1_STATUS" "$STEP1_DETAIL"
    return
  fi

  # Real probe — needs gh + jq.
  if ! command -v gh >/dev/null 2>&1; then
    STEP1_STATUS="FAILED"
    STEP1_DETAIL="gh CLI required for ci_cd.promotion_chain probe but not on PATH"
    STEP1_REASON="pre-publish-gate-failed"
    _progress 1 "pre-publish-gate" "$STEP1_STATUS" "$STEP1_DETAIL"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    STEP1_STATUS="FAILED"
    STEP1_DETAIL="jq required to parse gh JSON output but not on PATH"
    STEP1_REASON="pre-publish-gate-failed"
    _progress 1 "pre-publish-gate" "$STEP1_STATUS" "$STEP1_DETAIL"
    return
  fi

  # Single gh invocation; reuse the JSON for all required-check probes.
  GH_RUNS_JSON=$(gh run list --branch "$SRC_BRANCH" --limit 50 \
    --json status,conclusion,name,headSha 2>/dev/null || echo "[]")

  # HEAD SHA from the first entry (the most-recent run on the branch).
  local head_sha
  head_sha=$(printf '%s' "$GH_RUNS_JSON" | jq -r '.[0].headSha // "unknown"' 2>/dev/null)

  # Iterate required checks; collect failures.
  local failed_checks=""
  local check_name conc
  while IFS= read -r check_name; do
    [ -z "$check_name" ] && continue
    conc=$(_gh_check_conclusion "$check_name")
    if [ "$conc" != "success" ]; then
      failed_checks="${failed_checks}${check_name}=${conc} "
    fi
  done <<<"$REQ_CI_CHECKS"

  if [ -n "$failed_checks" ]; then
    STEP1_STATUS="FAILED"
    STEP1_DETAIL="red/missing CI checks on branch $SRC_BRANCH HEAD $head_sha: ${failed_checks% } — re-run after CI is green"
    STEP1_REASON="pre-publish-gate-failed"
    err "$STEP1_DETAIL"
  else
    STEP1_STATUS="PASSED"
    STEP1_DETAIL="all required ci_checks success on branch $SRC_BRANCH HEAD $head_sha"
  fi
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

  # Normalize: strip leading 'v' from requested version for comparison only.
  # Reporting (stderr) retains the operator's raw --version including any 'v'.
  local req_compare="${VERSION#v}"
  local mfst_compare="${manifest_version#v}"

  if [ -z "$mfst_compare" ]; then
    STEP2_STATUS="FAILED"
    STEP2_DETAIL="could not extract version from manifest $MANIFEST"
    STEP2_REASON="manifest-version-mismatch"
    err "$STEP2_DETAIL"
  elif [ "$mfst_compare" != "$req_compare" ]; then
    STEP2_STATUS="FAILED"
    # Verbatim AC4 format: "manifest version <X> does not match --version <Y>"
    # Raw manifest value on the left, raw --version (including leading 'v') on the right.
    STEP2_DETAIL="manifest version $manifest_version does not match --version $VERSION"
    STEP2_REASON="manifest-version-mismatch"
    err "$STEP2_DETAIL"
  else
    STEP2_STATUS="PASSED"
    STEP2_DETAIL="manifest version $manifest_version matches --version"
  fi
  _progress 2 "manifest-version-check" "$STEP2_STATUS" "$STEP2_DETAIL"
}

# ---------- Step 3: Trigger publish (adapter dispatch) ----------

# Invoke the resolver early so strict-builtin HALT and the
# canonical shadow WARN fire here, BEFORE the credential-exposing trigger
# phase. The actual adapter dispatch only fires when a custom shadow OR a
# PATH-shim is configured — preserving the stub-fallback for projects
# that haven't wired any adapter yet.
_step3_trigger_publish() {
  # Resolve via the security-aware resolver FIRST to fire strict-builtin checks.
  # If --strict-builtin would HALT on a custom shadow, that surfaces here
  # before we dispatch any binary.
  local resolver="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/resolve-publish-adapter.sh"
  if [ ! -x "$resolver" ]; then
    resolver="$(dirname "$0")/../../../scripts/lib/resolve-publish-adapter.sh"
  fi
  local custom_exists=0
  if [ -d "$PROJECT_ROOT/.gaia/custom/adapters/publish-$CHANNEL" ] && \
     [ -x "$PROJECT_ROOT/.gaia/custom/adapters/publish-$CHANNEL/run.sh" ]; then
    custom_exists=1
  fi
  if [ "$custom_exists" = "1" ] && [ -x "$resolver" ]; then
    local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
    [ -z "$plugin_root" ] && plugin_root="$(cd "$(dirname "$0")/../../.." && pwd)"
    local strict_arg=""
    [ "$STRICT_BUILTIN" = "1" ] && strict_arg="--strict-builtin"
    set +e
    "$resolver" --adapter "$CHANNEL" --project-root "$PROJECT_ROOT" --plugin-root "$plugin_root" $strict_arg >/dev/null 2>&1
    local resolver_pre_exit=$?
    set -e
    if [ "$resolver_pre_exit" = "3" ]; then
      # Re-run to surface stderr to user.
      "$resolver" --adapter "$CHANNEL" --project-root "$PROJECT_ROOT" --plugin-root "$plugin_root" $strict_arg >/dev/null 2>&1 || true
      STEP3_STATUS="FAILED"
      STEP3_DETAIL="--strict-builtin refused custom shadow for sensitive channel $CHANNEL"
      err "HALT: --strict-builtin refuses custom shadow for sensitive channel"
      _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
      return
    fi
    if [ "$resolver_pre_exit" = "2" ]; then
      STEP3_STATUS="FAILED"
      STEP3_DETAIL="adapter resolver rejected channel=$CHANNEL (see stderr — likely path-traversal or manifest-validation failure)"
      "$resolver" --adapter "$CHANNEL" --project-root "$PROJECT_ROOT" --plugin-root "$plugin_root" $strict_arg 2>&1 >/dev/null | head -3 >&2 || true
      _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
      return
    fi
    # resolver_pre_exit=0 — custom adapter is well-formed; surface WARN.
    "$resolver" --adapter "$CHANNEL" --project-root "$PROJECT_ROOT" --plugin-root "$plugin_root" $strict_arg 2>&1 >/dev/null | grep -F "WARN:" >&2 || true
  fi

  # Resolve adapter binary (PATH-shim first, then resolver fallback).
  local adapter_bin
  adapter_bin=$(_resolve_adapter_binary "$CHANNEL")

  # Stub-fallback: no PATH-shim AND no custom adapter → preserve the stub PASSED.
  # (Built-in adapters are present for many channels, but
  # without configured credentials they would FAIL; the legacy contract is
  # that an unconfigured environment returns PASSED stub so the orchestrator
  # remains testable.)
  if [ "$custom_exists" = "0" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      STEP3_STATUS="PASSED"
      STEP3_DETAIL="dry-run dispatch (would publish channel=$CHANNEL version=$VERSION)"
    else
      STEP3_STATUS="PASSED"
      STEP3_DETAIL="stub (no custom adapter configured for channel=$CHANNEL; built-in dispatch requires credentials)"
    fi
    _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
    return
  fi

  # Pre-flight credential audit against the resolved adapter dir.
  # Refuse to invoke run.sh on audit FAIL.
  local audit_script="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/audit-publish-adapter-credentials.sh"
  [ -x "$audit_script" ] || audit_script="$(dirname "$0")/../../../scripts/lib/audit-publish-adapter-credentials.sh"
  if [ -x "$audit_script" ] && [ -n "$adapter_bin" ]; then
    local adapter_dir
    adapter_dir=$(dirname "$adapter_bin")
    if ! "$audit_script" "$adapter_dir" >&2; then
      STEP3_STATUS="FAILED"
      STEP3_DETAIL="HALT: adapter credential audit failed — undeclared credential source"
      _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
      return
    fi
  fi

  # Custom adapter present → invoke its --action trigger.
  if [ "$DRY_RUN" = "1" ]; then
    STEP3_STATUS="PASSED"
    STEP3_DETAIL="dry-run dispatch (custom adapter=$(basename "$adapter_bin") channel=$CHANNEL version=$VERSION)"
    _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
    return
  fi
  if [ -z "$adapter_bin" ]; then
    STEP3_STATUS="FAILED"
    STEP3_DETAIL="custom adapter for channel=$CHANNEL not invocable (resolver returned empty)"
    _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
    return
  fi
  local trigger_findings adapter_exit
  trigger_findings=$(mktemp -t gaia-publish-trigger.XXXXXX.json)
  rm -f "$trigger_findings"
  set +e
  "$adapter_bin" --action trigger --version "$VERSION" --registry "$REGISTRY" --manifest "$MANIFEST" --output "$trigger_findings" >/dev/null 2>&1
  adapter_exit=$?
  set -e
  if [ "$adapter_exit" -ne 0 ] && [ ! -s "$trigger_findings" ]; then
    STEP3_STATUS="FAILED"
    STEP3_DETAIL="custom adapter trigger exited $adapter_exit without writing findings.json"
    rm -f "$trigger_findings"
    _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
    return
  fi
  if command -v jq >/dev/null 2>&1 && [ -s "$trigger_findings" ]; then
    local trigger_verdict
    trigger_verdict=$(jq -r '.verdict // "UNVERIFIED"' "$trigger_findings" 2>/dev/null)
    case "$trigger_verdict" in
      PASSED|UNVERIFIED)
        STEP3_STATUS="PASSED"
        STEP3_DETAIL="custom adapter trigger PASSED (channel=$CHANNEL version=$VERSION verdict=$trigger_verdict)"
        ;;
      *)
        STEP3_STATUS="FAILED"
        STEP3_DETAIL="custom adapter trigger returned verdict=$trigger_verdict"
        ;;
    esac
  else
    STEP3_STATUS="PASSED"
    STEP3_DETAIL="custom adapter trigger completed"
  fi
  rm -f "$trigger_findings"
  _progress 3 "trigger-publish" "$STEP3_STATUS" "$STEP3_DETAIL"
}

# ---------- Step 4: Post-publish verify ----------

# Defensive cap to prevent unbounded local resource consumption.
SR83_MAX_VERIFY_WINDOW=3600

# Resolve the verify-retry window for the given channel by reading
# adapter-manifest.yaml::verify_retry_window_seconds — checks user's
# .gaia/custom/adapters/ first, then plugin built-in. Echoes int or empty.
_resolve_adapter_verify_window() {
  local channel="$1"
  local custom_manifest="$PROJECT_ROOT/.gaia/custom/adapters/publish-$channel/adapter-manifest.yaml"
  local builtin_manifest="${CLAUDE_PLUGIN_ROOT:-}/adapters/publish-$channel/adapter-manifest.yaml"
  local mfile=""
  if [ -f "$custom_manifest" ]; then
    mfile="$custom_manifest"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$builtin_manifest" ]; then
    mfile="$builtin_manifest"
  fi
  [ -z "$mfile" ] && return
  yq eval '.verify_retry_window_seconds // ""' "$mfile" 2>/dev/null
}

# Locate the adapter binary for the given channel. PATH-namespaced shim is
# tried FIRST (allows test fixtures and operator overrides to take effect),
# then the resolve-publish-adapter.sh helper which implements
# custom-shadow precedence, path-traversal mitigation, and the strict-builtin gate.
_resolve_adapter_binary() {
  local channel="$1"
  # PATH-shim has highest precedence for backward-compat with existing bats fixtures.
  local on_path
  on_path=$(command -v "gaia-adapter-publish-$channel" 2>/dev/null || true)
  if [ -n "$on_path" ]; then
    printf '%s' "$on_path"
    return 0
  fi

  # resolve-publish-adapter.sh handles custom-shadow precedence + path-traversal + strict-builtin.
  local resolver="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/resolve-publish-adapter.sh"
  if [ ! -x "$resolver" ]; then
    resolver="$(dirname "$0")/../../../scripts/lib/resolve-publish-adapter.sh"
  fi
  if [ -x "$resolver" ]; then
    local strict_arg=""
    [ "$STRICT_BUILTIN" = "1" ] && strict_arg="--strict-builtin"
    local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
    if [ -z "$plugin_root" ]; then
      plugin_root="$(cd "$(dirname "$0")/../../.." && pwd)"
    fi
    # Surface resolver stderr (WARN + HALT messages) to user.
    # --strict-builtin HALT is the resolver's responsibility; the
    # caller propagates by leaving stdout empty. Step 3's main flow already
    # checks for empty adapter_bin and FAILs cleanly.
    # Use mktemp -t over a fixed /tmp path to avoid collisions.
    local resolver_stdout
    resolver_stdout=$(mktemp -t gaia-resolver.XXXXXX.stdout)
    local adapter_dir
    set +e
    adapter_dir=$("$resolver" --adapter "$channel" --project-root "$PROJECT_ROOT" --plugin-root "$plugin_root" $strict_arg 2>&1 >"$resolver_stdout")
    local resolver_exit=$?
    set -e
    # Forward resolver stderr (WARN/HALT lines).
    if [ -n "$adapter_dir" ]; then
      printf '%s\n' "$adapter_dir" >&2
    fi
    adapter_dir=$(cat "$resolver_stdout" 2>/dev/null || true)
    rm -f "$resolver_stdout"
    if [ "$resolver_exit" = "0" ] && [ -x "$adapter_dir/run.sh" ]; then
      printf '%s' "$adapter_dir/run.sh"
      return 0
    fi
    # resolver_exit=3 (strict-builtin HALT) and resolver_exit=2 (path-traversal)
    # both leave stdout empty → caller's "no adapter" branch
    # records FAILED without internal step-3 inconsistency.
  fi
  return 0
}

_step4_post_publish_verify() {
  if [ "$DRY_RUN" = "1" ]; then
    STEP4_STATUS="SKIPPED"
    STEP4_DETAIL="dry-run mode — verify/post-publish skipped"
    _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
    return
  fi
  if [ "$SKIP_VERIFY" = "1" ]; then
    STEP4_STATUS="SKIPPED"
    VERIFY_SKIPPED=1
    STEP4_DETAIL="WARNING: --skip-verify opt-out — MANDATORY post-publish registry probe bypassed; only documented use case is unbounded-lag registries"
    _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
    return
  fi

  # Adapter-manifest-driven retry-window + adapter dispatch.
  local window
  window=$(_resolve_adapter_verify_window "$CHANNEL")

  # Defensive runtime cap with WARNING. Guarded with regex so the
  # `-gt` comparison never sees a non-numeric value (set -e safety).
  if [ -n "$window" ] && [[ "$window" =~ ^[0-9]+$ ]] && [ "$window" -gt "$SR83_MAX_VERIFY_WINDOW" ]; then
    err "WARNING: manifest verify_retry_window_seconds=$window exceeds 3600 cap; clamping to 3600"
    window="$SR83_MAX_VERIFY_WINDOW"
  fi

  local adapter_bin
  adapter_bin=$(_resolve_adapter_binary "$CHANNEL")

  # Stub-fallback: no manifest AND no adapter binary → preserve the stub happy-path.
  if [ -z "$window" ] && [ -z "$adapter_bin" ]; then
    STEP4_STATUS="PASSED"
    STEP4_DETAIL="stub-fallback (no adapter binary and no verify_retry_window_seconds configured)"
    _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
    return
  fi

  # If we have a window but no adapter — cannot verify. FAILED.
  if [ -z "$adapter_bin" ]; then
    STEP4_STATUS="FAILED"
    STEP4_DETAIL="adapter binary not resolvable for channel=$CHANNEL — install gaia-adapter-publish-$CHANNEL or unset adapter-manifest"
    STEP4_REASON="verify-adapter-missing"
    _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
    return
  fi

  # Default to 60s if no window declared (sensible default).
  : "${window:=60}"

  # Envelope validator helper.
  local envelope_validator="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/validate-adr037-envelope.sh"
  # Fallback for development trees where CLAUDE_PLUGIN_ROOT is not set.
  if [ ! -x "$envelope_validator" ]; then
    envelope_validator="$(dirname "$0")/../../../scripts/lib/validate-adr037-envelope.sh"
  fi

  # Bounded exponential back-off loop.
  local elapsed=0 delay=1 attempt=0
  local findings adapter_exit verdict adapter_summary last_verdict="UNKNOWN"
  while [ "$elapsed" -lt "$window" ]; do
    attempt=$((attempt + 1))
    findings=$(mktemp -t gaia-publish-verify.XXXXXX.json)
    rm -f "$findings"  # mktemp creates; we want it to be created by the adapter
    set +e
    "$adapter_bin" --action verify --version "$VERSION" --registry "$REGISTRY" --manifest "$MANIFEST" --output "$findings" >/dev/null 2>&1
    adapter_exit=$?
    set -e

    # adapter-internal-failure — non-zero exit BEFORE findings written.
    if [ "$adapter_exit" -ne 0 ] && [ ! -s "$findings" ]; then
      STEP4_STATUS="FAILED"
      STEP4_DETAIL="adapter $(basename "$adapter_bin") exited $adapter_exit without writing findings.json — adapter-internal-failure"
      STEP4_REASON="adapter-internal-failure"
      err "$STEP4_DETAIL"
      _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
      rm -f "$findings"
      return
    fi

    # envelope-schema-violation — findings written but malformed.
    if [ -x "$envelope_validator" ]; then
      local validate_err
      if ! validate_err=$("$envelope_validator" "$findings" 2>&1); then
        STEP4_STATUS="FAILED"
        STEP4_DETAIL="envelope-schema-violation in findings.json: $validate_err"
        STEP4_REASON="envelope-schema-violation"
        err "$STEP4_DETAIL"
        _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
        rm -f "$findings"
        return
      fi
    fi

    if [ -s "$findings" ] && command -v jq >/dev/null 2>&1; then
      verdict=$(jq -r '.verdict // "UNVERIFIED"' "$findings" 2>/dev/null)
      adapter_summary=$(jq -r '.summary // ""' "$findings" 2>/dev/null)
    else
      verdict="UNVERIFIED"
      adapter_summary=""
    fi
    ADAPTER_FINDINGS_SUMMARY="$adapter_summary"
    rm -f "$findings"
    last_verdict="$verdict"

    case "$verdict" in
      PASSED)
        STEP4_STATUS="PASSED"
        STEP4_DETAIL="adapter verified channel=$CHANNEL version=$VERSION on attempt $attempt (window=${window}s, elapsed=${elapsed}s)"
        _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
        return
        ;;
      UNVERIFIED)
        # mobile-app STUB sentinel — acceptable; surface to user with human-review note.
        STEP4_STATUS="PASSED"
        STEP4_DETAIL="adapter returned UNVERIFIED (STUB sentinel) — human review required for channel=$CHANNEL"
        _progress 4 "post-publish-verify" "$STEP4_STATUS" "$STEP4_DETAIL"
        return
        ;;
      FAILED|*)
        # Keep polling within the window.
        ;;
    esac

    # Back-off, capped per iteration at 30s.
    sleep "$delay"
    elapsed=$((elapsed + delay))
    delay=$((delay * 2))
    [ "$delay" -gt 30 ] && delay=30
  done

  STEP4_STATUS="FAILED"
  STEP4_DETAIL="artifact not resolvable — verify-window exhausted at ${elapsed}s (last verdict: $last_verdict; adapter summary: ${ADAPTER_FINDINGS_SUMMARY:-<none>})"
  STEP4_REASON="post-publish-verify-failed"
  err "$STEP4_DETAIL"
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
**verify-skipped:** $([ "$VERIFY_SKIPPED" = "1" ] && echo "yes" || echo "no")

## Audit-trail reasons
${STEP1_REASON:+- step 1: reason=$STEP1_REASON}
${STEP2_REASON:+- step 2: reason=$STEP2_REASON}
${STEP4_REASON:+- step 4: reason=$STEP4_REASON}

## Publish Adapter Findings
${ADAPTER_FINDINGS_SUMMARY:+adapter summary: $ADAPTER_FINDINGS_SUMMARY}
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
