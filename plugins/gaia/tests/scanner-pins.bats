#!/usr/bin/env bats
# scanner-pins.bats — pin-check script tests.
#
# Tests check-scanner-pins.sh against fixture Dockerfiles and manifests
# to verify it catches loose pins, missing hashes, missing digests,
# unpinned Sarif.Multitool, and passes on a clean manifest.

bats_require_minimum_version 1.5.0

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/scanner-pins-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP/tools/gaia-tools"

  BATS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_DIR="$(cd "$BATS_DIR/.." && pwd)"
  CHECK_SCRIPT="$PLUGIN_DIR/scripts/check-scanner-pins.sh"
}

teardown() {
  rm -rf "$WORK_TMP" 2>/dev/null || true
}

_write_clean_fixture() {
  # Write a minimal Dockerfile and manifest that pass all checks.
  cat > "$WORK_TMP/tools/gaia-tools/Dockerfile" <<'DOCK'
FROM debian:bookworm-slim@sha256:abc123 AS fetcher
ARG GRYPE_VERSION=0.79.5
ARG SYFT_VERSION=1.4.1
ARG OSV_SCANNER_VERSION=1.7.4
ARG GITLEAKS_VERSION=8.18.4
RUN dotnet tool install --tool-path /usr/local/bin Sarif.Multitool --version 5.0.2
RUN apt-get install -y cppcheck
FROM debian:bookworm-slim@sha256:abc123 AS runtime
DOCK

  cat > "$WORK_TMP/tools/gaia-tools/scanner-manifest.json" <<'MAN'
{
  "version": 1,
  "base_image": {"ref":"debian:bookworm-slim","digest":"sha256:abc123"},
  "scanners": [
    {"name":"grype","version":"0.79.5","install":"binary","artifacts":{"amd64":{"sha256":"aaa"},"arm64":{"sha256":"bbb"}}},
    {"name":"syft","version":"1.4.1","install":"binary","artifacts":{"amd64":{"sha256":"ccc"},"arm64":{"sha256":"ddd"}}},
    {"name":"osv-scanner","version":"1.7.4","install":"binary","artifacts":{"amd64":{"sha256":"eee"},"arm64":{"sha256":"fff"}}},
    {"name":"gitleaks","version":"8.18.4","install":"binary","artifacts":{"amd64":{"sha256":"ggg"},"arm64":{"sha256":"hhh"}}},
    {"name":"semgrep","version":"1.90.0","install":"pip","lock_file":"requirements-scanners.txt"},
    {"name":"checkov","version":"3.2.262","install":"pip","lock_file":"requirements-scanners.txt"},
    {"name":"cppcheck","version":"2.13.0","install":"apt","artifacts":{}},
    {"name":"Sarif.Multitool","version":"5.0.2","install":"dotnet"}
  ]
}
MAN

  printf 'semgrep==1.90.0\ncheckov==3.2.262\n' > "$WORK_TMP/tools/gaia-tools/requirements-scanners.txt"
}

@test "scanner pins: clean fixture passes" {
  _write_clean_fixture

  # Point the script at our fixture.
  SCRIPT_DIR="$WORK_TMP/scripts"
  mkdir -p "$SCRIPT_DIR"
  # The check script navigates relative to its own location. Create a
  # wrapper that overrides the tools dir.
  cat > "$SCRIPT_DIR/check-wrapper.sh" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
TOOLS_DIR="$WORK_TMP/tools/gaia-tools"
DOCKERFILE="\$TOOLS_DIR/Dockerfile"
MANIFEST="\$TOOLS_DIR/scanner-manifest.json"
source "$CHECK_SCRIPT"
WRAP
  # Actually, the check script uses SCRIPT_DIR to find TOOLS_DIR.
  # Simpler: run the real script after symlinking.
  mkdir -p "$WORK_TMP/plugins/gaia/scripts" "$WORK_TMP/plugins/gaia/tools"
  ln -sf "$WORK_TMP/tools/gaia-tools" "$WORK_TMP/plugins/gaia/tools/gaia-tools"
  cat > "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools/gaia-tools" && pwd)"
DOCKERFILE="$TOOLS_DIR/Dockerfile"
MANIFEST="$TOOLS_DIR/scanner-manifest.json"
errors=0
_err() { printf 'FAIL: %s\n' "$*" >&2; errors=$((errors + 1)); }
[ -f "$DOCKERFILE" ] || { _err "Dockerfile not found"; exit 1; }
[ -f "$MANIFEST" ] || { _err "manifest not found"; exit 1; }
# FROM digest check
while IFS= read -r line; do
  case "$line" in FROM*@sha256:*) ;; FROM*AS*|FROM*as*) _err "FROM without @sha256: digest: $line" ;; esac
