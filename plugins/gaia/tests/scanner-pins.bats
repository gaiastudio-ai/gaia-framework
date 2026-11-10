#!/usr/bin/env bats
# scanner-pins.bats — pin-check script tests.
#
# Tests the REAL check-scanner-pins.sh against fixture Dockerfiles and
# manifests. Every test builds a clean fixture tree, mutates one aspect,
# and verifies the shipped script catches it.

bats_require_minimum_version 1.5.0
load 'test_helper.bash'

setup() {
  WORK_TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/scanner-pins-$$-$BATS_TEST_NUMBER"
  mkdir -p "$WORK_TMP/plugins/gaia/scripts" "$WORK_TMP/plugins/gaia/tools/gaia-tools"

  BATS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PLUGIN_DIR="$(cd "$BATS_DIR/.." && pwd)"

  # Copy the REAL check-scanner-pins.sh into the fixture tree so its
  # relative path resolution (SCRIPT_DIR -> ../tools/gaia-tools) works.
  cp "$PLUGIN_DIR/scripts/check-scanner-pins.sh" "$WORK_TMP/plugins/gaia/scripts/"
  chmod +x "$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
  CHECK_SCRIPT="$WORK_TMP/plugins/gaia/scripts/check-scanner-pins.sh"
}

teardown() {
  rm -rf "$WORK_TMP" 2>/dev/null || true
}

_write_clean_fixture() {
  local D="$WORK_TMP/plugins/gaia/tools/gaia-tools"
  cat > "$D/Dockerfile" <<'DOCK'
FROM debian:bookworm-slim@sha256:4b50eb66f977b4062683ff434ef18ac191da862dbe966961bc11990cf5791a8d AS fetcher
ARG GRYPE_VERSION=0.79.5
ARG SYFT_VERSION=1.4.1
ARG OSV_SCANNER_VERSION=1.7.4
ARG GITLEAKS_VERSION=8.18.4
ARG CPPCHECK_VERSION=2.10
RUN echo "ff054e389ffb40619911f6bd75b3f46610245df9b11ab72fcdc2e08b9c34a09e  grype.tar.gz" | sha256sum -c
RUN echo "20f55117742aec388bf28bb24122236d3705e53996a27524e934569c5a0992cb  grype.tar.gz" | sha256sum -c
RUN echo "5e4c6a0d1ca28d25e060a29c7cca0aedc50d951bfb270b45bc9a71e86ac6fbe2  syft.tar.gz" | sha256sum -c
RUN echo "a28d63bb2bca96092a1a42cd5afdd0787633ae05998935a5e6e2aac8f2e2ec44  syft.tar.gz" | sha256sum -c
RUN echo "0b35daf50d3a9992836e7f78f56cb21b870da58f15f75c516dfb2c2ab4789d0f  osv" | sha256sum -c
RUN echo "fe26a8bd00e38d2b70bd049a97e03f6c27ac8fd74d5608c2c48b425cf46568ae  osv" | sha256sum -c
RUN echo "ba6dbb656933921c775ee5a2d1c13a91046e7952e9d919f9bac4cec61d628e7d  gl.tar.gz" | sha256sum -c
RUN echo "bf5f7f466ebfade1296c8bd32cf7d3f592c2aa78836aa9980ffbe2cadca7a861  gl.tar.gz" | sha256sum -c
RUN apt-get install -y cppcheck=2.10-2
RUN dotnet tool install --tool-path /usr/local/bin Sarif.Multitool --version 5.0.2
FROM debian:bookworm-slim@sha256:4b50eb66f977b4062683ff434ef18ac191da862dbe966961bc11990cf5791a8d AS runtime
DOCK

  cat > "$D/scanner-manifest.json" <<'MAN'
{
  "version": 1,
  "base_image": {"ref":"debian:bookworm-slim","digest":"sha256:4b50eb66"},
  "scanners": [
    {"name":"grype","version":"0.79.5","install":"binary","artifacts":{"amd64":{"sha256":"ff054e389ffb40619911f6bd75b3f46610245df9b11ab72fcdc2e08b9c34a09e"},"arm64":{"sha256":"20f55117742aec388bf28bb24122236d3705e53996a27524e934569c5a0992cb"}}},
    {"name":"syft","version":"1.4.1","install":"binary","artifacts":{"amd64":{"sha256":"5e4c6a0d1ca28d25e060a29c7cca0aedc50d951bfb270b45bc9a71e86ac6fbe2"},"arm64":{"sha256":"a28d63bb2bca96092a1a42cd5afdd0787633ae05998935a5e6e2aac8f2e2ec44"}}},
    {"name":"osv-scanner","version":"1.7.4","install":"binary","artifacts":{"amd64":{"sha256":"0b35daf50d3a9992836e7f78f56cb21b870da58f15f75c516dfb2c2ab4789d0f"},"arm64":{"sha256":"fe26a8bd00e38d2b70bd049a97e03f6c27ac8fd74d5608c2c48b425cf46568ae"}}},
    {"name":"gitleaks","version":"8.18.4","install":"binary","artifacts":{"amd64":{"sha256":"ba6dbb656933921c775ee5a2d1c13a91046e7952e9d919f9bac4cec61d628e7d"},"arm64":{"sha256":"bf5f7f466ebfade1296c8bd32cf7d3f592c2aa78836aa9980ffbe2cadca7a861"}}},
    {"name":"semgrep","version":"1.90.0","install":"pip","lock_file":"requirements-scanners.txt"},
    {"name":"checkov","version":"3.2.262","install":"pip","lock_file":"requirements-scanners.txt"},
    {"name":"cppcheck","version":"2.10","install":"apt","apt_pin":"2.10-2","artifacts":{}},
    {"name":"Sarif.Multitool","version":"5.0.2","install":"dotnet"}
  ]
}
MAN

  cat > "$D/requirements-scanners.txt" <<'REQ'
semgrep==1.90.0 \
    --hash=sha256:b90fef7562101f76b66a3836b4e8d0619bf73aa14d27515c7645a7b758f36214
checkov==3.2.262 \
    --hash=sha256:b45f4d8a4bc902ef2823413fd9fd2f796016f714a97728c4e5e07d2ef2737c93
REQ
}

