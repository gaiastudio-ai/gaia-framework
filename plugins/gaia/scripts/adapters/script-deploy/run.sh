#!/usr/bin/env bash
# adapters/script-deploy/run.sh — deploy-adapter contract for the reference
# script-deploy adapter.
#
# Contract:
#   run.sh --env <env> --version <ver> --output-dir <dir> [--components <list>]
#
# Resolves the user-declared deploy script from either:
#   1. SCRIPT_DEPLOY_PATH env-var (test override / explicit caller override)
#   2. `deployment.script_path` from config (resolved upstream by the skill;
#      the skill exports SCRIPT_DEPLOY_PATH before invoking run.sh)
#
# Exit codes:
#   0 — user deploy script exited 0
#   1 — user deploy script exited non-zero (BLOCKED upstream)
#   2 — usage / missing flag
#   3 — dormant environment: declared in config but not yet provisioned
#   127 — user deploy script not found or not executable
#
# Dormant environments:
#   When an environment is declared as deployable in config but not yet
#   provisioned on target infrastructure (environments.<env>.dormant: true
#   in project-config.yaml), the deploy script path is typically absent.
#   The caller signals this by setting GAIA_DEPLOY_ENV_DORMANT=1 before
#   invoking run.sh. The adapter then emits a distinct diagnostic and
#   exits 3, allowing operators to distinguish "not yet provisioned"
#   from a genuine misconfiguration (exit 127).

set -euo pipefail
LC_ALL=C
export LC_ALL

ENV_NAME=""
VERSION=""
OUTPUT_DIR=""
COMPONENTS=""

usage() {
  cat <<EOF
adapters/script-deploy/run.sh — Reference deploy adapter.
Usage:
  run.sh --env <env> --version <ver> --output-dir <dir> [--components <list>]

Reads the deploy script path from SCRIPT_DEPLOY_PATH (env-var) or from the
caller-resolved deployment.script_path. The script is invoked with the
positional arguments: <env> <version> <output-dir>. When --components is
provided, the value is exported as GAIA_DEPLOY_COMPONENTS so the user's
deploy script can scope the deploy to the named components.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --components) COMPONENTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$ENV_NAME" ] || [ -z "$VERSION" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "run.sh: --env, --version, --output-dir are required" >&2
  usage >&2
  exit 2
fi

# Path-traversal mitigation: reject env/version that contain shell-meta or path components.
case "$ENV_NAME" in
  */*|*..*|*$'\n'*|*' '*)
    echo "run.sh: invalid --env value (no slashes, dot-dot, or whitespace allowed)" >&2
    exit 2 ;;
esac

mkdir -p "$OUTPUT_DIR" || { echo "run.sh: cannot create output-dir: $OUTPUT_DIR" >&2; exit 2; }

DEPLOY_SCRIPT="${SCRIPT_DEPLOY_PATH:-}"
if [ -z "$DEPLOY_SCRIPT" ]; then
  if [ "${GAIA_DEPLOY_ENV_DORMANT:-0}" = "1" ]; then
    echo "run.sh: dormant environment '${ENV_NAME}' — declared in config but not yet provisioned; skipping deploy" >&2
    exit 3
  fi
  echo "run.sh: SCRIPT_DEPLOY_PATH not set (configure deployment.script_path)" >&2
  exit 127
fi
if [ ! -f "$DEPLOY_SCRIPT" ] || [ ! -x "$DEPLOY_SCRIPT" ]; then
  if [ "${GAIA_DEPLOY_ENV_DORMANT:-0}" = "1" ]; then
    echo "run.sh: dormant environment '${ENV_NAME}' — deploy script not provisioned: $DEPLOY_SCRIPT; skipping deploy" >&2
    exit 3
  fi
  echo "run.sh: deploy script not found or not executable: $DEPLOY_SCRIPT" >&2
  exit 127
fi

# Export GAIA_DEPLOY_COMPONENTS so the user's deploy script can scope the deploy.
if [ -n "$COMPONENTS" ]; then
  export GAIA_DEPLOY_COMPONENTS="$COMPONENTS"
fi

# Invoke the user's deploy script. Capture stdout / stderr to evidence files.
rc=0
"$DEPLOY_SCRIPT" "$ENV_NAME" "$VERSION" "$OUTPUT_DIR" \
  >"$OUTPUT_DIR/deploy.stdout" 2>"$OUTPUT_DIR/deploy.stderr" || rc=$?

if [ "$rc" -ne 0 ]; then
  echo "run.sh: user deploy script exited $rc — see $OUTPUT_DIR/deploy.stderr" >&2
  exit 1
fi

exit 0
