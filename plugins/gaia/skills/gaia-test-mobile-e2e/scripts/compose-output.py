#!/usr/bin/env python3
"""Compose the final E74-S10 /gaia-test-mobile-e2e skill output from the
adapter name, normalized per-device array, and the composite-verdict JSON.

Inputs (argv):
  1. adapter name
  2. JSON array of normalized per-device results
  3. JSON object emitted by composite-verdict.sh
Output:
  Single-line JSON object on stdout matching the SKILL.md output contract.
"""
import json
import sys


def main() -> int:
    adapter = sys.argv[1]
    normalized = json.loads(sys.argv[2])
    composite = json.loads(sys.argv[3])
    out = {
        "skill": "gaia-test-mobile-e2e",
        "adapter": adapter,
        "verdict": composite["verdict"],
        "passed_count": composite["passed_count"],
        "failed_count": composite["failed_count"],
        "error_count": composite["error_count"],
        "timeout_count": composite["timeout_count"],
        "per_device_results": normalized,
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
