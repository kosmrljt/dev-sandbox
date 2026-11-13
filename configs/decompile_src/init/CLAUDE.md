# Reverse-engineering project — rules for Claude Code

Goal: turn an old binary into readable, commented code. Work selectively, not on
every function.

## Grounding (non-negotiable)

- Reason from pseudocode and evidence (signature, callers, callees, referenced
  strings/data with addresses and values) — never from names. `FUN_*`, `uVar1`,
  `undefined4` are automatic and meaningless.
- Back every claim about behavior with an address/line. No evidence → no claim.
- Read constants from values (`DAT_* = 500` → a limit); recognise known magics
  (`0x5A4D` = "MZ"), verify the rest.
- Keep guesses from names/strings in a separate "Hypotheses (unverified)" section.

## Tools (run via Bash)

- `file <bin>` — identify first (native ELF/PE, .NET, frozen Python, Delphi/TD32).
- `exportjson.sh <bin> out.json` — machine-readable export of all functions
  (signature, call graph, strings/data with addresses, pseudocode). Main source.
- `contextpack.sh <bin> out.md [filter]` — same, readable, for one function.
- `decompile-dotnet.sh <asm>` (.NET→C#), `unfreeze-python.sh <app>` (frozen Python).
- `td32-import <App.exe>` — Delphi/C++Builder: real procedure names from TD32.

## Workflow (selective, recursive)

1. `file` → if native, `exportjson.sh` → read the JSON.
2. Pick an entry point (e.g. `main`) and follow `callees` to a chosen depth. Skip
   thunks/external stubs; do the relevant subgraph, not everything.
3. Process callees before callers: each function's summary feeds upward as
   context (recursive grounding).
4. For each function write `review/<name>.md`: a summary with references, a
   readable pseudocode version (meaningful names + comments), type/struct guesses
   from offset patterns, and a Hypotheses section.

## Live loop (if GhidraMCP tools are available)

With the `ghidra` MCP server, don't just describe — improve the decompilation:
rename variables/functions, set prototypes, **create and apply structs/types**
(`create_struct`, `add_struct_field`, `apply_data_type`, `set_function_prototype`),
then RE-DECOMPILE and read the cleaner output. Repeat until `uVar`/`undefined` are
gone. Query xrefs/memory before each claim. Reads run automatically; changes are
prompted (`.claude/settings.json`).

## Status of claims

Mark every claim [C] confirmed (evidence you cite, or the user's notes) or
[H] hypothesis. "Hypotheses (unverified)" sections hold the [H] items.
The user's notes in review/ win over your own reading.


## Skills in this project (.claude/skills)

The re-* skills are for binaries without source code (they read Ghidra's out.json).

- /re-explain <function or question> - how one part works, every claim verified (explain/)
- /re-map - interactive map of modules and functions (map/index.html)
- /re-doc - how the whole program or library is built and runs (ARCHITECTURE.md)
Other skills may be present in .claude/skills; their descriptions say when to use
them. Use a skill when the user asks for what it does; otherwise follow the
workflow above.
