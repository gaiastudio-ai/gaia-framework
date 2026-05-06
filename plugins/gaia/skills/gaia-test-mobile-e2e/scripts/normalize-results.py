#!/usr/bin/env python3
"""Normalize upstream device-farm dispatcher output into the canonical
per-device schema required by E74-S10 AC3.

Inputs (argv):
  1. path to raw upstream stdout (JSON object with per_device_results[])
Output:
  JSON array on stdout
"""
import json
import pathlib
import sys


def main() -> int:
    raw_path = sys.argv[1]
    text = pathlib.Path(raw_path).read_text().strip()
    try:
        payload = json.loads(text)
    except Exception:
        s, e = text.find("{"), text.rfind("}")
        payload = json.loads(text[s : e + 1]) if s >= 0 and e > s else {}

    raw_results = payload.get("per_device_results", [])
    status_map = {
        "pass": "PASSED",
        "fail": "FAILED",
        "error": "ERROR",
        "timeout": "TIMEOUT",
    }
    normalized = []
    for idx, r in enumerate(raw_results):
        dev_id = r.get("device_id") or r.get("device") or "device-{}".format(idx + 1)
        status = (r.get("status") or r.get("verdict") or "pass").lower()
        verdict = status_map.get(status, status.upper())
        normalized.append(
            {
                "device_id": dev_id,
                "os_version": r.get("os_version", "unknown"),
                "form_factor": r.get("form_factor", "phone"),
                "verdict": verdict,
                "duration_ms": r.get("duration_ms", 0),
                "artifacts": r.get("artifacts", []),
            }
        )
    print(json.dumps(normalized))
    return 0


if __name__ == "__main__":
    sys.exit(main())
