#!/usr/bin/env bash
# gaia-config-device-target-edit.sh — manage device_targets in project-config.yaml
#
# Manage the `device_targets:` section of project-config.yaml. Subcommands:
#
#   set <platform> --os-versions "<a,b,c>" --form-factors "<phone,tablet>" \
#                  --screen-sizes "WxH@D,WxH@D,..."
#   show <platform>
#   clear <platform>
#
# `set` rejects orphan targets — i.e. <platform> not present in `platforms[]`
# — with exit 1.
#
# `set` is idempotent in the replace sense (existing values are
# replaced, never appended).
#
# Comment-preserving: we operate on the whole `device_targets:` section,
# regenerating it from the merged map. The rest of the file is untouched.
#
# Exit codes:
#   0 success
#   1 argument / validation error
#
# Requires: python3 (PyYAML) for safe YAML parse/serialize of the section.

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="gaia-config-device-target-edit.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

CFG=""
CMD=""
PLATFORM=""
OS_VERSIONS=""
FORM_FACTORS=""
SCREEN_SIZES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || { err "--config requires a path"; exit 1; }
      CFG="$2"; shift 2 ;;
    --config=*)
      CFG="${1#--config=}"; shift ;;
    set|show|clear)
      CMD="$1"; shift
      if [ $# -ge 1 ]; then PLATFORM="$1"; shift; fi
      ;;
    --os-versions)
      [ $# -ge 2 ] || { err "--os-versions requires a value"; exit 1; }
      OS_VERSIONS="$2"; shift 2 ;;
    --os-versions=*) OS_VERSIONS="${1#--os-versions=}"; shift ;;
    --form-factors)
      [ $# -ge 2 ] || { err "--form-factors requires a value"; exit 1; }
      FORM_FACTORS="$2"; shift 2 ;;
    --form-factors=*) FORM_FACTORS="${1#--form-factors=}"; shift ;;
    --screen-sizes)
      [ $# -ge 2 ] || { err "--screen-sizes requires a value"; exit 1; }
      SCREEN_SIZES="$2"; shift 2 ;;
    --screen-sizes=*) SCREEN_SIZES="${1#--screen-sizes=}"; shift ;;
    -h|--help) sed -n '1,30p' "$0" >&2; exit 0 ;;
    *) err "unexpected argument: $1"; exit 1 ;;
  esac
done

[ -n "$CFG" ]      || { err "missing --config"; exit 1; }
[ -f "$CFG" ]      || { err "config not found: $CFG"; exit 1; }
[ -n "$CMD" ]      || { err "missing subcommand (set|show|clear)"; exit 1; }
[ -n "$PLATFORM" ] || { err "missing platform argument"; exit 1; }

command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { err "PyYAML is required"; exit 1; }

