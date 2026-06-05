# gaia-tools — bundled deterministic-tools image

"Lower the install cost so enabling the suite actually yields something."

## What this is

A single OCI image that bundles every Tier 2 scanner `/gaia-doctor` declares + a curated set of Tier 1 helpers, all pinned. Operators on a stock machine need only Docker — not brew + pip + npm + Go SDK + Java SDK + .NET Sarif.Multitool.

When `brownfield.tools.runner: docker` is set in `project-config.yaml`, the brownfield adapters dispatch through this image instead of resolving binaries from `$PATH`. Findings become reproducible: pin to a specific image tag → get the same vuln-DB snapshot + the same scanner versions across machines and CI.

## Bundled tools

| Tool          | Tier | Version    | Stack scope        |
|---------------|------|------------|--------------------|
| `grype`       | 2    | 0.79.5     | any (CVE scan)     |
| `syft`        | 2    | 1.4.1      | any (SBOM)         |
| `osv-scanner` | 1    | 1.7.4      | any (CVE)          |
| `spotbugs`    | 2    | 4.8.4      | java, android      |
| `vulture`     | 1    | 2.13       | python (dead-code) |
| `pip-audit`   | 1    | 2.7.3      | python (CVE)       |
| `cyclonedx-bom` | 1  | 4.4.3      | python (SBOM)      |
| `cdxgen`      | 1    | 10.11.0    | any (Node SBOM)    |
| `yamllint`    | 1    | 1.35.1     | yaml workflows     |
| `yq` (Mike Farah) | — | 4.44.1   | core               |

The image version (`0.1.0`) and DB date (`2026-05-30`) are stamped into image labels and surfaced via `gaia-tools --bom`.

## Build

```
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/gaiastudio-ai/gaia-tools:0.1.0-2026-05-30 \
  plugins/gaia/tools/gaia-tools/
```

CI publishes on push to `main` and on a monthly cron for vuln-DB freshness — see `.github/workflows/gaia-tools-image.yml`.

### Self-build when the published image lags

If `docker pull ghcr.io/gaiastudio-ai/gaia-tools:latest` fails with `denied` (registry visibility) or the pulled image is older than the Dockerfile in this branch (the monthly cron has not yet republished), build locally:

```
docker build -t ghcr.io/gaiastudio-ai/gaia-tools:latest plugins/gaia/tools/gaia-tools/
```

That tag matches the default `docker-runner.sh` resolves when `brownfield.tools.image` isn't set, so the brownfield adapters route through the local image without further config. A fresh build from this branch will succeed where prior tags failed.

## Use

### Direct invocation

```
docker run --rm ghcr.io/gaiastudio-ai/gaia-tools:0.1.0-2026-05-30 --version

docker run --rm \
  -v "$(pwd):/workspace:ro" \
  -v "$(pwd)/out:/out" \
  ghcr.io/gaiastudio-ai/gaia-tools:0.1.0-2026-05-30 \
  grype dir:/workspace -o sarif > out/grype.sarif
```

### Via GAIA framework (the canonical path)

Set the runner switch:

```
/gaia-config-brownfield set tools.runner docker
```

Or hand-edit `.gaia/config/project-config.yaml`:

```yaml
brownfield:
  tools:
    runner: docker          # default: native
  deterministic_tools: true
```

After that, `/gaia-brownfield` Phase 3 adapter dispatch routes through `scripts/lib/docker-runner.sh`, which calls the image with the canonical mount layout (`/workspace` = project read-only, `/out` = SARIF + JSON output destination). The adapter contract is unchanged from the caller's perspective; the runner switch is transparent.

`/gaia-doctor --json` reports `Achievable scan tier: TIER 2 (via docker runner)` when:
1. Docker is installed and reachable.
2. The pinned `gaia-tools` image is in the local cache (or `--install` will pull it).

## Image lifecycle policy

- **Tag shape:** `{version}-{db-date}` (e.g. `0.1.0-2026-05-30`).
- **`:latest`** floats to the newest `{version}-{db-date}` — fine for dev / experimentation, **never pin in production**.
- **Reproducibility:** to reproduce a finding from N months ago, pull the image whose `db-date` matches the date the scan ran. Vuln-DB freshness matters.
- **Monthly DB refresh:** CI re-builds + re-publishes the image on the 1st of each month so adopters can pin to a rolling-recent DB snapshot.
- **Patch releases:** when a bundled tool ships a security fix, bump the `GAIA_TOOLS_VERSION` ARG and re-publish off-cycle.

## Network policy

The container has full network by default so operators can `grype db update` on demand. Hosts that want a hermetic run:

```
docker run --network=none --rm ghcr.io/gaiastudio-ai/gaia-tools:0.1.0-2026-05-30 grype dir:/workspace
```

The image build pre-warms the Grype DB so offline scans work for the lifetime of the DB freshness window.

## Resource bounds

Container resource limits are the operator's responsibility. Recommended for CI:

```
docker run --rm --cpus=2 --memory=4g ...
```

The brownfield adapter dispatch enforces its own wall-clock cap per adapter.

## Adding a new tool

1. Add the version ARG + fetch step to the fetcher stage of `Dockerfile`.
2. COPY the binary into the runtime stage.
3. Update `gaia-tools-entrypoint.sh` `_BOM()` so the bill-of-materials reports it.
4. Add the tool to `plugins/gaia/skills/gaia-doctor/knowledge/tool-readiness.json` with an `install.docker` string of `docker run --rm gaia-tools <tool>`.
5. Add a bats line in `plugins/gaia/tests/af-2026-05-30-3-docker-runner.bats` asserting `--bom` lists the new tool.

## Why we shipped this

- An earlier cycle closed the HIGH/MEDIUM bug class but left the "containerized runner" half of the deterministic-tools tier-banner design deferred because the work is multi-day.
- This image ships the missing half: bundle the toolchains operators were never going to install, surface them through the existing `/gaia-doctor` + brownfield adapter contracts, and make Tier 2 scans achievable with one command (`docker pull`).
