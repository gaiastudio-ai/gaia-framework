#!/usr/bin/env bash
# audit-v2-migration.sh — E28-S190 audit harness
#
# Purpose: Exercise every installed plugin skill's setup.sh + finalize.sh after
# a v1→v2 /gaia-migrate apply and capture exit code + stderr per skill. The
# output is a machine-readable CSV the audit writeup consumes.
#
# Scope: READ-ONLY against the reporter's workspace. This script operates on a
# /tmp/ copy. It does NOT run /gaia-migrate apply against the caller's
# workspace — the caller provides a pre-migrated fixture directory.
#
# Usage:
#   audit-v2-migration.sh \
#     --plugin-cache <path-to-cache/gaia/VERSION/skills> \
#     --project-root <path-to-pre-migrated-project> \
#     [--out <output-csv-path>] \
#     [--fixture-mode minimal|enriched]
#
# Fixture modes (E28-S200 — unblocks E28-S195):
#   minimal   (default) — no prereq artifacts pre-created; harness run
#                         surfaces FixtureGap residuals intentionally so
#                         skills that depend on prereq artifacts expose
#                         the bug. This is the bug-detection mode.
#   enriched            — opt-in. Pre-creates prereq artifacts
#                         (prd.md, epics-and-stories.md, test-plan.md,
#                         traceability-matrix.md, ci-setup.md) under
#                         $PROJECT_ROOT/docs/{planning,test}-artifacts/,
#                         seeds config/project-config.yaml (E28-S213) so
#                         resolve-config.sh satisfies its priority ladder
#                         and skills that call it exit 0 rather than B1,
#                         and EXPORTS uppercase env vars
#                         ($TEST_ARTIFACTS, $PLANNING_ARTIFACTS,
#                         $IMPLEMENTATION_ARTIFACTS) before each skill run,
#                         so skill setup.sh scripts + validate-gate.sh pick
#                         up the paths instead of PWD-relative defaults.
#                         Designed for CI regression gating (E28-S195).
#
# Exit codes (E28-S195 AC8 — split 1 vs 2):
#   0 — audit completed and every skill landed in OK or NO-SCRIPTS bucket
#       (no B1-B5 failures). The CSV is still the authoritative per-skill
#       detail surface.
#   1 — audit completed but ONE OR MORE skills landed in a failure bucket
#       (B1, B2, B3, B4, or B5). This is a PLUGIN REGRESSION — the CI gate
#       on this exit code is the whole point of E28-S195. Pre-E28-S195 the
#       harness conflated this with harness-bug exit code; downstream CI
#       diagnostics now distinguish "plugin regressed" from "harness bug".
#   2 — harness misconfiguration or runtime error (missing flags, unreadable
#       plugin cache, unknown --fixture-mode value, fixture pre-creation
#       failed). This is a HARNESS BUG — the audit did not run meaningfully
#       and CI should surface the problem loudly but distinctly from exit 1.
#
# CI integration (E28-S195 AC6, AC7):
#   - When $CI is truthy (GitHub Actions sets CI=true) and no --fixture-mode
#     flag is given, the harness defaults to --fixture-mode enriched. Local
#     invocations still default to minimal for backwards compat.
#   - At end-of-run the harness emits a machine-readable summary line to
#     stderr:
#       audit-v2-migration: result=<PASS|FAIL> total=<N> ok=<N> \
#         no_scripts=<N> failed=<N>
#   - When $GITHUB_STEP_SUMMARY points at a file, the harness appends a
#     short markdown block (header + totals table) so the GitHub Actions
#     run page surfaces a human-readable summary.
#
# Output schema (CSV header):
#   skill_name,has_setup,setup_exit,setup_stderr_head,has_finalize,
#     finalize_exit,finalize_stderr_head,bucket
#
# Bucket classification (see E28-S190 story):
#   B1 — CLAUDE_SKILL_DIR path contract mismatch
#   B2 — Checkpoint write target deleted by migration
#   B3 — SKILL.md body references _gaia/_config/ literal paths
#   B4 — Missing global.yaml overlay fallback
#   B5 — Other
#   OK — setup & finalize both exited 0

