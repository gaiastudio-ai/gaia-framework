#!/usr/bin/env bash
# migrate-planning-vs-test.sh — planning-vs-test artifact taxonomy migration
#
# Moves the documents ABOUT testing — test-plan, test-strategy,
# traceability-matrix, nfr-assessment, performance-test-plan — out of
# test-artifacts/ (including the test-artifacts/strategy/ subdir) and into
# planning-artifacts/, and rewrites cross-references that point at the old
# location. test-artifacts/ keeps ONLY test-EXECUTION outputs (atdd,
# qa/test-review reports, execution-evidence, the test-environment manifest).
#
# Safety:
#   * --dry-run (DEFAULT): report every planned move + reference rewrite,
#     mutating NOTHING. A real migration requires the explicit --migrate flag.
#   * idempotent: re-running --migrate after a completed migration is a no-op.
#   * per-file rollback on failure: each already-moved file is restored to its
#     origin individually. The script NEVER `rm -rf` a source directory.
#   * phase-exit gate ITERATES the move manifest (each target exists) — it does
#     NOT count files against a cumulative target.
#
# READ-ONLY by default. Only --migrate mutates, and only the dirs passed in.
#
#

# Invocation:
#   migrate-planning-vs-test.sh --test-artifacts <dir> --planning-artifacts <dir>
#       [--dry-run | --migrate] [--simulate-fail-after N]
#   migrate-planning-vs-test.sh --help
#
# Exit codes:
#   0 — dry-run reported, or migration completed (or idempotent no-op)
#   1 — bad arguments, or migration failed (after per-file rollback)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="migrate-planning-vs-test.sh"

log() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
die() { log "$*"; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'USAGE'
migrate-planning-vs-test.sh — migrate docs-about-testing to planning-artifacts/

Usage:
  migrate-planning-vs-test.sh --test-artifacts <dir> --planning-artifacts <dir>
      [--dry-run | --migrate] [--simulate-fail-after N]

Moves test-plan / test-strategy / traceability-matrix / nfr-assessment /
performance-test-plan out of test-artifacts/(strategy/) into planning-artifacts/
and rewrites cross-references. Test-EXECUTION outputs (atdd, review reports,
execution-evidence) stay in test-artifacts/.

--dry-run (default) reports planned moves + rewrites, mutating nothing.
--migrate performs the move; it is idempotent and rolls back per-file on failure
(NEVER rm -rf the source). The completion gate iterates the move manifest.
USAGE
  exit 0
fi

# Canonical set of docs-ABOUT-testing to relocate (basename, no dir).
DOC_TYPES="test-plan test-strategy traceability-matrix nfr-assessment performance-test-plan"

TEST_ARTIFACTS=""
PLANNING_ARTIFACTS=""
MODE="dry-run"
FAIL_AFTER=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --test-artifacts) TEST_ARTIFACTS="${2:-}"; shift 2 ;;
    --planning-artifacts) PLANNING_ARTIFACTS="${2:-}"; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    --migrate) MODE="migrate"; shift ;;
    --simulate-fail-after) FAIL_AFTER="${2:-0}"; shift 2 ;;  # test affordance
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$TEST_ARTIFACTS" ] || die "--test-artifacts <dir> is required (try --help)"
[ -n "$PLANNING_ARTIFACTS" ] || die "--planning-artifacts <dir> is required (try --help)"
[ -d "$TEST_ARTIFACTS" ] || die "test-artifacts dir not found: $TEST_ARTIFACTS"

# ---------- Build the move manifest ----------
# A manifest entry is a "src<TAB>dst" line. Sources are searched at BOTH the
# test-artifacts root and its strategy/ subdir; the destination is always the
# planning-artifacts root with the same basename.
MANIFEST=""
for doc in $DOC_TYPES; do
  for src in "$TEST_ARTIFACTS/${doc}.md" "$TEST_ARTIFACTS/strategy/${doc}.md"; do
    if [ -f "$src" ]; then
      MANIFEST="${MANIFEST}${src}	${PLANNING_ARTIFACTS}/${doc}.md
"
    fi
  done
done

# Count manifest entries (iterating the manifest, NOT find|wc against a target).
manifest_count=0
if [ -n "$MANIFEST" ]; then
  manifest_count=$(printf '%s' "$MANIFEST" | grep -c $'\t')
fi

# Idempotency: if every doc already lives at planning-artifacts/ and no source
# remains, there is nothing to do.
if [ "$manifest_count" -eq 0 ]; then
  log "no docs-about-testing under $TEST_ARTIFACTS — nothing to migrate (idempotent no-op)"
  exit 0
fi

