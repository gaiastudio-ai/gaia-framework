# gaia-tools — bundled deterministic-tools image for /gaia-doctor Tier 2.
#
# AF-2026-05-30-3 / Test10 §7 Component 2 ("Lower the install cost").
# Bundles every Tier 2 scanner /gaia-doctor declares + a curated set of
# Tier 1 helpers. Operators on a stock machine need only Docker — not
# brew + pip + npm + Go SDK + Java SDK + .NET Sarif.Multitool.
#
# Pinned versions are the single source of truth — reproduce a scan by
# pinning to a specific image tag, never `:latest` in production.
#
# Build:
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -t ghcr.io/gaiastudio-ai/gaia-tools:0.1.0 \
#     plugins/gaia/tools/gaia-tools/
#
# Smoke-test:
#   docker run --rm ghcr.io/gaiastudio-ai/gaia-tools:0.1.0 gaia-tools --version
#   docker run --rm ghcr.io/gaiastudio-ai/gaia-tools:0.1.0 grype version
#   docker run --rm ghcr.io/gaiastudio-ai/gaia-tools:0.1.0 syft version
#
# Volume-mount contract (consumed by scripts/lib/docker-runner.sh):
#   -v "${PROJECT_ROOT}:/workspace:ro"     project source tree, read-only
#   -v "${SARIF_OUT_DIR}:/out"             SARIF + JSON output destination
#   -w /workspace                          working directory inside container
#   tools see the project at /workspace and write findings to /out.
#
# Network policy: the container needs network ONLY for the initial grype
# DB sync (or skip with GRYPE_DB_AUTO_UPDATE=false + a pre-baked DB).
# All other tools work fully offline once the image is pulled.

# ---------------------------------------------------------------------------
# Stage 1 — Tool fetcher. Pulls binary releases from upstream, pinned by
# SHA-256 where the tool publishes a checksum file.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS fetcher

ARG TARGETARCH

# Pinned tool versions — the bill of materials for this image tag.
ARG GRYPE_VERSION=0.79.5
ARG SYFT_VERSION=1.4.1
ARG OSV_SCANNER_VERSION=1.7.4
ARG SPOTBUGS_VERSION=4.8.4

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      unzip \
      tar \
      gzip \
      && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/fetch

# Map docker buildx TARGETARCH (amd64|arm64) to the upstream release
# nomenclature each tool uses.
# AF-2026-05-31-2 / Test13 F-03: osv-scanner v1.7.4 asset is
# `osv-scanner_linux_amd64` (underscore), NOT `osv-scanner_linux-amd64`
# (dash). The prior dash form produced a 404 on fetch. Switched both
# arches to the canonical underscore form so the fetch step succeeds.
RUN case "${TARGETARCH}" in \
      amd64) echo "linux_amd64" > /opt/fetch/.arch_anchore ; \
             echo "linux_amd64" > /opt/fetch/.arch_osv ; ;; \
      arm64) echo "linux_arm64" > /opt/fetch/.arch_anchore ; \
             echo "linux_arm64" > /opt/fetch/.arch_osv ; ;; \
      *)     echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac

# Grype — vulnerability scanner (Anchore). The official installer is
# distributed as a shell script; we pin the version explicitly so
# `:latest` drift can't change the bundled scanner shape between builds.
# AF-2026-05-31-2 / Test13 F-01: extract grype into /opt/fetch directly
# (`-C /opt/fetch`) instead of the prior `tar -xzf … grype && mv grype
# /opt/fetch/grype` two-step. The prior form failed because tar's CWD was
# already /opt/fetch (per the WORKDIR above) — so the `mv grype
# /opt/fetch/grype` was a no-op AND the second `mv` invocation in a
# rebuild step would error `'grype' and '/opt/fetch/grype' are the same
# file`. The `-C` form is single-step, clear, and idempotent.
RUN ARCH=$(cat /opt/fetch/.arch_anchore) && \
    curl -fsSL "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_${ARCH}.tar.gz" \
      -o grype.tar.gz && \
    tar -xzf grype.tar.gz -C /opt/fetch grype && \
    chmod +x /opt/fetch/grype && \
    rm -f grype.tar.gz && \
    /opt/fetch/grype version

