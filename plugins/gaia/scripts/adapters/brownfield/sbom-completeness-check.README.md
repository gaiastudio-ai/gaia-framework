# `sbom-completeness-check.sh` — SBOM completeness assertion

Compares the declared dependency count (parsed from lock files) against the cdxgen
SBOM component count, and emits a **WARNING** when the divergence is high enough to
suggest the SBOM under-counted real dependencies — so CVEs in real deps don't silently
fail to surface because the SBOM generator was incomplete.

## Thresholds + per-ecosystem carve-outs

- **Default threshold: 10%.** `abs(divergence_pct) >= 10` (and SBOM under-counts) → WARNING.
- **Carve-out threshold: 15%.** When ANY of five ecosystems auto-detects, the threshold
  relaxes to 15% (these ecosystems systematically produce >10% lock-vs-SBOM divergence
  even when nothing is actually missing):

  | Carve-out | Detection rule |
  |-----------|----------------|
  | `yarn-berry-pnp` | `enablePnP: true` in `.yarnrc.yml` at repo root |
  | `conda` | `env.yml` or `environment.yml` at repo root |
  | `go-vendor` | `vendor/` directory AND `vendor/modules.txt` present |
  | `gradle-no-lockfile` | a `build.gradle`/`build.gradle.kts` present AND no `gradle.lockfile` |
  | `gradle-shadow` | `com.github.johnrengelman.shadow` (Gradle Shadow) OR `maven-shade-plugin` in `build.gradle*`/`pom.xml` |

  Rules are independent — ANY match relaxes the threshold to 15%, and `detected_carve_outs`
  lists ALL matched rules.

## Divergence formula

`divergence_pct = round( ((declared - sbom_component_count) / declared) * 100 )`.
Positive = SBOM under-counts (incomplete). The threshold gates on `abs()`, but a
**negative** divergence (SBOM over-counts, rare — vendored transitive inflation) does
**NOT** trigger the WARNING (under-count guard).

## Per-stack expected divergence samples (meeting provenance)

From the 2026-05-23 brownfield deterministic-tools meeting transcript:

- **npm / pnpm:** `<3%`
- **Yarn Classic:** `<5%`
- **Yarn Berry PnP:** `>10%` (Cleo, turn 6) — dependencies live in `.pnp.cjs`, cdxgen historically under-counts.
- **Maven:** `<5%`
- **Gradle dynamic-version + shadow/shade:** `10–15%` (Hugo, turn 9) — re-bundled transitive deps escape tracing.
- **conda:** `10–15%` pip-sublayer (Ravi, turn 7) — pip sub-layer escapes the conda manifest.
- **Go vendor:** `5–10%` (Kai, turn 8).

## No hard ceiling

The check NEVER aborts the Phase 3 scan. A WARNING in the
report frontmatter is the strongest signal it produces — operators act on it; CI can grep
the frontmatter and fail at the pipeline level if desired (not this script's responsibility).

## Lock-file parsers (v1 scope)

Pure bash + jq (grep/awk for TOML/XML — `tomlq`/`xmlstarlet` are NOT assumed; only `jq`/`yq` are used, both foundational). Declared counts are
summed across all detected lock files (repo-wide). Supported: `package-lock.json` (npm v2+),
`yarn.lock`, `Pipfile.lock`, `composer.lock`, `go.sum`, `Gemfile.lock`, `Cargo.lock`,
`gradle.lockfile`, `pom.xml`. The grep/awk heuristics for `yarn.lock`/`Cargo.lock`/`pom.xml`
are approximate (format variance) — the precision caveat is noted in the adapter comments.

## Missing SBOM (degrade)

The cdxgen SBOM (`.gaia/memory/brownfield-audit/sbom.json`) is the sole input. The producer
that persists it is **not yet wired** (the pre-warm step primes the cdxgen cache but discards
the SBOM; the persist step is tracked). When the SBOM is absent, the check emits an
**INFO skip** and exits 0 (never aborts) — there is nothing to compare against.

## Flag gate

Runs only when `brownfield.deterministic_tools: true` AND `brownfield.sbom_completeness_enabled:
true` (default true). Flag-off → INFO skip. Telemetry (`sbom_completeness_warning`,
`divergence_pct`, `applied_threshold`, `detected_carve_outs`, `*.sbom_completeness`,
`llm_token_count: 0`) is written via the shared `brownfield-telemetry.sh` (single-author).
