#!/usr/bin/env bash
# plugin-trace-chain.sh — E77-S16 / FR-421 plugin traceability chain.
#
# Resolves the plugin chain for a Claude Code plugin project:
#   manifest.yaml | .claude-plugin/plugin.json
#       -> plugins/*/SKILL.md
#       -> bang-line script references inside each SKILL.md
#       -> tests/*.bats files referencing those scripts
#
# Output: JSON with two top-level arrays:
#   * `chain`  — one entry per resolved skill, each with `skill`, `skill_md`,
#                `scripts` (each with `path`, `exists`, `bats_files[]`,
#                `covered`).
#   * `gaps`   — entries with `gap_kind` in:
#                  - missing_skill_md       (manifest lists skill, no SKILL.md)
#                  - missing_script         (SKILL.md references absent file)
#                  - no_bats_coverage       (script exists, no bats file refs it)
#                  - orphan_skill_md        (SKILL.md not listed in manifest)
#
# Plugin-gating: when `--require-plugin` is passed and plugin-detection.sh
# reports `is_plugin: false` (fewer than 3 co-occurring signals per FR-420),
# emit an empty chain and `is_plugin: false`. This keeps non-plugin
# projects' /gaia-trace behaviour unchanged (AC5).
#
# Usage:
#   plugin-trace-chain.sh --project-root <dir> [--require-plugin]
#
# Exit codes:
#   0 success
#   1 argument error or missing dependency

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="plugin-trace-chain.sh"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

PROJECT_ROOT=""
REQUIRE_PLUGIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project-root)
      [ $# -ge 2 ] || { err "--project-root requires a path"; exit 1; }
      PROJECT_ROOT="$2"; shift 2 ;;
    --project-root=*)
      PROJECT_ROOT="${1#--project-root=}"; shift ;;
    --require-plugin)
      REQUIRE_PLUGIN=1; shift ;;
    -h|--help)
      sed -n '1,30p' "$0" >&2; exit 0 ;;
    *)
      err "unknown argument: $1"; exit 1 ;;
  esac
done

