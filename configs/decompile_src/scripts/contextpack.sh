#!/usr/bin/env bash
# contextpack.sh — headless Ghidra (PyGhidra): one function (or a group) as a
# readable Markdown file with callers, callees, strings and data. For reading in
# a session, `outq show` gives the same instantly; use this for a file to keep.
#
# Usage:  contextpack.sh [id|binary] [output.md] [name_filter]
#   default output: work/<id>.context.md
set -euo pipefail

IFS=$'\t' read -r ID BIN < <(re resolve "${1:-}")
OUT="${2:-work/$ID.context.md}"
FILTER="${3:-}"

# The output stays inside the project: these scripts run without a prompt
# (.claude/settings.json), so an output path outside it would let anything that
# steers the agent overwrite files elsewhere. INSIDE_OK=1 lifts the check.
case "$(realpath -m "$OUT")/" in
    "$(pwd -P)"/*) ;;
    *) [[ "${INSIDE_OK:-}" == 1 ]] || { echo "$(basename "$0"): output must be inside the project directory: $OUT" >&2; exit 1; } ;;
esac
[[ -f "$BIN" ]] || { echo "No such file: $BIN" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

echo "== Context pack for $ID (PyGhidra headless) =="
ghidra-run "$ID" /opt/scripts/ContextPack.py "$(realpath -m "$OUT")" ${FILTER:+"$FILTER"}
echo "== Done: $OUT =="