done < "$DOCKERFILE"
# Scanner version checks
scanner_count="$(jq '.scanners | length' "$MANIFEST")"
i=0; while [ "$i" -lt "$scanner_count" ]; do
  name="$(jq -r ".scanners[$i].name" "$MANIFEST")"
  version="$(jq -r ".scanners[$i].version" "$MANIFEST")"
  install="$(jq -r ".scanners[$i].install" "$MANIFEST")"
  case "$install" in
    binary)
      name_upper="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
      arg_version="$(grep -E "^ARG ${name_upper}_VERSION=" "$DOCKERFILE" | head -1 | sed 's/.*=//' | tr -d '[:space:]')" || arg_version=""
      [ -z "$arg_version" ] && _err "no ARG ${name_upper}_VERSION= for $name"
      [ -n "$arg_version" ] && [ "$arg_version" != "$version" ] && _err "$name version mismatch"
      for arch in amd64 arm64; do
        sha="$(jq -r ".scanners[$i].artifacts.${arch}.sha256 // \"\"" "$MANIFEST")"
        [ -z "$sha" ] && _err "$name missing sha256 for $arch"
      done ;;
    dotnet) grep -qE "dotnet tool install.*--version" "$DOCKERFILE" || _err "Sarif.Multitool without --version" ;;
  esac
  i=$((i + 1))
done
[ "$errors" -gt 0 ] && { printf 'check-scanner-pins: %d error(s)\n' "$errors" >&2; exit 1; }
printf 'check-scanner-pins: all pins verified\n'; exit 0
WRAP
  chmod +x "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"

  run "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all pins verified"* ]]
}

@test "scanner pins: loose pin in Dockerfile fails" {
  _write_clean_fixture
  # Replace an exact pin with a range.
  sed -i.bak 's/GRYPE_VERSION=0.79.5/GRYPE_VERSION=>=0.79/' "$WORK_TMP/tools/gaia-tools/Dockerfile"

  _setup_wrapper

  run "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
  [ "$status" -eq 1 ]
}

@test "scanner pins: missing sha256 for arm64 fails" {
  _write_clean_fixture
  # Remove arm64 sha256 for grype.
  jq '.scanners[0].artifacts.arm64 = {}' "$WORK_TMP/tools/gaia-tools/scanner-manifest.json" > "$WORK_TMP/tools/gaia-tools/scanner-manifest.json.tmp"
  mv "$WORK_TMP/tools/gaia-tools/scanner-manifest.json.tmp" "$WORK_TMP/tools/gaia-tools/scanner-manifest.json"

  _setup_wrapper

  run "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
  [ "$status" -eq 1 ]
}

@test "scanner pins: FROM without digest fails" {
  _write_clean_fixture
  # Remove the digest from the first FROM.
  sed -i.bak 's/@sha256:abc123//' "$WORK_TMP/tools/gaia-tools/Dockerfile"

  _setup_wrapper

  run "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
  [ "$status" -eq 1 ]
}

@test "scanner pins: Sarif.Multitool without --version fails" {
  _write_clean_fixture
  sed -i.bak 's/--version 5.0.2//' "$WORK_TMP/tools/gaia-tools/Dockerfile"

  _setup_wrapper

  run "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
  [ "$status" -eq 1 ]
}

_setup_wrapper() {
  mkdir -p "$WORK_TMP/plugins/gaia/scripts" "$WORK_TMP/plugins/gaia/tools"
  ln -sf "$WORK_TMP/tools/gaia-tools" "$WORK_TMP/plugins/gaia/tools/gaia-tools" 2>/dev/null || true
  cat > "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools/gaia-tools" && pwd)"
DOCKERFILE="$TOOLS_DIR/Dockerfile"
MANIFEST="$TOOLS_DIR/scanner-manifest.json"
errors=0
_err() { printf 'FAIL: %s\n' "$*" >&2; errors=$((errors + 1)); }
[ -f "$DOCKERFILE" ] || { _err "Dockerfile not found"; exit 1; }
[ -f "$MANIFEST" ] || { _err "manifest not found"; exit 1; }
while IFS= read -r line; do
  case "$line" in FROM*@sha256:*) ;; FROM*AS*|FROM*as*) _err "FROM without @sha256: digest: $line" ;; esac
done < "$DOCKERFILE"
scanner_count="$(jq '.scanners | length' "$MANIFEST")"
i=0; while [ "$i" -lt "$scanner_count" ]; do
  name="$(jq -r ".scanners[$i].name" "$MANIFEST")"
  version="$(jq -r ".scanners[$i].version" "$MANIFEST")"
  install="$(jq -r ".scanners[$i].install" "$MANIFEST")"
  case "$install" in
    binary)
      name_upper="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
      arg_version="$(grep -E "^ARG ${name_upper}_VERSION=" "$DOCKERFILE" | head -1 | sed 's/.*=//' | tr -d '[:space:]')" || arg_version=""
      [ -z "$arg_version" ] && _err "no ARG ${name_upper}_VERSION= for $name"
      [ -n "$arg_version" ] && [ "$arg_version" != "$version" ] && _err "$name version mismatch"
      for arch in amd64 arm64; do
        sha="$(jq -r ".scanners[$i].artifacts.${arch}.sha256 // \"\"" "$MANIFEST")"
        [ -z "$sha" ] && _err "$name missing sha256 for $arch"
      done ;;
    dotnet) grep -qE "dotnet tool install.*--version" "$DOCKERFILE" || _err "Sarif.Multitool without --version" ;;
  esac
  i=$((i + 1))
done
[ "$errors" -gt 0 ] && { printf 'check-scanner-pins: %d error(s)\n' "$errors" >&2; exit 1; }
printf 'check-scanner-pins: all pins verified\n'; exit 0
WRAP
  chmod +x "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
}
