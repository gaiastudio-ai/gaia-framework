#!/usr/bin/env bats
# design-probe.bats — tests for scripts/design-probe.sh
#
# Stubs replace only the bridge command; the REAL classification logic in
# design_probe() is exercised on every invocation.

setup() {
  TEST_TMP="$(mktemp -d)"
  PLUGIN_ROOT="${BATS_TEST_DIRNAME}/.."
  PROBE="${PLUGIN_ROOT}/scripts/design-probe.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# Helper: build the retired provider name from fragments (never contiguous)
# ---------------------------------------------------------------------------
_retired_provider() {
  printf '%s%s' 'fig' 'ma'
}

# ---------------------------------------------------------------------------
# Helper: run the probe with a stubbed bridge command, opted in via
# DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 (the marker every non-seam-focused test
# needs to reach the classifier at all). Dedupes the `run env ... bash
# "$PROBE"` boilerplate that would otherwise be repeated in nearly every
# test in this file. Extra env assignments (e.g. DESIGN_PROBE_TIMEOUT_SECONDS)
# can be passed as additional args, each in NAME=value form.
# Usage: _run_probe DESIGN_PROBE_BRIDGE_CMD="..." [NAME=value ...]
# Sets $status/$output via bats' `run`, same as calling `run` directly.
_run_probe() {
  run env DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 "$@" bash "$PROBE"
}

# Helper: first line of $output, i.e. the probe's stdout classification
# word, isolated from any stderr diagnostic lines that may precede it in
# the merged `run` capture.
_probe_state_line() {
  printf '%s\n' "$output" | head -1
}

# Helper: run the probe with an internal DESIGN_PROBE_TIMEOUT_SECONDS bound
# and an OUTER `timeout` guard (outer_bound seconds) around the whole
# invocation. The outer guard is the mutant detector: if the probe's own
# bound fails to fire (e.g. exec_with_timeout is bypassed), the hanging
# bridge runs past the outer guard and `timeout` kills the process tree
# instead, producing a 124/137 status that is NOT the probe's own
# "missing" exit(1) — the assertions in each timeout test tell the two
# apart by checking for exit 1 specifically, not merely non-zero.
# Usage: _run_probe_with_timeout <outer_bound> <inner_timeout_s> [bridge_cmd]
_run_probe_with_timeout() {
  local outer_bound="$1"
  local inner_timeout_s="$2"
  local bridge_cmd="${3:-sleep 999}"
  run timeout "$outer_bound" env \
    DESIGN_PROBE_BRIDGE_CMD="$bridge_cmd" \
    DESIGN_PROBE_TIMEOUT_SECONDS="$inner_timeout_s" \
    DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 \
    bash "$PROBE"
}

# ---------------------------------------------------------------------------
# AC1 — missing state
# ---------------------------------------------------------------------------

@test "(AC1) probe reports missing when bridge command is absent" {
  run env DESIGN_PROBE_BRIDGE_CMD="" \
    bash "$PROBE"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$output" == *"missing"* ]] || { echo "expected 'missing' state word: $output"; return 1; }
  [[ "$output" == *"could not be reached"* ]] || { echo "missing message must say the surface could not be reached: $output"; return 1; }
  [[ "$output" == *"enable"* ]] || { echo "missing message must say how to enable it: $output"; return 1; }
}

@test "(AC1) probe reports missing when bridge command fails with non-unauthorized error" {
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'exit 2'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"missing"* ]] \
    || { echo "expected 'missing' as the first stdout line: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# AC2 — unauthorized state
# ---------------------------------------------------------------------------

@test "(AC2) probe reports unauthorized when bridge stderr contains unauthorized" {
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo unauthorized >&2; exit 3'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$output" == *"unauthorized"* ]] || { echo "expected 'unauthorized' state word: $output"; return 1; }
  [[ "$output" == *"/design-login"* ]] \
    || { echo "unauthorized message must name the /design-login command: $output"; return 1; }
  [[ "$output" == *"you must run"* ]] || [[ "$output" == *"your"*"to run"* ]] \
    || { echo "unauthorized message must say the user runs it, not the framework: $output"; return 1; }
}

@test "(AC2) unauthorized message states the framework cannot run it on the user behalf" {
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo unauthorized >&2; exit 3'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$output" == *"cannot"*"on your behalf"* ]] \
    || [[ "$output" == *"cannot"*"on their behalf"* ]] \
    || [[ "$output" == *"cannot run it on your behalf"* ]] \
    || { echo "unauthorized message must own that the framework cannot run /design-login for the user: $output"; return 1; }
}

@test "(AC2) bridge rejecting with exit 3 classified as unauthorized even without stderr confirmation" {
  # Exit 3 is the PRIMARY signal — no stderr confirmation needed
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo nothing-relevant >&2; exit 3'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"unauthorized"* ]] \
    || { echo "exit code 3 alone must classify as unauthorized: $output"; return 1; }
}

@test "(AC2) bridge rejecting with different wording but exit 1 plus unauthorized still classified" {
  # Legacy bridge: exit 1 with "unauthorized" on stderr
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo 403 unauthorized >&2; exit 1'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"unauthorized"* ]] \
    || { echo "exit 1 + stderr 'unauthorized' must classify as unauthorized (legacy bridge path): $output"; return 1; }
}

# ---------------------------------------------------------------------------
# AC3 — available state
# ---------------------------------------------------------------------------

@test "(AC3) probe reports available when bridge exits 0" {
  _run_probe DESIGN_PROBE_BRIDGE_CMD="true"
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == "available" ]] \
    || { echo "expected exactly 'available' as the first stdout line: $output"; return 1; }
}