# --- Clean fixture passes ---

@test "scanner pins: clean fixture passes" {
  _write_clean_fixture
  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all pins verified"* ]]
}

# --- FROM without digest ---

@test "scanner pins: FROM without digest fails" {
  _write_clean_fixture
  printf 'FROM debian:bookworm-slim\n' >> "$WORK_TMP/plugins/gaia/tools/gaia-tools/Dockerfile"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FROM without"*"digest"* ]] || [[ "${lines[*]}" == *"FROM without"*"digest"* ]]
}

# --- pip install with loose pin ---

@test "scanner pins: pip loose pin in Dockerfile fails" {
  _write_clean_fixture
  # Add a loose pip install
  printf 'RUN pip install --break-system-packages "semgrep>=1"\n' >> "$WORK_TMP/plugins/gaia/tools/gaia-tools/Dockerfile"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"loose version pin"* ]] || [[ "${lines[*]}" == *"loose version pin"* ]]
}

# --- cppcheck apt unpinned ---

@test "scanner pins: cppcheck apt unpinned fails" {
  _write_clean_fixture
  # Replace the pinned cppcheck install with an unpinned one
  local D="$WORK_TMP/plugins/gaia/tools/gaia-tools"
  sed -i.bak 's/cppcheck=2.10-2/cppcheck/' "$D/Dockerfile"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
}

# --- pip lock file deleted ---

@test "scanner pins: deleted pip lock file fails" {
  _write_clean_fixture
  rm "$WORK_TMP/plugins/gaia/tools/gaia-tools/requirements-scanners.txt"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lock file not found"* ]] || [[ "${lines[*]}" == *"lock file not found"* ]]
}

# --- sha256 value is bogus ---

