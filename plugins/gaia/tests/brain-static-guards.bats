#!/usr/bin/env bats
# brain-static-guards.bats — durable boundary + single-writer static guards for
# the brain knowledge layer.
#
# Two invariants are pinned here by static analysis over the committed source,
# so a future change that violates either turns this gate red:
#
#   1. Read-only boundary: no brain script writes into the agent-sidecar memory
#      subtree. The brain reads artifacts + state and writes only the knowledge
#      store; it must never produce a write-shaped op targeting a memory path —
#      whether spelled as a literal or reached through a variable.
#
#   2. Single writer: the knowledge manifest is written by exactly one script —
#      the reindex sweep. Every other script may READ the manifest path, but no
#      other script may carry a write-shaped op against it.
#
# The realistic hazard both guards must catch is VARIABLE INDIRECTION: the real
# writer never names the manifest on its write line. It assigns the path to a
# variable, derives a sibling tempfile variable from that, writes the tempfile,
# then atomically renames it. A literal-only grep would match nothing and pass
# vacuously. So each guard resolves writes THROUGH variables: it first collects
# the variables that hold (or transitively derive from) the forbidden path, then
# looks for write-shaped operations against that variable set.
#
# Each guard ships a self-test that injects a throwaway script exhibiting the
# realistic var-indirected violation and asserts the guard goes red on it —
# proving the guard bites the real-world form, not just a bare literal.
#
# Paths derive from $BATS_TEST_DIRNAME via test_helper.bash (SCRIPTS_DIR); no
# hardcoded source-layout prefix, so the gate runs identically from a cache.

load 'test_helper.bash'

