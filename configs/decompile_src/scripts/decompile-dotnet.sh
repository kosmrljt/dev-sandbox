#!/usr/bin/env bash
# decompile-dotnet.sh — decompile a .NET assembly (C#) with ilspycmd.
#
# Use it when re init (or `file`) says the binary is a .NET assembly. Works for
# .dll and .exe, Windows- or Linux-built.
#
# Usage:  decompile-dotnet.sh [id|assembly] [output_dir]
#   default output: src/<id>/  (recorded in decompile.yaml as binaries.<id>.src)
set -euo pipefail

IFS=$'\t' read -r ID ASM < <(re resolve "${1:-}")
OUT="${2:-src/$ID}"
[[ -f "$ASM" ]] || { echo "No such file: $ASM" >&2; exit 1; }

echo "== What is this file? =="
file "$ASM" || true
mkdir -p "$OUT"
echo "== Decompiling to C# with ilspycmd =="
# -p : one .csproj + one file per type (easier to read and to search)
ilspycmd -p -o "$OUT" "$ASM"
re set "binaries.$ID.src" "$OUT" >/dev/null

echo
echo "== Done. C# project written to: $OUT =="
