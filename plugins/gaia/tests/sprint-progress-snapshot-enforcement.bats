#!/usr/bin/env bats
# sprint-progress-snapshot-enforcement.bats — security enforcement tests for the
# sprint progress snapshot: single-writer sweep, command allowlist, story-key
# validation, realpath containment, and single-flight lock (flock + fallback).

# bats file_tags=sprint-progress,security

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  SCRIPT="$(snapshot_script_under_test "$SCRIPTS_DIR/sprint-progress-snapshot.sh")"
  # The shell that runs the script when a test sources it.
  SNAP_BASH="${SNAPSHOT_TEST_BASH:-bash}"
  PLUGIN_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

  export PROJECT_ROOT="$TEST_TMP/project"
  mkdir -p "$PROJECT_ROOT/.gaia/state"
  mkdir -p "$PROJECT_ROOT/.gaia/config"

  IMPL="$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts"
  mkdir -p "$IMPL"
  CACHE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json"
  LOCK_FILE="$PROJECT_ROOT/.gaia/state/.sprint-progress-cache.json.lock"
  export SPRINT_STATUS_YAML="$PROJECT_ROOT/.gaia/state/sprint-status.yaml"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers (minimal — reused from the main test file)
# ---------------------------------------------------------------------------

write_sprint_yaml() {
  local sprint_status="${1:-active}"; shift || true
  local start_date="${1:-2026-10-01}"; shift || true
  local end_date="${1:-2026-10-14}"; shift || true
  cat > "$SPRINT_STATUS_YAML" <<EOF
sprint_id: "sprint-test"
status: ${sprint_status}
start_date: "${start_date}"
end_date: "${end_date}"
total_points: 0
goals: []
stories:
EOF
  local total_pts=0
  for row in "$@"; do
    local key status pts
    key="$(echo "$row" | cut -d: -f1)"
    status="$(echo "$row" | cut -d: -f2)"
    pts="$(echo "$row" | cut -d: -f3)"
    pts="${pts:-5}"
    cat >> "$SPRINT_STATUS_YAML" <<EOF
  - key: "${key}"
    title: "Story ${key}"
    status: "${status}"
    points: ${pts}
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
EOF
    total_pts=$((total_pts + pts))
  done
  sed "s/^total_points: 0/total_points: ${total_pts}/" "$SPRINT_STATUS_YAML" > "${SPRINT_STATUS_YAML}.tmp" \
    && mv "${SPRINT_STATUS_YAML}.tmp" "$SPRINT_STATUS_YAML"
}

write_story() {
  local key="$1" status="$2" pts="${3:-5}"
  local slug
  slug="$(echo "$key" | tr '[:upper:]' '[:lower:]')-enf"
  local dir="$IMPL/epic-test/${key}-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<EOF
---
template: 'story'
key: "${key}"
title: "Story ${key}"
status: ${status}
points: ${pts}
manual_verification: false
depends_on: []
---

# Story: ${key}

> **Status:** ${status}

## Tasks / Subtasks

- [x] Task 1: Done

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Definition of Done

- [x] All done
EOF
}

# backdate_tree — move every fixture file and directory mtime well into the
# past, so a snapshot run does not treat it as written in its own second
# (such entries are deliberately re-read by the next run).
backdate_tree() {
  find "$PROJECT_ROOT" \( -type f -o -type d \) -exec touch -t 202610010000 {} + 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Single-writer enforcement sweep
# ---------------------------------------------------------------------------

# _cache_write_detector — awk program run once per candidate file.  It
# prints "WRITER" when the file WRITES the cache, not when it merely names it:
#   1. taint: a variable assigned a value that holds the cache file name, or
#      a tainted variable, is tainted too (repeated until nothing changes);
#   2. a line is a write when the target of a write form is the literal name
#      or a tainted variable.  Shell: `>` / `>>` redirects, the last operand
#      of mv/cp/install/ln/rsync, any operand of tee.  Python: open() with a
#      w/a/x/+ mode, os.replace/os.rename/shutil.move/copy targets,
#      write_text/write_bytes.  JS/TS: writeFile/appendFile/createWriteStream
#      targets, rename/copyFile destinations.
# A name built from pieces at run time (".sprint-progress-" + "cache.json")
# is out of reach of any static sweep; that limit is accepted.
_cache_write_detector() {
  cat <<'AWK'
function isref(tok,   v) {
  if (index(tok, ".sprint-progress-cache.json") > 0) return 1
  for (v in taint) if (tok ~ ("(^|[^A-Za-z0-9_])" v "([^A-Za-z0-9_]|$)")) return 1
  return 0
}
function lastarg(call,   t) {
  t = call; sub(/\).*$/, "", t)
  if (index(t, ",") == 0) return ""
  sub(/^.*,/, "", t); return t
}
function firstarg(call,   t) {
  t = call; sub(/^[^(]*\(/, "", t); sub(/[,)].*$/, "", t); return t
}
function shell_write(l,   rest, after, pre, tok, segs, ns, i, seg, wds, nw, cmd, j) {
  rest = l
  while (match(rest, />>?[ \t]*/)) {
    pre = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
    after = substr(rest, RSTART + RLENGTH)
    if (substr(after, 1, 1) != "&" && pre != "-" && pre != "=") {
      tok = after; sub(/[ \t;|&)].*$/, "", tok)
      if (isref(tok)) return 1
    }
    rest = after
  }
  ns = split(l, segs, /&&|\|\||;|\|/)
  for (i = 1; i <= ns; i++) {
    seg = segs[i]; sub(/^[ \t]+/, "", seg)
    while (seg ~ /^(then|do|else|if|while|until|!|command|sudo|exec|time|\{|\()[ \t]+/) sub(/^[^ \t]+[ \t]+/, "", seg)
    nw = split(seg, wds, /[ \t]+/)
    while (nw > 1 && (wds[nw] == "" || wds[nw] ~ /^(\}|\)|fi|done)$/)) nw--
    cmd = wds[1]
    if (cmd ~ /^(mv|cp|install|ln|rsync)$/ && nw > 2 && isref(wds[nw])) return 1
    if (cmd == "tee") for (j = 2; j <= nw; j++) if (wds[j] !~ /^-/ && isref(wds[j])) return 1
  }
  return 0
}
function py_write(l,   call) {
  if (match(l, /open\(.*\)/)) {
    call = substr(l, RSTART, RLENGTH)
    if (isref(firstarg(call)) && call ~ /["'][rbt]*[wax+][rbt+]*["']/) return 1
  }
  if (match(l, /(os\.replace|os\.rename|shutil\.(move|copy|copyfile|copy2))\(.*\)/)) {
    call = substr(l, RSTART, RLENGTH)
    if (isref(lastarg(call))) return 1
  }
  if (l ~ /\.(write_text|write_bytes)\(/ && isref(l)) return 1
  return 0
}
function js_write(l,   call) {
  if (match(l, /(writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|outputFile|outputFileSync|writeJson|writeJsonSync)\(.*\)/)) {
    call = substr(l, RSTART, RLENGTH)
    if (isref(firstarg(call))) return 1
  }
  if (match(l, /(rename|renameSync|copyFile|copyFileSync)\(.*\)/)) {
    call = substr(l, RSTART, RLENGTH)
    if (isref(lastarg(call))) return 1
  }
  return 0
}
{ line[NR] = $0 }
END {
  for (pass = 0; pass < 8; pass++) {
    changed = 0
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (!match(l, /^[ \t]*((export|local|readonly|declare|const|let|var)[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*=[^=]/)) continue
      name = substr(l, RSTART, RLENGTH - 1)
      sub(/^[ \t]*((export|local|readonly|declare|const|let|var)[ \t]+)?/, "", name)
      sub(/[ \t]*=.*$/, "", name)
      val = substr(l, RSTART + RLENGTH - 1)
      if (!(name in taint) && isref(val)) { taint[name] = 1; changed = 1 }
    }
    if (!changed) break
  }
  for (i = 1; i <= NR; i++) {
    l = line[i]
    if (l ~ /^[ \t]*(#|\/\/)/) continue
    if (lang == "sh" && shell_write(l)) { print "WRITER"; exit }
    if (lang == "py" && py_write(l)) { print "WRITER"; exit }
    if (lang == "js" && js_write(l)) { print "WRITER"; exit }
  }
}
AWK
}

# _cache_writer_sweep ROOT — print every plugin source file under ROOT's
# scripts/, hooks/ and skills/ (tests excluded) that WRITES the cache file.
# Shared by the real sweep and the planted writer/reader checks below.
_cache_writer_sweep() {
  local root="$1" d f lang prog
  local -a dirs=()
  prog="$(_cache_write_detector)"
  for d in scripts hooks skills; do [ -d "$root/$d" ] && dirs+=("$root/$d/"); done
  grep -rlF '.sprint-progress-cache.json' "${dirs[@]}" \
    --include='*.sh' --include='*.bash' --include='*.js' --include='*.mjs' \
    --include='*.cjs' --include='*.ts' --include='*.py' 2>/dev/null \
    | grep -v '/tests/' | grep -v '__tests__' \
    | while IFS= read -r f; do
        case "$f" in *.py) lang="py" ;; *.sh|*.bash) lang="sh" ;; *) lang="js" ;; esac
        [ "$(awk -v lang="$lang" "$prog" "$f")" = "WRITER" ] && printf '%s\n' "$f"
      done || true
}

# _sweep_scanned_count ROOT — how many candidate files the sweep looked at.
_sweep_scanned_count() {
  find "$1/scripts" "$1/hooks" "$1/skills" -type f \( -name '*.sh' -o -name '*.bash' \
    -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' -o -name '*.py' \) \
    2>/dev/null | grep -v '/tests/' | wc -l | tr -d ' '
}

# _copy_plugin_sources DEST — copy the plugin source trees the sweep reads.
_copy_plugin_sources() {
  mkdir -p "$1"
  cp -R "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/skills" "$1/"
  [ -d "$PLUGIN_ROOT/hooks" ] && cp -R "$PLUGIN_ROOT/hooks" "$1/"
  mkdir -p "$1/hooks"
}

@test "single-writer sweep finds only snapshot script" {
  [ "$(_sweep_scanned_count "$PLUGIN_ROOT")" -gt 0 ]
  local writers
  writers="$(_cache_writer_sweep "$PLUGIN_ROOT")"
  [ -n "$writers" ]
  [ "$(printf '%s\n' "$writers" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(basename "$writers")" = "sprint-progress-snapshot.sh" ]
}

@test "single-writer sweep mutant turns red when second writer planted" {
  # Copy the real plugin source tree and plant a second writer in each form
  # the sweep covers, then run the SAME sweep helper over the copy.
  local copy="$TEST_TMP/plugin-copy"
  _copy_plugin_sources "$copy"
  [ "$(_cache_writer_sweep "$copy" | wc -l | tr -d ' ')" -eq 1 ]

  local -a names=(redirect.sh mv-var.sh tee.bash cp.sh open-w.py replace.py write.mjs rename.ts append.cjs)
  local -a bodies=(
    'echo "{}" > "$STATE/.sprint-progress-cache.json"'
    'C="$STATE/.sprint-progress-cache.json"
T="$C.next"
jq . in.json > "$T" && mv -f "$T" "$C"'
    'CACHE_PATH="$STATE/.sprint-progress-cache.json"
printf "{}" | tee "$CACHE_PATH" >/dev/null'
    'cache=".gaia/state/.sprint-progress-cache.json"
if true; then cp new.json "${cache}"; fi'
    'CACHE = os.path.join(state, ".sprint-progress-cache.json")
with open(CACHE, "w") as f:
    f.write("{}")'
    'target = state / ".sprint-progress-cache.json"
os.replace(tmp, target)'
    'const cachePath = join(state, ".sprint-progress-cache.json");
writeFileSync(cachePath, "{}");'
    'const dest = `${state}/.sprint-progress-cache.json`;
fs.renameSync(tmp, dest);'
    'fs.appendFileSync(".gaia/state/.sprint-progress-cache.json", "x");'
  )
  local i
  for i in "${!names[@]}"; do
    printf '%s\n' "${bodies[$i]}" > "$copy/hooks/rogue-${names[$i]}"
    if [ "$(_cache_writer_sweep "$copy" | wc -l | tr -d ' ')" -ne 2 ]; then
      echo "planted writer not detected: ${names[$i]}" >&2; return 1
    fi
    unlink "$copy/hooks/rogue-${names[$i]}"
  done
}

@test "single-writer sweep stays green for read-only consumers of the cache" {
  local copy="$TEST_TMP/plugin-copy"
  _copy_plugin_sources "$copy"
  local -a names=(statusline.sh band.bash dashboard.py sidebar.mjs panel.ts)
  local -a bodies=(
    'CACHE="$STATE/.sprint-progress-cache.json"
[ -f "$CACHE" ] || exit 0
pct="$(jq -r ".totals.progress_pct" "$CACHE" 2>/dev/null)"
jq -c . "$CACHE" > "$OUT/copy.json"
cp "$CACHE" "$OUT/backup.json"'
    'cat "$STATE/.sprint-progress-cache.json" | jq -r .sprint.id >&2'
    'CACHE = os.path.join(state, ".sprint-progress-cache.json")
with open(CACHE) as f:
    data = json.load(f)
with open(CACHE, "r") as g:
    g.read()'
    'const cachePath = join(state, ".sprint-progress-cache.json");
const data = JSON.parse(readFileSync(cachePath, "utf8"));
const show = (x) => x > 0;'
    'const p = `${root}/.gaia/state/.sprint-progress-cache.json`;
copyFileSync(p, backupPath);'
  )
  local i
  for i in "${!names[@]}"; do
    printf '%s\n' "${bodies[$i]}" > "$copy/hooks/reader-${names[$i]}"
  done
  # Every reader names the cache, yet none of them writes it.
  [ "$(grep -rlF '.sprint-progress-cache.json' "$copy/hooks" | wc -l | tr -d ' ')" -eq 5 ]
  local writers; writers="$(_cache_writer_sweep "$copy")"
  [ "$(printf '%s\n' "$writers" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(basename "$writers")" = "sprint-progress-snapshot.sh" ]
}

# ---------------------------------------------------------------------------
# Command allowlist
# ---------------------------------------------------------------------------

@test "command allowlist passes valid commands" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  local slug="e900-s1-al"
  local dir="$IMPL/epic-test/E900-S1-${slug}"
  mkdir -p "$dir"
  cat > "$dir/story.md" <<'EOF'
---
template: 'story'
key: "E900-S1"
title: "Allowlist test"
status: review
points: 5
manual_verification: true
depends_on: []
---

# Story: Allowlist test

> **Status:** review

## Tasks / Subtasks

- [x] Task 1: Done

## Review Gate

| Review | Status | Report |
|--------|--------|--------|
| Code Review | PASSED | — |
| QA Tests | PASSED | — |
| Security Review | PASSED | — |
| Test Automation | PASSED | — |
| Test Review | PASSED | — |
| Performance Review | PASSED | — |

## Definition of Done

- [x] All done
EOF

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Rule (a) fires with an allowlisted command
  [ "$(jq -r '.action_needed[0].command' "$CACHE")" = "/gaia-test-manual" ]
}

@test "command allowlist nullifies unknown command" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local bad
  bad="$(jq -r '[.action_needed[].command | select(. != null and . != "/gaia-test-manual" and . != "/gaia-sprint-close" and . != "/gaia-action-items")] | length' "$CACHE")"
  [ "$bad" = "0" ]
  [ "$(jq -r '.action_needed[0].command' "$CACHE")" = "/gaia-sprint-close" ]

  # The one allowlist filter both the cold and the warm path use, fed
  # hostile values straight from the sourced script.
  run "$SNAP_BASH" -c '
    . "$1"
    chk() { jq -n -r --argjson c "$1" "${_JQ_DEFS} \$c | allow" --args "${_ALLOWED_COMMANDS[@]}"; }
    for ok in "\"/gaia-test-manual\"" "\"/gaia-sprint-close\"" "\"/gaia-action-items\""; do
      [ "$(chk "$ok")" = "$(jq -r . <<< "$ok")" ] || { echo "rejected $ok"; exit 1; }
    done
    for bad in "\"/gaia-test-manual; rm -rf x\"" "\"\"" "\"  /gaia-test-manual  \"" \
               "\"/unknown-command\"" "\"hello world\"" "null" "42" "[\"/gaia-test-manual\"]"; do
      [ "$(chk "$bad")" = "null" ] || { echo "accepted $bad"; exit 1; }
    done
    echo ALL_PASS
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "ALL_PASS" ]
}

@test "cold run sends every rule command through the allowlist" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  # Rule d fires with /gaia-sprint-close.  With that command taken out of the
  # allowlist the cold assembly must write null, never the literal.
  run "$SNAP_BASH" -c '. "$1"; _ALLOWED_COMMANDS=("/gaia-test-manual" "/gaia-action-items"); _snapshot_main' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.action_needed[] | [.rule, .command]]' "$CACHE")" = '[["d",null]]' ]
  run grep -c 'gaia-sprint-close' "$CACHE"
  [ "$output" = "0" ]
}

