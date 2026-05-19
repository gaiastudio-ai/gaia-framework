#!/usr/bin/env bash
# test-fixture-command.sh — deterministic test fixture for E93-S4 bats tests.
#
# Behavior is driven by env vars:
#   FIXTURE_EXIT_CODE       — integer exit code (default 0)
#   FIXTURE_STDOUT          — string written to stdout
#   FIXTURE_STDERR          — string written to stderr
#   FIXTURE_SLEEP_SECONDS   — seconds to sleep before exiting (default 0)
#   FIXTURE_PRINT_ENV       — if "1", print full env to stdout
#
# Used by gaia-sprint-review-track-b-orchestration.bats.

[ "${FIXTURE_PRINT_ENV:-}" = "1" ] && env

[ -n "${FIXTURE_STDOUT:-}" ] && printf '%s\n' "$FIXTURE_STDOUT"
[ -n "${FIXTURE_STDERR:-}" ] && printf '%s\n' "$FIXTURE_STDERR" >&2

[ "${FIXTURE_SLEEP_SECONDS:-0}" -gt 0 ] && sleep "$FIXTURE_SLEEP_SECONDS"

exit "${FIXTURE_EXIT_CODE:-0}"
