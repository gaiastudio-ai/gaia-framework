# POSIX Portability

<!-- SECTION: portability-scope -->
## When Portability Matters

Scripts that run in CI on Alpine Linux, macOS, and WSL/Git Bash must avoid
Bash-specific extensions. The default shell on macOS is still Bash 3.2 (2007).
Use Bash 4+ features only when the target environment is guaranteed — and document
the requirement at the top of the file.

<!-- SECTION: bashisms-to-avoid -->
## Common Bashisms to Avoid on Bash 3.2

| Bashism | POSIX / 3.2-portable alternative |
|---|---|
| `mapfile -t arr < <(cmd)` | `while IFS= read -r line; do arr+=("$line"); done < <(cmd)` |
| `declare -A map` (associative array) | newline-delimited string + `grep -Fxq` for membership |
| `[[ ... ]]` double-bracket | `[ ... ]` single-bracket with careful quoting |
| `${var,,}` / `${var^^}` | `printf '%s' "$var" \| tr '[:upper:]' '[:lower:]'` |
| `readarray` | same as `mapfile` — use `while read` loop |
| `local -r` | `local` only (readonly on locals is not POSIX sh) |
| `<<<` herestring | `printf '%s\n' "$val" \|` piped to command |

<!-- SECTION: portable-constructs -->
## Portable Constructs

### Arithmetic
```sh
# POSIX: $((expr)) is portable; let and (()) are not
count=$((count + 1))
half=$((total / 2))
```

### String operations
```sh
# POSIX parameter expansion — no external tools needed
base="${path##*/}"          # basename
dir="${path%/*}"            # dirname
ext="${file##*.}"           # extension
no_ext="${file%.*}"         # strip extension
prefix_stripped="${var#PREFIX_}"
```

### Conditional tests
```sh
# Use [ ] with explicit -eq/-lt/-gt for numbers; = for strings
if [ "$count" -gt 0 ]; then ...
if [ "$mode" = "verbose" ]; then ...
# Check file/dir existence
if [ -f "$path" ] && [ -r "$path" ]; then ...
if [ -d "$dir" ]; then ...
```

### Command availability check
```sh
# Portable — works in sh, bash, dash
if command -v jq >/dev/null 2>&1; then
  jq . "$file"
else
  printf 'jq not found\n' >&2; exit 1
fi
```

<!-- SECTION: heredocs -->
## Heredocs

Heredocs are POSIX-portable; herestrings (`<<<`) are not:

```sh
# Portable heredoc
python3 - "$arg" <<'PY'
import sys
print(sys.argv[1])
PY

# Indented form (dash-heredoc — strips leading tabs, not spaces)
generate_config() {
  cat <<-EOF
	[section]
	key = value
	EOF
}
```

<!-- SECTION: subshell-vs-braces -->
## Subshell vs Brace Group

Use `{ }` brace groups (same shell) for output capture that must see the parent
environment without forking:

```sh
# Subshell — isolated; changes to variables are lost
(cd "$dir" && run_command)

# Brace group — same process; variable changes persist
{ read -r line; result="$line"; } < "$file"
```
