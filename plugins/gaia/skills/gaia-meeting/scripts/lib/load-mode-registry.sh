#!/usr/bin/env bash
# load-mode-registry.sh — gaia-meeting mode registry loader
#
# Sourced by callers; provides three functions over a yq-free YAML shape:
#
#   mode_registry_path
#   mode_registry_canonical <mode-or-alias>      -> stdout: canonical name (or empty)
#   mode_registry_field <canonical-mode> <field> -> stdout: scalar field value
#   mode_registry_list_field <canonical-mode> <list-field>
#                                                 -> stdout: one item per line
#
# Supported list fields: `aliases`, `default_invitees`.
# Supported scalar fields: `closing_artifact_bias`, `notes_template_ref`.

# shellcheck disable=SC2034

mode_registry_path() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "$script_dir/../../knowledge/modes.yaml"
}

# Internal: extract the per-mode block from `- name: <mode>` (inclusive) up to
# the next `- name:` line (exclusive). Mode names are matched literally.
_mode_block() {
  local file="$1" mode="$2"
  awk -v m="$mode" '
    BEGIN { in_block = 0 }
    /^  - name:[[:space:]]*/ {
      sub(/^  - name:[[:space:]]*/, "")
      if ($0 == m) {
        in_block = 1
        print "  - name: " $0
        next
      } else if (in_block) {
        in_block = 0
      }
    }
    in_block { print }
  ' "$file"
}

mode_registry_canonical() {
  local query="$1"
  local file
  file="$(mode_registry_path)"
  [[ -f "$file" ]] || { echo "" ; return 1 ; }

  # First: direct name match.
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "$query" ]]; then
      echo "$name"
      return 0
    fi
  done < <(awk -F': *' '/^  - name:/ { print $2 }' "$file")

  # Second: alias match — scan each mode block's aliases list.
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local block aliases
    block="$(_mode_block "$file" "$name")"
    aliases="$(awk '
      /^    aliases:[[:space:]]*\[/ {
        line = $0
        sub(/^.*\[/, "", line)
        sub(/\].*$/, "", line)
        gsub(/[[:space:]]/, "", line)
        n = split(line, parts, ",")
        for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
      }
    ' <<< "$block")"
    while IFS= read -r alias; do
      [[ -z "$alias" ]] && continue
      if [[ "$alias" == "$query" ]]; then
        echo "$name"
        return 0
      fi
    done <<< "$aliases"
  done < <(awk -F': *' '/^  - name:/ { print $2 }' "$file")

  echo ""
  return 1
}

mode_registry_field() {
  local mode="$1" field="$2"
  local file block
  file="$(mode_registry_path)"
  block="$(_mode_block "$file" "$mode")"
  awk -v f="$field" -F': *' '
    $0 ~ ("^    " f ":") { sub("^    " f ":[[:space:]]*", ""); print; exit }
  ' <<< "$block"
}

mode_registry_list_field() {
  local mode="$1" field="$2"
  local file block
  file="$(mode_registry_path)"
  block="$(_mode_block "$file" "$mode")"
  awk -v f="$field" '
    $0 ~ ("^    " f ":[[:space:]]*\\[") {
      line = $0
      sub(/^.*\[/, "", line)
      sub(/\].*$/, "", line)
      gsub(/[[:space:]]/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
      exit
    }
  ' <<< "$block"
}

mode_registry_known_modes() {
  local file
  file="$(mode_registry_path)"
  awk -F': *' '/^  - name:/ { print $2 }' "$file"
}
