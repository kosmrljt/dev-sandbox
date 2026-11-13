---
name: re-map
description: For a compiled binary without source code (Ghidra out.json) - build or refresh an interactive architecture map (map/index.html) of the binary being analyzed - modules, external resources, data flows, each marked confirmed or hypothesis with evidence. Use when the user asks for the program's architecture, structure, overview, module map or call graph.
argument-hint: "[binary] [--refresh]"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(exportjson.sh *), Bash(python3 ${CLAUDE_SKILL_DIR}/*), Bash(ls *), Bash(file *)
---

# /re-map - architecture map of the analyzed binary

Arguments: `$ARGUMENTS` (optional binary path; `--refresh` = keep existing modules,
only update them from new notes in review/).

The page is built by a fixed script. Your only job is to write `map/modules.json`
exactly in the schema below, grounded in evidence. Never write the HTML yourself.

## Step 1 - Facts

1. If `out.json` is missing or older than the binary, run
   `exportjson.sh <binary> out.json` (binary = argument, else the only executable
   in `target/`; if unsure, ask).
2. Read `out.json` with `jq` or a short script, not by loading it whole: list function count,
   entry points (`entry`, `main`, `WinMain`, exports), and per function the number
   of callers, callees and strings.
3. Read every file in `review/`. The user's notes win over your own reading.

## Step 2 - Decide what to leave out

Skip thunks, externals, and library/runtime code. Treat a function as library when
it has many callers, no program-specific strings, and a known runtime shape
(string/memory helpers, CRT start-up, Delphi `System`/`SysUtils` units, `__vba*`).
Record every skipped group in `skipped` with the pattern and the reason.

## Step 3 - Modules

Group the remaining functions into 3 to 12 modules. Use evidence in this order:

1. Real names: namespaces from TD32 (`Unit::Class::Method`), exports, RTTI.
2. Shared program strings and imports: file I/O, registry, network, UI, drawing.
3. Call-graph clusters: functions mostly calling each other and called from one place.

Rules:
- Each function belongs to at most one module. Leave a function out rather than guess.
- `status: "confirmed"` only if the grouping is backed by real names, by review/ notes,
  or by xrefs you can cite. Everything else is `"hypothesis"`.
- `evidence` lists concrete items: `"0x00401a30: references \"scores.dat\""`,
  `"TD32 namespace Unit1::TMainForm"`, `"review/save_scores.md"`. No evidence = no module.
- `name` says what the module does in 1 to 4 words; `summary` is one sentence.
  Do not take names from a single string.

## Step 4 - Resources and flows

- `resources`: things outside the program it touches - files, registry keys, hosts,
  dialogs/windows, devices. `kind` is one of `file`, `registry`, `network`, `ui`,
  `device`, `other`. Name them by their real value (`scores.dat`, `HKCU\Software\X`).
- `flows`: arrows module -> resource or module -> module that carry data, with a short
  verb label (`reads`, `writes`, `sends`, `draws`). Each has an address as evidence.

## Step 5 - Next steps

`next`: the 5 functions whose analysis would most improve the map (unplaced
functions called by several modules, hypothesis modules with one strong lead).

## Schema of map/modules.json

```json
{
  "program": "GAME.EXE",
  "modules": [
    {
      "id": "persist",
      "name": "Score storage",
      "summary": "Loads and saves the high-score table.",
      "status": "confirmed",
      "functions": ["FUN_00402210", "FUN_00401a30"],
      "evidence": ["0x00402210: opens \"scores.dat\" with CreateFileA", "review/save_scores.md"]
    }
  ],
  "resources": [
    {"id": "scores_dat", "kind": "file", "name": "scores.dat",
     "evidence": ["string at 0x0040c120"]}
  ],
  "flows": [
    {"from": "persist", "to": "scores_dat", "label": "writes", "status": "confirmed",
     "evidence": "WriteFile call at 0x00402238"}
  ],
  "skipped": [
    {"pattern": "Delphi System unit (@LStr*, @Halt*)", "reason": "runtime library, 210 callers"}
  ],
  "next": [
    {"function": "FUN_00403000", "why": "called by 3 modules, no strings; likely shared parser"}
  ]
}
```

`id` values: lowercase letters, digits and `_`, unique across modules and resources.
Function names must match the `name` field of `out.json` exactly (it is
namespace-qualified, e.g. `Unit1::TMainForm::FormCreate`).

## Step 6 - Build and check

```bash
python3 ${CLAUDE_SKILL_DIR}/archmap.py --check     # validates against out.json
python3 ${CLAUDE_SKILL_DIR}/archmap.py               # writes map/index.html
```

Fix every problem `--check` reports and run it again. Do not edit `archmap.py`.

## Step 7 - Report (short)

- Modules: how many confirmed, how many hypothesis.
- Functions placed / not placed / skipped.
- The 5 `next` functions, one line each.
- Tell the user to open `map/index.html` on the host (the project folder is mounted).

With `--refresh`: read the existing `map/modules.json`, change only what new review/
notes or new evidence justify, and list each change (module, old -> new, evidence).
