# gaia-tools — bundled deterministic-tools image for Tier 2 scanning.
#
# Bundles every Tier 2 scanner the doctor declares + a curated set of
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
# SHA-256. Each downloaded artifact is verified against the sha256 recorded
# in scanner-manifest.json so a checksum mismatch fails the build.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim@sha256:4b50eb66f977b4062683ff434ef18ac191da862dbe966961bc11990cf5791a8d AS fetcher

ARG TARGETARCH

# Pinned tool versions — the bill of materials for this image tag.
ARG GRYPE_VERSION=0.79.5
ARG SYFT_VERSION=1.4.1
ARG OSV_SCANNER_VERSION=1.7.4
ARG SPOTBUGS_VERSION=4.8.4
ARG GITLEAKS_VERSION=8.18.4
ARG SEMGREP_VERSION=1.90.0
ARG CHECKOV_VERSION=3.2.262
ARG CPPCHECK_VERSION=2.10

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
             echo "linux_amd64" > /opt/fetch/.arch_osv ; \
             echo "linux_x64"   > /opt/fetch/.arch_gitleaks ; \
             echo "ff054e389ffb40619911f6bd75b3f46610245df9b11ab72fcdc2e08b9c34a09e" > /opt/fetch/.sha_grype ; \
             echo "5e4c6a0d1ca28d25e060a29c7cca0aedc50d951bfb270b45bc9a71e86ac6fbe2" > /opt/fetch/.sha_syft ; \
             echo "0b35daf50d3a9992836e7f78f56cb21b870da58f15f75c516dfb2c2ab4789d0f" > /opt/fetch/.sha_osv ; \
             echo "ba6dbb656933921c775ee5a2d1c13a91046e7952e9d919f9bac4cec61d628e7d" > /opt/fetch/.sha_gitleaks ;; \
      arm64) echo "linux_arm64" > /opt/fetch/.arch_anchore ; \
             echo "linux_arm64" > /opt/fetch/.arch_osv ; \
             echo "linux_arm64" > /opt/fetch/.arch_gitleaks ; \
             echo "20f55117742aec388bf28bb24122236d3705e53996a27524e934569c5a0992cb" > /opt/fetch/.sha_grype ; \
             echo "a28d63bb2bca96092a1a42cd5afdd0787633ae05998935a5e6e2aac8f2e2ec44" > /opt/fetch/.sha_syft ; \
             echo "fe26a8bd00e38d2b70bd049a97e03f6c27ac8fd74d5608c2c48b425cf46568ae" > /opt/fetch/.sha_osv ; \
             echo "bf5f7f466ebfade1296c8bd32cf7d3f592c2aa78836aa9980ffbe2cadca7a861" > /opt/fetch/.sha_gitleaks ;; \
      *)     echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac

# Grype — vulnerability scanner (Anchore).
RUN ARCH=$(cat /opt/fetch/.arch_anchore) && \
    EXPECTED=$(cat /opt/fetch/.sha_grype) && \
    curl -fsSL "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_${ARCH}.tar.gz" \
      -o grype.tar.gz && \
    echo "${EXPECTED}  grype.tar.gz" | sha256sum -c && \
    tar -xzf grype.tar.gz -C /opt/fetch grype && \
    chmod +x /opt/fetch/grype && \
    rm -f grype.tar.gz && \
    /opt/fetch/grype version

# Syft — SBOM generator (Anchore).
RUN ARCH=$(cat /opt/fetch/.arch_anchore) && \
    EXPECTED=$(cat /opt/fetch/.sha_syft) && \
    curl -fsSL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_${ARCH}.tar.gz" \
      -o syft.tar.gz && \
    echo "${EXPECTED}  syft.tar.gz" | sha256sum -c && \
    tar -xzf syft.tar.gz -C /opt/fetch syft && \
    chmod +x /opt/fetch/syft && \
    rm -f syft.tar.gz && \
    /opt/fetch/syft version