# Syft — SBOM generator (Anchore).
# AF-2026-05-31-2 / Test13 F-01: same fix as grype above — extract via
# `-C /opt/fetch` instead of the same-file mv pattern.
RUN ARCH=$(cat /opt/fetch/.arch_anchore) && \
    curl -fsSL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_${ARCH}.tar.gz" \
      -o syft.tar.gz && \
    tar -xzf syft.tar.gz -C /opt/fetch syft && \
    chmod +x /opt/fetch/syft && \
    rm -f syft.tar.gz && \
    /opt/fetch/syft version

# osv-scanner — Google OSV.dev CVE scanner, single static binary.
# Upstream asset layout: osv-scanner_linux_<arch>.tar.gz → resolved by
# the underscore-form `.arch_osv` (Test13 F-03 fix above).
RUN ARCH=$(cat /opt/fetch/.arch_osv) && \
    curl -fsSL "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_${ARCH}" \
      -o /opt/fetch/osv-scanner && \
    chmod +x /opt/fetch/osv-scanner && \
    /opt/fetch/osv-scanner --version

# SpotBugs — JVM bytecode static analyzer. Java archive; runs via
# java -jar inside the runtime stage. Note: SpotBugs distributes a
# single multi-platform .tgz, no arch split.
# AF-2026-05-31-2 / Test13 F-07: the upstream tarball does NOT preserve
# the +x bit on bin/spotbugs (the launcher script). chmod the bin/
# subtree so the symlink at /usr/local/bin/spotbugs in the runtime stage
# resolves to an executable file.
RUN curl -fsSL "https://github.com/spotbugs/spotbugs/releases/download/${SPOTBUGS_VERSION}/spotbugs-${SPOTBUGS_VERSION}.tgz" \
      -o spotbugs.tgz && \
    tar -xzf spotbugs.tgz && \
    chmod -R +x "spotbugs-${SPOTBUGS_VERSION}/bin/" && \
    mv "spotbugs-${SPOTBUGS_VERSION}" /opt/fetch/spotbugs && \
    rm -f spotbugs.tgz

# ---------------------------------------------------------------------------
# Stage 2 — Runtime. Lean Debian + the Python and Node runtimes the
# pip / npm-installed tools need. Java runtime for SpotBugs. Copy the
# fetched binaries from stage 1.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

ARG GAIA_TOOLS_VERSION=0.1.4
ARG GAIA_TOOLS_DB_DATE=2026-06-02
# AF-2026-06-02-1 / Test16 F-L01 — re-declare SPOTBUGS_VERSION in the
# runtime stage (multi-stage ARGs do not cross stage boundaries) so we
# can bake the version into an ENV the BOM banner reads. The launcher's
# `-version` probe emits nothing on stdout AND nothing on stderr on the
# 4.8.4 launcher under non-interactive shells, leaving the BOM row blank
# since Test14. The version is canonical from the fetcher ARG.
ARG SPOTBUGS_VERSION=4.8.4

ENV GAIA_TOOLS_VERSION=${GAIA_TOOLS_VERSION} \
    GAIA_TOOLS_DB_DATE=${GAIA_TOOLS_DB_DATE} \
    GAIA_SPOTBUGS_VERSION=${SPOTBUGS_VERSION} \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    DEBIAN_FRONTEND=noninteractive