@test "command allowlist source-code grep confirms no dynamic assignment" {
  # The command field must come from a hardcoded allowlist, never a variable
  # The snapshot script should have a literal allowlist array
  [ -f "$SCRIPT" ]
  grep -q '_ALLOWED_COMMANDS' "$SCRIPT"
  grep -q '/gaia-test-manual' "$SCRIPT"
  grep -q '/gaia-sprint-close' "$SCRIPT"
  grep -q '/gaia-action-items' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Story-key shape validation
# ---------------------------------------------------------------------------

@test "story-key shape validation accepts valid rejects invalid" {
  # Inject an invalid key alongside valid ones
  cat > "$SPRINT_STATUS_YAML" <<'EOF'
sprint_id: "sprint-test"
status: active
start_date: "2026-10-01"
end_date: "2026-10-14"
total_points: 5
goals: []
stories:
  - key: "E900-S1"
    title: "Valid key"
    status: "in-progress"
    points: 5
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
  - key: "INVALID-KEY"
    title: "Bad key"
    status: "in-progress"
    points: 3
    risk_level: "medium"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
  - key: "E900-S1; rm -rf /"
    title: "Injection attempt"
    status: "in-progress"
    points: 1
    risk_level: "low"
    assignee: null
    blocked_by: null
    updated: "2026-10-01"
EOF
  write_story E900-S1 in-progress 5

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Only the valid key should appear
  [ "$(jq '.stories | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
  # Stderr should mention the rejected keys (real assertion, not || true)
  grep -qi "INVALID-KEY\|skipp" <<< "$output"
}

@test "story-key validation is anchored at both ends" {
  cat > "$SPRINT_STATUS_YAML" <<'EOF'
sprint_id: "sprint-test"
status: active
stories:
  - key: "E900-S1"
    status: "in-progress"
  - key: "xE900-S2"
    status: "in-progress"
  - key: "E900-S3x"
    status: "in-progress"
EOF
  write_story E900-S1 in-progress 5
  # Story directories exist for the near-miss keys, so only the key check can
  # keep them out.
  mkdir -p "$IMPL/epic-test/xE900-S2-near" "$IMPL/epic-test/E900-S3x-near"
  cp "$IMPL/epic-test/E900-S1-e900-s1-enf/story.md" "$IMPL/epic-test/xE900-S2-near/story.md"
  cp "$IMPL/epic-test/E900-S1-e900-s1-enf/story.md" "$IMPL/epic-test/E900-S3x-near/story.md"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'skipping invalid story key: xE900-S2' <<< "$stderr"
  grep -q 'skipping invalid story key: E900-S3x' <<< "$stderr"
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1"]' ]
}

# ---------------------------------------------------------------------------
# Realpath containment
# ---------------------------------------------------------------------------

# Both tests below reach the containment check: the story is first resolved
# and cached by a normal run, then its file (or directory) is swapped for a
# link out of the root.  The yaml and the story tree are unchanged, so the
# cached path is reused and only containment can keep the data out.

@test "realpath containment skips a story directory that is a symlink escaping the project root" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:in-progress:3"
  write_story E900-S1 done 5
  write_story E900-S2 in-progress 3
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.stories[] | select(.key == "E900-S2")] | length' "$CACHE")" = "1" ]

  # The story DIRECTORY becomes a link to a directory outside the root.
  local outside="$TEST_TMP/outside-project"
  mkdir -p "$outside"
  printf -- '---\nkey: "E900-S2"\ntitle: "ESCAPED story"\nstatus: in-progress\npoints: 3\n---\n' > "$outside/story.md"
  local dir="$IMPL/epic-test/E900-S2-e900-s2-enf"
  rm -rf "${dir:?}"; ln -s "$outside" "$dir"
  touch -t 202610010000 "$IMPL/epic-test"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE" >/dev/null
  grep -q 'path escapes project root for E900-S2' <<< "$stderr"
  [ "$(jq '[.stories[] | select(.key == "E900-S2")] | length' "$CACHE")" = "0" ]
  [ "$(jq '[.stories[] | select(.key == "E900-S1")] | length' "$CACHE")" = "1" ]
  run grep -c 'ESCAPED story' "$CACHE"
  [ "$output" = "0" ]
}

