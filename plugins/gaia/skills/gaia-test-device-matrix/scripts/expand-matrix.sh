#!/usr/bin/env bash
# gaia-test-device-matrix/expand-matrix.sh — E74-S10 / AC2.
#
# Reads device_targets from project-config.yaml and emits a JSON array
# representing the cartesian product of os_versions × form_factors × screen_sizes.
#
# Each output entry has: { "os_version": "...", "form_factor": "...", "screen_size": "..." }
#
# Empty axes are treated as ["default"] so the cartesian product remains well-defined.
#
# Usage: expand-matrix.sh --config <project-config.yaml>
#
# Exit codes:
#   0 — array emitted on stdout
#   1 — bad arguments or unreadable config

set -euo pipefail
LC_ALL=C; export LC_ALL

CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    -h|--help) sed -n '1,18p' "$0"; exit 0 ;;
    *) printf 'expand-matrix.sh: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[ -n "$CONFIG" ] || { printf 'expand-matrix.sh: --config required\n' >&2; exit 1; }
[ -f "$CONFIG" ] || { printf 'expand-matrix.sh: config not found: %s\n' "$CONFIG" >&2; exit 1; }

# Use Python for YAML axis parsing — minimal, dependency-free (PyYAML if
# available, else a regex fallback for the simple flow style we expect).
python3 - "$CONFIG" <<'PY'
import json, re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()

# Try PyYAML first; fall back to a tolerant parser tailored to the
# expected `key: ["a", "b"]` flow-list style under `device_targets:`.
def parse_with_yaml():
    try:
        import yaml  # type: ignore
    except Exception:
        return None
    try:
        return yaml.safe_load(text) or {}
    except Exception:
        return None

def parse_fallback():
    cfg = {}
    in_dt = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if re.match(r'^[^\s#].*:\s*$', line) or re.match(r'^[^\s#][^:]*:\s', line):
            # top-level key
            in_dt = stripped.startswith("device_targets:")
            continue
        if in_dt:
            m = re.match(r'^\s+([a-z_]+):\s*\[(.*)\]\s*$', line)
            if m:
                key = m.group(1)
                items = [x.strip().strip('"').strip("'") for x in m.group(2).split(",") if x.strip()]
                cfg.setdefault("device_targets", {})[key] = items
    return cfg

parsed = parse_with_yaml()
if parsed is None:
    parsed = parse_fallback()

dt = (parsed or {}).get("device_targets") or {}
os_versions  = dt.get("os_versions")  or ["default"]
form_factors = dt.get("form_factors") or ["default"]
screen_sizes = dt.get("screen_sizes") or ["default"]

# Coerce non-list values to single-element lists for robustness.
def coerce(v):
    if isinstance(v, list):
        return [str(x) for x in v]
    return [str(v)]
os_versions  = coerce(os_versions)
form_factors = coerce(form_factors)
screen_sizes = coerce(screen_sizes)

out = []
for ov in os_versions:
    for ff in form_factors:
        for ss in screen_sizes:
            out.append({"os_version": ov, "form_factor": ff, "screen_size": ss})

print(json.dumps(out))
PY
