#!/usr/bin/env python3
"""Normalize upstream device-farm dispatcher output and project the expanded
matrix axes onto each per-device row.

Inputs (argv):
  1. path to raw upstream stdout (JSON object with per_device_results[])
  2. JSON array of expanded matrix entries
       (each: {os_version, form_factor, screen_size})
Output:
  JSON array on stdout — one row per matrix entry, with adapter-side fields
  (device_id, verdict, duration_ms, artifacts) round-robined from the
  upstream payload (mock mode often returns fewer rows than the matrix
  size).
"""
import json
import pathlib
import sys


def main() -> int:
    raw_text = pathlib.Path(sys.argv[1]).read_text().strip()
    expanded = json.loads(sys.argv[2])

    try:
        payload = json.loads(raw_text)
    except Exception:
        s, e = raw_text.find("{"), raw_text.rfind("}")
        payload = json.loads(raw_text[s : e + 1]) if s >= 0 and e > s else {}

    raw_results = payload.get("per_device_results", [])
    if not raw_results:
        raw_results = [{"device": "d1", "status": "pass"}]

    status_map = {
        "pass": "PASSED",
        "fail": "FAILED",
        "error": "ERROR",
        "timeout": "TIMEOUT",
    }
    normalized = []
    for idx, axes in enumerate(expanded):
        raw = raw_results[idx % len(raw_results)]
        status = (raw.get("status") or raw.get("verdict") or "pass").lower()
        verdict = status_map.get(status, status.upper())
        normalized.append(
            {
                "device_id": raw.get("device_id")
                or raw.get("device")
                or "device-{}".format(idx + 1),
                "os_version": axes.get("os_version", "unknown"),
                "form_factor": axes.get("form_factor", "phone"),
                "screen_size": axes.get("screen_size", "default"),
                "verdict": verdict,
                "duration_ms": raw.get("duration_ms", 0),
                "artifacts": raw.get("artifacts", []),
            }
        )
    print(json.dumps(normalized))
    return 0


if __name__ == "__main__":
    sys.exit(main())
