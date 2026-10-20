#!/usr/bin/env bash
# contextpack.sh — headless Ghidra (PyGhidra): emit grounded context packs for an agent.
#
# Like decompile.sh, but each function also carries its callers, callees, and
# the strings/globals it references (with addresses + values) — so the AI
# reasons from real data-flow, not from names.
#
# Usage:  contextpack.sh <binary> [output.md] [name_filter]
# Example: contextpack.sh /work/legacy.bin /work/legacy.context.md
#          contextpack.sh /work/legacy.bin /work/one.md parse_header
#
# Ghidra 12.x dropped Jython; Python GhidraScripts run only via PyGhidra. The
# `pyghidra` launcher imports the binary, auto-analyzes it, and runs our .py
# script (replaces `analyzeHeadless -import -postScript`). Trailing args are
# passed to the script.

set -euo pipefail

BIN="${1:?usage: contextpack.sh <binary> [output.md] [name_filter]}"
OUT="${2:-${BIN%.*}.context.md}"
FILTER="${3:-}"

[[ -f "$BIN" ]] || { echo "No such file: $BIN" >&2; exit 1; }
export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR:-${GHIDRA_HOME:-/opt/ghidra}}"

echo "== Building grounded context pack (PyGhidra headless) =="
pyghidra "$BIN" /opt/scripts/ContextPack.py "$OUT" ${FILTER:+"$FILTER"}

echo
echo "== Done: $OUT =="
echo "Feed it to an agent together with AGENT_PROMPT.md as the system prompt."
