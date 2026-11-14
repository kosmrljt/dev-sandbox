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
- `outq` — query out.json instead of parsing it yourself: `outq info` first (counts,
  whether real names are present, entry points, which binary it belongs to), then
  `outq ls [regex]`, `outq roots`, `outq show <name> [from:to]`, `outq grep <regex>`,
  `outq strings [regex]`, `outq imports`. `outq --help` describes the JSON format.
- `contextpack.sh <bin> out.md [filter]` — same, readable, for one function.
- `decompile-dotnet.sh <asm>` (.NET→C#), `unfreeze-python.sh <app>` (frozen Python).
- `td32-import <App.exe>` — Delphi/C++Builder: real procedure names from TD32.

## Workflow (selective, recursive)

1. `file` → if native, `exportjson.sh` → `outq info`. The binary may be in
   `target/` or in the project directory; `outq target` prints its path.
   out.json is a JSON list (one object per function), not an object. If
   `outq info` reports real names, use them: Ghidra already read the symbols.
2. Pick an entry point (e.g. `main`) and follow `callees` to a chosen depth. Skip
   thunks/external stubs; do the relevant subgraph, not everything.
3. Process callees before callers: each function's summary feeds upward as
   context (recursive grounding).
4. For each function write its card `review/<name>.md` in the format of the
   /re-code skill: purpose, signature, data, a readable version of the code
   (meaningful names + comments), and a Hypotheses section.

## Write it down, in the right place

The user keeps what is in the project folder, not what was said in chat. Whenever
you work something out, save it. Never leave anything worth keeping only in /tmp
or a scratchpad: extracted tables, disassembly listings and helper scripts that
were needed for a result go to `work/`.

| What | Where | Written by |
| --- | --- | --- |
| One function: purpose, signature, data, readable code | `review/<function>.md` (card) | /re-code, the workflow above; updated by /re-explain and /re-port |
| Answer to "how does X work", with checked claims | `explain/<topic>.md` | /re-explain |
| Python version or simulation of a feature, with its test | `reimpl/` | /re-port |
| The whole program: components, runtime, data | `ARCHITECTURE.md` | /re-doc |
| Modules and functions as a map | `map/` | /re-map |
| Facts about the whole project, decisions, session log | `NOTES.md` | you and the user |
| Extracted tables, listings, one-off helper scripts | `work/` | you |

A card has two parts. `## Analysis` is yours: keep it current, mark every item
[C] or [H]. `## My notes` is the user's: never edit it, and what it says wins
over your reading. When you answer a question about a function in chat and
learned something new about it, add it to the card's Analysis.

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
What the user wrote (`## My notes` in a card, NOTES.md) wins over your own
reading. Your own earlier Analysis does not: re-check it when a new claim
depends on it.

## Native Linux targets (.so, ELF)

These can run here, so verify by running: call an exported function through
ctypes, trace with `ltrace` / `strace`, or break in `gdb`. A claim checked
against real behaviour beats one read from pseudocode.
Function names in out.json are namespace-qualified (`Class::method`).

## Skills in this project (.claude/skills)

The re-* skills are for binaries without source code (they read Ghidra's out.json).

- /re-code <function> [--depth N] - readable code and a card for a function (review/)
- /re-port <feature> - Python version or simulation of a feature, compared with the original (reimpl/)
- /re-explain <function or question> - how one part works, every claim verified (explain/)
- /re-map - interactive map of modules and functions (map/index.html)
- /re-doc - how the whole program or library is built and runs (ARCHITECTURE.md)
Other skills may be present in .claude/skills; their descriptions say when to use
them. Use a skill when the user asks for what it does; otherwise follow the
workflow above.