@test "scanner pins: bogus sha256 in manifest fails" {
  _write_clean_fixture
  local M="$WORK_TMP/plugins/gaia/tools/gaia-tools/scanner-manifest.json"
  local tmp_m; tmp_m="$(jq '.scanners[0].artifacts.amd64.sha256="x"' < "$M")"
  printf '%s\n' "$tmp_m" > "$M"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not 64 characters"* ]] || [[ "${lines[*]}" == *"not 64 characters"* ]]
}

# --- Sarif --version differs from manifest ---

@test "scanner pins: Sarif.Multitool version mismatch fails" {
  _write_clean_fixture
  local D="$WORK_TMP/plugins/gaia/tools/gaia-tools/Dockerfile"
  sed -i.bak 's/--version 5.0.2/--version 9.9.9/' "$D"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version mismatch"* ]] || [[ "${lines[*]}" == *"version mismatch"* ]]
}

# --- Lock file missing --hash lines ---

@test "scanner pins: lock file without hashes fails" {
  _write_clean_fixture
  printf 'semgrep==1.90.0\ncheckov==3.2.262\n' > "$WORK_TMP/plugins/gaia/tools/gaia-tools/requirements-scanners.txt"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no --hash lines"* ]] || [[ "${lines[*]}" == *"no --hash lines"* ]]
}

# --- Binary version mismatch ---

@test "scanner pins: binary version mismatch between Dockerfile and manifest fails" {
  _write_clean_fixture
  local D="$WORK_TMP/plugins/gaia/tools/gaia-tools/Dockerfile"
  sed -i.bak 's/GRYPE_VERSION=0.79.5/GRYPE_VERSION=0.80.0/' "$D"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version mismatch"* ]] || [[ "${lines[*]}" == *"version mismatch"* ]]
}

# --- Unversioned pip install ---

@test "scanner pins: unversioned pip install fails" {
  _write_clean_fixture
  local D="$WORK_TMP/plugins/gaia/tools/gaia-tools/Dockerfile"
  # Add an unversioned pip install line.
  printf 'RUN pip install --break-system-packages semgrep\n' >> "$D"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unversioned pip install"* ]] || [[ "${lines[*]}" == *"unversioned pip install"* ]]
}

# --- Dockerfile sha256 differs from manifest ---

@test "scanner pins: Dockerfile sha256 differs from manifest fails" {
  _write_clean_fixture
  local D="$WORK_TMP/plugins/gaia/tools/gaia-tools/Dockerfile"
  local M="$WORK_TMP/plugins/gaia/tools/gaia-tools/scanner-manifest.json"
  # Change a manifest sha256 to something different but valid length.
  local new_sha; new_sha="$(printf 'a%.0s' {1..64})"
  local tmp_m; tmp_m="$(jq --arg s "$new_sha" '.scanners[0].artifacts.amd64.sha256=$s' < "$M")"
  printf '%s\n' "$tmp_m" > "$M"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in Dockerfile"* ]] || [[ "${lines[*]}" == *"not found in Dockerfile"* ]]
}

# --- Missing sha256sum verification ---

@test "scanner pins: missing sha256sum verification fails" {
  _write_clean_fixture
  local D="$WORK_TMP/plugins/gaia/tools/gaia-tools/Dockerfile"
  # Remove all sha256sum -c lines (simulating all verifications removed),
  # but keep one curl download.
  sed -i.bak '/sha256sum -c/d' "$D"
  printf 'RUN curl -fsSL "https://example.com/tool.tgz" -o /tmp/tool.tgz\n' >> "$D"
  run "$CHECK_SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256sum"* ]] || [[ "${lines[*]}" == *"sha256sum"* ]]
}

# --- Verify the SHIPPED check script ---

@test "scanner pins: shipped check-scanner-pins.sh passes on shipped Dockerfile and manifest" {
  # This runs the REAL script against the REAL shipped files.
  run "$PLUGIN_DIR/scripts/check-scanner-pins.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all pins verified"* ]]
}