# Read platforms[] for orphan-validation.
_read_platforms_list() {
  awk '
    BEGIN { in_section=0 }
    /^platforms:[[:space:]]*$/ { in_section=1; next }
    in_section && /^[^[:space:]]/ { in_section=0 }
    in_section && /^[[:space:]]+-[[:space:]]+/ {
      v=$0; sub(/^[[:space:]]+-[[:space:]]+/, "", v);
      sub(/[[:space:]]*(#.*)?$/, "", v); gsub(/"/, "", v); print v
    }
  ' "$CFG"
}

# Read the existing device_targets:{} as JSON (or "{}" if absent).
_read_device_targets_json() {
  python3 - "$CFG" <<'PY'
import sys, yaml, json
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    d = {}
print(json.dumps(d.get("device_targets") or {}))
PY
}

# Write the full device_targets:{} back. Section preserved via
# config-yaml-editor.sh.
_write_device_targets_json() {
  local payload_json="$1"
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  python3 - "$payload_json" "$tmp" <<'PY'
import sys, json, yaml
payload = json.loads(sys.argv[1])
out = sys.argv[2]
with open(out, "w") as fh:
    if not payload:
        # Section header alone (effectively clears the section).
        # Write bare 'device_targets:' (block-style empty section) instead of
        # inline-flow 'device_targets: {}' so the file round-trips to the
        # reconciler-hydrated baseline shape and trailing comments stay
        # anchored as child-position comments of the empty mapping.
        fh.write("device_targets:\n")
    else:
        fh.write("device_targets:\n")
        for plat, body in payload.items():
            fh.write(f"  {plat}:\n")
            ov = body.get("os_versions") or []
            ff = body.get("form_factors") or []
            ss = body.get("screen_sizes") or []
            fh.write("    os_versions:\n")
            for v in ov: fh.write(f"      - \"{v}\"\n")
            fh.write("    form_factors:\n")
            for v in ff: fh.write(f"      - {v}\n")
            fh.write("    screen_sizes:\n")
            for s in ss:
                fh.write(f"      - {{ width: {s['width']}, height: {s['height']}, density: {s['density']} }}\n")
PY

  if grep -qE '^device_targets:' "$CFG"; then
    "$(dirname "$0")/config-yaml-editor.sh" replace "$CFG" device_targets "$tmp"
  else
    "$(dirname "$0")/config-yaml-editor.sh" insert "$CFG" device_targets "$tmp"
  fi
  trap - EXIT
  rm -f "$tmp"
}

# Parse comma-separated string into a JSON list (trim whitespace).
_csv_to_json_list() {
  python3 - "$1" <<'PY'
import sys, json
parts = [p.strip() for p in (sys.argv[1] or "").split(",") if p.strip()]
print(json.dumps(parts))
PY
}

# Parse "WxH@D,WxH@D" into JSON list of {width,height,density} objects.
# Reject malformed entries.
_screens_to_json() {
  python3 - "$1" <<'PY'
import sys, re, json
spec = sys.argv[1] or ""
out = []
for entry in [e.strip() for e in spec.split(",") if e.strip()]:
    m = re.match(r"^(\d+)x(\d+)@(\d+(?:\.\d+)?)$", entry)
    if not m:
        sys.stderr.write(f"invalid screen-size: '{entry}' (expected WxH@D)\n")
        sys.exit(1)
    w, h, d = m.groups()
    out.append({"width": int(w), "height": int(h), "density": float(d)})
if not out:
    sys.stderr.write("at least one screen-size required\n")
    sys.exit(1)
print(json.dumps(out))
PY
}

case "$CMD" in
  show)
    cur="$(_read_device_targets_json)"
    printf '%s' "$cur" | python3 -c "
import json, sys, yaml
d = json.load(sys.stdin)
body = d.get('$PLATFORM')
if body is None:
    sys.exit(1)
print(yaml.safe_dump({'$PLATFORM': body}, default_flow_style=False, sort_keys=False))
"
    ;;
  clear)
    cur="$(_read_device_targets_json)"
    new="$(printf '%s' "$cur" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d.pop('$PLATFORM', None)
print(json.dumps(d))
")"
    _write_device_targets_json "$new"
    ;;
  set)
    # Orphan-target validation
    if ! _read_platforms_list | grep -Fxq "$PLATFORM"; then
      err "platform '$PLATFORM' is not in platforms[] — declare it first via /gaia-config-platform add $PLATFORM"
      exit 1
    fi
    [ -n "$OS_VERSIONS" ]   || { err "--os-versions is required"; exit 1; }
    [ -n "$FORM_FACTORS" ]  || { err "--form-factors is required"; exit 1; }
    [ -n "$SCREEN_SIZES" ]  || { err "--screen-sizes is required"; exit 1; }

    ov_json="$(_csv_to_json_list "$OS_VERSIONS")"
    ff_json="$(_csv_to_json_list "$FORM_FACTORS")"
    ss_json="$(_screens_to_json "$SCREEN_SIZES")" || exit 1

    cur="$(_read_device_targets_json)"
    new="$(python3 - "$cur" "$PLATFORM" "$ov_json" "$ff_json" "$ss_json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
plat, ov, ff, ss = sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4]), json.loads(sys.argv[5])
d[plat] = {"os_versions": ov, "form_factors": ff, "screen_sizes": ss}
print(json.dumps(d))
PY
)"
    _write_device_targets_json "$new"
    ;;
  *)
    err "unknown subcommand: $CMD"; exit 1 ;;
esac
