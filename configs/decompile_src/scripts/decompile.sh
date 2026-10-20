#!/usr/bin/env bash
# decompile.sh — headless Ghidra (PyGhidra): import a binary, auto-analyze, export C.
#
# Usage:  decompile.sh <binary> [output.c]
# Example: decompile.sh /work/legacy.bin /work/legacy.c
#
# Produces a single .c file containing Ghidra's decompiled pseudocode for every
# function it finds. This is the input you then hand to an AI agent to clean up.
#
# Ghidra 12.x dropped Jython; Python GhidraScripts run only via PyGhidra. The
# `pyghidra` launcher imports the binary, auto-analyzes it, and runs our .py
# script (replaces `analyzeHeadless -import -postScript`, which can't start
# Python). Trailing args are passed to the script.

set -euo pipefail

BIN="${1:?usage: decompile.sh <binary> [output.c]}"
OUT="${2:-${BIN%.*}.c}"

if [[ ! -f "$BIN" ]]; then
    echo "No such file: $BIN" >&2
    exit 1
fi
export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR:-${GHIDRA_HOME:-/opt/ghidra}}"

echo "== What is this file? =="
file "$BIN" || true
echo

echo "== Running Ghidra analysis + decompile (PyGhidra headless; can take a while) =="
pyghidra "$BIN" /opt/scripts/DecompileAll.py "$OUT"

echo
echo "== Done. Decompiled C written to: $OUT =="
echo "Tip: open it and feed it to an agent with a prompt like:"
echo "  'Rename the variables, add comments, and explain what this function does.'"
