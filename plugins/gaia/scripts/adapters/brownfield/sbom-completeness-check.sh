#!/usr/bin/env bash
# adapters/brownfield/sbom-completeness-check.sh — E104-S3 SBOM completeness check.
#
# Compares the declared dependency count (parsed from lock files) against the
# cdxgen SBOM component count, and emits a WARNING when abs(divergence_pct)
# exceeds 10% — or 15% when any of five per-ecosystem carve-outs auto-detects
# (FR-543). NEVER aborts the Phase 3 scan (NFR-84 no-hard-ceiling). Records the
# WARNING + divergence + applied-threshold + detected-carve-outs in the report
# frontmatter via brownfield-telemetry.sh.
#
# divergence_pct = round( ((declared - sbom) / declared) * 100 ). Positive ==
# SBOM under-counts (incomplete); the threshold gates on abs(), but a NEGATIVE
# divergence (SBOM over-count) does NOT trigger the WARNING (under-count guard).
#
# Carve-outs (ANY match -> 15% threshold): Yarn Berry PnP, conda, Go vendor,
# Gradle no-lockfile, Gradle shadow/shade.
#
# Pure bash + jq (grep/awk for TOML/XML — tomlq/xmlstarlet not assumed; AC-X4
# binary-pinning is vacuous: only jq/yq, foundational). Exit code ALWAYS 0.
#
# Env seams (tests/sbom-completeness-check.bats):
#   SBOM_PROJECT_ROOT  repo to scan for lock files + carve-outs (default .)
#   SBOM_FILE          cdxgen SBOM JSON (default .gaia/memory/brownfield-audit/sbom.json)
#   SBOM_REPORT        report frontmatter to populate (default consolidated-gaps.md)

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="adapters/brownfield/sbom-completeness-check.sh"
log_info() { printf 'INFO: %s: %s\n' "$SCRIPT_NAME" "$*"; }
log_warn() { printf 'WARNING: %s: %s\n' "$SCRIPT_NAME" "$*"; }

# --- Flag gate ------------------------------------------------------------
MASTER="${GAIA_BROWNFIELD_DETERMINISTIC_TOOLS:-true}"
PER_TOOL="${GAIA_BROWNFIELD_SBOM_COMPLETENESS_ENABLED:-true}"
if [ "$MASTER" != "true" ] || [ "$PER_TOOL" != "true" ]; then
  log_info "SBOM completeness check skipped (flag-off: deterministic_tools=$MASTER sbom_completeness_enabled=$PER_TOOL)"
  exit 0
fi

ROOT="${SBOM_PROJECT_ROOT:-.}"
default_sbom() {
  if [ -n "${GAIA_MEMORY_DIR:-}" ]; then printf '%s/brownfield-audit/sbom.json' "$GAIA_MEMORY_DIR"
  else printf '%s' "./.gaia/memory/brownfield-audit/sbom.json"; fi
}
SBOM_FILE="${SBOM_FILE:-$(default_sbom)}"

# --- Missing-SBOM guard (Val F1 — E70-S7 does not yet persist an SBOM) -----
# The cdxgen SBOM producer is unbuilt today (E70-S7 pre-warm discards the SBOM;
# see story Finding). With no SBOM there is nothing to compare — INFO-skip and
# exit 0 (never abort), rather than crash or emit a false WARNING.
if [ ! -f "$SBOM_FILE" ]; then
  log_info "SBOM not found at $SBOM_FILE — completeness check skipped (cdxgen SBOM producer not yet wired; never aborts)"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { log_warn "jq not found — SBOM completeness check skipped"; exit 0; }

# --- Declared dependency count (sum across all detected lock files) -------
declared=0
_add() { declared=$(( declared + ${1:-0} )); }

# npm package-lock.json v2+ : .packages keys minus the root "" entry.
if [ -f "$ROOT/package-lock.json" ]; then
  n="$(jq '([.packages | keys | length] | add // 0) - 1' "$ROOT/package-lock.json" 2>/dev/null || printf 0)"
  [ "$n" -lt 0 ] 2>/dev/null && n=0; _add "$n"
fi
# yarn.lock (Yarn Classic): count top-level entries (lines ending in ':' at col 0, non-comment).
if [ -f "$ROOT/yarn.lock" ]; then
  n="$(grep -cE '^[^[:space:]#].*:$' "$ROOT/yarn.lock" 2>/dev/null || printf 0)"; _add "$n"
fi
# Pipfile.lock : .default + .develop keys.
if [ -f "$ROOT/Pipfile.lock" ]; then
  n="$(jq '((.default // {}) + (.develop // {})) | keys | length' "$ROOT/Pipfile.lock" 2>/dev/null || printf 0)"; _add "$n"
fi
# composer.lock : .packages length.
if [ -f "$ROOT/composer.lock" ]; then
  n="$(jq '(.packages // []) | length' "$ROOT/composer.lock" 2>/dev/null || printf 0)"; _add "$n"
fi
# go.sum : 2 lines per module (go.mod + zip hash) -> count / 2.
if [ -f "$ROOT/go.sum" ]; then
  lines="$(grep -c . "$ROOT/go.sum" 2>/dev/null || printf 0)"; _add "$(( lines / 2 ))"