@test "file-level symlink to outside target is rejected by containment" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:done:5" "E900-S2:in-progress:3"
  write_story E900-S1 done 5
  write_story E900-S2 in-progress 3
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # The story FILE becomes a single link to a file outside the root.
  local outside="$TEST_TMP/outside-file"
  mkdir -p "$outside"
  printf -- '---\nkey: "E900-S2"\ntitle: "ESCAPED via file symlink"\nstatus: in-progress\npoints: 3\n---\n' > "$outside/real-story.md"
  local sf="$IMPL/epic-test/E900-S2-e900-s2-enf/story.md"
  rm -f "${sf:?}"; ln -s "$outside/real-story.md" "$sf"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE" >/dev/null
  grep -q 'path escapes project root for E900-S2' <<< "$stderr"
  [ "$(jq '[.stories[] | select(.key == "E900-S2")] | length' "$CACHE")" = "0" ]
  [ "$(jq '[.stories[] | select(.key == "E900-S1")] | length' "$CACHE")" = "1" ]
  run grep -c 'ESCAPED via file symlink' "$CACHE"
  [ "$output" = "0" ]
}

@test "a story file that is a symlink is followed when it stays inside the root" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5" "E900-S2:in-progress:3"
  # E900-S1: the story file is a link to a file elsewhere inside the root.
  mkdir -p "$PROJECT_ROOT/shared" "$IMPL/epic-test/E900-S1-linked"
  printf -- '---\nkey: "E900-S1"\ntitle: "LINKED-INSIDE"\nstatus: review\npoints: 5\n---\n' > "$PROJECT_ROOT/shared/E900-S1.md"
  ln -s "$PROJECT_ROOT/shared/E900-S1.md" "$IMPL/epic-test/E900-S1-linked/story.md"
  # E900-S2: the story file is a link out of the root.
  local outside="$TEST_TMP/outside-linked"; mkdir -p "$outside" "$IMPL/epic-test/E900-S2-linked"
  printf -- '---\nkey: "E900-S2"\ntitle: "LINKED-OUTSIDE"\nstatus: done\npoints: 3\n---\n' > "$outside/story.md"
  ln -s "$outside/story.md" "$IMPL/epic-test/E900-S2-linked/story.md"

  # First run: no sidecar, so both keys come from the story-tree search.
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[] | [.key, .title, .status]]' "$CACHE")" = '[["E900-S1","LINKED-INSIDE","review"]]' ]
  grep -q 'path escapes project root for E900-S2' <<< "$stderr"
  ! grep -q 'no file found' <<< "$stderr" || false
  run grep -c 'LINKED-OUTSIDE' "$CACHE"
  [ "$output" = "0" ]
}

@test "realpath containment follows a two-hop symlink chain out of the root" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5" "E900-S2:in-progress:3"
  write_story E900-S1 done 5
  write_story E900-S2 in-progress 3
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '[.stories[] | select(.key == "E900-S2")] | length' "$CACHE")" = "1" ]

  # Replace E900-S2's story with: story.md -> inner (inside the root) ->
  # secret outside the root.  The yaml is unchanged, so the cached sidecar
  # path is reused and the containment check is the only guard.
  local dir="$IMPL/epic-test/E900-S2-e900-s2-enf"
  local outside="$TEST_TMP/outside-chain"; mkdir -p "$outside"
  printf -- '---\nkey: "E900-S2"\ntitle: "ESCAPED TWO HOP"\nstatus: review\npoints: 3\n---\n' > "$outside/secret.md"
  rm -f "$dir/story.md"
  ln -s "$outside/secret.md" "$dir/inner"
  ln -s inner "$dir/story.md"

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  grep -q 'escapes project root for E900-S2' <<< "$stderr"
  [ "$(jq '[.stories[] | select(.key == "E900-S2")] | length' "$CACHE")" = "0" ]
  run grep -c 'ESCAPED TWO HOP' "$CACHE"
  [ "$output" = "0" ]
}

@test "realpath helper resolves every hop and refuses missing targets" {
  local d="$TEST_TMP/rp"; mkdir -p "$d/a" "$d/b"
  echo x > "$d/b/target"
  ln -s ../b/target "$d/a/hop2"
  ln -s hop2 "$d/a/hop1"
  local phys; phys="$(cd "$d/b" && pwd -P)/target"
  run "$SNAP_BASH" -c ". '$SCRIPT'; _realpath_one '$d/a/hop1'"
  [ "$status" -eq 0 ]
  [ "$output" = "$phys" ]
  # Dangling chain: no path is produced (BSD-safe guard on missing targets).
  ln -s nowhere "$d/a/dangling"
  run "$SNAP_BASH" -c ". '$SCRIPT'; _realpath_one '$d/a/dangling'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # The batch form keeps one line per argument, in order, with a blank line
  # for the unresolvable one.
  run "$SNAP_BASH" -c ". '$SCRIPT'; _realpath_batch '$d/a/hop1' '$d/a/dangling' '$d/b/target'"
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "$phys" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "?" ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "$phys" ]
}

@test "story file missing between resolution and parse is skipped with a warning" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5" "E900-S2:in-progress:3"
  write_story E900-S1 done 5
  write_story E900-S2 in-progress 3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Cached path for E900-S2 now points at a dangling symlink.
  local sf="$IMPL/epic-test/E900-S2-e900-s2-enf/story.md"
  rm -f "$sf"; ln -s "$TEST_TMP/gone.md" "$sf"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1"]' ]
  grep -q 'E900-S2' <<< "$stderr"
}

@test "lock works for a project path containing a single quote" {
  local q="$TEST_TMP/it's a project"
  mkdir -p "$q/.gaia/state" "$q/.gaia/artifacts/implementation-artifacts"
  local probe="$TEST_TMP/EVAL_PWNED"
  local evil="$TEST_TMP/proj'\$(touch $probe)'x"
  mkdir -p "$evil/.gaia/state"
  for root in "$q" "$evil"; do
    printf 'sprint_id: "s"\nstatus: active\nstories: []\n' > "$root/.gaia/state/sprint-status.yaml"
    PROJECT_ROOT="$root" SPRINT_STATUS_YAML="$root/.gaia/state/sprint-status.yaml" run "$SCRIPT"
    [ "$status" -eq 0 ]
    jq -e . "$root/.gaia/state/.sprint-progress-cache.json" >/dev/null
  done
  [ ! -e "$probe" ]
  [ "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -cw 'eval')" = "0" ]
}

# ---------------------------------------------------------------------------
# Single-flight lock — flock backend
# ---------------------------------------------------------------------------

@test "single-flight lock with flock backend skips concurrent run" {
  # Skip if flock is not available — this test exercises the flock backend only
  command -v flock >/dev/null 2>&1 || skip "flock not available on this host"

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Hold the lock via flock
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 7>>"$LOCK_FILE"
  flock -n 7

  # Run snapshot — should skip (exit 0, no write)
  local pre_cache=""
  [ -f "$CACHE" ] && pre_cache="$(cat "$CACHE")"

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # Release the flock
  flock -u 7
  exec 7>&-

  # Cache should not have been written (or should be unchanged)
  if [ -n "$pre_cache" ]; then
    [ "$(cat "$CACHE")" = "$pre_cache" ]
  else
    [ ! -f "$CACHE" ]
  fi
}

# ---------------------------------------------------------------------------
# Single-flight lock — fallback backend (GAIA_LOCK_FORCE_FALLBACK=1)
# ---------------------------------------------------------------------------

@test "single-flight lock with fallback backend skips concurrent run" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Hold the lock via ln (fallback backend pattern)
  mkdir -p "$(dirname "$LOCK_FILE")"
  local tmp_lock="${LOCK_FILE}.tmp.holder.$$"
  printf '%s %s\n' "$$" "$(date +%s)" > "$tmp_lock"
  ln "$tmp_lock" "$LOCK_FILE" 2>/dev/null
  rm -f "$tmp_lock"

  # Run snapshot with fallback backend — should skip (exit 0, no write)
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$CACHE" ]

  # Cleanup
  rm -f "$LOCK_FILE"
  unset GAIA_LOCK_FORCE_FALLBACK
}

@test "single-flight lock fallback backend acquires free lock and writes cache" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # No pre-existing lock — should acquire and write
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"

  # Lock should be cleaned up
  [ ! -f "$LOCK_FILE" ]

  unset GAIA_LOCK_FORCE_FALLBACK
}

# ---------------------------------------------------------------------------
# Stale lock recovery
# ---------------------------------------------------------------------------

@test "killed holder stale lock does not suppress snapshots indefinitely" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Create a stale lock with a dead PID (PID 99999 is unlikely to exist)
  mkdir -p "$(dirname "$LOCK_FILE")"
  local stale_tmp="${LOCK_FILE}.tmp.stale.$$"
  printf '%s %s\n' "99999" "$(date -v -2H +%s 2>/dev/null || date -d '2 hours ago' +%s)" > "$stale_tmp"
  ln "$stale_tmp" "$LOCK_FILE" 2>/dev/null
  rm -f "$stale_tmp"
  # Backdate the lock file to ensure it exceeds the reap threshold
  touch -t 202601010000 "$LOCK_FILE"

  # Snapshot should reap the stale lock, acquire, and write
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$CACHE" ]
  jq -e '.' "$CACHE"

  unset GAIA_LOCK_FORCE_FALLBACK
}

@test "snapshot cleans its lock on exit" {
  export GAIA_LOCK_FORCE_FALLBACK=1

  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Run snapshot — it should acquire and release the lock
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Lock file should be cleaned up after normal exit
  [ ! -f "$LOCK_FILE" ]

  unset GAIA_LOCK_FORCE_FALLBACK
}

# ---------------------------------------------------------------------------
# Lock-path type policy
# ---------------------------------------------------------------------------

@test "directory at lock path is refused without following into it" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Plant a directory at the lock path
  mkdir -p "$LOCK_FILE"
  echo "planted" > "$LOCK_FILE/decoy.txt"

  # Snapshot should exit 0 (best-effort) but not write inside the directory
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # The decoy file must be untouched
  [ -f "$LOCK_FILE/decoy.txt" ]
  [ "$(cat "$LOCK_FILE/decoy.txt")" = "planted" ]
}

