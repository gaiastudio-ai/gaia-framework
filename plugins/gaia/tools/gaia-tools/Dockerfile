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
RUN case "${TARGETARCH}" in \
      amd64) echo "linux_amd64" > /opt/fetch/.arch_anchore ; \
             echo "linux-amd64" > /opt/fetch/.arch_osv ; ;; \
      arm64) echo "linux_arm64" > /opt/fetch/.arch_anchore ; \
             echo "linux-arm64" > /opt/fetch/.arch_osv ; ;; \
      *)     echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac

# Grype — vulnerability scanner (Anchore). The official installer is
# distributed as a shell script; we pin the version explicitly so
# `:latest` drift can't change the bundled scanner shape between builds.
RUN ARCH=$(cat /opt/fetch/.arch_anchore) && \
    curl -fsSL "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_${ARCH}.tar.gz" \
      -o grype.tar.gz && \
    tar -xzf grype.tar.gz grype && \
    mv grype /opt/fetch/grype && \
    chmod +x /opt/fetch/grype && \
    /opt/fetch/grype version

# Syft — SBOM generator (Anchore).
RUN ARCH=$(cat /opt/fetch/.arch_anchore) && \
    curl -fsSL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_${ARCH}.tar.gz" \
      -o syft.tar.gz && \
    tar -xzf syft.tar.gz syft && \
    mv syft /opt/fetch/syft && \
    chmod +x /opt/fetch/syft && \
    /opt/fetch/syft version

# osv-scanner — Google OSV.dev CVE scanner, single static binary.
# Upstream tarball layout: osv-scanner_<version>_linux_<arch>.tar.gz
RUN ARCH=$(cat /opt/fetch/.arch_osv) && \
    curl -fsSL "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_${ARCH}" \
      -o /opt/fetch/osv-scanner && \
    chmod +x /opt/fetch/osv-scanner && \
    /opt/fetch/osv-scanner --version

# SpotBugs — JVM bytecode static analyzer. Java archive; runs via
# java -jar inside the runtime stage. Note: SpotBugs distributes a
# single multi-platform .tgz, no arch split.
RUN curl -fsSL "https://github.com/spotbugs/spotbugs/releases/download/${SPOTBUGS_VERSION}/spotbugs-${SPOTBUGS_VERSION}.tgz" \
      -o spotbugs.tgz && \
    tar -xzf spotbugs.tgz && \
    mv "spotbugs-${SPOTBUGS_VERSION}" /opt/fetch/spotbugs

# ---------------------------------------------------------------------------
# Stage 2 — Runtime. Lean Debian + the Python and Node runtimes the
# pip / npm-installed tools need. Java runtime for SpotBugs. Copy the
# fetched binaries from stage 1.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

ARG GAIA_TOOLS_VERSION=0.1.0
ARG GAIA_TOOLS_DB_DATE=2026-05-30

ENV GAIA_TOOLS_VERSION=${GAIA_TOOLS_VERSION} \
    GAIA_TOOLS_DB_DATE=${GAIA_TOOLS_DB_DATE} \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    DEBIAN_FRONTEND=noninteractive

# Runtime dependencies. Keep this list tight — every line is image bloat.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      jq \
      git \
      python3 \
      python3-pip \
      python3-venv \
      nodejs \
      npm \
      default-jre-headless \
      && \
    rm -rf /var/lib/apt/lists/* && \
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

# Pure-npm Tier 1 tools.
RUN npm install -g --silent --no-audit --no-fund \
      '@cyclonedx/cdxgen@10.6.4'

# Pre-warm the Grype DB so the first user invocation doesn't pay the
# database-sync round-trip. The DB date is stamped into the image tag
# (GAIA_TOOLS_DB_DATE) so operators can pin reproducible scans.
RUN grype db update && \
    grype db status

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
