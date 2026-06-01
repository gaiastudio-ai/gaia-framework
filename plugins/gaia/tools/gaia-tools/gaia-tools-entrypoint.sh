#!/usr/bin/env bash
# gaia-tools entrypoint — AF-2026-05-30-3 / Test10 §7 Component 2.
#
# Dispatches `gaia-tools <subcommand>` to the bundled binary.  Used as
# the image ENTRYPOINT so callers from `scripts/lib/docker-runner.sh`
# can invoke the bundled tools with a uniform shape:
#
#   docker run --rm gaia-tools grype <args>
#   docker run --rm gaia-tools syft <args>
#   docker run --rm gaia-tools osv-scanner <args>
#   docker run --rm gaia-tools spotbugs <args>
#   docker run --rm gaia-tools vulture <args>
#   docker run --rm gaia-tools pip-audit <args>
#   docker run --rm gaia-tools cyclonedx-bom <args>     (Python SBOM)
#   docker run --rm gaia-tools cdxgen <args>            (Node SBOM)
#   docker run --rm gaia-tools yamllint <args>
#   docker run --rm gaia-tools yq <args>
#
# Bare invocation prints the bill of materials so the adapter dispatch
# can verify the image carries the version pins it expects:
#
#   docker run --rm gaia-tools --version
#
# Exit codes mirror the underlying tool. `--version` exits 0.
#
# Network policy: full network in the default container (operators can
# `grype db update` on demand). Hosts that want a hermetic run should
# `docker run --network=none gaia-tools <...>` — the bundled DB pre-warm
# during image build means grype works offline for the lifetime of the
# image's vuln-DB freshness window.

set -euo pipefail

_BOM() {
  # AF-2026-05-31-2 / Test13 F-09: grype 0.79.5's `grype version` output
  # uses the format `Application: grype\nVersion: 0.79.5\n...`. The prior
  # awk that extracted `Application:` (field 2) returned the literal
  # string `grype`, not the version. Switched to the `Version:` row.
  # AF-2026-05-31-2 / Test13 F-08: cyclonedx-bom 4.x renamed its CLI
  # binary to `cyclonedx-py`. The prior `cyclonedx-bom --version` call
  # produced "unknown" because the binary no longer exists by that name.
  # AF-2026-05-31-3 / Test14 F-03: spotbugs's launcher emits its version
  # on stderr in the form "SpotBugs <ver>"; redirect stderr→stdout and
  # awk the second token rather than `head -1` (which produced a blank
  # field in the BOM banner row).
  # AF-2026-05-31-3 / Test14 F-02 + F-06: probe the `sarif` binary
  # (Microsoft.Sarif.Multitool) so the BOM table reflects whether the
  # tool is actually present. The prior row had no probe at all, which
  # let the silent install failure persist invisibly.
  # AF-2026-06-01-1 / Test15 L-02 — spotbugs + sarif version probes need
  # to grab BOTH stdout and stderr:
  #   spotbugs's bash launcher (`bin/spotbugs -version`) prints
  #     `SpotBugs 4.8.4` to STDERR, not stdout. The prior `2>/dev/null`
  #     stripped the only output that carried the version, leaving the
  #     BOM banner blank. Now `2>&1` merges stderr → stdout so awk sees
  #     the version line.
  #   sarif (Sarif.Multitool 5.0.2) emits `Sarif.Multitool 5.0.2.0` on
  #     stdout for `sarif --version`, but the legacy `--version` flag is
  #     not always present in older bundled versions; fall back to the
  #     binary's `help` first-line which includes the version banner
  #     (`Sarif.Multitool 5.0.2.0 — …`). The combined probe
  #     `(--version 2>&1 || --help 2>&1)` covers both shapes.
  cat <<EOF
gaia-tools $GAIA_TOOLS_VERSION (db: $GAIA_TOOLS_DB_DATE)
  grype       $(grype version 2>/dev/null | awk -F: '/^Version:/ {print $2; exit}' | tr -d ' ' || echo unknown)
  syft        $(syft version 2>/dev/null | awk '/Version:/ {print $2; exit}' || echo unknown)
  osv-scanner $(osv-scanner --version 2>/dev/null | awk '{print $NF; exit}' || echo unknown)
  spotbugs    $(spotbugs -version 2>&1 | awk '/SpotBugs/ {print $NF; exit}' || echo unknown)
  vulture     $(vulture --version 2>/dev/null || echo unknown)
  pip-audit   $(pip-audit --version 2>/dev/null || echo unknown)
  cyclonedx   $(cyclonedx-py --version 2>/dev/null | head -1 || echo unknown)
  cdxgen      $(cdxgen --version 2>/dev/null | head -1 || echo unknown)
  yamllint    $(yamllint --version 2>/dev/null || echo unknown)
  yq          $(yq --version 2>/dev/null || echo unknown)
  sarif       $(( sarif --version 2>&1 || sarif --help 2>&1 ) | awk 'tolower($0) ~ /sarif/ && /[0-9]\.[0-9]/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}' || echo unknown)
EOF
}

if [ $# -eq 0 ] || [ "${1:-}" = "--version" ] || [ "${1:-}" = "version" ]; then
  _BOM
  exit 0
fi

case "${1}" in
  --bom|bom)
    _BOM
    exit 0
    ;;
  --help|-h|help)
    echo "usage: gaia-tools <subcommand> [args...]"
    echo "       gaia-tools --version | --bom"
    echo ""
    echo "Subcommands dispatch to bundled binaries: grype, syft, osv-scanner,"
    echo "spotbugs, vulture, pip-audit, cyclonedx-py, cdxgen, yamllint, yq, sarif."
    exit 0
    ;;
esac

# Verify the subcommand resolves to a known binary before exec'ing.
# AF-2026-05-31-3 / Test14 F-02 + F-06: `sarif` (Microsoft.Sarif.Multitool)
# is now in the documented dispatch set + the error-message vocabulary so
# `docker_runner_dispatch sarif merge ...` lands on a real binary rather
# than the prior "unknown subcommand 'sarif'" path that silently dropped
# every Phase-7 grype SARIF (Test14 F-06). The binary itself is bundled
# by the Dockerfile's Sarif.Multitool install step; the entrypoint just
# needs to advertise it in the help text and error vocabulary so callers
# (and docs) don't claim it isn't supported.
# AF-2026-05-31-3 / Test14 F-08: `cyclonedx-bom` (the legacy alias from
# the cyclonedx-bom 3.x days) is dropped from both vocabularies — the
# binary is `cyclonedx-py` post-4.x; advertising both forms misled
# operators into invoking a binary that doesn't exist in the image.
_subcmd="$1"
shift
if ! command -v "$_subcmd" >/dev/null 2>&1; then
  echo "gaia-tools: unknown subcommand '$_subcmd'" >&2
  echo "  valid: grype | syft | osv-scanner | spotbugs | vulture | pip-audit |" >&2
  echo "         cyclonedx-py | cdxgen | yamllint | yq | sarif | --version | --bom" >&2
  exit 127
fi

exec "$_subcmd" "$@"
