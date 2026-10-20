#!/usr/bin/env bash
# unfreeze-python.sh — recover .py source from a frozen Python binary.
#
# Use this ONLY when `file <binary>` or `strings` show it is a PyInstaller /
# py2exe / cx_Freeze app (look for "pyinstaller", "python3X.dll", "_MEIPASS").
#
# Usage: unfreeze-python.sh <frozen_app.exe|elf>

set -euo pipefail

BIN="${1:?usage: unfreeze-python.sh <frozen_app>}"
WORK="$(dirname "$BIN")/unfreeze_out"
mkdir -p "$WORK"

echo "== Extracting PyInstaller archive =="
# pyinstxtractor-ng writes a <name>_extracted/ folder with the .pyc files
( cd "$WORK" && pyinstxtractor-ng "$BIN" )

echo
echo "== Decompiling .pyc files with pycdc =="
found=0
while IFS= read -r -d '' pyc; do
    found=1
    out="${pyc%.pyc}.py"
    echo "  $pyc -> $out"
    pycdc "$pyc" > "$out" 2>/dev/null || echo "    (pycdc failed; try: pycdas \"$pyc\" for a disassembly)"
done < <(find "$WORK" -name '*.pyc' -print0)

[[ "$found" -eq 0 ]] && echo "No .pyc files found — this may not be a frozen-Python binary."

echo
echo "== Done. Recovered sources under: $WORK =="
echo "Note: the app entry point is usually the .pyc matching the program name."