set -uo pipefail
LC_ALL=C
export LC_ALL

die() { printf 'audit-v2-migration: %s\n' "$1" >&2; exit 2; }

PLUGIN_CACHE=""
PROJECT_ROOT=""
OUT=""
# E28-S195 AC7 — default to enriched under CI (GitHub Actions sets CI=true),
# minimal otherwise for local backward compatibility. Explicit --fixture-mode
# on the command line always wins over this default.
FIXTURE_MODE_DEFAULT="minimal"
if [ -n "${CI:-}" ] && [ "${CI:-}" != "false" ] && [ "${CI:-}" != "0" ]; then
  FIXTURE_MODE_DEFAULT="enriched"
fi
FIXTURE_MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-cache) PLUGIN_CACHE="$2"; shift 2 ;;
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --out)          OUT="$2"; shift 2 ;;
    --fixture-mode) FIXTURE_MODE="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,78p' "$0" >&2; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Resolve default when --fixture-mode was not passed (E28-S195 AC7).
if [ -z "$FIXTURE_MODE" ]; then
  FIXTURE_MODE="$FIXTURE_MODE_DEFAULT"
fi

[ -n "$PLUGIN_CACHE" ] || die "--plugin-cache <path> is required"
[ -n "$PROJECT_ROOT" ] || die "--project-root <path> is required"
[ -d "$PLUGIN_CACHE" ] || die "plugin-cache dir not found: $PLUGIN_CACHE"
[ -d "$PROJECT_ROOT" ] || die "project-root dir not found: $PROJECT_ROOT"

case "$FIXTURE_MODE" in
  minimal|enriched) ;;
  *) die "unsupported --fixture-mode '$FIXTURE_MODE' (expected minimal|enriched)" ;;
esac

if [ -z "$OUT" ]; then
  OUT="$(mktemp -t gaia-audit-v2.XXXXXX.csv)"
fi

# ---------- Helpers ----------

stderr_head() {
  # Collapse newlines and keep first 5 lines, quote CSV-safely.
  local text="$1"
  printf '%s' "$text" \
    | head -n 5 \
    | tr '\n' ' ' \
    | sed 's/"/""/g'
}

classify() {
  # Echo bucket based on setup/finalize stderr text.
  local combined="$1"
  if printf '%s' "$combined" | grep -qE 'resolve-config: (no config path|config file not found)'; then
    printf '%s' 'B1'
    return
  fi
  if printf '%s' "$combined" | grep -qE 'checkpoint\.sh: .*write failed|_memory/checkpoints.*(not found|No such file)'; then
    printf '%s' 'B2'
    return
  fi
  if printf '%s' "$combined" | grep -qE '_gaia/_config/.*\.(csv|yaml)|_gaia/_config/.*No such file'; then
    printf '%s' 'B3'
    return
  fi
  if printf '%s' "$combined" | grep -qE 'global\.yaml.*(not found|No such file)'; then
    printf '%s' 'B4'
    return
  fi
  printf '%s' 'B5'
}

run_script() {
  # run_script <absolute-script-path> <skill-dir>
  # Echoes "<exit_code>\t<stderr text>" (tab-separated).
  #
  # CLAUDE_SKILL_DIR emulates Claude Code's plugin harness convention:
  # it points at the skill directory, NOT the project root.
  #
  # E28-S200 / AC8 — enriched fixture mode exports the uppercase
  # artifact-dir env vars before each skill run. Skill setup.sh scripts
  # use the pattern `${TEST_ARTIFACTS:-docs/test-artifacts}` so without
  # these exports the fallback points at /tmp/fixture/docs/… which does
  # not exist (the minimal fixture intentionally omits those files). We
  # export ONLY in enriched mode so minimal mode continues to surface
  # FixtureGap residuals (AC10). FIXTURE_ENV_EXPORTS is populated once,
  # at the top of the main loop, and consumed here via env's positional
  # VAR=VALUE syntax — no duplicated subshell blocks.
  local script="$1" skill_dir="$2"
  local stderr_txt exit_code
  stderr_txt=$(
    env \
      CLAUDE_SKILL_DIR="$skill_dir" \
      CLAUDE_PROJECT_ROOT="$PROJECT_ROOT" \
      "${FIXTURE_ENV_EXPORTS[@]}" \
      bash "$script" 2>&1 1>/dev/null
  )
  exit_code=$?
  printf '%s\t%s' "$exit_code" "$stderr_txt"
}