@test "symlink at lock path is refused without following it" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5

  # Dangling symlink: following it would CREATE the target outside the project.
  local target="$TEST_TMP/outside/created-through-symlink"
  mkdir -p "$TEST_TMP/outside" "$(dirname "$LOCK_FILE")"
  ln -s "$target" "$LOCK_FILE"
  for backend in flock fallback; do
    if [ "$backend" = "fallback" ]; then export GAIA_LOCK_FORCE_FALLBACK=1
    else command -v flock >/dev/null 2>&1 || continue; fi
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$target" ]
    [ -L "$LOCK_FILE" ]
    grep -q 'lock path is a symlink, refusing' <<< "$stderr"
    [ ! -e "$CACHE" ]
    unset GAIA_LOCK_FORCE_FALLBACK
  done

  # Existing target: its content is never touched either.
  rm -f "$LOCK_FILE"
  echo "original" > "$target"
  ln -s "$target" "$LOCK_FILE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$target")" = "original" ]
  [ ! -e "$CACHE" ]
}

# ---------------------------------------------------------------------------
# Alias sanitization
# ---------------------------------------------------------------------------

@test "alias with special chars is sanitized in cache and matches only exactly" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5

  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  # Alias containing double quote, single quote, regex metachars
  cat > "$config" <<'YAML'
sprint_status_mod:
  user_aliases:
    - 'test"user'
    - "it's me"
    - ".*[]()^$|+?\\"
YAML

  # Action item assigned to the regex-metachars alias (exact match)
  local ai_path="$PROJECT_ROOT/.gaia/state/action-items.yaml"
  cat > "$ai_path" <<'YAML'
items:
  - id: "AI-940"
    title: "Check"
    status: "open"
    assignee: '.*[]()^$|+?\\'
    created_at: "2026-10-05"
  - id: "AI-941"
    title: "Unrelated"
    status: "open"
    assignee: "anything"
    created_at: "2026-10-05"
YAML

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"

  # The aliases must appear sanitized (control chars stripped) and as valid JSON
  local alias_count
  alias_count="$(jq '.user_aliases | length' "$CACHE")"
  [ "$alias_count" = "3" ]

  # The regex-metachars alias should NOT match "anything" via .*
  # Only the exact-match item should appear as rule-c
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "1" ]
  [ "$(jq -r '.action_needed[] | select(.rule == "c") | .item_id' "$CACHE")" = "AI-940" ]
}

@test "alias with control chars is stripped and empties are dropped" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5

  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  # Real TAB, ESC and BEL bytes inside the alias values.
  printf 'sprint_status_mod:\n  user_aliases:\n    - "clean"\n    - "has\ttab"\n    - "e\033[31msc\007"\n    - ""\n' > "$config"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  jq -e '.' "$CACHE"
  [ "$(jq -c '.user_aliases' "$CACHE")" = '["clean","hastab","e[31msc"]' ]
}

@test "aliases are capped at 100 characters each and 20 entries" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"
  local long; long="$(printf 'a%.0s' $(seq 1 150))"
  {
    printf 'sprint_status_mod:\n  user_aliases:\n    - "%s"\n' "$long"
    local i; for i in $(seq 1 24); do printf '    - "alias-%s"\n' "$i"; done
  } > "$config"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.user_aliases | length' "$CACHE")" = "20" ]
  [ "$(jq '.user_aliases[0] | length' "$CACHE")" = "100" ]
  [ "$(jq -r '.user_aliases[19]' "$CACHE")" = "alias-19" ]
}

# ---------------------------------------------------------------------------
# Threshold validation
# ---------------------------------------------------------------------------

@test "threshold accepts valid integers and rejects non-integers" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5

  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"

  # Valid: 0
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 0\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "0" ]

  # Valid: 300
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 300\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "300" ]

  # Invalid: "abc" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: abc\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: "-5" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: -5\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: "1e3" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 1e3\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: "12 34" -> fallback to 120
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: "12 34"\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Invalid: 30-digit number -> fallback to 120 (length check)
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 123456789012345678901234567890\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]

  # Empty config -> default 120
  printf 'sprint_status_mod: {}\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]
}

@test "threshold above one hour falls back to the default with a warning" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  local config="$PROJECT_ROOT/.gaia/config/project-config.yaml"

  # 3600 is the largest value the config schema allows.
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 3600\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "3600" ]
  ! grep -q 'invalid threshold' <<< "$stderr" || false

  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 3601\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]
  grep -q "invalid threshold value '3601', using default 120" <<< "$stderr"

  # Leading zeros are read as decimal, and still capped.
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 0003601\n' > "$config"
  rm -f "$CACHE" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]
}

# ---------------------------------------------------------------------------
# Control bytes in story paths
# ---------------------------------------------------------------------------

@test "a story directory name with a unit separator, CR, LF or TAB is refused and cannot shift fields" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5" \
    "E900-S2:in-progress:5" "E900-S3:in-progress:5" "E900-S4:in-progress:5" "E900-S5:in-progress:5"
  # A shifted record would make the parser open the path's last field ("B")
  # relative to the working directory, which is a link out of the root.
  local outside="$TEST_TMP/outside-sep"; mkdir -p "$outside"
  printf -- '---\ntitle: "OUTSIDE-VIA-SEP"\nstatus: done\n---\n' > "$outside/story.md"
  ln -s "$outside" "$PROJECT_ROOT/B"
  local -a keys=(E900-S1 E900-S2 E900-S3 E900-S4) bytes=($'\037' $'\r' $'\n' $'\t')
  local i d
  for i in 0 1 2 3; do
    d="$IMPL/epic-test/${keys[$i]}-x${bytes[$i]}A${bytes[$i]}B"
    mkdir -p "$d"
    printf -- '---\ntitle: "INSIDE"\nstatus: in-progress\n---\n' > "$d/story.md"
  done
  write_story E900-S5 in-progress 5

  cd "$PROJECT_ROOT"
  run --separate-stderr "$SCRIPT"
  local err="$stderr"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S5"]' ]
  for i in 0 1 2 3; do
    grep -q "a story path for key ${keys[$i]} contains control characters" <<< "$err"
  done
  run grep -c 'OUTSIDE-VIA-SEP' "$CACHE"
  [ "$output" = "0" ]
  run grep -c 'INSIDE' "$CACHE"
  [ "$output" = "0" ]
}

@test "a story link that resolves to a path with control bytes is refused without shifting other stories" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:in-progress:5" "E900-S2:in-progress:5" "E900-S3:in-progress:5"
  write_story E900-S1 in-progress 5
  write_story E900-S2 in-progress 5
  write_story E900-S3 in-progress 5
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]

  # In-root targets whose directory names hold a unit separator and a
  # newline; the story files of S1 and S2 become links to them.  The yaml and
  # the story tree are unchanged, so the cached paths are reused and the
  # resolved paths reach the containment check.
  local t1="$PROJECT_ROOT/w"$'\037'"x" t2="$PROJECT_ROOT/w"$'\n'"y"
  mkdir -p "$t1" "$t2"
  printf -- '---\ntitle: "LINKED-TARGET"\nstatus: done\n---\n' > "$t1/story.md"
  cp "$t1/story.md" "$t2/story.md"
  local s1="$IMPL/epic-test/E900-S1-e900-s1-enf/story.md" s2="$IMPL/epic-test/E900-S2-e900-s2-enf/story.md"
  rm -f "${s1:?}" "${s2:?}"; ln -s "$t1/story.md" "$s1"; ln -s "$t2/story.md" "$s2"

  run --separate-stderr "$SCRIPT"
  local err="$stderr"
  [ "$status" -eq 0 ]
  jq -e . "$CACHE" >/dev/null
  grep -q 'story path for E900-S1 contains control characters' <<< "$err"
  # The newline path cannot be resolved to one line, so it is refused too,
  # and the story after it keeps its own data.
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S3"]' ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S3" ]
  run grep -c 'LINKED-TARGET' "$CACHE"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# A story name that does not lead to a regular file
# ---------------------------------------------------------------------------

# three_story_sprint — E900-S1 and E900-S2 are ordinary stories; E900-S3's
# story directory exists and is given its story.md by the test.
three_story_sprint() {
  write_sprint_yaml active "2026-10-01" "2026-10-14" \
    "E900-S1:in-progress:5" "E900-S2:review:3" "E900-S3:in-progress:2"
  write_story E900-S1 in-progress 5
  write_story E900-S2 review 3
  mkdir -p "$IMPL/epic-test/E900-S3-linked"
}

# run_bounded SECS CMD... — run CMD in the background and fail when it is
# still running after SECS seconds.  A run blocked on a FIFO is released by
# opening the FIFO ($BOUNDED_FIFO) for writing before it is killed.  Sets
# status, output (stdout) and stderr like `run --separate-stderr`.
run_bounded() {
  local secs="$1"; shift
  "$@" > "$TEST_TMP/bounded.out" 2> "$TEST_TMP/bounded.err" &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt $((secs * 20)) ]; then
      if [ -n "${BOUNDED_FIFO:-}" ]; then exec 7<>"$BOUNDED_FIFO"; exec 7>&-; fi
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "still running after ${secs}s" >&2
      return 1
    fi
    sleep 0.05
  done
  status=0; wait "$pid" || status=$?
  output="$(cat "$TEST_TMP/bounded.out")"
  stderr="$(cat "$TEST_TMP/bounded.err")"
}

@test "a story link to a directory is skipped and the other stories stay in the cache" {
  three_story_sprint
  mkdir -p "$PROJECT_ROOT/somedir"
  ln -s "$PROJECT_ROOT/somedir" "$IMPL/epic-test/E900-S3-linked/story.md"
  backdate_tree

  run_bounded 20 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1","E900-S2"]' ]
  [ "$(jq '.totals.total_stories' "$CACHE")" = "2" ]
  grep -q 'story file for E900-S3 is not a regular file, skipping' <<< "$stderr"
  ! grep -q 'i/o error' <<< "$stderr" || false
  grep -q "^miss	E900-S3$" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"

  # The next run is not served warm from what this run wrote: it looks
  # again (a planted title is rebuilt) and still keeps the other stories.
  jq '.stories[0].title = "PLANTED"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run_bounded 20 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1","E900-S2"]' ]
  grep -q 'story file for E900-S3 is not a regular file, skipping' <<< "$stderr"

  # Once the link leads to a story file, the story is picked up.
  printf -- '---\nkey: "E900-S3"\ntitle: "NOW A FILE"\nstatus: done\npoints: 2\n---\n' > "$PROJECT_ROOT/real-s3.md"
  rm -f "$IMPL/epic-test/E900-S3-linked/story.md"
  ln -s "$PROJECT_ROOT/real-s3.md" "$IMPL/epic-test/E900-S3-linked/story.md"
  run_bounded 20 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1","E900-S2","E900-S3"]' ]
}

