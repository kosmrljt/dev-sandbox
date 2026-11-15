#!/usr/bin/env bash
# unfreeze-python.sh — recover .py source from a frozen Python binary.
#
# Use it when re init says python-frozen (PyInstaller: "_MEIPASS", "python3X.dll").
#
# Usage:  unfreeze-python.sh [id|frozen_app] [output_dir]
#   default output: src/<id>/  (recorded in decompile.yaml as binaries.<id>.src)
set -euo pipefail

IFS=$'\t' read -r ID BIN < <(re resolve "${1:-}")
BIN="$(realpath "$BIN")"
WORK="$(realpath -m "${2:-src/$ID}")"
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

if [[ "$found" -eq 0 ]]; then
    echo "No .pyc files found — this may not be a frozen-Python binary."
else
    re set "binaries.$ID.src" "$(realpath --relative-to=. "$WORK")" >/dev/null
fi

echo
echo "== Done. Recovered sources under: $WORK =="
echo "Note: the app entry point is usually the .pyc matching the program name."