# ---------- Fixture env exports (E28-S200 / AC8) ----------
# Declared at module scope so run_script's env invocation can expand it
# without an empty-array safety dance on macOS bash 3.2.
FIXTURE_ENV_EXPORTS=()
if [ "$FIXTURE_MODE" = "enriched" ]; then
  FIXTURE_ENV_EXPORTS=(
    "TEST_ARTIFACTS=$PROJECT_ROOT/docs/test-artifacts"
    "PLANNING_ARTIFACTS=$PROJECT_ROOT/docs/planning-artifacts"
    "IMPLEMENTATION_ARTIFACTS=$PROJECT_ROOT/docs/implementation-artifacts"
    # AF-2026-05-22-9 Bug-12: gaia-sprint-review/finalize.sh now hard-errors
    # when SPRINT_ID is unset unless this fixture-opt-in flag is set. The
    # audit harness is the canonical legacy-fixture invocation path the
    # comment in finalize.sh refers to — we don't have a real SPRINT_ID to
    # export here, so set the fixture flag.
    "GAIA_SPRINT_REVIEW_FIXTURE=1"
  )
fi

# ---------- Enriched fixture pre-creation (E28-S200 / AC6; E28-S213) ----------
#
# Creates the prereq artifacts multiple skills expect (validate-gate.sh
# gate list: prd_exists, epics_and_stories_exists, test_plan_exists,
# traceability_exists, ci_setup_exists) and seeds config/project-config.yaml
# so resolve-config.sh's priority ladder resolves correctly (E28-S213).
# Content is a minimal non-empty placeholder — the audit harness only cares
# that files exist and are non-empty, not that they are semantically valid.
#
# Runs exactly once BEFORE the main loop so every skill's setup.sh sees
# the same enriched state. Minimal mode does NOT call this — that's what
# keeps the bug-detection signal intact (AC10).
prepare_enriched_fixture() {
  local planning_dir="$PROJECT_ROOT/docs/planning-artifacts"
  local test_dir="$PROJECT_ROOT/docs/test-artifacts"
  local impl_dir="$PROJECT_ROOT/docs/implementation-artifacts"
  local creative_dir="$PROJECT_ROOT/docs/creative-artifacts"
  # AF-2026-05-21-20: also seed canonical .gaia/artifacts/ dirs.
  local canonical_planning_dir="$PROJECT_ROOT/.gaia/artifacts/planning-artifacts"
  local canonical_test_dir="$PROJECT_ROOT/.gaia/artifacts/test-artifacts"
  local canonical_impl_dir="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  local canonical_creative_dir="$PROJECT_ROOT/.gaia/artifacts/creative-artifacts"
  mkdir -p "$planning_dir" "$test_dir" "$impl_dir" "$creative_dir"
  mkdir -p "$canonical_planning_dir" "$canonical_test_dir" "$canonical_impl_dir" "$canonical_creative_dir"

  # E45-S2 — Seed a brainstorm fixture so gaia-product-brief's
  # pre_start quality gate passes in enriched mode. The audit only cares
  # that the file exists. AF-2026-05-21-20: gate now checks canonical
  # .gaia/artifacts/creative-artifacts/ — seed there too.
  if [ ! -s "$creative_dir/brainstorm-fixture.md" ]; then
    printf '# placeholder — audit-v2-migration.sh --fixture-mode enriched (E45-S2 brainstorm prereq)\n' \
      > "$creative_dir/brainstorm-fixture.md"
  fi
  if [ ! -s "$canonical_creative_dir/brainstorm-fixture.md" ]; then
    printf '# placeholder — audit-v2-migration.sh --fixture-mode enriched (AF-21-20 canonical brainstorm prereq)\n' \
      > "$canonical_creative_dir/brainstorm-fixture.md"
  fi

  # Write only if absent so re-running the harness is idempotent. The file
  # set covers every validate-gate.sh gate the installed skills invoke
  # under setup.sh or finalize.sh (audited against the full plugin cache):
  #   - prd.md + epics-and-stories.md    (planning_artifacts)
  #   - test-plan.md + traceability-matrix.md + ci-setup.md (test_artifacts)
  #   - readiness-report.md              (planning_artifacts — deploy-checklist
  #                                       finalize needs this)
  local f
  for f in "$planning_dir/prd.md" "$planning_dir/epics-and-stories.md" \
           "$planning_dir/readiness-report.md" \
           "$test_dir/test-plan.md" "$test_dir/traceability-matrix.md" \
           "$test_dir/ci-setup.md"; do
    if [ ! -s "$f" ]; then
      printf '# placeholder — audit-v2-migration.sh --fixture-mode enriched\n' > "$f"
    fi
  done

  # E28-S213 — Seed config/project-config.yaml so resolve-config.sh's
  # priority ladder ($CLAUDE_PROJECT_ROOT/config/project-config.yaml) resolves
  # and skills that call resolve-config.sh as their first step exit 0 instead
  # of being classified B1. The guard mirrors the placeholder loop above:
  # write only when absent so re-running the harness is idempotent (AC4).
  local config_dir="$PROJECT_ROOT/config"
  local config_file="$config_dir/project-config.yaml"
  mkdir -p "$config_dir"
  if [ ! -s "$config_file" ]; then
    # Resolve the absolute project_root at write time — same pattern used
    # elsewhere in the harness for env exports.
    local abs_root
    abs_root="$(cd "$PROJECT_ROOT" && pwd)"
    cat > "$config_file" <<YAML
framework_version: "1.0.0-fixture"
date: "2026-01-01"
project_root: "$abs_root"
project_path: "."
memory_path: "$abs_root/_memory"
checkpoint_path: "$abs_root/_memory/checkpoints"
installed_path: "$abs_root/_gaia"
planning_artifacts: "$abs_root/docs/planning-artifacts"
implementation_artifacts: "$abs_root/docs/implementation-artifacts"
test_artifacts: "$abs_root/docs/test-artifacts"
YAML
  fi
}

