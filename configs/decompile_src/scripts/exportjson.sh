#!/usr/bin/env bash
# exportjson.sh — headless Ghidra (PyGhidra): export the program as structured JSON.
#
# Usage:  exportjson.sh <binary> [output.json]
# Example: exportjson.sh /work/legacy.bin /work/legacy.json
#
# Ghidra 12.x dropped Jython; Python GhidraScripts run only via PyGhidra. The
# `pyghidra` launcher imports the binary, auto-analyzes it, and runs our .py
# script against it (equivalent to the old `analyzeHeadless -import -postScript`,
# which can no longer start Python). Trailing args are passed to the script.

set -euo pipefail

BIN="${1:?usage: exportjson.sh <binary> [output.json]}"
OUT="${2:-${BIN%.*}.json}"

[[ -f "$BIN" ]] || { echo "No such file: $BIN" >&2; exit 1; }
export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR:-${GHIDRA_HOME:-/opt/ghidra}}"

echo "== Exporting program to JSON (PyGhidra headless) =="
pyghidra "$BIN" /opt/scripts/ExportJson.py "$OUT"

echo
echo "== Done: $OUT =="
echo "Next: analyze.py --in $OUT --seed main --depth 2   (needs ANTHROPIC_API_KEY)"
