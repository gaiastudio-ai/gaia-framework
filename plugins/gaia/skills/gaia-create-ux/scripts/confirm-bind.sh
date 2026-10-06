#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C; export LC_ALL

# confirm-bind.sh — structured bind-confirmation check.
# Exits 0 only when the answer equals exactly "Bind this project".

answer="${1:-}"
[ "$answer" = "Bind this project" ]
