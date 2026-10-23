#!/usr/bin/env bash
# rubric-evaluate.sh — Deterministic sgr-velocity-003 evaluator.
#
# Pipeline:
#   1) Parse sprint-status.yaml for goals[], stories[], total_points,
#      sprint_shape (optional, default 'thrust').
#   2) Compute per-goal share = sum(stories where goal_index == g).points /
#      total_points.
#   3) Compute scaled floor_pct = min(1.0/N, max(0.10, 0.30 * (4 / max(4, N))))
#      where N = len(goals).  The outer min(1.0/N, ...) caps the total of
#      all per-goal floors at 100%.
#   4) For each below-floor goal that is NOT fully delivered, emit a
#      finding.  A goal is fully delivered only when it has at least one
#      story and every assigned story is done.  A goal with zero stories
#      is never fully delivered.  Fully delivered goals are exempt — the
#      team invested enough to complete every assigned story.
#        - severity = High when (floor_pct - share) > 0.05
#        - severity = Medium when 0 < (floor_pct - share) <= 0.05
#                     (intermediate tier per Risk 3 mitigation)
#        - severity is reduced from High → Low (Medium stays Medium → Low)
#          when sprint_shape == completion-pass.
#   5) When sprint_shape == completion-pass, always emit exactly one
#      sgr-velocity-006 advisory finding (audit-trail).
#
# Usage:
#   rubric-evaluate.sh --sprint-status <path> --rubric <path> [--emit-floor]
#
# Output:
#   One JSON object per line on stdout (NDJSON). Each line has:
#     {"rule_id": "...", "severity": "...", "goal_index": N, "share": 0.XX,
#      "floor_pct": 0.XX, "message": "..."}
#   With --emit-floor, the first line is a meta-record:
#     {"meta": "floor", "floor_pct": 0.XX, "n_goals": N}
#
# Exit codes:
#   0  success
#   1  usage / IO error
#   2  malformed sprint-status.yaml (missing goals[] or stories[])

set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_NAME="rubric-evaluate.sh"
die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

sprint_status=""
rubric=""
emit_floor=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sprint-status) sprint_status="$2"; shift 2 ;;
    --sprint-status=*) sprint_status="${1#--sprint-status=}"; shift ;;
    --rubric) rubric="$2"; shift 2 ;;
    --rubric=*) rubric="${1#--rubric=}"; shift ;;
    --emit-floor) emit_floor=1; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: rubric-evaluate.sh --sprint-status <path> --rubric <path> [--emit-floor]
Emits NDJSON findings for sgr-velocity-003 + sgr-velocity-006 against the
given sprint-status.yaml. See script header for the formula and severity tiers.
USAGE
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

[ -n "$sprint_status" ] || die "--sprint-status is required"
[ -n "$rubric" ] || die "--rubric is required"
[ -r "$sprint_status" ] || die "sprint-status not readable: $sprint_status"
[ -r "$rubric" ] || die "rubric not readable: $rubric"

python3 - "$sprint_status" "$emit_floor" <<'PY'
import sys, json, re

sprint_status_path = sys.argv[1]
emit_floor = sys.argv[2] == "1"

# Minimal YAML parser tailored to sprint-status.yaml shape.
# We only need: goals (list), stories (list of dicts with points + goal_index),
# total_points (int), sprint_shape (optional str).
goals = []
stories = []
total_points = None
sprint_shape = "thrust"

with open(sprint_status_path) as f:
    lines = f.read().splitlines()

i = 0
n = len(lines)
while i < n:
    line = lines[i]
    stripped = line.strip()
    # Top-level scalars
    m = re.match(r'^total_points:\s*(\d+)', line)
    if m:
        total_points = int(m.group(1))
        i += 1; continue
    m = re.match(r'^sprint_shape:\s*([A-Za-z_-]+)', line)
    if m:
        sprint_shape = m.group(1).strip()
        i += 1; continue
    if re.match(r'^goals:\s*$', line):
        i += 1
        while i < n and re.match(r'^\s+-\s', lines[i]):
            g = lines[i].strip()
            # Strip leading `- ` and surrounding quotes
            g = re.sub(r'^-\s+', '', g)
            g = g.strip().strip('"').strip("'")
            goals.append(g)
            i += 1
        continue
    bm = re.match(r'^(stories|items):\s*$', line)
    if bm:
        block_name = bm.group(1)
        i += 1
        current = None
        while i < n and (lines[i].startswith(' ') or lines[i].startswith('-')):
            ln = lines[i]
            m_item = re.match(r'^\s*-\s+key:\s*(.*)$', ln)
            if m_item:
                if current is not None:
                    current["_src"] = block_name
                    stories.append(current)
                current = {"key": m_item.group(1).strip().strip('"').strip("'")}
                i += 1; continue
            m_kv = re.match(r'^\s+(\w+):\s*(.*)$', ln)
            if m_kv and current is not None:
                k = m_kv.group(1)
                v = m_kv.group(2).strip().strip('"').strip("'")
                if k in ("points", "goal_index"):
                    try:
                        v = int(v)
                    except ValueError:
                        pass
                current[k] = v
                i += 1; continue
            i += 1
        if current is not None:
            current["_src"] = block_name
            stories.append(current)
        continue
    i += 1