@test "a story link to a FIFO is skipped without hanging the run" {
  command -v mkfifo >/dev/null 2>&1 || skip "mkfifo not available"
  three_story_sprint
  mkfifo "$PROJECT_ROOT/fifo"
  BOUNDED_FIFO="$PROJECT_ROOT/fifo"
  ln -s "$PROJECT_ROOT/fifo" "$IMPL/epic-test/E900-S3-linked/story.md"
  backdate_tree

  run_bounded 20 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1","E900-S2"]' ]
  grep -q 'story file for E900-S3 is not a regular file, skipping' <<< "$stderr"

  # The following run does not hang either, and does not reuse the result.
  jq '.stories[0].title = "PLANTED"' "$CACHE" > "$CACHE.new" && mv "$CACHE.new" "$CACHE"
  run_bounded 20 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
  grep -q 'story file for E900-S3 is not a regular file, skipping' <<< "$stderr"
}

@test "a story file awk cannot read costs only that story" {
  three_story_sprint
  write_story E900-S3 in-progress 2
  # awk stops outright on a read error (BSD awk does so on a directory that
  # slips in between the checks and the read).  Simulate that: any parse
  # that includes E900-S2 fails.
  run --separate-stderr "$SNAP_BASH" -c '
    . "$1"
    eval "real_$(declare -f _story_records)"
    _story_records() {
      case "$SNAP_WANT" in *E900-S2*) real__story_records "$@" > /dev/null; return 2 ;; esac
      real__story_records "$@"
    }
    _snapshot_main
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S1","E900-S3"]' ]
  [ "$(jq -r '.stories[1].title' "$CACHE")" = "Story E900-S3" ]
  grep -q 'story file for E900-S2 could not be read, skipping' <<< "$stderr"
  # Recorded as missing, so the next run reads it again.
  grep -q "^miss	E900-S2$" "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes"
}

@test "a story link to a path with a TAB is refused by the cold containment check" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5" "E900-S2:in-progress:5"
  write_story E900-S1 in-progress 5
  write_story E900-S2 in-progress 5
  local t="$PROJECT_ROOT/tab"$'\t'"dir"; mkdir -p "$t"
  printf -- '---\ntitle: "TAB-TARGET"\nstatus: done\n---\n' > "$t/story.md"
  local s1="$IMPL/epic-test/E900-S1-e900-s1-enf/story.md"
  rm -f "${s1:?}"; ln -s "$t/story.md" "$s1"

  # No sidecar yet, so this is a cold run: the link is found by the search
  # and its resolved path is checked before anything is read.
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'sprint-progress-snapshot: story path for E900-S1 contains control characters, skipping' <<< "$stderr"
  ! grep -q 'escapes project root' <<< "$stderr" || false
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S2"]' ]
  run grep -c 'TAB-TARGET' "$CACHE"
  [ "$output" = "0" ]
}

@test "the warm path refuses a recorded story path that now leads to a path with a TAB" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5" "E900-S2:in-progress:5"
  write_story E900-S1 in-progress 5
  write_story E900-S2 in-progress 5
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local t="$PROJECT_ROOT/tab"$'\t'"dir"; mkdir -p "$t"
  printf -- '---\ntitle: "TAB-TARGET"\nstatus: done\n---\n' > "$t/story.md"
  local s1="$IMPL/epic-test/E900-S1-e900-s1-enf/story.md"
  rm -f "${s1:?}"; ln -s "$t/story.md" "$s1"
  backdate_tree

  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qF 'sidecar story path for E900-S1 contains control characters, rebuilding' <<< "$stderr"
  [ "$(jq -c '[.stories[].key]' "$CACHE")" = '["E900-S2"]' ]
}

# ---------------------------------------------------------------------------
# State-file writes stay inside the project root
# ---------------------------------------------------------------------------

@test "a symlink or directory at a state file name is refused, never followed" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  local state="$PROJECT_ROOT/.gaia/state" outside="$TEST_TMP/outside-dir" n
  mkdir -p "$outside"

  # Links to an outside DIRECTORY at each name: a rename would drop the temp
  # file inside the directory the link points to.
  for n in .sprint-progress-cache.json .sprint-progress-mtimes .sprint-progress-parsed; do
    ln -s "$outside" "$state/$n"
  done
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$outside")" ]
  grep -q 'refusing to replace .sprint-progress-cache.json' <<< "$stderr"
  for n in .sprint-progress-cache.json .sprint-progress-mtimes .sprint-progress-parsed; do
    [ -L "$state/$n" ]; rm -f "${state:?}/${n:?}"
  done

  # A first run creates real files; then the parse cache and sidecar names
  # become links (the cache itself stays a regular file).
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  rm -f "${CACHE:?}"
  for n in .sprint-progress-mtimes .sprint-progress-parsed; do
    rm -f "${state:?}/${n:?}"; ln -s "$outside" "$state/$n"
  done
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'refusing to replace .sprint-progress-parsed' <<< "$stderr"
  grep -q 'refusing to replace .sprint-progress-mtimes' <<< "$stderr"
  jq -e . "$CACHE" >/dev/null
  [ -z "$(ls -A "$outside")" ]
  for n in .sprint-progress-mtimes .sprint-progress-parsed; do rm -f "${state:?}/${n:?}"; done

  # A directory at the cache name: nothing is moved into it.
  rm -f "${CACHE:?}"; mkdir "$CACHE"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$CACHE")" ]
  grep -q 'refusing to replace .sprint-progress-cache.json' <<< "$stderr"
  rmdir "$CACHE"

  # A link to an outside FILE: the file is never touched.
  echo "original" > "$TEST_TMP/outside-file"
  ln -s "$TEST_TMP/outside-file" "$CACHE"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMP/outside-file")" = "original" ]
  [ -L "$CACHE" ]
}

@test "a symlinked .gaia/state or .gaia directory is refused" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  local outside="$TEST_TMP/outside-state"
  mv "$PROJECT_ROOT/.gaia/state" "$outside"
  ln -s "$outside" "$PROJECT_ROOT/.gaia/state"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(find "$outside" -name '.sprint-progress-*')" ]
  grep -q 'state directory is a symlink, refusing to write' <<< "$stderr"

  # The whole .gaia tree behind a link.
  unlink "$PROJECT_ROOT/.gaia/state"; mv "$outside" "$PROJECT_ROOT/.gaia/state"
  local outside2="$TEST_TMP/outside-gaia"
  mv "$PROJECT_ROOT/.gaia" "$outside2"
  ln -s "$outside2" "$PROJECT_ROOT/.gaia"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(find "$outside2" -name '.sprint-progress-*')" ]
  grep -q 'state directory is a symlink, refusing to write' <<< "$stderr"
}

@test "sprint yaml, ledger, config and action-items outside the project root are not read" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:review:5"
  local dir="$IMPL/epic-test/E900-S1-meta"; mkdir -p "$dir"
  printf -- '---\ntitle: "T"\nstatus: review\nmanual_verification: true\n---\n' > "$dir/story.md"
  local out="$TEST_TMP/outside-meta"; mkdir -p "$out"
  printf 'E900-S1\tmanual-test\tp\tOUTSIDE-VERDICT\n' > "$out/ledger"
  printf 'sprint_status_mod:\n  waiting_agent_threshold_seconds: 7\n  user_aliases:\n    - "outsider"\n' > "$out/cfg"
  printf 'items:\n  - id: "AI-990"\n    status: open\n    assignee: outsider\n' > "$out/ai"
  ln -s "$out/ledger" "$PROJECT_ROOT/.gaia/state/.review-gate-ledger"
  ln -s "$out/cfg" "$PROJECT_ROOT/.gaia/config/project-config.yaml"
  ln -s "$out/ai" "$PROJECT_ROOT/.gaia/state/action-items.yaml"

  run --separate-stderr "$SCRIPT"
  local err="$stderr"
  [ "$status" -eq 0 ]
  [ "$(jq '.stories[0].manual_test.verdict' "$CACHE")" = "null" ]
  [ "$(jq '.waiting_agent_threshold_seconds' "$CACHE")" = "120" ]
  [ "$(jq '[.action_needed[] | select(.rule == "c")] | length' "$CACHE")" = "0" ]
  run grep -c 'outsider\|OUTSIDE-VERDICT' "$CACHE"
  [ "$output" = "0" ]
  grep -q 'review-gate-ledger resolves outside the project root, not reading it' <<< "$err"
  grep -q 'project-config.yaml resolves outside the project root, not reading it' <<< "$err"
  grep -q 'action-items.yaml resolves outside the project root, not reading it' <<< "$err"
  # An entry that is not read is recorded unverified, so every run re-checks it.
  [ "$(awk -F'\t' '$2 == "__review_gate_ledger__" { print $4 }' "$PROJECT_ROOT/.gaia/state/.sprint-progress-mtimes")" = "racy" ]

  # Explicit overrides are held to the same rule.
  sed 's/^sprint_id: "sprint-test"/sprint_id: "sprint-outside"/' "$SPRINT_STATUS_YAML" > "$out/yaml"
  SPRINT_STATUS_YAML="$out/yaml" REVIEW_GATE_LEDGER="$out/ledger" run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq '.sprint' "$CACHE")" = "null" ]
  grep -q "$out/yaml resolves outside the project root" <<< "$stderr"
}

@test "a symlinked parse cache is never read" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local parsed="$PROJECT_ROOT/.gaia/state/.sprint-progress-parsed"
  # A crafted record set whose (key, path, mtime) matches the real story, so
  # it would be reused verbatim if the link were followed.
  local forged="$TEST_TMP/forged-parsed"
  sed 's/Story E900-S1/FORGED-TITLE/' "$parsed" > "$forged"
  grep -q 'FORGED-TITLE' "$forged"
  unlink "$parsed" 2>/dev/null || rm -f "${parsed:?}"
  ln -s "$forged" "$parsed"
  rm -f "${CACHE:?}"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
  run grep -c 'FORGED-TITLE' "$CACHE"
  [ "$output" = "0" ]
}