@test "(AC3) available case does not emit a remediation message" {
  # Capture stderr separately from stdout — `run` merges them, and the
  # assertion here is specifically that stderr contributes NOTHING.
  local stderr_file="$TEST_TMP/stderr"
  run bash -c "env DESIGN_PROBE_BRIDGE_CMD=true DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 bash '$PROBE' 2>'$stderr_file'"
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status: $output"; return 1; }
  [ ! -s "$stderr_file" ] \
    || { echo "available state must not write to stderr, got: $(cat "$stderr_file")"; return 1; }
}

# ---------------------------------------------------------------------------
# AC4 — timeout handling
# ---------------------------------------------------------------------------

@test "(AC4) probe returns within bound when bridge hangs" {
  # Use a 1-second bound so the test is fast; the outer kill at +4s catches
  # a regression where the internal timeout fails to fire.
  _run_probe_with_timeout 4 1
  # If the outer `timeout` fired instead of the probe's own bound, status
  # would be 124/137 from the OUTER kill, not the probe's own exit 1.
  [ "$status" -eq 1 ] \
    || { echo "expected the probe's own bound to fire (exit 1), got $status — outer kill probably fired instead: $output"; return 1; }
  [[ "$output" == *"missing"* ]] \
    || { echo "a hung bridge must classify as missing: $output"; return 1; }
}

@test "(AC4) timeout classified as missing not available" {
  _run_probe_with_timeout 4 1
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  local stdout_line
  stdout_line="$(_probe_state_line)"
  [[ "$stdout_line" != "available" ]] \
    || { echo "a timeout must never report available (fail-closed): $output"; return 1; }
  [[ "$stdout_line" == *"missing"* ]] \
    || { echo "expected 'missing' as the first stdout line: $output"; return 1; }
}