fi
# Gemfile.lock : specs under the GEM section (indented 4 spaces "name (ver)").
if [ -f "$ROOT/Gemfile.lock" ]; then
  n="$(grep -cE '^    [a-zA-Z0-9._-]+ \(' "$ROOT/Gemfile.lock" 2>/dev/null || printf 0)"; _add "$n"
fi
# Cargo.lock : [[package]] count (grep, no tomlq).
if [ -f "$ROOT/Cargo.lock" ]; then
  n="$(grep -c '^\[\[package\]\]' "$ROOT/Cargo.lock" 2>/dev/null || printf 0)"; _add "$n"
fi
# gradle.lockfile : non-comment, non-empty lines.
if [ -f "$ROOT/gradle.lockfile" ]; then
  n="$(grep -cE '^[^#[:space:]]' "$ROOT/gradle.lockfile" 2>/dev/null || printf 0)"; _add "$n"
fi
# pom.xml : <dependency> element count (grep, no xmlstarlet).
if [ -f "$ROOT/pom.xml" ]; then
  n="$(grep -c '<dependency>' "$ROOT/pom.xml" 2>/dev/null || printf 0)"; _add "$n"
fi

if [ "$declared" -le 0 ]; then
  log_info "no recognized lock files under $ROOT (declared=0) — completeness check skipped"
  exit 0
fi

sbom_count="$(jq '(.components // []) | length' "$SBOM_FILE" 2>/dev/null || printf 0)"

# --- Divergence (signed; threshold on abs; negative = no WARNING) ---------
# round((declared - sbom)/declared * 100)
divergence_pct="$(awk -v d="$declared" -v s="$sbom_count" 'BEGIN { printf "%d", ( (d - s) / d * 100 ) + ( (d>=s)?0.5:-0.5 ) }')"
abs_div="${divergence_pct#-}"

# --- Carve-out detection (ANY match -> 15%) -------------------------------
carve_outs=()
if [ -f "$ROOT/.yarnrc.yml" ] && grep -qE 'enablePnP:[[:space:]]*true' "$ROOT/.yarnrc.yml" 2>/dev/null; then
  carve_outs+=("yarn-berry-pnp")
fi
if [ -f "$ROOT/env.yml" ] || [ -f "$ROOT/environment.yml" ]; then
  carve_outs+=("conda")
fi
if [ -d "$ROOT/vendor" ] && [ -f "$ROOT/vendor/modules.txt" ]; then
  carve_outs+=("go-vendor")
fi
# Gradle without lockfile: a build.gradle* present AND no gradle.lockfile.
if { [ -f "$ROOT/build.gradle" ] || [ -f "$ROOT/build.gradle.kts" ]; } && [ ! -f "$ROOT/gradle.lockfile" ]; then
  carve_outs+=("gradle-no-lockfile")
fi
# Gradle shadow / Maven shade plugin declaration (grep only the files that exist;
# `grep -r` over missing-file args returns exit 2 and confuses the pipeline).
shade_found=0
for gf in "$ROOT/build.gradle" "$ROOT/build.gradle.kts" "$ROOT/pom.xml"; do
  [ -f "$gf" ] || continue
  if grep -Eq 'com\.github\.johnrengelman\.shadow|maven-shade-plugin' "$gf" 2>/dev/null; then
    shade_found=1; break
  fi
done
[ "$shade_found" -eq 1 ] && carve_outs+=("gradle-shadow")

threshold=10
[ "${#carve_outs[@]}" -gt 0 ] && threshold=15

# JSON array of carve-outs for telemetry.
if [ "${#carve_outs[@]}" -gt 0 ]; then
  carve_json="$(printf '%s\n' "${carve_outs[@]}" | jq -R . | jq -cs .)"
else
  carve_json="[]"
fi

# --- WARNING decision (only on POSITIVE divergence over threshold) --------
warning="false"
if [ "$divergence_pct" -gt 0 ] && [ "$abs_div" -ge "$threshold" ]; then
  warning="true"
fi

# --- Surface + telemetry --------------------------------------------------
log_info "declared=$declared sbom=$sbom_count divergence_pct=$divergence_pct applied_threshold=$threshold detected_carve_outs=$carve_json"
if [ "$warning" = "true" ]; then
  log_warn "SBOM completeness: divergence_pct=$divergence_pct exceeds applied_threshold=$threshold (declared=$declared sbom=$sbom_count carve_outs=$carve_json)"
fi

REPORT="${SBOM_REPORT:-${GAIA_ARTIFACTS_DIR:-.gaia/artifacts}/planning-artifacts/consolidated-gaps.md}"
TELEM="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/brownfield-telemetry.sh"
if [ -f "$REPORT" ] && [ -x "$TELEM" ]; then
  bash "$TELEM" --report "$REPORT" --field sbom_completeness_warning --value "$warning" || true
  bash "$TELEM" --report "$REPORT" --field divergence_pct --value "$divergence_pct" || true
  bash "$TELEM" --report "$REPORT" --field applied_threshold --value "$threshold" || true
  bash "$TELEM" --report "$REPORT" --field detected_carve_outs --value "$carve_json" || true
  bash "$TELEM" --report "$REPORT" --field llm_token_count --value 0 || true
fi

exit 0