@test "a planted parse-cache row for another story never reaches that story" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5" "E900-S2:in-progress:3"
  write_story E900-S1 in-progress 5
  write_story E900-S2 in-progress 3
  local s2="$IMPL/epic-test/E900-S2-e900-s2-enf/story.md"
  [ -f "$s2" ]
  backdate_tree
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  local parsed="$PROJECT_ROOT/.gaia/state/.sprint-progress-parsed"
  # A task row keyed to E900-S2 planted inside E900-S1's cached record, and
  # E900-S2 changed so it is parsed fresh.
  # A second, forged copy of E900-S1's record follows the tampered one: once
  # a record is found tampered, no later copy of it is trusted either.
  awk -v US=$'\037' '{ print } $1 ~ ("^P" US "E900-S1" US) { p = $0; print "T" US "E900-S2" US "false" US "INJECTED-VIA-PARSE-CACHE"; sub(/Story E900-S1/, "FORGED-SECOND-COPY", p); print p }' \
    "$parsed" > "$parsed.new" && mv "$parsed.new" "$parsed"
  grep -q 'FORGED-SECOND-COPY' "$parsed"
  grep -q 'INJECTED-VIA-PARSE-CACHE' "$parsed"
  sed 's/^status: in-progress/status: review/' "$s2" > "$s2.new" && mv "$s2.new" "$s2"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -c 'INJECTED-VIA-PARSE-CACHE\|FORGED-SECOND-COPY' "$CACHE"
  [ "$output" = "0" ]
  [ "$(jq -r '.stories[0].title' "$CACHE")" = "Story E900-S1" ]
  # Both stories keep exactly the tasks of their own files.
  [ "$(jq -c '[.stories[] | [.key, .status, .tasks.total]]' "$CACHE")" = '[["E900-S1","in-progress",1],["E900-S2","review",1]]' ]
}

@test "temp files are created exclusively and never follow a planted link" {
  local target="$TEST_TMP/state/cache.json" victim="$TEST_TMP/victim"
  mkdir -p "$TEST_TMP/state"
  # Seeding RANDOM makes the first temp name predictable; plant a dangling
  # link there.  An exclusive create must refuse it and pick another name.
  run "$SNAP_BASH" -c '
    . "$1"
    RANDOM=4242; first="$2.tmp.$$.${RANDOM}${RANDOM}"
    ln -s "$3" "$first"
    RANDOM=4242; _new_tmp "$2" || exit 9
    [ "$_TMP" != "$first" ] || exit 8
    [ -f "$_TMP" ] && [ ! -L "$_TMP" ] || exit 7
    printf "%s\n" "$_TMP"
  ' _ "$SCRIPT" "$target" "$victim"
  [ "$status" -eq 0 ]
  [ ! -e "$victim" ]
}

# ---------------------------------------------------------------------------
# Fallback lock and the empty lock file the flock backend leaves behind
# ---------------------------------------------------------------------------

@test "fallback lock replaces an old empty lock file but not a fresh one" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  # A fresh empty lock file may be a flock-backend run that has not written
  # its line yet, so it is left alone.
  : > "$LOCK_FILE"
  GAIA_LOCK_FORCE_FALLBACK=1 run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'lock not taken (the lock file is empty but only [0-9]*s old), skipping' <<< "$stderr"
  [ ! -e "$CACHE" ]
  # An old empty lock file (left by an older version) holds nothing.
  touch -t 202001010000 "$LOCK_FILE"
  GAIA_LOCK_FORCE_FALLBACK=1 run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'replacing an empty lock file nobody holds' <<< "$stderr"
  jq -e . "$CACHE" >/dev/null
  [ ! -e "$LOCK_FILE" ]
  [ ! -e "$LOCK_FILE.reaping" ]
}

