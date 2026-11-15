#!/usr/bin/env bash
# decompile.sh — headless Ghidra (PyGhidra): all pseudocode of one binary in one .c
# file, for searching with other tools. In a session, `outq grep` searches the
# export instantly.
#
# Usage:  decompile.sh [id|binary] [output.c]
#   default output: work/<id>.c
set -euo pipefail

IFS=$'\t' read -r ID BIN < <(re resolve "${1:-}")
OUT="${2:-work/$ID.c}"
[[ -f "$BIN" ]] || { echo "No such file: $BIN" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

echo "== Decompiling $ID (PyGhidra headless; the first time takes a while) =="
ghidra-run "$ID" /opt/scripts/DecompileAll.py "$(realpath -m "$OUT")"
echo "== Done: $OUT =="