# osv-scanner — Google OSV.dev CVE scanner, single static binary.
RUN ARCH=$(cat /opt/fetch/.arch_osv) && \
    EXPECTED=$(cat /opt/fetch/.sha_osv) && \
    curl -fsSL "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_${ARCH}" \
      -o /opt/fetch/osv-scanner && \
    echo "${EXPECTED}  /opt/fetch/osv-scanner" | sha256sum -c && \
    chmod +x /opt/fetch/osv-scanner && \
    /opt/fetch/osv-scanner --version

# SpotBugs — JVM bytecode static analyzer. Java archive; runs via
# java -jar inside the runtime stage. Note: SpotBugs distributes a
# single multi-platform .tgz, no arch split.
RUN curl -fsSL "https://github.com/spotbugs/spotbugs/releases/download/${SPOTBUGS_VERSION}/spotbugs-${SPOTBUGS_VERSION}.tgz" \
      -o spotbugs.tgz && \
    echo "11629b13aad39c453c23f8a8a43096b003afb55924a17424a9e1bc722190576b  spotbugs.tgz" | sha256sum -c && \
    tar -xzf spotbugs.tgz && \
    chmod -R +x "spotbugs-${SPOTBUGS_VERSION}/bin/" && \
    mv "spotbugs-${SPOTBUGS_VERSION}" /opt/fetch/spotbugs && \
    rm -f spotbugs.tgz

# Gitleaks — secret scanner, single static binary per architecture.
RUN GL_ARCH=$(cat /opt/fetch/.arch_gitleaks) && \
    EXPECTED=$(cat /opt/fetch/.sha_gitleaks) && \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${GL_ARCH}.tar.gz" \
      -o gitleaks.tar.gz && \
    echo "${EXPECTED}  gitleaks.tar.gz" | sha256sum -c && \
    tar -xzf gitleaks.tar.gz -C /opt/fetch gitleaks && \
    chmod +x /opt/fetch/gitleaks && \
    rm -f gitleaks.tar.gz && \
    /opt/fetch/gitleaks version

# ---------------------------------------------------------------------------
# Stage 2 — Runtime. Lean Debian + the Python and Node runtimes the
# pip / npm-installed tools need. Java runtime for SpotBugs. Copy the
# fetched binaries from stage 1.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim@sha256:4b50eb66f977b4062683ff434ef18ac191da862dbe966961bc11990cf5791a8d AS runtime

ARG GAIA_TOOLS_VERSION=0.1.4
ARG GAIA_TOOLS_DB_DATE=2026-06-02
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
    ARCH=$(dpkg --print-architecture) && \
    case "${ARCH}" in \
      amd64) YQ_ARCH="amd64" ;; \
      arm64) YQ_ARCH="arm64" ;; \
      *) echo "unsupported dpkg arch=${ARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_${YQ_ARCH}" \
      -o /usr/local/bin/yq && \
    case "${ARCH}" in \
      amd64) echo "6dc2d0cd4e0caca5aeffd0d784a48263591080e4a0895abe69f3a76eb50d1ba3  /usr/local/bin/yq" | sha256sum -c ;; \
      arm64) echo "8c12fcc10e14774ca6624cc282f092a526568b036fe1192258c3aecbad56d063  /usr/local/bin/yq" | sha256sum -c ;; \
    esac && \
    chmod +x /usr/local/bin/yq && \
    yq --version

# Copy Tier 2 native binaries from the fetcher stage.
COPY --from=fetcher /opt/fetch/grype        /usr/local/bin/grype
COPY --from=fetcher /opt/fetch/syft         /usr/local/bin/syft
COPY --from=fetcher /opt/fetch/osv-scanner  /usr/local/bin/osv-scanner
COPY --from=fetcher /opt/fetch/spotbugs     /opt/spotbugs
COPY --from=fetcher /opt/fetch/gitleaks     /usr/local/bin/gitleaks

# SpotBugs launcher shim.
RUN ln -s /opt/spotbugs/bin/spotbugs /usr/local/bin/spotbugs && \
    spotbugs -version 2>/dev/null || true

