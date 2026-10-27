#!/usr/bin/env bash
# migrate-items-to-stories.sh — shared library for the legacy items→stories
# key migration in sprint-status.yaml.
#
# Sourced by sprint-state.sh (pre-dispatch) and by standalone reader scripts
# that may be invoked independently (resolve-sprint-stories.sh, etc.).
#
# Exports:
#   migrate_items_to_stories <yaml> [--lock <lockfile>]
#   read_stories_or_items    <yaml>

# Guard against double-sourcing.
[ -z "${_GAIA_MIGRATE_ITEMS_LOADED:-}" ] || return 0
_GAIA_MIGRATE_ITEMS_LOADED=1

# ---------------------------------------------------------------------------
# migrate_items_to_stories <yaml_file> [--lock <lockfile>]
#
# When the file has a populated `items:` block, merge its entries into
# `stories:` (stories wins on duplicate key), remove the `items:` block, and
# write atomically via tmpfile+mv.
#
# --lock <lockfile>: acquire the sprint-status lock (fd 9, 5 s timeout)
#   before writing and release it after. The caller MUST have already sourced
#   acquire-lock.sh (sprint-state.sh does; standalone callers can source it
#   themselves). Fail closed (non-zero, clear message) if the lock times out.
#
# Without --lock: migrate without locking. Use ONLY when the caller already
#   holds the lock or when the file is guaranteed not to be written concurrently.
#
# Fast path: returns 0 (no write, no lock) when `items:` is absent or is the
#   empty `items: []` form.
#
# Idempotent. Preserves file mode. Fails closed on awk error.
# ---------------------------------------------------------------------------
migrate_items_to_stories() {
  local yaml="$1"; shift
  local lockfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lock) lockfile="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  [ -f "$yaml" ] || return 0

  # Fast path: no items: key at all.
  grep -q '^items[[:space:]]*:' "$yaml" 2>/dev/null || return 0

  # Fast path: items: [] (empty list) — no entries to lose.
  if grep -q '^items:[[:space:]]*\[\][[:space:]]*$' "$yaml" 2>/dev/null; then
    return 0
  fi

  # --- Populated items: block found — migrate under lock if requested. ---
  if [ -n "$lockfile" ]; then
    (
      if ! acquire_lock "$lockfile" 5 9; then
        printf 'migrate-items-to-stories: error: lock timeout on %s (fail-closed)\n' \
          "$lockfile" >&2
        exit 1
      fi
      trap 'release_lock 9 2>/dev/null || true' EXIT
      _gaia_do_migrate_items "$yaml"
    )
  else
    _gaia_do_migrate_items "$yaml"
  fi
}

# ---------------------------------------------------------------------------
# _gaia_do_migrate_items <yaml>  (internal — the actual awk rewrite)
# ---------------------------------------------------------------------------
_gaia_do_migrate_items() {
  local yaml="$1"
  [ -f "$yaml" ] || return 0

  # Re-check inside the lock (another process may have migrated).
  grep -q '^items[[:space:]]*:' "$yaml" 2>/dev/null || return 0
  if grep -q '^items:[[:space:]]*\[\][[:space:]]*$' "$yaml" 2>/dev/null; then
    return 0
  fi

  # Capture source mode for chmod after mv.
  local src_mode
  if stat -c %a / >/dev/null 2>&1; then
    src_mode="$(stat -c %a "$yaml")"
  else
    src_mode="$(stat -f %Lp "$yaml")"
  fi

  local tmp_mig
  tmp_mig="$(mktemp "${yaml}.mig.XXXXXX")"
  awk '
    BEGIN {
      in_items = 0; in_stories = 0
      items_count = 0; stories_count = 0
      other_count = 0; saw_stories = 0; saw_items = 0
    }
    /^items[[:space:]]*:[[:space:]]*$/ {
      in_items = 1; in_stories = 0; saw_items = 1; next
    }
    /^stories[[:space:]]*:[[:space:]]*$/ {
      in_stories = 1; in_items = 0; saw_stories = 1; next
    }
    /^stories[[:space:]]*:[[:space:]]*\[\][[:space:]]*$/ {
      in_items = 0; saw_stories = 1; next
    }
    /^[A-Za-z_]/ {
      in_items = 0; in_stories = 0
    }
    in_items {
      items_lines[items_count++] = $0
      if ($0 ~ /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/) {
        k = $0
        sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", k)
        gsub(/["'"'"'[:space:]]/, "", k)
        items_keys[k] = 1
      }
      next
    }
    in_stories {
      stories_lines[stories_count++] = $0
      if ($0 ~ /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/) {
        k = $0
        sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", k)
        gsub(/["'"'"'[:space:]]/, "", k)
        stories_keys[k] = 1
      }
      next
    }
    {
      other[other_count++] = $0
    }
    END {
      for (i = 0; i < other_count; i++) {
        print other[i]
      }
      if (stories_count > 0 || items_count > 0) {
        print "stories:"
        for (i = 0; i < stories_count; i++) {
          print stories_lines[i]
        }
        cur_key = ""
        skip = 0
        for (i = 0; i < items_count; i++) {
          ln = items_lines[i]
          if (ln ~ /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/) {
            cur_key = ln
            sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", cur_key)
            gsub(/["'"'"'[:space:]]/, "", cur_key)
            skip = (cur_key in stories_keys) ? 1 : 0
          }
          if (!skip) print ln
        }
      }
    }
  ' "$yaml" > "$tmp_mig" || {
    rm -f "$tmp_mig"
    printf 'migrate-items-to-stories: error: awk failed on %s (fail-closed)\n' \
      "$yaml" >&2
    return 1
  }
  chmod "$src_mode" "$tmp_mig" 2>/dev/null || true
  mv "$tmp_mig" "$yaml"
}