setup() {
  common_setup
  BRAIN_DIR="$SCRIPTS_DIR/brain"
  REINDEX="$BRAIN_DIR/gaia-brain-reindex.sh"
  LOADER="$BRAIN_DIR/brain-reliance-loader.sh"
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Shared analysis core — variable-indirection-aware write detector (awk).
#
# bash 3.2 / BSD+GNU+ugrep portable: all parsing is done in ONE awk pass so we
# never build per-variable regexes (which both injects metacharacters and trips
# the stricter ugrep), and so multi-declaration `local a=.. b=..` lines parse
# correctly. Pure POSIX awk — no gensub, no length-of-array extensions.
#
# _brain_indirect_writes FILE SEED_REGEX
#   Prints "FILE:LINENO: <line>" for every WRITE-shaped op whose target is the
#   SEED path OR a variable that holds / transitively derives from it.
#
#   Taint model (fixed point over the whole file):
#     * a variable is tainted if its assigned value matches SEED_REGEX, or
#       references an already-tainted variable as $v / ${v}.
#   Write model:
#     * a line is a hit if it contains a write op — '>' / '>>' redirection,
#       `tee`, `cp`/`mv` (destination), or `yq -i` — AND the line references a
#       tainted variable (or the literal SEED), AND the line is not itself a
#       pure assignment of that variable (assignments are reads/derivations,
#       not writes of the target).
# ---------------------------------------------------------------------------
_brain_indirect_writes() {
  local file="$1" seed="$2"
  awk -v SEED="$seed" '
    function strip_comment(s) {
      if (s ~ /^[ \t]*#/) return ""   # whole-line comment
      return s
    }
    # tok_is_target(tok) — does this single token (a write destination operand)
    # name the seed path or a tainted variable?
    function tok_is_target(tok,   name) {
      if (tok ~ SEED) return 1
      for (name in taint) {
        if (taint[name] != 1) continue
        if (tok ~ ("\\$\\{?" name "([^A-Za-z0-9_]|$)")) return 1
      }
      return 0
    }
    {
      line[NR] = $0
      s = strip_comment($0)
      code[NR] = s
      # Collect assignments: one or more  name=value  tokens (handles
      # `local a="x" b="y"`, `name=$(...)`, plain `name=...`). The value is
      # taken to end-of-line — sufficient for taint propagation.
      rest = s
      while (match(rest, /[A-Za-z_][A-Za-z0-9_]*=/)) {
        nm = substr(rest, RSTART, RLENGTH - 1)
        after = substr(rest, RSTART + RLENGTH)
        aval[NR, ++acount[NR]] = after
        avar[NR, acount[NR]]   = nm
        rest = after
      }
    }
    END {
      # --- taint to a fixed point -------------------------------------------
      changed = 1
      while (changed) {
        changed = 0
        for (n = 1; n <= NR; n++) {
          for (k = 1; k <= acount[n]; k++) {
            nm = avar[n, k]; v = aval[n, k]
            if (taint[nm] == 1) continue
            ref = 0
            if (v ~ SEED) ref = 1
            else {
              for (name in taint) {
                if (taint[name] != 1) continue
                if (v ~ ("\\$\\{?" name "([^A-Za-z0-9_]|$)")) { ref = 1; break }
              }
            }
            if (ref) { taint[nm] = 1; changed = 1 }
          }
        }
      }
      # --- write detection: only the WRITE TARGET is examined ---------------
      for (n = 1; n <= NR; n++) {
        s = code[n]
        if (s == "") continue
        hit = 0

        # (1) Truncating/appending redirection: > TARGET  or  >> TARGET.
        #     Ignore fd-qualified error redirects (2>, &>) and /dev/null sinks.
        t = s
        while (match(t, /(^|[^0-9&>])>>?[ \t]*("?[^ \t;|&)>]+)/)) {
          seg = substr(t, RSTART, RLENGTH)
          tgt = seg; sub(/^[^>]*>>?[ \t]*/, "", tgt)
          if (tgt !~ /\/dev\/null/ && tok_is_target(tgt)) hit = 1
          t = substr(t, RSTART + RLENGTH)
        }

        # (2) tee TARGET... — every operand after tee is a write target.
        if (s ~ /(^|[ \t|();&])tee[ \t]/) {
          rhs = s; sub(/^.*(^|[ \t|();&])tee[ \t]+/, "", rhs)
          nt = split(rhs, parts, /[ \t]+/)
          for (i = 1; i <= nt; i++)
            if (parts[i] !~ /^-/ && tok_is_target(parts[i])) hit = 1
        }

        # (3) cp/mv SRC... DEST — destination is the LAST operand.
        if (s ~ /(^|[ \t|();&])(cp|mv)[ \t]/) {
          rhs = s; sub(/^.*(^|[ \t|();&])(cp|mv)[ \t]+/, "", rhs)
          sub(/[ \t]*(\|\|.*|&&.*|;.*|\|.*)$/, "", rhs)
          nt = split(rhs, parts, /[ \t]+/)
          if (nt >= 1 && tok_is_target(parts[nt])) hit = 1
        }

        # (4) yq -i FILE — in-place edit of the file operand.
        if (s ~ /yq[ \t]+-i/) {
          if (tok_is_target(s)) hit = 1
        }

        if (hit) printf "%s:%d: %s\n", FILE, n, line[n]
      }
    }
  ' FILE="$file" "$file"
}

# _memory_write_lines FILE — write-shaped ops into the agent memory subtree,
# whether spelled as a literal (.gaia/memory or $GAIA_MEMORY_DIR) or reached
# through a memory-derived variable (e.g. mem_subtree). The query's own
# compute-and-exclude `mem_subtree=` assignment is a derivation, not a write,
# and is therefore NOT reported.
_memory_write_lines() {
  # Seed taint on any value that names the agent-memory subtree: the .gaia/memory
  # literal, the GAIA_MEMORY_DIR env var, the bare "memory" sidecar-subdir literal
  # (as used in a dirname(knowledge)/memory construction), or a path segment
  # ending /memory". Taint then propagates through derived variables so a write
  # to e.g. $mem_subtree/x is caught even though no memory literal sits on the
  # write line.
  _brain_indirect_writes "$1" '(\.gaia/memory|GAIA_MEMORY_DIR|"memory"|/memory")'
}

# _manifest_writer_files DIR — files under DIR containing a write-shaped op
# against a brain-index.yaml-derived variable (the single-writer detector).
_manifest_writer_files() {
  local dir="$1" f hits
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    hits="$(_brain_indirect_writes "$f" 'brain-index\.yaml')"
    if [ -n "$hits" ]; then printf '%s\n' "$f"; fi
  done | sort -u
}

# ---------------------------------------------------------------------------
# AC2 — read-only boundary: no brain script writes into agent memory.
# ---------------------------------------------------------------------------

@test "no brain script writes into the agent-sidecar memory subtree" {
  local f hits rc=0
  for f in "$BRAIN_DIR"/*.sh; do
    [ -f "$f" ] || continue
    hits="$(_memory_write_lines "$f")"
    if [ -n "$hits" ]; then
      printf 'MEMORY WRITE in %s:\n%s\n' "$f" "$hits" >&2
      rc=1
    fi
  done
  [ "$rc" -eq 0 ]
}

@test "the memory-write guard bites a literal AND a variable-derived memory write" {
  # Self-test: a throwaway brain script that writes memory two ways — once via a
  # bare .gaia/memory literal, once via a variable derived from a memory subtree
  # construction (the var-indirection form a literal grep would miss).
  local decoy="$TEST_TMP/decoy-memory-writer.sh"
  cat > "$decoy" <<'EOS'
#!/usr/bin/env bash
knowledge_dir="$PROJ/.gaia/knowledge"
# (a) bare literal memory write
echo hi > "$PROJ/.gaia/memory/leak.txt"
# (b) var-indirected memory write
sidecar_subdir="memory"
mem_subtree="$(dirname "$knowledge_dir")/$sidecar_subdir"
target="$mem_subtree/sneaky.txt"
mv "$tmp" "$target"
EOS
  local hits
  hits="$(_memory_write_lines "$decoy")"
  # Literal form must be caught: the `echo ... > .gaia/memory/leak.txt` line.
  printf '%s\n' "$hits" | grep -q 'leak.txt'
  # Var-indirected form: the flagged line is `mv "$tmp" "$target"` — no memory
  # literal sits on it; it is caught only because $target derives (via
  # $mem_subtree <- sidecar_subdir="memory") from the memory subtree. That hit
  # is what proves the guard resolves writes THROUGH variables.
  printf '%s\n' "$hits" | grep -q 'mv "\$tmp" "\$target"'
}

@test "the query memory-subtree assignment is a read, not a write, and does not trip the guard" {
  # The query computes the memory subtree only to EXCLUDE it (an assignment +
  # canonicalisation, never a write). Confirm the real query script is clean.
  local q="$BRAIN_DIR/gaia-brain-query.sh"
  [ -f "$q" ]
  local hits
  hits="$(_memory_write_lines "$q")"
  [ -z "$hits" ]
}

@test "the reindex source-root enumeration is exactly artifacts and state, never memory" {
  [ -f "$REINDEX" ]
  # Walks artifacts + state roots.
  grep -qE 'GAIA_ARTIFACTS_DIR' "$REINDEX"
  grep -qE 'GAIA_STATE_DIR' "$REINDEX"
  # The walked-root loop names artifacts + state only.
  grep -qE 'for[[:space:]]+root[[:space:]]+in[[:space:]]+"\$artifacts_dir"[[:space:]]+"\$state_dir"' "$REINDEX"
  # No memory literal anywhere in the writer.
  ! grep -qE '\.gaia/memory|GAIA_MEMORY_DIR' "$REINDEX"
}

@test "the reindex skill never lists the memory tree as a source root" {
  local skill="$SCRIPTS_DIR/../skills/gaia-brain-reindex/SKILL.md"
  [ -f "$skill" ]
  ! grep -qE '\.gaia/memory/' "$skill"
}

# ---------------------------------------------------------------------------
# AC3 — partitioned ownership: the manifest has exactly three sanctioned
# writers, each owning a distinct source_type partition or lifecycle.
#   - gaia-brain-reindex.sh         -> project-artifact partition
#   - gaia-feed.sh                  -> ingested partition (initial ingest)
#   - gaia-knowledge-refresh.sh     -> ingested partition (re-fetch lifecycle)
# Any OTHER manifest writer is still forbidden.
# ---------------------------------------------------------------------------

@test "the knowledge manifest is written by exactly the three sanctioned partition owners" {
  local writers
  writers="$(_manifest_writer_files "$BRAIN_DIR")"
  [ -n "$writers" ]
  # Exactly three writers.
  [ "$(printf '%s\n' "$writers" | grep -c .)" -eq 3 ]
  # The reindex sweep (project-artifact partition).
  printf '%s\n' "$writers" | grep -q 'gaia-brain-reindex\.sh'
  # The ingestion writer (ingested partition).
  printf '%s\n' "$writers" | grep -q 'gaia-feed\.sh'
  # The refresh lifecycle (ingested partition — re-fetch).
  printf '%s\n' "$writers" | grep -q 'gaia-knowledge-refresh\.sh'
}

@test "no script outside the brain dir carries a manifest write" {
  # Widen the scope to the whole scripts tree: any script that writes a
  # brain-index.yaml-derived variable must be one of the three sanctioned writers.
  local f hits rc=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    [ "$f" = "$REINDEX" ] && continue
    [ "$f" = "$BRAIN_DIR/gaia-feed.sh" ] && continue
    [ "$f" = "$BRAIN_DIR/gaia-knowledge-refresh.sh" ] && continue
    hits="$(_brain_indirect_writes "$f" 'brain-index\.yaml')"
    if [ -n "$hits" ]; then
      printf 'UNEXPECTED MANIFEST WRITER %s:\n%s\n' "$f" "$hits" >&2
      rc=1
    fi
  done <<EOF
$(find "$SCRIPTS_DIR" -type f -name '*.sh')
EOF
  [ "$rc" -eq 0 ]
}

@test "the partitioned-writer guard bites a rogue third manifest writer" {
  # Self-test: inject a throwaway script that writes the manifest THROUGH a
  # variable (the realistic form — the literal never appears on the write line).
  # The guard must flag it as an unexpected writer alongside the two legitimate ones.
  local injdir="$TEST_TMP/inj-brain"
  mkdir -p "$injdir"
  # Copy the two sanctioned writers so the directory has them.
  cp "$REINDEX" "$injdir/gaia-brain-reindex.sh"
  cp "$BRAIN_DIR/gaia-feed.sh" "$injdir/gaia-feed.sh"
  cat > "$injdir/rogue-writer.sh" <<'EOS'
#!/usr/bin/env bash
# A rogue third writer that reaches the manifest through a variable.
KDIR="$PROJ/.gaia/knowledge"
m="$KDIR/brain-index.yaml"
tmp="$(mktemp)"
echo "entries: []" > "$tmp"
mv "$tmp" "$m"
EOS
  local writers
  writers="$(_manifest_writer_files "$injdir")"
  # Three writers now present; the rogue one must be among them.
  [ "$(printf '%s\n' "$writers" | grep -c .)" -eq 3 ]
  printf '%s\n' "$writers" | grep -q 'rogue-writer.sh'
}

@test "a read-only manifest consumer does not trip the single-writer guard" {
  # Self-test (negative): a script that only READS the manifest path — assigns
  # it to a var and feeds it to a reader — must NOT be flagged as a writer.
  local injdir="$TEST_TMP/inj-reader"
  mkdir -p "$injdir"
  cat > "$injdir/reader-only.sh" <<'EOS'
#!/usr/bin/env bash
KDIR="$PROJ/.gaia/knowledge"
manifest="$KDIR/brain-index.yaml"
[ -f "$manifest" ] && cat "$manifest"
grep entries "$manifest" || true
EOS
  local writers
  writers="$(_manifest_writer_files "$injdir")"
  [ -z "$writers" ]
}

@test "the manifest writer uses a sibling tempfile and an atomic rename" {
  [ -f "$REINDEX" ]
  # Sibling tempfile derived from the manifest path.
  grep -qE 'mktemp[[:space:]]+"\$\{?out_manifest\}?\.tmp' "$REINDEX"
  # Atomic rename of the tempfile onto the manifest path.
  grep -qE 'mv[[:space:]]+"\$manifest_tmp"[[:space:]]+"\$out_manifest"' "$REINDEX"
}

# ---------------------------------------------------------------------------
# Read-only boundary, workflow-entry loader edition — the loader is a brain
# CONSUMER and writes nothing into the agent-sidecar memory subtree (the
# validator sidecar in particular), on EVERY exit path. Two complementary
# guards: a static one (no write-shaped op against a memory-derived variable
# anywhere in the loader source, var-indirection-aware) and a runtime one (the
# validator-sidecar tree is byte-for-byte unchanged across the loader's HALT
# and warn-continue paths).
#
# _memory_write_lines and the var-indirection analysis core are defined above
# and already cover every brain script generically; these tests PIN the loader
# specifically so a future loader change that starts touching memory turns this
# gate red on its own line, and add the runtime cross-path assertion.
# ---------------------------------------------------------------------------

@test "the workflow-entry loader carries no write-shaped op against the memory subtree" {
  [ -f "$LOADER" ]
  local hits
  hits="$(_memory_write_lines "$LOADER")"
  if [ -n "$hits" ]; then
    printf 'MEMORY WRITE in loader:\n%s\n' "$hits" >&2
  fi
  [ -z "$hits" ]
  # And no bare validator-sidecar literal anywhere in the source either.
  ! grep -qE 'validator-sidecar|\.gaia/memory|GAIA_MEMORY_DIR' "$LOADER"
}

@test "the loader writes nothing under the validator sidecar across the HALT path" {
  [ -f "$LOADER" ]
  # Build an isolated project whose index lacks a MANDATORY node -> clean HALT.
  local proj="$TEST_TMP/halt-proj"
  local know="$proj/.gaia/knowledge"
  local sidecar="$proj/.gaia/memory/validator-sidecar"
  mkdir -p "$know" "$sidecar"
  cat > "$know/brain-index.yaml" <<'EOF'
schema_version: 1
entries: []
EOF
  cat > "$know/brain-reliance-map.yaml" <<'EOF'
stages:
  "demo:entry":
    requires:
      - brain_node: "absent-node"
        obligation: MANDATORY
EOF
  # Snapshot the sidecar subtree (listing + content hash) before and after.
  local before after
  before="$(cd "$sidecar" && find . -type f -exec shasum {} \; 2>/dev/null | sort; ls -1A "$sidecar" 2>/dev/null | sort)"
  CLAUDE_PROJECT_ROOT="$proj" run bash "$LOADER" "demo:entry"
  [ "$status" -ne 0 ]                 # HALT path exercised
  after="$(cd "$sidecar" && find . -type f -exec shasum {} \; 2>/dev/null | sort; ls -1A "$sidecar" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
  # No new files appeared anywhere under the memory tree either.
  [ -z "$(find "$proj/.gaia/memory" -type f 2>/dev/null)" ]
}

@test "the loader writes nothing under the validator sidecar across the warn path" {
  [ -f "$LOADER" ]
  # An OPTIONAL miss exercises the warn-and-continue (exit 0) path.
  local proj="$TEST_TMP/warn-proj"
  local know="$proj/.gaia/knowledge"
  local sidecar="$proj/.gaia/memory/validator-sidecar"
  mkdir -p "$know" "$sidecar"
  cat > "$know/brain-index.yaml" <<'EOF'
schema_version: 1
entries: []
EOF
  cat > "$know/brain-reliance-map.yaml" <<'EOF'
stages:
  "demo:entry":
    requires:
      - brain_node: "absent-node"
        obligation: OPTIONAL
EOF
  local before after
  before="$(cd "$sidecar" && find . -type f -exec shasum {} \; 2>/dev/null | sort; ls -1A "$sidecar" 2>/dev/null | sort)"
  CLAUDE_PROJECT_ROOT="$proj" run bash "$LOADER" "demo:entry"
  [ "$status" -eq 0 ]                 # warn-continue path exercised
  after="$(cd "$sidecar" && find . -type f -exec shasum {} \; 2>/dev/null | sort; ls -1A "$sidecar" 2>/dev/null | sort)"
  [ "$before" = "$after" ]
  [ -z "$(find "$proj/.gaia/memory" -type f 2>/dev/null)" ]
}

@test "the loader-edition memory guard bites a var-indirected sidecar write (self-test)" {
  # Inject a throwaway script that reaches the validator sidecar THROUGH a
  # variable — no memory literal on the write line — and assert the same
  # analysis core that pins the loader flags it. Proves the guard bites the
  # realistic var-indirected form, not just a bare literal.
  local decoy="$TEST_TMP/decoy-sidecar-writer.sh"
  cat > "$decoy" <<'EOS'
#!/usr/bin/env bash
proj="$PROJ"
mem_root="$proj/.gaia/memory"
sidecar="$mem_root/validator-sidecar"
target="$sidecar/leak.json"
echo '{}' > "$target"
EOS
  local hits
  hits="$(_memory_write_lines "$decoy")"
  # The flagged line is the redirection into $target, which derives (via
  # $sidecar <- $mem_root <- ".gaia/memory") from the memory subtree.
  printf '%s\n' "$hits" | grep -q 'target'
}