@test "(AC4) timeout test uses configured bound not hardcoded 5s" {
  # Set bound to 1s, stub sleeps 999. If the probe ignored the override and
  # used the hardcoded 5s default, the outer kill at 3s fires first and the
  # probe never gets to report its own classification — this is the mutant
  # that reds: replacing "${DESIGN_PROBE_TIMEOUT_SECONDS:-5}" with a bare
  # "5" in the script makes this test time out instead of asserting.
  _run_probe_with_timeout 3 1
  [ "$status" -eq 1 ] \
    || { echo "expected the 1s override to be honoured (exit 1 within ~1s); got $status, suggesting the hardcoded 5s default was used and the 3s outer kill fired: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# AC5 — no fallback provider, setup report, credential sweep
# ---------------------------------------------------------------------------

@test "(AC5) no alternative provider branch in probe script" {
  # NOTE for future editors: _retired_provider() builds the name from two
  # non-contiguous fragments ('fig' + 'ma') instead of using the literal in
  # this test file. That indirection is load-bearing, not decorative: this
  # suite lives under plugins/gaia/, which is swept by the leaked-identifier
  # / retired-provider guards described in the project's contribution rules.
  # A literal occurrence of the name HERE (even inside a "must not contain"
  # assertion) would itself trip that sweep and fail CI on this file, not on
  # design-probe.sh. Splitting the string is what lets this test assert
  # the provider's absence from the *script under test* without the test
  # file itself becoming a second occurrence the sweep has to special-case.
  local provider
  provider="$(_retired_provider)"
  local count
  count="$(grep -ci "$provider" "$PROBE" 2>/dev/null)" || count=0
  [ "$count" -eq 0 ] \
    || { echo "design-probe.sh must not name the retired design provider anywhere: $(grep -ni "$provider" "$PROBE")"; return 1; }

  # Also sweep for fallback / alternative-provider / local-copy / offline
  # wording — the epic's fail-closed posture forbids a silent degrade path.
  # This is a SECOND, independent regex from the provider-name check above
  # on purpose: a fallback branch could reference a different provider (or
  # none by name at all, e.g. "use the local copy instead"), so collapsing
  # this into the provider check would blind the test to that class of
  # regression. Keep the two greps separate.
  local fallback_count
  fallback_count="$(grep -cEi 'fallback|alternative.*provider|local.*copy|offline' "$PROBE" 2>/dev/null)" || fallback_count=0
  [ "$fallback_count" -eq 0 ] \
    || { echo "design-probe.sh must not contain a fallback/alternative-provider branch: $(grep -nEi 'fallback|alternative.*provider|local.*copy|offline' "$PROBE")"; return 1; }
}

@test "(AC5) probe reports performed and could-not-perform halves" {
  # Both failure messages must carry the two-part setup report (AC5): what
  # was performed non-interactively (nothing — no such routine exists) and
  # what could not be performed and why (the interactive /design-login
  # step). Checked on BOTH failure states — missing and unauthorized — since
  # each has its own message text and either could regress independently.
  run env DESIGN_PROBE_BRIDGE_CMD="" \
    bash "$PROBE"
  [[ "$output" == *"Non-interactive setup performed: none"* ]] \
    || { echo "missing message must report the 'performed' half of the setup report: $output"; return 1; }
  [[ "$output" == *"Could not perform:"* ]] \
    || { echo "missing message must report the 'could not perform' half: $output"; return 1; }

  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo unauthorized >&2; exit 3'"
  [[ "$output" == *"Non-interactive setup performed: none"* ]] \
    || { echo "unauthorized message must report the 'performed' half of the setup report: $output"; return 1; }
  [[ "$output" == *"Could not perform:"* ]] \
    || { echo "unauthorized message must report the 'could not perform' half: $output"; return 1; }
}

@test "(AC5) zero credential-shaped reads or echoes in probe" {
  # Sweep for sensitive patterns. The probe uses "marker" / "confirmation
  # string" in its own vocabulary (not "token") specifically so this sweep
  # can stay an unconditional zero rather than needing an allowlisted
  # exception for the probe's own remediation text — do not add the word
  # "token" to design-probe.sh without also reconsidering this test.
  local count
  count="$(grep -cEi 'secret|password|credential|api.key|bearer' "$PROBE" 2>/dev/null)" || count=0
  [ "$count" -eq 0 ] \
    || { echo "design-probe.sh must not read or echo credential-shaped values: $(grep -nEi 'secret|password|credential|api.key|bearer' "$PROBE")"; return 1; }
}

# ---------------------------------------------------------------------------
# AC6 — injection seam design
# ---------------------------------------------------------------------------

@test "(AC6) stub drives the real classification logic through the seam" {
  # All three states exercised via the bridge seam, with BATS_TEST_FILENAME
  # inherited from the bats runtime (so _run_probe's explicit
  # DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 is technically redundant here — kept for
  # symmetry with the other tests using the same helper).

  # 1. available
  _run_probe DESIGN_PROBE_BRIDGE_CMD="true"
  [ "$status" -eq 0 ] || { echo "expected exit 0 for the available stub, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == "available" ]] \
    || { echo "expected 'available': $output"; return 1; }

  # 2. unauthorized
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo unauthorized >&2; exit 3'"
  [ "$status" -eq 1 ] || { echo "expected exit 1 for the unauthorized stub, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"unauthorized"* ]] \
    || { echo "expected 'unauthorized': $output"; return 1; }

  # 3. missing
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'exit 2'"
  [ "$status" -eq 1 ] || { echo "expected exit 1 for the missing stub, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"missing"* ]] \
    || { echo "expected 'missing': $output"; return 1; }
}

@test "(AC6) unset seam defaults to missing without consulting any stub" {
  run env -u DESIGN_PROBE_BRIDGE_CMD \
    bash "$PROBE"
  [ "$status" -eq 1 ] || { echo "expected exit 1 with no bridge configured, got $status: $output"; return 1; }
  [[ "$output" == *"missing"* ]] || { echo "expected 'missing' with no bridge configured: $output"; return 1; }
}

@test "(AC6) ambient bridge variable refused when no marker present" {
  # This is the crux seam test — modelled on phase-parallel-orchestrator.bats
  # lines 2797-2814. A child process has BATS_TEST_FILENAME and
  # DESIGN_PROBE_ALLOW_BRIDGE_CMD stripped, but DESIGN_PROBE_BRIDGE_CMD names
  # a real executable stub on PATH. If the marker gate fails open, the stub
  # fires and its invocation log gains an entry.
  #
  # LOAD-BEARING CONSTRUCTION — do not simplify: an earlier version of this
  # test asserted the refusal only by grepping the probe's OWN source or by
  # stubbing the classifier instead of the bridge, which passed even when
  # the marker gate was deleted from design-probe.sh (a red review caught
  # this — the stub-mock version proves nothing about the real seam). The
  # only proof that matters is behavioral: a REAL executable on PATH, named
  # by DESIGN_PROBE_BRIDGE_CMD, with BOTH markers stripped via `env -u` in a
  # genuine child process (not just an unset local var, which could still
  # leak the parent bats process's BATS_TEST_FILENAME). If the marker gate
  # is ever removed or weakened, this stub actually executes and the
  # invocation-log assertion below goes non-empty and reds. Keep the stub as
  # a real file on PATH — do not replace it with a shell function or an
  # inline stub referenced only within this bats process.
  local stub_dir="$TEST_TMP/bin"
  local stub_log="$TEST_TMP/stubstate/invoked.log"
  mkdir -p "$stub_dir" "$TEST_TMP/stubstate"
  : > "$stub_log"

  # Write a real executable stub that logs when invoked
  cat > "$stub_dir/design-probe-bridge-stub" <<'STUB'
#!/usr/bin/env bash
echo "invoked at $(date +%s)" >> "${DESIGN_PROBE_STUB_LOG}"
exit 0
STUB
  chmod +x "$stub_dir/design-probe-bridge-stub"

  # Run the probe in a child process with test markers stripped.
  # The stub is on PATH and the bridge variable names it, so if the marker
  # gate fails open the stub will fire and the log will be non-empty.
  run env \
    -u BATS_TEST_FILENAME \
    -u DESIGN_PROBE_ALLOW_BRIDGE_CMD \
    PATH="$stub_dir:$PATH" \
    DESIGN_PROBE_BRIDGE_CMD="design-probe-bridge-stub" \
    DESIGN_PROBE_STUB_LOG="$stub_log" \
    bash "$PROBE"

  # The stub's invocation log MUST be empty — the gate refused the bridge
  [ ! -s "$stub_log" ] \
    || { echo "the stub was invoked with no marker present: $(cat "$stub_log")"; return 1; }

  # The probe must have logged the refusal
  [[ "$output" == *"action=refused"* ]] \
    || [[ "$output" == *"refused"*"no-marker"* ]] \
    || { echo "no refused log line in output: $output"; return 1; }

  # Classification must be missing (fail-closed)
  [[ "$output" == *"missing"* ]] \
    || { echo "expected missing classification: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# AC1+AC2 — distinctness
# ---------------------------------------------------------------------------

@test "(AC1+AC2) missing and unauthorized messages are distinct" {
  # LOAD-BEARING: this compares the stderr MESSAGE BODIES only, deliberately
  # EXCLUDING stdout (which carries the state classification word). An earlier
  # version captured merged output via 2>&1, so the state word ("missing" vs
  # "unauthorized") on the first stdout line always differed and the whole-string
  # inequality could never fail on identical message bodies — i.e. collapsing
  # both messages to one shared generic string left all tests passing. By
  # redirecting stdout to /dev/null and capturing stderr alone, the check is
  # satisfied ONLY when the two remediation messages actually differ in content.
  # Do not merge stdout back into the capture.
  local missing_msg
  missing_msg="$(env DESIGN_PROBE_BRIDGE_CMD="" bash "$PROBE" 2>&1 >/dev/null || true)"

  local unauth_msg
  unauth_msg="$(env \
    DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo unauthorized >&2; exit 3'" \
    DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 \
    bash "$PROBE" 2>&1 >/dev/null || true)"

  [ "$missing_msg" != "$unauth_msg" ] \
    || { echo "missing and unauthorized MESSAGE BODIES are identical (stdout state word excluded): $missing_msg"; return 1; }
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "(AC3-EC1) available even when bridge succeeds with empty project list" {
  # Bridge exits 0 with empty stdout — still available
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'exit 0'"
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == "available" ]] \
    || { echo "empty stdout from the bridge must not change the classification: $output"; return 1; }
}

@test "(AC1-EC1) unknown bridge error classified as missing" {
  # Bridge exits 42 without any unauthorized signal
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'exit 42'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"missing"* ]] \
    || { echo "an unrecognized exit code must fail closed to missing: $output"; return 1; }
}

@test "(AC2-EC1) unauthorized detected even with surrounding noise on stderr" {
  # stderr carries noise around the confirmation string
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo error: request unauthorized by server >&2; exit 1'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"unauthorized"* ]] \
    || { echo "the unauthorized marker must be detected even surrounded by other text: $output"; return 1; }
}

@test "(AC4-EC1) bridge under bound succeeds normally" {
  # Bridge sleeps briefly then exits 0 — within the configured bound
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'sleep 0.5; exit 0'" DESIGN_PROBE_TIMEOUT_SECONDS=2
  [ "$status" -eq 0 ] || { echo "expected exit 0 for a bridge finishing within the bound, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == "available" ]] \
    || { echo "a bridge that finishes under the bound must not be treated as a timeout: $output"; return 1; }
}

@test "(AC2-EC2) bridge exits 3 with stderr saying 403 not authorized" {
  # Exit 3 is the primary signal; stderr wording does not match the exact
  # confirmation string but exit code 3 is sufficient
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo 403 not authorized >&2; exit 3'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"unauthorized"* ]] \
    || { echo "exit code 3 must classify as unauthorized regardless of stderr wording: $output"; return 1; }
}

@test "(AC1-EC2) bridge exits 1 without exact marker or exit 3 classified as missing" {
  # Bridge exits 1 with "403 not authorized" — no literal confirmation
  # string, no exit 3. Fail-closed: classified as missing.
  _run_probe DESIGN_PROBE_BRIDGE_CMD="sh -c 'echo 403 not authorized >&2; exit 1'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [[ "$(_probe_state_line)" == *"missing"* ]] \
    || { echo "exit 1 without exit-3 or the literal unauthorized marker must fail closed to missing: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# Security rework — bridge stdout isolation
# ---------------------------------------------------------------------------

@test "(SEC1) bridge stdout never bleeds onto the probe's own stdout" {
  # LOAD-BEARING: a hostile or merely chatty bridge writes a FALSE state
  # word ("available") to its own stdout, then exits 1 (a plain,
  # non-unauthorized failure that the real classifier maps to "missing").
  # If the bridge's stdout is not discarded, that false word lands on the
  # probe's stdout ahead of (or instead of) the probe's own classification
  # word, and a caller reading stdout would read the WRONG verdict. The
  # probe never consumes bridge stdout, so it must be redirected to
  # /dev/null before the real "missing" word is ever printed.
  #
  # Capture the probe's own stderr separately (into a file), the same
  # idiom used by "(AC3) available case does not emit a remediation
  # message" above — `run`'s $output otherwise merges stdout+stderr, which
  # would hide a bleed behind the probe's own remediation text.
  #
  # Mutant proof (see design-probe.sh:83 exec_with_timeout invocation): if
  # the >/dev/null redirect on the bridge's own stdout is removed, this
  # test reds because $output (stdout only) becomes "available\nmissing"
  # instead of exactly "missing".
  local stderr_file="$TEST_TMP/sec1-stderr"
  run bash -c "env DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 DESIGN_PROBE_BRIDGE_CMD=\"sh -c 'printf available; exit 1'\" bash '$PROBE' 2>'$stderr_file'"
  [ "$status" -eq 1 ] \
    || { echo "expected exit 1 (plain failure, no unauthorized marker), got $status: $output"; return 1; }
  [ "$output" = "missing" ] \
    || { echo "bridge stdout bled through: probe stdout must be exactly 'missing' and nothing else, got: $output"; return 1; }
}

# ---------------------------------------------------------------------------
# Security rework — refusal log sanitization
# ---------------------------------------------------------------------------

@test "(SEC2) refusal log line strips control bytes and stays a single line" {
  # LOAD-BEARING: DESIGN_PROBE_BRIDGE_CMD is attacker-controlled when the
  # caller's environment is hostile. The refusal path (no marker present)
  # interpolates this value into a log line via cmd=%s. An unsanitized
  # value carrying ESC/BEL (terminal escape injection) or an embedded
  # newline (log-line forging) must not reach the log verbatim.
  local evil_cmd
  evil_cmd=$'evil\x1b[31minjected-line=hacked\x07\nsecond-line-should-not-exist'

  run env \
    -u BATS_TEST_FILENAME \
    -u DESIGN_PROBE_ALLOW_BRIDGE_CMD \
    DESIGN_PROBE_BRIDGE_CMD="$evil_cmd" \
    bash "$PROBE"

  [ "$status" -eq 1 ] || { echo "expected exit 1 (refused, fail-closed), got $status: $output"; return 1; }

  # The refusal line must exist and must be a SINGLE line in $output —
  # i.e. splitting the raw evil_cmd's embedded newline must not have
  # produced a second attacker-controlled log line.
  local refused_line_count
  refused_line_count="$(printf '%s\n' "$output" | grep -c 'action=refused')"
  [ "$refused_line_count" -eq 1 ] \
    || { echo "expected exactly 1 refusal log line, got $refused_line_count (newline was not sanitized): $output"; return 1; }

  # The forged second line's marker must never appear as its own line.
  ! printf '%s\n' "$output" | grep -qx 'second-line-should-not-exist' \
    || { echo "embedded newline forged a second log line: $output"; return 1; }

  # Raw control bytes (ESC 0x1b, BEL 0x07) must not appear in the
  # sanitized cmd= field specifically. Scoped to just that field's value
  # (not the whole refused-line or $output) because the probe's own
  # fixed-string log/remediation text legitimately contains non-ASCII
  # punctuation (an em dash), which is not part of what this test proves
  # and must not false-positive it.
  # Portable check (no grep -P / PCRE dependency, works with BSD grep
  # too): strip every printable ASCII byte plus tab with LC_ALL=C tr;
  # whatever remains is exactly the raw control-byte leakage, if any —
  # the sanitizer's own '?' substitute is itself printable and vanishes
  # here, so a genuinely sanitized field always ends empty.
  local refused_line cmd_field
  refused_line="$(printf '%s\n' "$output" | grep 'action=refused')"
  cmd_field="$(printf '%s\n' "$refused_line" | sed -E 's/^event=bridge_hook cmd=(.*) action=refused.*/\1/')"
  local leaked_bytes
  leaked_bytes="$(printf '%s' "$cmd_field" | LC_ALL=C tr -d '[:print:]\t')"
  [ -z "$leaked_bytes" ] \
    || { echo "raw control bytes (ESC/BEL) leaked into the sanitized cmd= field: $(printf '%s' "$cmd_field" | od -An -tx1 | head -5)"; return 1; }
}

# ---------------------------------------------------------------------------
# Test-quality rework — marker-gate value must be the EXACT string "1"
# ---------------------------------------------------------------------------

@test "(SEC3) DESIGN_PROBE_ALLOW_BRIDGE_CMD must be exactly \"1\", not merely non-empty" {
  # LOAD-BEARING CONSTRUCTION — mirrors "(AC6) ambient bridge variable
  # refused when no marker present" above: a REAL executable stub on
  # PATH, named by DESIGN_PROBE_BRIDGE_CMD, with BATS_TEST_FILENAME
  # stripped via `env -u` in a genuine child process. Do not replace the
  # stub with a mock or a source-grep — see the sibling test's comment for
  # why that proves nothing about the real seam.
  #
  # The gate at design-probe.sh is `[ "${DESIGN_PROBE_ALLOW_BRIDGE_CMD:-}"
  # != "1" ]` — an exact-string comparison. Today no test sends a
  # non-empty, non-"1" value, so a future loosening to a plain non-empty
  # check (`[ -z "${DESIGN_PROBE_ALLOW_BRIDGE_CMD:-}" ]`) would pass the
  # whole suite while silently accepting "0", "false", "yes", etc. as
  # opt-in. Two values are tried: "0" (the classic falsy-string trap) and
  # "yes" (an arbitrary non-"1" truthy-looking string).
  #
  # Mutant proof: loosen the gate's `!= "1"` to `-z ... ` (i.e. any
  # non-empty value is accepted) → the stub fires for "0" and/or "yes"
  # and this test reds.
  local stub_dir="$TEST_TMP/bin"
  local stub_log="$TEST_TMP/stubstate/invoked.log"
  mkdir -p "$stub_dir" "$TEST_TMP/stubstate"
  : > "$stub_log"

  cat > "$stub_dir/design-probe-bridge-stub" <<'STUB'
#!/usr/bin/env bash
echo "invoked at $(date +%s) with ALLOW=${DESIGN_PROBE_ALLOW_BRIDGE_CMD:-}" >> "${DESIGN_PROBE_STUB_LOG}"
exit 0
STUB
  chmod +x "$stub_dir/design-probe-bridge-stub"

  for bogus_value in "0" "yes"; do
    : > "$stub_log"
    run env \
      -u BATS_TEST_FILENAME \
      PATH="$stub_dir:$PATH" \
      DESIGN_PROBE_BRIDGE_CMD="design-probe-bridge-stub" \
      DESIGN_PROBE_ALLOW_BRIDGE_CMD="$bogus_value" \
      DESIGN_PROBE_STUB_LOG="$stub_log" \
      bash "$PROBE"

    [ ! -s "$stub_log" ] \
      || { echo "DESIGN_PROBE_ALLOW_BRIDGE_CMD=$bogus_value must NOT open the gate, but the stub was invoked: $(cat "$stub_log")"; return 1; }

    [[ "$output" == *"action=refused"* ]] \
      || { echo "DESIGN_PROBE_ALLOW_BRIDGE_CMD=$bogus_value: expected a refusal log line, got: $output"; return 1; }

    [[ "$output" == *"missing"* ]] \
      || { echo "DESIGN_PROBE_ALLOW_BRIDGE_CMD=$bogus_value: expected fail-closed 'missing' classification, got: $output"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# Test-quality rework — pin the state word to stdout for the failure states
# too (the AC3 "available" test above already isolates stdout/stderr; the
# failure-state tests elsewhere in this file assert against $output, bats'
# MERGED stdout+stderr capture, which would still pass if the classification
# word were emitted on stderr instead of stdout — same idiom as "(AC3)
# available case does not emit a remediation message", applied to
# "missing" and "unauthorized").
# ---------------------------------------------------------------------------

@test "(AC1-SEC) missing state word is on stdout only, message is on stderr only" {
  local stderr_file="$TEST_TMP/ac1-stderr"
  run bash -c "env DESIGN_PROBE_BRIDGE_CMD='sh -c \"exit 2\"' DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 bash '$PROBE' 2>'$stderr_file'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [ "$output" = "missing" ] \
    || { echo "the classification word must be the ONLY thing on stdout, got: $output"; return 1; }
  [ -s "$stderr_file" ] \
    || { echo "the remediation message must be on stderr"; return 1; }
  ! grep -q '^missing$' "$stderr_file" \
    || { echo "the classification word must not ALSO appear on stderr as its own line: $(cat "$stderr_file")"; return 1; }
}

@test "(AC2-SEC) unauthorized state word is on stdout only, message is on stderr only" {
  local stderr_file="$TEST_TMP/ac2-stderr"
  run bash -c "env DESIGN_PROBE_BRIDGE_CMD=\"sh -c 'echo unauthorized >&2; exit 3'\" DESIGN_PROBE_ALLOW_BRIDGE_CMD=1 bash '$PROBE' 2>'$stderr_file'"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  [ "$output" = "unauthorized" ] \
    || { echo "the classification word must be the ONLY thing on stdout, got: $output"; return 1; }
  [ -s "$stderr_file" ] \
    || { echo "the remediation message must be on stderr"; return 1; }
  ! grep -q '^unauthorized$' "$stderr_file" \
    || { echo "the classification word must not ALSO appear on stderr as its own line: $(cat "$stderr_file")"; return 1; }
}
