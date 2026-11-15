# Reverse-engineering project

Goal: help the user understand a compiled program without source code, to the
depth their purpose needs.

## Start of a session

1. Read decompile.yaml (its comments explain each key), NOTES.md and the last
   entries of LOG.md. If plan/ exists, read plan.md of the last phase (highest
   number) and say in one line where the research stands; for anything about
   the plan use /re-plan.
2. If decompile.yaml is missing, ask for the binary and run `re init <path>`.

## Project layout

| Path | What | Who writes |
| --- | --- | --- |
| decompile.yaml | binaries (path, type, export), which one is `current`, settings | scripts (binaries); the user; you only after asking |
| out.<id>.json | export of one binary; read it only with outq | exportjson.sh |
| ghidra/ | the one Ghidra project, ghidra/project.gpr; each binary is a program named by its id | scripts, Ghidra |
| src/<id>/ | recovered source (.NET, Python) | decompile-dotnet.sh, unfreeze-python.sh |
| work/ | scripts, extracted tables, captured runs (CSV, Parquet); never only /tmp | you |
| tools/queries.sql | this project's saved DuckDB queries | you, with approval |
| NOTES.md | the user's purpose, knowledge and agreements on scope | the user; you only after asking |
| LOG.md | a few lines per session: what was looked at, which cards, what is open | you |
| review/<id>/ | one card per function of that binary (source of truth) | you; "My notes" = user |
| plan/NN-<phase>/ | research plan, only when the user wants one | /re-plan |
| docs/ | results: ARCHITECTURE.md, map/, explain/, spec/, walkthrough/ | skills, you |

Three kinds of files: research data (decompile.yaml, exports, ghidra/, src/,
work/, tools/), working knowledge (NOTES.md, LOG.md, review/, plan/) and
results (docs/). Knowledge lives in review/; docs/ is derived from it and never
holds the only copy of a finding.

## Ask before you change these

Ask in the conversation and wait for the answer before you change NOTES.md, a
setting, `current` or a binary's `type` in decompile.yaml, the goal or the tasks
of a plan, or tools/queries.sql. An approval prompt from Claude Code does not
replace the question: it may not appear. Cards, LOG.md, work/ and task detail
files you write without asking.

## Environment

- Binaries can be anywhere; decompile.yaml has the paths. Always name the
  binary explicitly in commands (`outq -b app ...`, `exportjson.sh app`).
  `current` is for the user and for the program open in Ghidra.
- `re status` shows binaries, settings and next steps; `re get <key>` reads one
  value; `re use` and `re set` change them (see "Ask before you change these").
- Settings (empty = default): `lang_docs` and `lang_walkthrough` (language of
  files; default: the language the user writes in), `ghidra_live` (use the
  Ghidra MCP server; default false).
- outq is instant: use it for all reading: `info`, `roots`, `ls [regex]`,
  `show NAME [A:B]` (first 150 lines unless a range is given), `grep`,
  `strings`, `imports`. Never load an export whole.
- Anything else: `outq sql "<query>"` (DuckDB, read-only: SELECT and EXPLAIN;
  files only under work/) with the tables functions, calls (bin, src, dst) and
  strings (bin, function, addr, value), over all binaries. A query likely needed again goes into tools/queries.sql as a macro
  with a comment and a line `-- Example: ...`, then `outq selftest`. Do not
  write your own parsers of the exports.
- Exporting (`exportjson.sh <id>`, `re init`) takes minutes. Scripts cannot
  open ghidra/project.gpr while the Ghidra window has it open; they say so.
- With `ghidra_live`: read names and current code from Ghidra; the export does
  not see changes made there. Re-export only when you need the export to
  reflect them (outq sql, a skill over many functions): ask the user to close
  the project in Ghidra, run `exportjson.sh <id>`, and reopen it.

## Binary types

| type | Path |
| --- | --- |
| native-elf, native-pe | export + outq; everything below applies |
| delphi | as native; read .claude/kb/delphi.md first |
| dotnet, python-frozen | recovered source in src/<id>/; cite file:line instead of addresses |
| packed, installer | unpack first (on a copy), then `re init` the result |

## Evidence (non-negotiable)

- Reason from pseudocode and data, never from names. FUN_*, uVar1, undefined4
  mean nothing.
- Names are not evidence, whatever their source:
  - names you or the user gave in Ghidra are earlier hypotheses; check the
    code again before building on them,
  - names from debug info (TD32, PDB, symbols) are the author's names: they
    identify a function, but what it does still comes from the code.
- Every claim about behaviour cites an address (or file:line). No evidence,
  no claim.
- Read constants from their values (`DAT_* = 500` is a limit); recognise
  known magics (`0x5A4D` = "MZ"), verify the rest.
- Mark [C] confirmed (evidence you cite, or the user's notes) or [H]
  hypothesis. Guesses from names or strings go under "Hypotheses (unverified)".
- What the user wrote (NOTES.md, "My notes") wins over your reading. Your own
  earlier Analysis does not: re-check it when a new claim depends on it.
- Say so when you find something the user needs to know: a wrong assumption,
  a contradiction with NOTES.md or with an earlier card.
- The strongest check is behaviour (running, ctypes, strace, gdb, emulation).
  Propose it when it would settle a question; run only with approval.

## How to work

1. Purpose: if NOTES.md has none and the answer would change how you work,
   ask once. Otherwise start.
2. Top-down: what the binary offers to the outside (`outq -b <id> roots`),
   then the components, then functions. Callees before callers. Only what the
   question needs; skip thunks and library code.
3. Answer in the chat, concretely, with addresses. Ask when an answer would
   change what you do; one or two questions at a time.
4. At the end: update cards for functions where you found something with
   evidence, and write what is only likely as [H]; all at once, named in one
   line. Add a few lines to LOG.md (date, what, cards, open; the plan task, e.g.
   02/B, when the work was for one).

Card review/<id>/<name>.md (characters other than letters, digits, . _ -
replaced by _):

    # <full name> @ 0x<address>
    ## Analysis      (yours; keep current, mark [C] / [H])
    ## My notes      (the user's; never edit)

## Ghidra (only with ghidra_live)

Rename, retype or create structures only when the user asks or agrees, one
task at a time (e.g. "clean up the header parser"); say first what you will
change. Changes in Ghidra always ask for approval.

## Skills

Default is an answer in the chat. Use a skill only when the user wants a
document, a map, a verification, a walkthrough, a specification or a plan:
/re-doc, /re-map, /re-explain, /re-walkthrough, /re-spec, /re-plan. When a
lasting document would clearly help, offer it in one line.
