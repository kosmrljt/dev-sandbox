#!/usr/bin/env bash
# exportjson.sh — headless Ghidra (PyGhidra): export one binary as structured JSON.
#
# Usage:  exportjson.sh [id|binary] [output.json]
#   id       a binary from decompile.yaml (default: its "current")
#   binary   a path; an unknown one is first added with  re init --no-export
#   output   default: out.<id>.json in the project directory
#
# Runs through ghidra-run: all binaries share one Ghidra project, ghidra-project/project.gpr,
# where each program is named after its id. A binary already there is not imported
# or analyzed again (td32-import names stay). Takes minutes the first time.
set -euo pipefail

IFS=$'\t' read -r ID BIN < <(re resolve "${1:-}")
OUT="${2:-out.$ID.json}"

# The output stays inside the project: these scripts run without a prompt
# (.claude/settings.json), so an output path outside it would let anything that
# steers the agent overwrite files elsewhere. INSIDE_OK=1 lifts the check.
case "$(realpath -m "$OUT")/" in
    "$(pwd -P)"/*) ;;
    *) [[ "${INSIDE_OK:-}" == 1 ]] || { echo "$(basename "$0"): output must be inside the project directory: $OUT" >&2; exit 1; } ;;
esac
[[ -f "$BIN" ]] || { echo "No such file: $BIN" >&2; exit 1; }

echo "== Exporting $ID ($BIN) to $OUT (PyGhidra headless) =="
ghidra-run "$ID" /opt/scripts/ExportJson.py "$(realpath -m "$OUT")"
re set "binaries.$ID.out_json" "$OUT" >/dev/null

echo
echo "== Done: $OUT =="
echo "Next: outq -b $ID info      (what is in the export; outq --help for more)"