# ---------------------------------------------------------------------------
# read_stories_or_items <yaml>
#
# Read-only helper: emit key<TAB>status lines with union-by-key semantics.
# Reads BOTH `stories:` and `items:` blocks. When a key appears in both,
# the `stories:` entry wins. Items-only keys are included. No duplicates.
# Key order: stories entries first (in file order), then items-only entries.
# Never writes the file.
# ---------------------------------------------------------------------------
read_stories_or_items() {
  local yaml="$1"
  [ -f "$yaml" ] || return 0
  awk '
    /^stories[[:space:]]*:[[:space:]]*$/ { in_s = 1; in_i = 0; next }
    /^items[[:space:]]*:[[:space:]]*$/ { in_i = 1; in_s = 0; next }
    /^stories[[:space:]]*:[[:space:]]*\[\]/ { in_s = 0; next }
    /^items[[:space:]]*:[[:space:]]*\[\]/ { in_i = 0; next }
    (in_s || in_i) && /^[A-Za-z_]/ { in_s = 0; in_i = 0 }
    in_s && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      k = $0; sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", k)
      gsub(/["'"'"'[:space:]]/, "", k); s_key[k] = 1; s_order[s_n++] = k; next
    }
    in_s && /^[[:space:]]+status:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/["'"'"'[:space:]]/, "", v); s_status[s_order[s_n-1]] = v; next
    }
    in_i && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      k = $0; sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", k)
      gsub(/["'"'"'[:space:]]/, "", k); i_order[i_n++] = k; next
    }
    in_i && /^[[:space:]]+status:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+status:[[:space:]]*/, "", v)
      gsub(/["'"'"'[:space:]]/, "", v); i_status[i_order[i_n-1]] = v; next
    }
    END {
      # Emit stories entries first.
      for (j = 0; j < s_n; j++) {
        printf "%s\t%s\n", s_order[j], s_status[s_order[j]]
        seen[s_order[j]] = 1
      }
      # Emit items-only entries (not already in stories).
      for (j = 0; j < i_n; j++) {
        if (!(i_order[j] in seen))
          printf "%s\t%s\n", i_order[j], i_status[i_order[j]]
      }
    }
  ' "$yaml"
}

# ---------------------------------------------------------------------------
# read_stories_or_items_points <yaml>
#
# Like read_stories_or_items but emits key<TAB>points (for throughput).
# Same union-by-key semantics.
# ---------------------------------------------------------------------------
read_stories_or_items_points() {
  local yaml="$1"
  [ -f "$yaml" ] || return 0
  awk '
    /^stories[[:space:]]*:[[:space:]]*$/ { in_s = 1; in_i = 0; next }
    /^items[[:space:]]*:[[:space:]]*$/ { in_i = 1; in_s = 0; next }
    /^stories[[:space:]]*:[[:space:]]*\[\]/ { in_s = 0; next }
    /^items[[:space:]]*:[[:space:]]*\[\]/ { in_i = 0; next }
    (in_s || in_i) && /^[A-Za-z_]/ { in_s = 0; in_i = 0 }
    in_s && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      k = $0; sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", k)
      gsub(/["'"'"'[:space:]]/, "", k); s_key[k] = 1; s_order[s_n++] = k; next
    }
    in_s && /^[[:space:]]+points:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+points:[[:space:]]*/, "", v)
      gsub(/[^0-9].*$/, "", v); s_pts[s_order[s_n-1]] = v; next
    }
    in_i && /^[[:space:]]+-[[:space:]]+key:[[:space:]]*/ {
      k = $0; sub(/^[[:space:]]+-[[:space:]]+key:[[:space:]]*/, "", k)
      gsub(/["'"'"'[:space:]]/, "", k); i_order[i_n++] = k; next
    }
    in_i && /^[[:space:]]+points:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+points:[[:space:]]*/, "", v)
      gsub(/[^0-9].*$/, "", v); i_pts[i_order[i_n-1]] = v; next
    }
    END {
      for (j = 0; j < s_n; j++) {
        if (s_order[j] != "" && s_pts[s_order[j]] != "")
          printf "%s\t%s\n", s_order[j], s_pts[s_order[j]]
        seen[s_order[j]] = 1
      }
      for (j = 0; j < i_n; j++) {
        if (!(i_order[j] in seen) && i_order[j] != "" && i_pts[i_order[j]] != "")
          printf "%s\t%s\n", i_order[j], i_pts[i_order[j]]
      }
    }
  ' "$yaml"
}