# take_lock_racing SCRIPT LOCK HOOK — source the script, override HOOK (a
# function the fallback lock calls after it judged the existing lock and
# before it removes it) so that another run swaps in its own live lock at
# exactly that moment, then try to take the lock.  Prints the outcome, the
# lock file's content and the number of leftover reap files.
take_lock_racing() {
  "$SNAP_BASH" -c '
    . "$1"; lock="$2"; hook="$3"
    GAIA_LOCK_FORCE_FALLBACK=1
    other_takes_lock() {
      rm -f "$lock"
      printf "%s %s\n" "$PPID" "$(date +%s)" > "$lock.other"
      ln "$lock.other" "$lock"; rm -f "$lock.other"
    }
    case "$hook" in
      warn) _warn() { case "$*" in *"replacing an empty lock"*) other_takes_lock ;; esac; } ;;
      age)  _stat_mtime_age() { other_takes_lock; printf 120; } ;;
      # A flock-backend run announces itself in the judged file right after
      # the reaper checked it again under the reap mutex.
      flockwrite)
        _warn() { :; }
        eval "real_$(declare -f _lock_ident)"
        n=0
        _lock_ident() {
          real__lock_ident "$@" || return 1
          n=$((n + 1))
          if [ "$n" = "2" ]; then printf "%s %s\n" "$PPID" "$(date +%s)" >> "$lock"; fi
        } ;;
    esac
    if _try_snapshot_lock "$lock"; then echo "TOOK"; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    echo "holder=$(cut -d" " -f1 < "$lock") other=$PPID self=$$"
    echo "reap=$(find "${lock%/*}" -name "*.reap.*" | wc -l | tr -d " ") mutex=$([ -e "$lock.reaping" ] && echo left || echo none)"
  ' _ "$SCRIPT" "$LOCK_FILE" "$1"
}

@test "replacing an empty lock never removes a lock another run linked after the check" {
  : > "$LOCK_FILE"; touch -t 202001010000 "$LOCK_FILE"
  run take_lock_racing warn
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SKIPPED: taken by another process" ]
  # The other run's lock (a live PID that is not this run's) is still in place.
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ other=([0-9]+)\ self=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
  [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]
  [ "${lines[2]}" = "reap=0 mutex=none" ]
}

@test "reaping never removes a lock a flock-backend run announced itself in after the last check" {
  : > "$LOCK_FILE"; touch -t 202001010000 "$LOCK_FILE"
  run take_lock_racing flockwrite
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SKIPPED: taken by another process" ]
  # The announcing run's file was put back, with its line last.
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ other=([0-9]+)\ self=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
  [ "${lines[2]}" = "reap=0 mutex=none" ]
}

@test "a stale lock is reaped by one run at a time" {
  : > "$LOCK_FILE"; touch -t 202001010000 "$LOCK_FILE"
  # Another run is reaping the same file right now (it holds the mutex).
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"; GAIA_LOCK_FORCE_FALLBACK=1
    _warn() { case "$*" in *"replacing an empty lock"*) mkdir "$lock.reaping" ;; esac; }
    if _try_snapshot_lock "$lock"; then echo TOOK; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    [ -f "$lock" ] && [ ! -s "$lock" ] && echo UNTOUCHED
  ' _ "$SCRIPT" "$LOCK_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SKIPPED: taken by another process" ]
  [ "${lines[1]}" = "UNTOUCHED" ]
}

@test "a reaper re-checks the lock under the mutex before moving it aside" {
  : > "$LOCK_FILE"; touch -t 202001010000 "$LOCK_FILE"
  sleep 30 & local third=$!
  # After the judgement another run links its own lock; any moment the lock
  # name is free, a third run links its lock there.  The reaper must notice
  # the new lock before it ever moves it aside.
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"; third="$3"; GAIA_LOCK_FORCE_FALLBACK=1
    _warn() {
      case "$*" in *"replacing an empty lock"*)
        rm -f "$lock"; printf "%s %s\n" "$PPID" "$(date +%s)" > "$lock.o"; ln "$lock.o" "$lock"; rm -f "$lock.o" ;;
      esac
    }
    eval "real_$(declare -f _lock_ident)"
    _lock_ident() {
      if [ ! -e "$lock" ]; then printf "%s %s\n" "$third" "$(date +%s)" > "$lock.t"; ln "$lock.t" "$lock"; rm -f "$lock.t"; fi
      real__lock_ident "$@"
    }
    if _try_snapshot_lock "$lock"; then echo TOOK; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    echo "holder=$(cut -d" " -f1 < "$lock") other=$PPID"
  ' _ "$SCRIPT" "$LOCK_FILE" "$third"
  kill "$third" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SKIPPED: taken by another process" ]
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ other=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
}

@test "a flock-backend run that loses its lock file before announcing itself backs off" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  # Right after this run takes the flock, a fallback run replaces the file
  # (as a reaper of an old empty file would) and links its own live lock.
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"; first=1
    eval "real_$(declare -f _lock_last)"
    _lock_last() {
      if [ "$first" = "1" ]; then
        first=0
        rm -f "$lock"; printf "%s %s\n" "$PPID" "$(date +%s)" > "$lock.o"; ln "$lock.o" "$lock"; rm -f "$lock.o"
        _LOCK_LAST=""; return 1
      fi
      real__lock_last "$@"
    }
    if _try_snapshot_lock "$lock"; then echo "TOOK ($_SNAPSHOT_LOCK_BACKEND)"; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    echo "holder=$(cut -d" " -f1 < "$lock") other=$PPID lines=$(wc -l < "$lock" | tr -d " ")"
  ' _ "$SCRIPT" "$LOCK_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SKIPPED: taken by another process" ]
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ other=([0-9]+)\ lines=1$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
}

@test "reaping a stale lock never removes a lock another run linked after the check" {
  sleep 0 & local dead=$!; wait "$dead" || true
  printf '%s %s\n' "$dead" 1000000000 > "$LOCK_FILE"
  touch -t 202001010000 "$LOCK_FILE"
  run take_lock_racing age
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SKIPPED: taken by another process" ]
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ other=([0-9]+)\ self=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
  [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]
  [ "${lines[2]}" = "reap=0 mutex=none" ]

  # Without a racing run the stale lock is reaped and taken.
  rm -f "$LOCK_FILE"
  printf '%s %s\n' "$dead" 1000000000 > "$LOCK_FILE"
  touch -t 202001010000 "$LOCK_FILE"
  run take_lock_racing none
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOK" ]
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ other=([0-9]+)\ self=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[3]}" ]
  [ "${lines[2]}" = "reap=0 mutex=none" ]
}

# slow_build_stub — a jq stub whose cold assembly records a build, announces
# itself and then waits for $TEST_TMP/go (at most 10 s) before finishing.
slow_build_stub() {
  local stub="$TEST_TMP/stub-bin"; mkdir -p "$stub"
  local real_jq; real_jq="$(command -v jq)"
  cat > "$stub/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'inputs | split'*)
    echo build >> "$TEST_TMP/builds"
    : > "$TEST_TMP/assembling"
    i=0; while [ ! -e "$TEST_TMP/go" ] && [ "\$i" -lt 200 ]; do sleep 0.05; i=\$((i + 1)); done ;;
esac
exec "$real_jq" "\$@"
SH
  chmod +x "$stub/jq"
  printf '%s' "$stub"
}

# wait_for FILE — wait up to 10 s for FILE to exist.
wait_for() {
  local i=0
  while [ ! -e "$1" ]; do i=$((i + 1)); [ "$i" -le 200 ] || return 1; sleep 0.05; done
}

@test "a fallback run never takes the lock while a flock-backend run holds it" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  local stub; stub="$(slow_build_stub)"
  PATH="$stub:$PATH" "$SCRIPT" 2>/dev/null &
  local pid=$!
  wait_for "$TEST_TMP/assembling" || { kill "$pid"; return 1; }
  # The flock holder announces itself in the lock file.
  [ "$(cut -d' ' -f1 < "$LOCK_FILE")" = "$pid" ]

  GAIA_LOCK_FORCE_FALLBACK=1 PATH="$stub:$PATH" run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "lock not taken (held by live process $pid), skipping" <<< "$stderr"
  [ "$(wc -l < "$TEST_TMP/builds" | tr -d ' ')" = "1" ]

  : > "$TEST_TMP/go"
  wait "$pid"
  # Released: the flock backend removes its lock file too.
  [ ! -e "$LOCK_FILE" ]
  jq -e . "$CACHE" >/dev/null
}

@test "a flock-backend run never takes the lock while a fallback run holds it" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  local stub; stub="$(slow_build_stub)"
  GAIA_LOCK_FORCE_FALLBACK=1 PATH="$stub:$PATH" "$SCRIPT" 2>/dev/null &
  local pid=$!
  wait_for "$TEST_TMP/assembling" || { kill "$pid"; return 1; }

  PATH="$stub:$PATH" run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "lock not taken (held by live process $pid), skipping" <<< "$stderr"
  [ "$(wc -l < "$TEST_TMP/builds" | tr -d ' ')" = "1" ]

  : > "$TEST_TMP/go"
  wait "$pid"
  [ ! -e "$LOCK_FILE" ]
}

@test "many fallback runs racing to reap a stale lock file never build at the same time" {
  # Every runner sources the script and replaces only the build with a
  # start/end marker pair; the lock code is the real one.  They all find the
  # same old empty lock file, so they all try to reap it at once.
  local log="$TEST_TMP/overlap.log" trial r
  for trial in 1 2 3 4 5 6 7 8; do
    : > "$LOCK_FILE"; touch -t 202001010000 "$LOCK_FILE"; : > "$log"
    local -a pids=()
    for r in $(seq 1 12); do
      "$SNAP_BASH" -c '
        . "$1"; export GAIA_LOCK_FORCE_FALLBACK=1; LOG="$2"
        _warn() { :; }
        _snapshot_build() { echo "S $$" >> "$LOG"; sleep 0.05; echo "E $$" >> "$LOG"; }
        _snapshot_main
      ' _ "$SCRIPT" "$log" &
      pids+=("$!")
    done
    wait "${pids[@]}"
    # At most one build in flight at any moment, and at least one build ran.
    [ "$(awk '$1 == "S" { a++; if (a > m) m = a } $1 == "E" { a-- } END { print m + 0 }' "$log")" = "1" ]
    rm -f "$LOCK_FILE"
  done
}

@test "a lock file that disappears after a failed link is simply retried" {
  printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK_FILE"
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"; GAIA_LOCK_FORCE_FALLBACK=1; calls=0
    eval "real_$(declare -f _fallback_link)"
    # The holder releases right after this run failed to link.
    _fallback_link() {
      calls=$((calls + 1))
      if [ "$calls" = "1" ]; then real__fallback_link "$@" && return 0; rm -f "$lock"; return 1; fi
      real__fallback_link "$@"
    }
    if _try_snapshot_lock "$lock"; then echo "TOOK after $calls"; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    [ "$(cut -d" " -f1 < "$lock")" = "$$" ] && echo OWNED
  ' _ "$SCRIPT" "$LOCK_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOK after 2" ]
  [ "${lines[1]}" = "OWNED" ]
}

@test "the fallback temp lock is created exclusively and never follows a planted link" {
  local victim="$TEST_TMP/victim"
  # Seeding RANDOM makes the first temp name predictable; plant a dangling
  # link there.  The exclusive create must refuse it and pick another name.
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"
    RANDOM=4242; first="$lock.tmp.$$.${RANDOM}${RANDOM}"
    ln -s "$3" "$first"
    RANDOM=4242; _fallback_link "$lock" || exit 9
    [ -L "$first" ] || exit 8
    [ "$(cut -d" " -f1 < "$lock")" = "$$" ] || exit 7
    echo OK
  ' _ "$SCRIPT" "$LOCK_FILE" "$victim"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
  [ ! -e "$victim" ]
}

@test "fallback lock that gives up says why on stderr" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  # Live holder.
  printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK_FILE"
  GAIA_LOCK_FORCE_FALLBACK=1 run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "lock not taken (held by live process $$), skipping" <<< "$stderr"
  [ ! -e "$CACHE" ]
  # Dead holder, but the lock is too young to reap.
  sleep 0 & local dead=$!; wait "$dead" || true
  printf '%s %s\n' "$dead" "$(date +%s)" > "$LOCK_FILE"
  GAIA_LOCK_FORCE_FALLBACK=1 run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "lock not taken (holder '$dead' is not running but the lock is only" <<< "$stderr"
  [ ! -e "$CACHE" ]
}

@test "releasing never removes a lock file whose last line belongs to another holder" {
  local backend
  for backend in fallback flock; do
    if [ "$backend" = "flock" ]; then command -v flock >/dev/null 2>&1 || continue; fi
    rm -f "$LOCK_FILE"
    run "$SNAP_BASH" -c '
      . "$1"; lock="$2"
      if [ "$3" = "fallback" ]; then GAIA_LOCK_FORCE_FALLBACK=1; fi
      _try_snapshot_lock "$lock" || { echo "NOT TAKEN: $_SNAPSHOT_LOCK_REASON"; exit 0; }
      echo "TOOK ($_SNAPSHOT_LOCK_BACKEND)"
      # Another live holder owns the lock name now.
      rm -f "$lock"; printf "%s %s\n" "$PPID" "$(date +%s)" > "$lock"
      _release_snapshot_lock
      if [ -e "$lock" ]; then echo "KEPT $(cut -d" " -f1 < "$lock") other=$PPID"; else echo "REMOVED"; fi
    ' _ "$SCRIPT" "$LOCK_FILE" "$backend"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "TOOK ($backend)" ]
    [[ ${lines[1]} =~ ^KEPT\ ([0-9]+)\ other=([0-9]+)$ ]]
    [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
  done
}

@test "a flock-backend run waits for a reap in progress and backs off when the lock changed hands" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  # A fallback run is reaping (it holds the reap mutex) and judged the file
  # before this run announced itself.  While this run waits, the reaper
  # moves the file aside and another run links its own lock at the name.
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"
    mkdir "$lock.reaping"
    sleep() {
      rm -f "$lock"; printf "%s %s\n" "$PPID" "$(date +%s)" > "$lock.o"; ln "$lock.o" "$lock"; rm -f "$lock.o"
      rmdir "$lock.reaping"
    }
    if _try_snapshot_lock "$lock"; then echo "TOOK"; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    echo "holder=$(cut -d" " -f1 < "$lock") other=$PPID"
  ' _ "$SCRIPT" "$LOCK_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "SKIPPED: taken by another process" ]
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ other=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
}

@test "a flock-backend run keeps the lock when the reaper leaves its file alone" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"; waited=0
    mkdir "$lock.reaping"
    # The reaper saw this run'"'"'s line and gave up without touching the file.
    sleep() { waited=1; rmdir "$lock.reaping"; }
    if _try_snapshot_lock "$lock"; then echo "TOOK waited=$waited"; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    echo "holder=$(cut -d" " -f1 < "$lock") self=$$"
  ' _ "$SCRIPT" "$LOCK_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOK waited=1" ]
  [[ ${lines[1]} =~ ^holder=([0-9]+)\ self=([0-9]+)$ ]]
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
}

@test "a reap mutex left behind by a dead reaper does not block the flock backend" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  mkdir "$LOCK_FILE.reaping"; touch -t 202001010000 "$LOCK_FILE.reaping"
  run "$SNAP_BASH" -c '
    . "$1"; lock="$2"
    sleep() { echo "WAITED"; }
    if _try_snapshot_lock "$lock"; then echo "TOOK"; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
  ' _ "$SCRIPT" "$LOCK_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "TOOK" ]
  [ ! -e "$LOCK_FILE.reaping" ]
}

@test "an aged reap mutex that cannot be removed makes the flock backend give up within seconds" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  # A stray file inside an old mutex: rmdir fails on every pass.
  mkdir "$LOCK_FILE.reaping"; : > "$LOCK_FILE.reaping/stray"
  touch -t 202001010000 "$LOCK_FILE.reaping"
  local t0=$SECONDS
  run_bounded 20 "$SCRIPT"
  local took=$((SECONDS - t0))
  [ "$status" -eq 0 ]
  grep -q 'lock not taken (taken by another process), skipping' <<< "$stderr"
  # Two lock attempts of about 2 s each, plus the run itself.
  [ "$took" -le 8 ]
  [ -e "$LOCK_FILE.reaping/stray" ]
}

# snap_has_subsecond_clock — true when the interpreter under test is bash 5
# or later (it has EPOCHREALTIME).
snap_has_subsecond_clock() {
  [ "$("$SNAP_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"')" -ge 5 ]
}

@test "the reap wait gives up after about 2 s of wall-clock time even when every pass is cheap" {
  snap_has_subsecond_clock || skip "the interpreter has no sub-second clock; its whole-second bound is tested in the bash 3.2 suite"
  mkdir "$LOCK_FILE.reaping"; : > "$LOCK_FILE.reaping/stray"
  touch -t 202001010000 "$LOCK_FILE.reaping"
  # 5 ms passes: the 1000-pass cap would take about 5 s, so only the 2 s
  # deadline can end the wait this early.
  local t0="${EPOCHREALTIME//[!0-9]/}" t1 ms
  run_bounded 15 "$SNAP_BASH" -c '
    . "$1"; mutex="$2"
    sleep() { command sleep 0.005; }
    if _await_reap "$mutex"; then echo "CLEARED"; else echo "GAVE UP"; fi
  ' _ "$SCRIPT" "$LOCK_FILE.reaping"
  t1="${EPOCHREALTIME//[!0-9]/}"; ms=$(( (10#$t1 - 10#$t0) / 1000 ))
  [ "$status" -eq 0 ]
  [ "$output" = "GAVE UP" ]
  [ "$ms" -ge 1900 ]
  [ "$ms" -le 4000 ]
}

@test "without a wall clock the reap wait gives up after 100 sleeps, counting passes that cannot clear an aged mutex" {
  mkdir "$LOCK_FILE.reaping"; : > "$LOCK_FILE.reaping/stray"
  touch -t 202001010000 "$LOCK_FILE.reaping"
  # The sleep stub also holds whole-second time still (SECONDS=0), so only
  # the pass count can end the wait.
  run_bounded 15 "$SNAP_BASH" -c '
    . "$1"; mutex="$2"; unset EPOCHREALTIME; slept=0
    sleep() { slept=$((slept + 1)); SECONDS=0; }
    if _await_reap "$mutex"; then echo "CLEARED"; else echo "GAVE UP"; fi
    echo "slept=$slept"
  ' _ "$SCRIPT" "$LOCK_FILE.reaping"
  [ "$status" -eq 0 ]
  local l0 l1; { read -r l0; read -r l1; } <<< "$output"
  [ "$l0" = "GAVE UP" ]
  [ "$l1" = "slept=100" ]
}

@test "a sub-second clock that does not move cannot hold the reap wait" {
  mkdir "$LOCK_FILE.reaping"; : > "$LOCK_FILE.reaping/stray"
  touch -t 202001010000 "$LOCK_FILE.reaping"
  # After unset, EPOCHREALTIME is a plain variable that never moves.  bash 5
  # still counts passes in clock mode (1000); an older shell ignores the
  # value and falls back to the 100-pass bound.
  local want=1000
  snap_has_subsecond_clock || want=100
  run_bounded 15 "$SNAP_BASH" -c '
    . "$1"; mutex="$2"; unset EPOCHREALTIME; EPOCHREALTIME=1000.000001; slept=0
    sleep() { slept=$((slept + 1)); SECONDS=0; }
    if _await_reap "$mutex"; then echo "CLEARED"; else echo "GAVE UP"; fi
    echo "slept=$slept"
  ' _ "$SCRIPT" "$LOCK_FILE.reaping"
  [ "$status" -eq 0 ]
  local l0 l1; { read -r l0; read -r l1; } <<< "$output"
  [ "$l0" = "GAVE UP" ]
  [ "$l1" = "slept=$want" ]
}

@test "a lock file that vanishes while its age is read is retried without stat noise" {
  sleep 0 & local dead=$!; wait "$dead" || true
  printf '%s %s\n' "$dead" 1000000000 > "$LOCK_FILE"
  run --separate-stderr "$SNAP_BASH" -c '
    . "$1"; lock="$2"; GAIA_LOCK_FORCE_FALLBACK=1; n=0
    eval "real_$(declare -f _stat_mtime)"
    # The holder releases right after this run judged its line.
    _stat_mtime() {
      n=$((n + 1))
      if [ "$n" = "1" ]; then rm -f "$lock"; fi
      real__stat_mtime "$@"
    }
    if _try_snapshot_lock "$lock"; then echo "TOOK"; else echo "SKIPPED: $_SNAPSHOT_LOCK_REASON"; fi
    [ "$(cut -d" " -f1 < "$lock")" = "$$" ] && echo OWNED
  ' _ "$SCRIPT" "$LOCK_FILE"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "TOOK" ]
  [ "${lines[1]}" = "OWNED" ]
  [ -z "$stderr" ]
}

@test "a holder line that names a live process but is too old does not block the lock" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  # This test's own shell is alive; its PID in a line written long ago (or
  # dated far in the future) is not a running build.
  local line
  for line in "$$ 1000000000" "$$ 99999999999"; do
    printf '%s\n' "$line" > "$LOCK_FILE"; touch -t 202001010000 "$LOCK_FILE"
    rm -f "$CACHE"
    GAIA_LOCK_FORCE_FALLBACK=1 run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -q 'held by live process' <<< "$stderr" || false
    jq -e . "$CACHE" >/dev/null
    [ ! -e "$LOCK_FILE" ]
    if command -v flock >/dev/null 2>&1; then
      printf '%s\n' "$line" > "$LOCK_FILE"
      rm -f "$CACHE"
      run --separate-stderr "$SCRIPT"
      [ "$status" -eq 0 ]
      ! grep -q 'held by live process' <<< "$stderr" || false
      jq -e . "$CACHE" >/dev/null
    fi
  done
  # A live holder that took the lock just now still holds it, on both backends.
  printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK_FILE"
  rm -f "$CACHE"
  GAIA_LOCK_FORCE_FALLBACK=1 run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "lock not taken (held by live process $$), skipping" <<< "$stderr"
  [ ! -e "$CACHE" ]
  if command -v flock >/dev/null 2>&1; then
    run --separate-stderr "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "lock not taken (held by live process $$), skipping" <<< "$stderr"
    [ ! -e "$CACHE" ]
  fi
}

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

@test "TERM releases the lock and exits without finishing the write" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:done:5"
  write_story E900-S1 done 5
  export GAIA_LOCK_FORCE_FALLBACK=1

  # Stub jq: the cold assembly announces itself, then takes 2 s.
  local stub="$TEST_TMP/stub-bin"; mkdir -p "$stub"
  local real_jq; real_jq="$(command -v jq)"
  cat > "$stub/jq" <<SH
#!/usr/bin/env bash
case "\$*" in *'inputs | split'*) : > "$TEST_TMP/assembling"; sleep 2 ;; esac
exec "$real_jq" "\$@"
SH
  chmod +x "$stub/jq"

  PATH="$stub:$PATH" "$SCRIPT" 2>/dev/null &
  local pid=$!
  local i=0
  while [ ! -e "$TEST_TMP/assembling" ]; do
    i=$((i + 1)); [ "$i" -le 100 ] || { kill "$pid" 2>/dev/null; return 1; }
    sleep 0.1
  done
  [ -e "$LOCK_FILE" ]
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  # It stopped: no cache was published, the lock and temp files are gone.
  [ ! -e "$CACHE" ]
  [ ! -e "$LOCK_FILE" ]
  [ -z "$(find "$PROJECT_ROOT/.gaia/state" -name '*.tmp.*')" ]
  unset GAIA_LOCK_FORCE_FALLBACK
}

# build_counting_jq STORY_FILE [mark] — put a jq wrapper first on PATH that
# appends one line to $TEST_TMP/builds per cold assembly and gives
# STORY_FILE a new mtime, so a further build in the same run is cold too and
# is counted.  With "mark", every assembly also leaves the re-run marker, the
# way a writer that never stops would.
build_counting_jq() {
  local stub="$TEST_TMP/stub-bin" real_jq sf="$1" mark="${2:-}"
  mkdir -p "$stub"; real_jq="$(command -v jq)"
  cat > "$stub/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'inputs | split'*)
    echo build >> "$TEST_TMP/builds"
    n="\$(wc -l < "$TEST_TMP/builds" | tr -d ' ')"
    touch -t "20300101\$(printf '%02d' "\$n")00" "$sf"
    if [ -n "$mark" ]; then mkdir "$LOCK_FILE.dirty" 2>/dev/null || true; fi ;;
esac
exec "$real_jq" "\$@"
SH
  chmod +x "$stub/jq"
  STUB_PATH="$stub:$PATH"
}

@test "a re-run marker planted as a symlink to a directory never asks for another build" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  mkdir "$TEST_TMP/elsewhere"
  ln -s "$TEST_TMP/elsewhere" "$LOCK_FILE.dirty"
  build_counting_jq "$IMPL/epic-test/E900-S1-e900-s1-enf/story.md"
  PATH="$STUB_PATH" run_bounded 30 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_TMP/builds" | tr -d ' ')" = "1" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
  # The planted link and its target are left alone.
  [ -L "$LOCK_FILE.dirty" ]
  [ -d "$TEST_TMP/elsewhere" ]
}

@test "a writer that keeps leaving the re-run marker gets at most five builds in one run" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  local sf="$IMPL/epic-test/E900-S1-e900-s1-enf/story.md"
  [ -f "$sf" ]
  build_counting_jq "$sf" mark
  PATH="$STUB_PATH" run_bounded 30 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_TMP/builds" | tr -d ' ')" = "5" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
  [ ! -e "$LOCK_FILE" ]
}

@test "a re-run marker that cannot be removed costs one build and a warning, not five" {
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  # A stray file inside the marker: rmdir fails on every pass.
  mkdir "$LOCK_FILE.dirty"; : > "$LOCK_FILE.dirty/stray"
  build_counting_jq "$IMPL/epic-test/E900-S1-e900-s1-enf/story.md"
  PATH="$STUB_PATH" run_bounded 30 "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_TMP/builds" | tr -d ' ')" = "1" ]
  [ "$(grep -c 're-run marker cannot be removed, building once: .*/\.sprint-progress-cache\.json\.lock\.dirty$' <<< "$stderr")" = "1" ]
  [ "$(jq -r '.stories[0].key' "$CACHE")" = "E900-S1" ]
  [ -e "$LOCK_FILE.dirty/stray" ]
}

@test "a flock-backend run refused by another flock holder leaves the re-run marker" {
  command -v flock >/dev/null 2>&1 || skip "needs flock for the flock backend"
  write_sprint_yaml active "2026-10-01" "2026-10-14" "E900-S1:in-progress:5"
  write_story E900-S1 in-progress 5 >/dev/null
  # Another process holds the flock on the lock file (and writes no line).
  : > "$LOCK_FILE"
  flock "$LOCK_FILE" sleep 30 &
  local holder=$! i=0
  while flock -n "$LOCK_FILE" true 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 100 ] || { kill "$holder"; return 1; }
    sleep 0.05
  done
  run --separate-stderr "$SCRIPT"
  kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  grep -q 'lock not taken (held by another process), skipping' <<< "$stderr"
  [ -d "$LOCK_FILE.dirty" ]
  [ ! -L "$LOCK_FILE.dirty" ]
  [ ! -e "$CACHE" ]
}