# Cppcheck — C/C++ static analysis. Installed from the Debian package at
# an exact version pin. Bookworm ships 2.10-2.
RUN apt-get update && \
    apt-get install -y --no-install-recommends cppcheck=2.10-2 && \
    rm -rf /var/lib/apt/lists/* && \
    cppcheck --version

# Scanner pip requirements — semgrep + checkov (exact pins with hashes).
COPY requirements-scanners.txt /tmp/requirements-scanners.txt
RUN pip install --break-system-packages --require-hashes \
      -r /tmp/requirements-scanners.txt && \
    rm -f /tmp/requirements-scanners.txt && \
    semgrep --version && \
    checkov --version

# Bake semgrep default rules at build time for offline scanning.
# Fetch the p/default ruleset into /opt/semgrep-rules so the image can
# scan offline with --config /opt/semgrep-rules/. semgrep stores
# downloaded rules under $XDG_CONFIG_HOME/semgrep (or /root/.semgrep).
RUN mkdir -p /opt/semgrep-rules /tmp/semgrep-bake && \
    printf '# empty target\n' > /tmp/semgrep-bake/empty.py && \
    semgrep --config "p/default" --json /tmp/semgrep-bake/empty.py 2>/dev/null || true && \
    find /root/.semgrep -name '*.yaml' -o -name '*.yml' | head -1 | xargs -I{} dirname {} | \
      xargs -I{} cp -r {}/* /opt/semgrep-rules/ 2>/dev/null || true && \
    RULE_COUNT=$(find /opt/semgrep-rules -name '*.yaml' -o -name '*.yml' 2>/dev/null | wc -l) && \
    echo "Baked ${RULE_COUNT} semgrep rule files" && \
    [ "${RULE_COUNT}" -gt 0 ] || { echo "ERROR: semgrep rule bake produced no rules" >&2; exit 1; } && \
    rm -rf /tmp/semgrep-bake

# Pure-pip Tier 1 tools.
RUN pip install --break-system-packages \
      'vulture==2.13' \
      'pip-audit==2.7.3' \
      'cyclonedx-bom==4.4.3' \
      'yamllint==1.35.1'

# Microsoft.Sarif.Multitool (dotnet tool) for SARIF merge step.
# The tool package name is Sarif.Multitool, not Microsoft.Sarif.Multitool.
ENV DOTNET_ROOT=/opt/dotnet \
    PATH=/opt/dotnet:${PATH}
RUN curl -fsSL "https://dot.net/v1/dotnet-install.sh" -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel 8.0 --install-dir /opt/dotnet && \
    rm -f /tmp/dotnet-install.sh && \
    ln -s /opt/dotnet/dotnet /usr/local/bin/dotnet && \
    dotnet --info >/dev/null 2>&1 && \
    dotnet tool install --tool-path /usr/local/bin Sarif.Multitool --version 5.0.2 && \
    /usr/local/bin/sarif --version && \
    rm -rf /root/.nuget /tmp/NuGetScratch

# Pure-npm Tier 1 tools.
RUN npm install -g --silent --no-audit --no-fund \
      '@cyclonedx/cdxgen@10.11.0' \
    || echo "WARNING: cdxgen install failed — SBOM completeness check will INFO-skip"

# Offline grype DB configuration.
ENV GRYPE_DB_VALIDATE_AGE=false
RUN grype db update || true
RUN grype db status || true

# Create the canonical mountpoints.
RUN mkdir -p /workspace /out && \
    chmod 0755 /workspace /out

WORKDIR /workspace

# Entrypoint shim.
COPY gaia-tools-entrypoint.sh /usr/local/bin/gaia-tools
RUN chmod +x /usr/local/bin/gaia-tools

LABEL org.opencontainers.image.title="gaia-tools" \
      org.opencontainers.image.description="Bundled deterministic-tools image for Tier 2 scanning." \
      org.opencontainers.image.source="https://github.com/gaiastudio-ai/gaia-public" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="GAIA Studio AI" \
      io.gaia.tools.version="${GAIA_TOOLS_VERSION}" \
      io.gaia.tools.db_date="${GAIA_TOOLS_DB_DATE}"

ENTRYPOINT ["gaia-tools"]
CMD ["--version"]