[ -n "$PROJECT_ROOT" ] || { err "missing required --project-root <dir>"; exit 1; }
[ -d "$PROJECT_ROOT" ] || { err "project root not a directory: $PROJECT_ROOT"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found in PATH"; exit 1; }

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECT_SCRIPT="$SCRIPT_DIR/plugin-detection.sh"

# ---------------------------------------------------------------------------
# Plugin gate (FR-421 / AC5) — when --require-plugin, defer to plugin-
# detection.sh. Non-plugin projects emit empty chain and short-circuit.
# ---------------------------------------------------------------------------
is_plugin="true"
if [ "$REQUIRE_PLUGIN" -eq 1 ]; then
  if [ -x "$DETECT_SCRIPT" ]; then
    detect_out="$("$DETECT_SCRIPT" --project-root "$PROJECT_ROOT" 2>/dev/null || true)"
    if printf '%s' "$detect_out" | grep -q '"is_plugin": false'; then
      is_plugin="false"
      python3 - <<PY
import json
print(json.dumps({"is_plugin": False, "chain": [], "gaps": []}, indent=2))
PY
      exit 0
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Collect manifest skill list + on-disk SKILL.md set + reverse-index of
# bats-file → script-references. Then walk each SKILL.md, extracting bang-
# line `!scripts/*.sh` references and joining against on-disk + bats data.
# All heavy lifting lives in python3 to keep the JSON emit deterministic.
# ---------------------------------------------------------------------------
python3 - "$PROJECT_ROOT" "$is_plugin" <<'PY'
import json, os, re, sys

project_root = sys.argv[1]
is_plugin = sys.argv[2] == "true"

# --- 1. Read manifest skill list ---------------------------------------------
manifest_skills = []
manifest_yaml = os.path.join(project_root, "manifest.yaml")
plugin_json   = os.path.join(project_root, ".claude-plugin", "plugin.json")
if os.path.isfile(manifest_yaml):
    # Lightweight YAML reader — extract list under `skills:` without pulling
    # PyYAML. We tolerate both `- name` and inline `[a, b]` forms.
    with open(manifest_yaml) as fh:
        in_skills = False
        for line in fh:
            stripped = line.rstrip("\n")
            if re.match(r"^\s*skills\s*:\s*$", stripped):
                in_skills = True
                continue
            if re.match(r"^\s*skills\s*:\s*\[", stripped):
                # Inline form: skills: [a, b]
                m = re.search(r"\[(.*)\]", stripped)
                if m:
                    for raw in m.group(1).split(","):
                        s = raw.strip().strip('"').strip("'")
                        if s:
                            manifest_skills.append(s)
                in_skills = False
                continue
            if in_skills:
                m = re.match(r"^\s*-\s*(.+)$", stripped)
                if m:
                    s = m.group(1).strip().strip('"').strip("'")
                    manifest_skills.append(s)
                elif re.match(r"^\S", stripped):
                    in_skills = False
elif os.path.isfile(plugin_json):
    try:
        d = json.load(open(plugin_json))
        for s in d.get("skills", []) or []:
            if isinstance(s, str):
                manifest_skills.append(s)
            elif isinstance(s, dict) and "name" in s:
                manifest_skills.append(s["name"])
    except Exception:
        pass

# --- 2. Locate SKILL.md files on disk ----------------------------------------
skill_md_paths = {}  # skill_name -> absolute SKILL.md path
for dirpath, dirs, files in os.walk(project_root):
    # Stay shallow — skip vendored test fixtures + node_modules etc.
    rel = os.path.relpath(dirpath, project_root)
    depth = 0 if rel == "." else rel.count(os.sep) + 1
    if depth > 5:
        dirs[:] = []
        continue
    for skip in (".git", "node_modules", ".venv", "__pycache__"):
        if skip in dirs:
            dirs.remove(skip)
    if "SKILL.md" in files:
        # Skill name = basename of containing directory.
        skill_name = os.path.basename(dirpath)
        skill_md_paths[skill_name] = os.path.join(dirpath, "SKILL.md")

# --- 3. Reverse-index bats files by referenced script ------------------------
bats_index = {}  # script-basename -> [bats file abs paths]
for dirpath, dirs, files in os.walk(project_root):
    for skip in (".git", "node_modules", ".venv", "__pycache__"):
        if skip in dirs:
            dirs.remove(skip)
    for f in files:
        if not f.endswith(".bats"):
            continue
        bats_path = os.path.join(dirpath, f)
        try:
            with open(bats_path, errors="ignore") as fh:
                contents = fh.read()
        except Exception:
            continue
        # Match any *.sh basename appearing in the file. We scan basenames
        # rather than full paths because bats files frequently use
        # variables / interpolation in script paths.
        for m in re.finditer(r"([A-Za-z0-9_.\-/]+\.sh)", contents):
            base = os.path.basename(m.group(1))
            bats_index.setdefault(base, []).append(bats_path)

# --- 4. Walk each candidate skill, build chain entries + gaps ----------------
chain = []
gaps  = []

# Skills listed in manifest but missing on disk -> missing_skill_md gap.
for sk in manifest_skills:
    if sk not in skill_md_paths:
        gaps.append({"gap_kind": "missing_skill_md", "skill": sk})

# Skills present on disk but not in the manifest -> orphan_skill_md (advisory).
manifest_set = set(manifest_skills)
for sk_name in skill_md_paths:
    if manifest_skills and sk_name not in manifest_set:
        # Only flag orphans when the manifest carries a non-empty skill list,
        # otherwise every disk skill would look orphaned on plugins that
        # don't enumerate skills in the manifest.
        gaps.append({"gap_kind": "orphan_skill_md", "skill": sk_name,
                     "skill_md": skill_md_paths[sk_name]})

# Build chain entries for each skill we found on disk.
bang_re = re.compile(r"^\s*!\s*([A-Za-z0-9_.\-/${}]+\.sh)\b", re.MULTILINE)

for sk_name, sk_md_path in skill_md_paths.items():
    try:
        sk_text = open(sk_md_path, errors="ignore").read()
    except Exception:
        sk_text = ""
    referenced = []
    for m in bang_re.finditer(sk_text):
        ref = m.group(1)
        # Strip CLAUDE_PLUGIN_ROOT or other ${...} prefixes — we resolve by
        # basename for the existence/coverage join below.
        ref_clean = re.sub(r"\$\{[^}]+\}", "", ref).lstrip("/")
        referenced.append(ref_clean)

    scripts_out = []
    for ref in referenced:
        # Resolve existence: relative to skill dir OR project-root scripts/.
        skill_dir = os.path.dirname(sk_md_path)
        candidates = [
            os.path.join(skill_dir, ref),
            os.path.join(project_root, ref),
            os.path.join(project_root, "scripts", os.path.basename(ref)),
        ]
        exists = any(os.path.isfile(c) for c in candidates)
        bats_files = sorted(set(bats_index.get(os.path.basename(ref), [])))
        covered = exists and bool(bats_files)
        scripts_out.append({
            "path": ref,
            "exists": exists,
            "bats_files": bats_files,
            "covered": covered,
        })
        if not exists:
            gaps.append({
                "gap_kind": "missing_script",
                "skill": sk_name,
                "script": ref,
            })
        elif not bats_files:
            gaps.append({
                "gap_kind": "no_bats_coverage",
                "skill": sk_name,
                "script": ref,
            })

    chain.append({
        "skill": sk_name,
        "skill_md": sk_md_path,
        "scripts": scripts_out,
    })

print(json.dumps({"is_plugin": is_plugin, "chain": chain, "gaps": gaps}, indent=2))
PY