if [ "$FIXTURE_MODE" = "enriched" ]; then
  prepare_enriched_fixture
fi

# ---------- Main loop ----------

printf 'skill_name,has_setup,setup_exit,setup_stderr_head,has_finalize,finalize_exit,finalize_stderr_head,bucket\n' > "$OUT"

total=0
failed=0
ok_count=0
no_scripts_count=0
b1=0; b2=0; b3=0; b4=0; b5=0

for skill_dir in "$PLUGIN_CACHE"/*/; do
  [ -d "$skill_dir" ] || continue
  skill_name=$(basename "$skill_dir")
  total=$((total + 1))

  setup_sh="$skill_dir/scripts/setup.sh"
  finalize_sh="$skill_dir/scripts/finalize.sh"

  has_setup=0
  setup_exit=""
  setup_err=""
  if [ -f "$setup_sh" ]; then
    has_setup=1
    result=$(run_script "$setup_sh" "$skill_dir")
    setup_exit="${result%%	*}"
    setup_err="${result#*	}"
  fi

  has_finalize=0
  finalize_exit=""
  finalize_err=""
  if [ -f "$finalize_sh" ]; then
    has_finalize=1
    result=$(run_script "$finalize_sh" "$skill_dir")
    finalize_exit="${result%%	*}"
    finalize_err="${result#*	}"
  fi

  combined="${setup_err}"$'\n'"${finalize_err}"
  if [ "$has_setup" -eq 0 ] && [ "$has_finalize" -eq 0 ]; then
    bucket="NO-SCRIPTS"
    no_scripts_count=$((no_scripts_count + 1))
  elif [ "${setup_exit:-0}" = "0" ] && [ "${finalize_exit:-0}" = "0" ]; then
    bucket="OK"
    ok_count=$((ok_count + 1))
  else
    bucket=$(classify "$combined")
    failed=$((failed + 1))
    case "$bucket" in
      B1) b1=$((b1 + 1)) ;;
      B2) b2=$((b2 + 1)) ;;
      B3) b3=$((b3 + 1)) ;;
      B4) b4=$((b4 + 1)) ;;
      *)  b5=$((b5 + 1)) ;;
    esac
  fi

  printf '%s,%d,%s,"%s",%d,%s,"%s",%s\n' \
    "$skill_name" \
    "$has_setup" "${setup_exit:-}" "$(stderr_head "$setup_err")" \
    "$has_finalize" "${finalize_exit:-}" "$(stderr_head "$finalize_err")" \
    "$bucket" >> "$OUT"
done

# ---------- Summary ----------
printf '\n=== audit-v2-migration summary ===\n' >&2
printf 'fixture_mode: %s\n' "$FIXTURE_MODE" >&2
printf 'total_skills: %d\n' "$total" >&2
printf 'failed_skills: %d\n' "$failed" >&2
printf 'bucket_B1_path_contract: %d\n' "$b1" >&2
printf 'bucket_B2_checkpoint_deleted: %d\n' "$b2" >&2
printf 'bucket_B3_skill_md_literal_paths: %d\n' "$b3" >&2
printf 'bucket_B4_global_yaml_overlay: %d\n' "$b4" >&2
printf 'bucket_B5_other: %d\n' "$b5" >&2
printf 'output_csv: %s\n' "$OUT" >&2

# ---------- Machine-readable summary line (E28-S195 AC6) ----------
# CI parses this single line to produce a step-level status string. Format
# is contract-stable: `result=<PASS|FAIL>` key first, then counts in fixed
# order. Keep on ONE line — downstream greppers rely on this.
if [ "$failed" -gt 0 ]; then
  summary_result="FAIL"
else
  summary_result="PASS"
fi
printf 'audit-v2-migration: result=%s total=%d ok=%d no_scripts=%d failed=%d\n' \
  "$summary_result" "$total" "$ok_count" "$no_scripts_count" "$failed" >&2

# ---------- GitHub Actions step summary (E28-S195 AC7) ----------
# When GITHUB_STEP_SUMMARY is set (it is on every GitHub Actions runner),
# append a markdown block rendering the audit outcome as a table. This
# surfaces on the Actions run page under the "Summary" pane without the
# developer needing to open the job log. Silent no-op when the var is
# empty (local runs).
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### audit-v2-migration (%s)\n\n' "$summary_result"
    printf '**Fixture mode:** `%s`  \n' "$FIXTURE_MODE"
    printf '**CSV artifact:** `%s`  \n\n' "$OUT"
    printf '| Bucket | Count |\n'
    printf '| --- | ---: |\n'
    printf '| OK | %d |\n' "$ok_count"
    printf '| NO-SCRIPTS | %d |\n' "$no_scripts_count"
    printf '| B1 path-contract | %d |\n' "$b1"
    printf '| B2 checkpoint-deleted | %d |\n' "$b2"
    printf '| B3 SKILL.md literal paths | %d |\n' "$b3"
    printf '| B4 global.yaml overlay | %d |\n' "$b4"
    printf '| B5 other | %d |\n' "$b5"
    printf '| **Total** | **%d** |\n' "$total"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# ---------- Exit code (E28-S195 AC8) ----------
# 0 — all skills OK or NO-SCRIPTS
# 1 — one or more B1-B5 failures (plugin regression — the CI gate signal)
# 2 — harness misconfig (already handled earlier via `die`)
if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
