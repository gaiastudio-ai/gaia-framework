#!/usr/bin/env bash
# gen-ci-config.sh — generate the tracked, CI-scoped config slice for a repo
# whose full project config lives outside (and is gitignored within) the repo.
set -euo pipefail
LC_ALL=C
export LC_ALL
#
# Purpose
# -------
# Some projects keep the full `.gaia/config/project-config.yaml` OUTSIDE the
# published git repo (above the checkout root, untracked / gitignored — the
# published repo must not ship a particular project's config). In that layout a
# CI run checks out only the repo and the config is never on the runner, so the
# workflow config-resolution chain finds nothing and selective tests fall back
# to the full suite on every PR.
#
# This generator emits a MINIMAL, CI-SCOPED slice that IS safe to commit into
# the repo (at a sanctioned tracked path, e.g. `.gaia/ci-config.yaml`, via a
# .gitignore negation). The slice carries ONLY the fields the CI workflows read
# to build the test matrix — NO secrets, NO local/dev paths, NO environments,
# NO release/version_files, NO distribution. It is a derived projection of the
# canonical config; regenerate it whenever the canonical config changes and let
# a CI lint regenerate-and-diff to catch drift (lockfile pattern).
#
# Emitted fields (CI contract only):
#   - stacks[]            : name, language, paths, path, excludes, cross_refs,
#                           test_cmd, repository  (the matrix-construction inputs)
#   - ci_cd.promotion_chain : so the promotion-push full-suite rail fires
#   - test_policy           : per-trigger scope rules (when present)
#
# Usage
# -----
#   gen-ci-config.sh --config <canonical project-config.yaml> [--out <file>]
#
#   --config        canonical project-config.yaml (required)
#   --out           write here (default: stdout)
#   --strip-prefix  strip this leading path prefix from every stacks[].paths and
#                   stacks[].path entry, so the slice's globs are relative to the
#                   CHECKOUT ROOT where the slice is resolved (e.g. when the
#                   canonical config uses project-root-relative globs like
#                   `gaia-public/plugins/**` but CI checks out `gaia-public/` as
#                   the root, pass --strip-prefix gaia-public/). Optional.
#   --help          show help
#
# Exit: 0 ok | 1 usage/IO error.

usage() {
  cat <<'EOF'
gen-ci-config.sh — emit a tracked, CI-scoped config slice (stacks + promotion_chain + test_policy)

  --config <path>   canonical project-config.yaml (required)
  --out <path>      output file (default: stdout)
  --help            show this help

The emitted slice carries ONLY CI-matrix inputs — no secrets, no local paths,
no environments/release/distribution. Safe to commit at a sanctioned tracked
path so CI can resolve config at the checkout root.
EOF
}

CONFIG=""
OUT=""
STRIP_PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config)  CONFIG="${2:-}"; shift 2 ;;
    --config=*) CONFIG="${1#--config=}"; shift ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --out=*)   OUT="${1#--out=}"; shift ;;
    --strip-prefix) STRIP_PREFIX="${2:-}"; shift 2 ;;
    --strip-prefix=*) STRIP_PREFIX="${1#--strip-prefix=}"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'gen-ci-config.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$CONFIG" ] || { printf 'gen-ci-config.sh: --config is required\n' >&2; usage >&2; exit 1; }
[ -f "$CONFIG" ] || { printf 'gen-ci-config.sh: config not found: %s\n' "$CONFIG" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { printf 'gen-ci-config.sh: yq is required\n' >&2; exit 1; }

# Project the CI-only fields. `with_entries(select(.value != null))` drops keys
# absent from the canonical config so the slice stays minimal and deterministic.
# `... comments=""` strips ALL comments — the canonical config may carry internal
# bookkeeping comments that must never land in published/tracked source, and a
# comment-free slice is also more stable under regenerate-and-diff drift linting.
SLICE="$(STRIP="$STRIP_PREFIX" yq '
  {
    "stacks": .stacks,
    "ci_cd": (.ci_cd.promotion_chain | {"promotion_chain": .}),
    "test_policy": .test_policy
  } | with_entries(select(.value != null)) | ... comments=""
' "$CONFIG")"

# Rebase stack globs to the checkout root by stripping a leading prefix, so the
# slice resolves correctly when CI checks out a sub-tree as the root. Done as a
# second pass (env-fed) to keep the projection filter readable.
if [ -n "$STRIP_PREFIX" ]; then
  SLICE="$(printf '%s\n' "$SLICE" | STRIP="$STRIP_PREFIX" yq '
    (.stacks[].paths) |= map(sub("^" + strenv(STRIP), ""))
    | (.stacks[] | select(has("path")) | .path) |= sub("^" + strenv(STRIP), "")
  ')"
fi

HEADER="# Generated CI-scoped config slice — DO NOT EDIT BY HAND.
# Source: the canonical project-config.yaml (kept outside / gitignored within this repo).
# Regenerate: plugins/gaia/scripts/gen-ci-config.sh --config <canonical> --out .gaia/ci-config.yaml
# Carries ONLY CI-matrix inputs (stacks + ci_cd.promotion_chain + test_policy) —
# no secrets, no local paths, no environments/release/distribution. A CI lint
# regenerates this and fails on drift."

if [ -n "$OUT" ]; then
  mkdir -p -- "$(dirname -- "$OUT")"
  { printf '%s\n' "$HEADER"; printf '%s\n' "$SLICE"; } > "$OUT"
  printf 'gen-ci-config.sh: wrote CI config slice -> %s\n' "$OUT" >&2
else
  printf '%s\n' "$HEADER"
  printf '%s\n' "$SLICE"
fi
