# Bash Patterns & Script Structure

<!-- SECTION: safety-header -->
## Safety Header

Every script starts with the safety triple and locale pin:

```bash
#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C
export LC_ALL
```

- `set -e` — exit on any unchecked error
- `set -u` — treat unset variables as errors
- `set -o pipefail` — pipeline exit code reflects the first failure, not the last command
- `LC_ALL=C` — deterministic sort/collation in CI across all platforms

<!-- SECTION: quoting -->
## Variable Quoting

Quote every expansion — unquoted expansions split on whitespace and glob-expand:

```bash
# BAD: word-splitting and glob expansion hazards
cp $src $dst
for f in $files; do rm $f; done

# GOOD: always quoted
cp "$src" "$dst"
for f in "${files[@]}"; do rm "$f"; done
```

Use `${var:-default}` for safe defaulting without triggering `set -u`:

```bash
LOG_LEVEL="${LOG_LEVEL:-info}"
OUT_DIR="${OUTPUT_DIR:-/tmp/build}"
```

<!-- SECTION: arrays -->
## Arrays

Bash arrays handle paths with spaces correctly; avoid IFS-split strings for lists:

```bash
# Collect paths into an array
files=()
while IFS= read -r line; do
  files+=("$line")
done < <(find . -name '*.sh' -type f | sort)

# Iterate safely
for f in "${files[@]}"; do
  shellcheck "$f"
done

# Length check
if [ "${#files[@]}" -eq 0 ]; then
  echo "no scripts found" >&2
  exit 1
fi
```

<!-- SECTION: traps -->
## Traps & Cleanup

Use `trap` to guarantee cleanup even on error or interrupt:

```bash
TMP_DIR=""

_cleanup() {
  [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap _cleanup EXIT

TMP_DIR="$(mktemp -d)"
# ... work with TMP_DIR ...
```

Chain signals when both interrupt and error cleanup are needed:

```bash
trap '_cleanup; exit 130' INT TERM
trap '_cleanup'            EXIT
```

<!-- SECTION: functions -->
## Function Conventions

- One function, one responsibility — independently testable
- Prefix internal helpers with `_` to signal private scope
- Use `local` for every variable declared inside a function

```bash
_log() {
  local level="$1"; shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

_die() {
  local rc="$1"; shift
  _log ERROR "$*"
  exit "$rc"
}

parse_args() {
  local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --verbose) VERBOSE=1 ;;
      --output)  [ "$#" -ge 1 ] || _die 1 "--output requires a value"; OUTPUT="$1"; shift ;;
      *)         _die 1 "unknown argument: $arg" ;;
    esac
  done
}
```