# ---------- Dry-run: report only ----------
if [ "$MODE" = "dry-run" ]; then
  printf '[dry-run] planned migration (%d move(s)) — no files will be mutated:\n' "$manifest_count"
  while IFS=$'\t' read -r src dst; do
    [ -n "$src" ] || continue
    printf '[dry-run] would move: %s -> %s\n' "$src" "$dst"
  done <<EOF
$MANIFEST
EOF
  printf '[dry-run] would rewrite cross-references from test-artifacts/(strategy/) to planning-artifacts/ across both trees.\n'
  exit 0
fi

# ---------- Migrate (per-file, with per-file rollback) ----------
mkdir -p "$PLANNING_ARTIFACTS"
moved_pairs=()     # "dst<TAB>src" for rollback (restore dst back to src)
n=0
migration_failed=0

while IFS=$'\t' read -r src dst; do
  [ -n "$src" ] || continue
  n=$((n + 1))
  # test affordance: simulate a mid-migration failure after N moves
  if [ "$FAIL_AFTER" -gt 0 ] && [ "$n" -gt "$FAIL_AFTER" ]; then
    log "simulated failure after $FAIL_AFTER move(s) — triggering per-file rollback"
    migration_failed=1
    break
  fi
  if [ ! -f "$src" ]; then
    # already moved (idempotent) — skip without counting as a failure
    continue
  fi
  if ! mv "$src" "$dst" 2>/dev/null; then
    log "move failed: $src -> $dst — triggering per-file rollback"
    migration_failed=1
    break
  fi
  moved_pairs+=("${dst}	${src}")
done <<EOF
$MANIFEST
EOF

if [ "$migration_failed" -eq 1 ]; then
  # PER-FILE rollback — restore each moved file to its origin. NEVER rm -rf.
  rb_idx=${#moved_pairs[@]}
  while [ "$rb_idx" -gt 0 ]; do
    rb_idx=$((rb_idx - 1))
    pair="${moved_pairs[$rb_idx]}"
    dst="${pair%%	*}"
    src="${pair#*	}"
    if [ -f "$dst" ]; then
      mv "$dst" "$src" 2>/dev/null || log "rollback warning: could not restore $dst -> $src"
    fi
  done
  die "migration failed and was rolled back per-file (origins restored); no source directory was removed"
fi

# ---------- Cross-reference rewrite ----------
# Rewrite any "test-artifacts/strategy/{doc}.md" or "test-artifacts/{doc}.md"
# reference to "planning-artifacts/{doc}.md" across both trees (skip binaries).
for doc in $DOC_TYPES; do
  # Newline-delimited grep -rl (NOT -Z/-d '': BSD grep -lZ does not emit a NUL
  # separator, so a read -d '' loop silently never fires). Artifact filenames do
  # not contain newlines, so newline-delimited iteration is safe here.
  while IFS= read -r ref_file; do
    [ -n "$ref_file" ] || continue
    [ -f "$ref_file" ] || continue
    # in-place rewrite via tmp + mv (atomic; no sed -i portability issues)
    tmp="$(mktemp "${ref_file}.tmp.XXXXXX")"
    sed -e "s#test-artifacts/strategy/${doc}.md#planning-artifacts/${doc}.md#g" \
        -e "s#test-artifacts/${doc}.md#planning-artifacts/${doc}.md#g" \
        "$ref_file" > "$tmp" && mv "$tmp" "$ref_file"
  done < <(grep -rl "test-artifacts/strategy/${doc}.md\|test-artifacts/${doc}.md" "$TEST_ARTIFACTS" "$PLANNING_ARTIFACTS" 2>/dev/null || true)
done

# ---------- Phase-exit gate: ITERATE the manifest (each target exists) ----------
verified=0
gate_failed=0
while IFS=$'\t' read -r src dst; do
  [ -n "$dst" ] || continue
  if [ -f "$dst" ]; then
    verified=$((verified + 1))
  else
    log "gate: expected migrated target missing: $dst"
    gate_failed=1
  fi
done <<EOF
$MANIFEST
EOF

if [ "$gate_failed" -eq 1 ]; then
  die "phase-exit gate failed — verified $verified of $manifest_count manifest targets"
fi

# Remove the now-empty strategy/ subdir ONLY if it exists and is empty
# (zero residual references already rewritten above). Per-dir rmdir, never rm -rf.
if [ -d "$TEST_ARTIFACTS/strategy" ]; then
  rmdir "$TEST_ARTIFACTS/strategy" 2>/dev/null \
    && log "removed empty test-artifacts/strategy/ (zero residual)" \
    || log "test-artifacts/strategy/ retained (non-empty — residual test-execution outputs present)"
fi

printf 'migration complete — verified %d of %d manifest target(s) at %s\n' \
  "$verified" "$manifest_count" "$PLANNING_ARTIFACTS"
exit 0