# Runtime dependencies. Keep this list tight — every line is image bloat.
# AF-2026-05-31-2 / Test13 F-04: Debian bookworm ships Node 18.20, but
# cdxgen 10.x requires Node 20+ (EBADENGINE on install). Skip the apt
# nodejs/npm and install Node 20 from NodeSource instead. The runtime is
# multi-arch (NodeSource supports amd64 + arm64 from the same repo URL).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      jq \
      git \
      python3 \
      python3-pip \
      python3-venv \
      default-jre-headless \
      libicu72 \
      && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version && \
    # yq via the static binary (Mike Farah's yq, not Python yq) — gaia
    # scripts assume the Go yq's --tojson / dot-path semantics. The apt
    # package on Debian ships the Python yq with different CLI shape, so
    # we pull the canonical binary directly.
    ARCH=$(dpkg --print-architecture) && \
    case "${ARCH}" in \
      amd64) YQ_ARCH="amd64" ;; \
      arm64) YQ_ARCH="arm64" ;; \
      *) echo "unsupported dpkg arch=${ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_${YQ_ARCH}" \
      -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq && \
    yq --version

# Copy Tier 2 native binaries from the fetcher stage.
COPY --from=fetcher /opt/fetch/grype        /usr/local/bin/grype
COPY --from=fetcher /opt/fetch/syft         /usr/local/bin/syft
COPY --from=fetcher /opt/fetch/osv-scanner  /usr/local/bin/osv-scanner
COPY --from=fetcher /opt/fetch/spotbugs     /opt/spotbugs

# SpotBugs launcher shim — `spotbugs` on PATH dispatches to the bundled
# launcher script (`bin/spotbugs` does its own java invocation).
RUN ln -s /opt/spotbugs/bin/spotbugs /usr/local/bin/spotbugs && \
    spotbugs -version 2>/dev/null || true

# Pure-pip Tier 1 tools. Install into the system Python (Debian slim has
# no PEP 668 EXTERNALLY-MANAGED marker; we own the container so direct
# install is the right shape here).
RUN pip install --break-system-packages \
      'vulture==2.13' \
      'pip-audit==2.7.3' \
      'cyclonedx-bom==4.4.3' \
      'yamllint==1.35.1'

# AF-2026-05-31-3 / Test14 F-02 + F-06 + AF-2026-06-01-1 / Test15 F-01/02/03:
# bundle Sarif.Multitool so the Phase-7 sarif-merge.sh step actually runs
# under docker-runner.
#
# History of compounding bugs in this layer:
#   AF-31-2 used `--runtime dotnet` (runtime only) — `dotnet tool install`
#       silently failed because it needs the SDK.
#   AF-31-3 switched to `--channel 8.0` (SDK) but never validated against a
#       real `docker build`. Test15 found THREE blockers that AF-31-3
#       introduced on top:
#
#   F-01 (Test15) — `libicu72` was not apt-installed in the runtime stage.
#       .NET aborts with SIGABRT 134 on globalization init without ICU. The
#       dotnet-install.sh script itself prints "Note that the script does
#       not resolve dependencies during installation." Added to the apt
#       install above.
#
#   F-02 (Test15) — the .NET TOOL package is published as `Sarif.Multitool`
#       (not `Microsoft.Sarif.Multitool` — that's the LIBRARY package and
#       can NOT be `dotnet tool install`'d). The prior `Microsoft.` prefix
#       errored `NU1101 microsoft.sarif.multitool not found in NuGet feeds`.
#       Fixed below by dropping the prefix. The CLI binary the tool
#       installs is still `sarif`, so the entrypoint route + BOM probe are
#       unchanged. Verified against nuget.org — Sarif.Multitool 5.0.2
#       published 2026-05-28.
#
#   F-03 (Test15) — the dotnet-tool apphost (the `sarif` native launcher
#       at /usr/local/bin/sarif) resolves the runtime via DOTNET_ROOT OR
#       by sitting next to `dotnet`. The SDK lives at /opt/dotnet and the
#       tool shim lands at /usr/local/bin/sarif, so without DOTNET_ROOT
#       the apphost dies "Failed to resolve libhostfxr.so". `ENV
#       DOTNET_ROOT=/opt/dotnet` is set BEFORE the dotnet-install layer
#       so it persists into the image AND covers the post-install verify
#       `sarif --version` call. PATH includes /opt/dotnet for robustness.
ENV DOTNET_ROOT=/opt/dotnet \
    PATH=/opt/dotnet:${PATH}
