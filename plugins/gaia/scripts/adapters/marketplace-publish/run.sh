#!/usr/bin/env bash
# adapters/marketplace-publish/run.sh — ADR-078 deploy-adapter contract for the
# marketplace-publish adapter (E78-S1, FR-423).
#
# Contract:
#   run.sh --env <env> --version <ver> --output-dir <dir> [--repository <owner/repo>] [--draft]
#
# Behavior:
#   1. Validates required flags (--env, --version, --output-dir).
#   2. If MARKETPLACE_PUBLISH_VERSION_FILE + MARKETPLACE_PUBLISH_VERSION_KEY are set
#      (or resolved upstream from project-config.yaml), reads the file and validates
#      the value at the key matches --version.
#   3. Creates a git tag matching --version and pushes it to origin (or to the
#      remote derived from --repository when supplied).
#   4. Invokes `gh release create <tag> [--repo <repo>] [--draft]` and forwards
#      its stdout JSON to {output-dir}/release.json. stderr from gh is forwarded
#      to {output-dir}/release.stderr on failure.
#
# Exit codes:
#   0   — release created successfully
#   1   — release failed (gh release create non-zero)
#   2   — usage / missing flag / version_file mismatch
#   127 — gh CLI not on PATH (probe should have caught this)
#
# Refs: ADR-078 §4 (run.sh contract), story AC3-AC6, PRD FR-423.

set -u
LC_ALL=C
export LC_ALL

ENV_NAME=""
VERSION=""
OUTPUT_DIR=""
REPOSITORY=""
DRAFT=0

usage() {
  cat <<EOF
adapters/marketplace-publish/run.sh — Publish plugin release to GitHub Releases (E78-S1).
Usage:
  run.sh --env <env> --version <ver> --output-dir <dir> [--repository <owner/repo>] [--draft]

Required flags:
  --env <env>            Target environment (informational; release is remote).
  --version <ver>        Release version / git tag name.
  --output-dir <dir>     Local directory for evidence files (release.json, release.stderr).

Optional flags:
  --repository <ow/repo> Override origin remote for tag push and gh release.
  --draft                Pass --draft to gh release create.

Environment overrides:
  MARKETPLACE_PUBLISH_VERSION_FILE  Path to a JSON file holding the version.
  MARKETPLACE_PUBLISH_VERSION_KEY   Key inside the file (e.g. "version").
  MARKETPLACE_PUBLISH_SKIP_VERSION_FILE=1
                                    Skip version_file validation (test/CI use).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)        ENV_NAME="${2-}"; shift 2 ;;
    --version)    VERSION="${2-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2-}"; shift 2 ;;
    --repository) REPOSITORY="${2-}"; shift 2 ;;
    --draft)      DRAFT=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Required-flag validation (AC3) ----------------------------------------
MISSING=""
[ -z "$ENV_NAME" ]   && MISSING="$MISSING --env"
[ -z "$VERSION" ]    && MISSING="$MISSING --version"
[ -z "$OUTPUT_DIR" ] && MISSING="$MISSING --output-dir"
if [ -n "$MISSING" ]; then
  echo "run.sh: missing required flag(s):${MISSING}" >&2
  usage >&2
  exit 2
fi

# Path-traversal mitigation on env / version.
case "$ENV_NAME" in
  */*|*..*|*$'\n'*|*' '*)
    echo "run.sh: invalid --env value (no slashes, dot-dot, or whitespace allowed)" >&2
    exit 2 ;;
esac
case "$VERSION" in
  */*|*..*|*$'\n'*|*' '*)
    echo "run.sh: invalid --version value (no slashes, dot-dot, or whitespace allowed)" >&2
    exit 2 ;;
esac

mkdir -p "$OUTPUT_DIR" || { echo "run.sh: cannot create output-dir: $OUTPUT_DIR" >&2; exit 2; }

# --- version_file validation (AC5) -----------------------------------------
if [ "${MARKETPLACE_PUBLISH_SKIP_VERSION_FILE:-0}" != "1" ]; then
  VFILE="${MARKETPLACE_PUBLISH_VERSION_FILE:-}"
  VKEY="${MARKETPLACE_PUBLISH_VERSION_KEY:-}"
  if [ -n "$VFILE" ] && [ -n "$VKEY" ]; then
    if [ ! -f "$VFILE" ]; then
      echo "run.sh: version_file not found: $VFILE" >&2
      exit 2
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "run.sh: jq required to read version_file" >&2
      exit 2
    fi
    extracted="$(jq -r --arg k "$VKEY" '.[$k] // ""' "$VFILE" 2>/dev/null || true)"
    if [ -z "$extracted" ]; then
      echo "run.sh: version key '$VKEY' not found or empty in $VFILE" >&2
      exit 2
    fi
    if [ "$extracted" != "$VERSION" ]; then
      echo "run.sh: version mismatch — version_file says '$extracted' but --version is '$VERSION'" >&2
      exit 2
    fi
  fi
fi

# --- gh availability -------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "run.sh: gh CLI not on PATH (probe.sh should have caught this)" >&2
  exit 127
fi
if ! command -v git >/dev/null 2>&1; then
  echo "run.sh: git not on PATH" >&2
  exit 127
fi

# --- Tag + push (AC6) ------------------------------------------------------
REMOTE="origin"
GH_REPO_ARGS=()
if [ -n "$REPOSITORY" ]; then
  GH_REPO_ARGS=(--repo "$REPOSITORY")
fi

# Best-effort tag create. Errors here are forwarded.
{ git tag "$VERSION" 2>"$OUTPUT_DIR/tag.stderr" || true; } >"$OUTPUT_DIR/tag.stdout"
{ git push "$REMOTE" "refs/tags/${VERSION}" 2>"$OUTPUT_DIR/push.stderr" || true; } >"$OUTPUT_DIR/push.stdout"

# --- gh release create (AC4, AC6) ------------------------------------------
GH_ARGS=(release create "$VERSION")
[ "$DRAFT" -eq 1 ] && GH_ARGS+=(--draft)
[ "${#GH_REPO_ARGS[@]}" -gt 0 ] && GH_ARGS+=("${GH_REPO_ARGS[@]}")
GH_ARGS+=(--title "$VERSION" --notes "Release $VERSION ($ENV_NAME)")

rc=0
gh "${GH_ARGS[@]}" \
  >"$OUTPUT_DIR/release.json" 2>"$OUTPUT_DIR/release.stderr" || rc=$?

if [ "$rc" -ne 0 ]; then
  echo "run.sh: gh release create failed (rc=$rc) — see $OUTPUT_DIR/release.stderr" >&2
  cat "$OUTPUT_DIR/release.stderr" >&2 || true
  exit 1
fi

exit 0
