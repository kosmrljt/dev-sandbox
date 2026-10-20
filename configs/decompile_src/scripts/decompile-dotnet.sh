#!/usr/bin/env bash
# decompile-dotnet.sh — decompile a .NET assembly (C#) with ilspycmd.
#
# Use this when `file <binary>` says the PE is a .NET assembly
# (e.g. "Mono/.Net assembly"). Works for .dll and .exe, Windows- or
# Linux-built — .NET assemblies are PE format on both.
#
# Usage:  decompile-dotnet.sh <assembly.dll|exe> [output_dir]

set -euo pipefail

ASM="${1:?usage: decompile-dotnet.sh <assembly.dll|exe> [output_dir]}"
OUT="${2:-${ASM%.*}_cs}"

if [[ ! -f "$ASM" ]]; then
    echo "No such file: $ASM" >&2
    exit 1
fi

echo "== What is this file? =="
file "$ASM" || true
echo

mkdir -p "$OUT"
echo "== Decompiling to C# with ilspycmd =="
# -p : split into one .csproj + per-type files (nicer for reading & for agents)
ilspycmd -p -o "$OUT" "$ASM"

echo
echo "== Done. C# project written to: $OUT =="
echo "Tip: open the .csproj tree, or hand a file to an agent:"
echo "  'Explain this class and what the program does; flag any obfuscated names.'"