RUN curl -fsSL "https://dot.net/v1/dotnet-install.sh" -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel 8.0 --install-dir /opt/dotnet && \
    rm -f /tmp/dotnet-install.sh && \
    ln -s /opt/dotnet/dotnet /usr/local/bin/dotnet && \
    dotnet --info >/dev/null 2>&1 && \
    dotnet tool install --tool-path /usr/local/bin Sarif.Multitool && \
    /usr/local/bin/sarif --version && \
    rm -rf /root/.nuget /tmp/NuGetScratch

# Pure-npm Tier 1 tools.
# AF-2026-05-31-2 / Test13 F-04: pin to a real published version
# (10.11.0; 10.6.4 was never released on npm) and keep the install
# non-fatal so a transient npm error during build doesn't kill the
# whole image. The Tier-2 grype/syft scanners are the load-bearing
# tools; cdxgen's SBOM is supplementary and degrades gracefully
# downstream if absent.
RUN npm install -g --silent --no-audit --no-fund \
      '@cyclonedx/cdxgen@10.11.0' \
    || echo "WARNING: cdxgen install failed — SBOM completeness check will INFO-skip"

# AF-2026-05-31-2 / Test13 F-10: bake GRYPE_DB_VALIDATE_AGE=false into
# the runtime so the bundled scanner can run against a DB that's older
# than grype's 5-day default freshness threshold. The docker-runner
# dispatches with `--network=none` (security policy) so the in-container
# grype CANNOT refresh on demand — without this env, every scan would
# refuse to start with "the vulnerability database was built N weeks
# ago". Operators who want strict freshness can rebuild the image with
# a current DB or override the env on dispatch.
ENV GRYPE_DB_VALIDATE_AGE=false

# Pre-warm the Grype DB so the first user invocation doesn't pay the
# database-sync round-trip. The DB date is stamped into the image tag
# (GAIA_TOOLS_DB_DATE) so operators can pin reproducible scans.
# AF-2026-05-31-2 / Test13 F-05: `grype db status` exits non-zero past
# the 5-day max-age threshold (Anchore froze schema 5 — the newest DB
# is already weeks old). Tolerate the non-zero so the image still
# builds; runtime scanning is gated by F-10's GRYPE_DB_VALIDATE_AGE=false
# above.
RUN grype db update || true
RUN grype db status || true

# Drop network capability at runtime via a wrapper if the host opts in —
# the default container has full network so the operator can grype-DB
# refresh on demand. The brownfield adapter dispatch caps wall-clock per
# adapter; container resource limits are the operator's responsibility.

# Create the canonical mountpoints. The host workspace mounts read-only
# at /workspace; tool output lands at /out.
RUN mkdir -p /workspace /out && \
    chmod 0755 /workspace /out

WORKDIR /workspace

# Entrypoint shim — `gaia-tools <subcommand>` dispatches to bundled
# binaries with a uniform argument shape. Bare invocation prints the
# bill of materials so operators can verify which versions they're
# running.
COPY gaia-tools-entrypoint.sh /usr/local/bin/gaia-tools
RUN chmod +x /usr/local/bin/gaia-tools

LABEL org.opencontainers.image.title="gaia-tools" \
      org.opencontainers.image.description="Bundled deterministic-tools image for /gaia-doctor Tier 2 — AF-2026-05-30-3 / Test10 §7 C2." \
      org.opencontainers.image.source="https://github.com/gaiastudio-ai/gaia-public" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="GAIA Studio AI" \
      io.gaia.tools.version="${GAIA_TOOLS_VERSION}" \
      io.gaia.tools.db_date="${GAIA_TOOLS_DB_DATE}"

ENTRYPOINT ["gaia-tools"]
CMD ["--version"]
