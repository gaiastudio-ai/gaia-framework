# Positive-violation fixture for the discovery-id leak gate
#
# This file lives under tests/fixtures/ (the exempt fixture tree) so it
# does NOT trip the real-tree-clean scan.  The gate's positive-violation
# test reads this file directly and asserts that the detection logic fires.
#
# The concrete identifier below is intentional — it simulates a leak that
# would be caught if it appeared anywhere in published source outside this
# exempt directory.

Leaked identifier for testing: DISC-2026-06-23-1