# Deduplicate: stories entry wins over items entry on the same key.
_by_key = {}
for s in stories:
    k = s.get("key", "")
    if not k:
        continue
    src = s.pop("_src", "items")
    if k not in _by_key or src == "stories":
        _by_key[k] = s
stories = list(_by_key.values())

if not goals:
    sys.stderr.write("rubric-evaluate.sh: malformed sprint-status: no goals[] block\n")
    sys.exit(2)
if not stories:
    sys.stderr.write("rubric-evaluate.sh: malformed sprint-status: no stories[] block\n")
    sys.exit(2)
if total_points is None or total_points <= 0:
    total_points = sum(s.get("points", 0) for s in stories)
if total_points <= 0:
    sys.stderr.write("rubric-evaluate.sh: malformed sprint-status: total_points <= 0\n")
    sys.exit(2)

n_goals = len(goals)
floor_pct = min(1.0 / n_goals, max(0.10, 0.30 * (4.0 / max(4.0, float(n_goals)))))

# Compute per-goal share and delivery status.
per_goal_share = {}
goal_fully_delivered = {}
for idx in range(1, n_goals + 1):
    goal_stories = [s for s in stories if s.get("goal_index") == idx]
    pts = sum(s.get("points", 0) for s in goal_stories)
    per_goal_share[idx] = float(pts) / float(total_points)
    # A goal is fully delivered when it has at least one story and every
    # assigned story has status "done".  Goals with zero stories are NOT
    # fully delivered (they behave as before — the floor check applies).
    goal_fully_delivered[idx] = (
        len(goal_stories) > 0
        and all(s.get("status") == "done" for s in goal_stories)
    )

if emit_floor:
    print(json.dumps({"meta": "floor", "floor_pct": round(floor_pct, 4), "n_goals": n_goals}, separators=(',', ':')))

n_goals_below_floor = 0
findings = []
for idx in range(1, n_goals + 1):
    share = per_goal_share[idx]
    if share >= floor_pct:
        continue
    # A fully delivered goal is exempt from the incidental-goal floor:
    # the team invested enough to complete every assigned story, so the
    # goal is substantive regardless of its share of total capacity.
    if goal_fully_delivered[idx]:
        continue
    n_goals_below_floor += 1
    delta = floor_pct - share
    # Severity tiering: HIGH if >5 pp below, MEDIUM if within 5 pp.
    # Round to 10 decimals to avoid floating-point boundary error
    # (e.g. 0.20 - 0.15 = 0.050000000000000003 in IEEE 754).
    if round(delta, 10) > 0.05:
        base_sev = "High"
    else:
        base_sev = "Medium"
    # Shape modifier: completion-pass reduces severity by one tier.
    if sprint_shape == "completion-pass":
        sev = "Low"
    else:
        sev = base_sev
    findings.append({
        "rule_id": "sgr-velocity-003",
        "severity": sev,
        "goal_index": idx,
        "share": round(share, 4),
        "floor_pct": round(floor_pct, 4),
        "message": f"Goal {idx} share {share:.2%} below scaled floor {floor_pct:.2%} (delta {delta:.2%})"
    })

# sgr-velocity-006 advisory: emit exactly once when sprint_shape: completion-pass.
if sprint_shape == "completion-pass":
    floor_label = f"{round(floor_pct * 100):d}"
    advisory = {
        "rule_id": "sgr-velocity-006",
        "severity": "Low",
        "goal_index": 0,
        "floor_pct": round(floor_pct, 4),
        "n_goals_below_floor": n_goals_below_floor,
        "message": f"sprint_shape: completion-pass applied — sgr-velocity-003 floor scaled to {floor_label}% and severity reduced from High to Low for {n_goals_below_floor} goal(s)"
    }
    print(json.dumps(advisory, separators=(',', ':')))

for f_ in findings:
    print(json.dumps(f_, separators=(',', ':')))
PY
