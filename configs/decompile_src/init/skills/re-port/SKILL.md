---
name: re-port
description: For a compiled binary without source code - write a Python version of one feature or function of the analyzed program (a re-implementation, or a simulation of its output or behaviour), save it under reimpl/, and compare it with the original wherever the original can be run or emulated. Use when the user asks for a Python version, a port, a re-implementation, a simulation or emulation of what the program does, or a script that reproduces its output or file format.
argument-hint: "<feature or function> [--lang sl|en]"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(outq *), Bash(contextpack.sh *), Bash(rabin2 *), Bash(readelf *), Bash(objdump *), Bash(file *)
---

# /re-port - a Python version of a feature, kept in reimpl/

Arguments: `$ARGUMENTS` (the feature, e.g. "the process list row", "the checksum",
"reading the config file"; `--lang` sets the language of comments and notes).

Two kinds of result; say which one you are making:
- **re-implementation**: the same computation as the original (an algorithm, a
  parser, a formatter). It can be compared value by value.
- **simulation**: reproduces what the user would see or what goes over an
  interface (screen output, a file, a reply), possibly with made-up input data.

## Step 1 - Scope and sources

- State the feature as one sentence and list the functions it covers
  (`outq show`, `outq grep`, `outq strings`).
- Read the cards in `review/` and anything in `explain/` for those functions and
  build on them. Missing understanding of a function: do `/re-code` for it first,
  or say what is still unknown.
- Constants, tables and format strings come from the binary's bytes, not from
  memory. Put larger tables in `reimpl/data/`.

## Step 2 - Write reimpl/<feature_slug>.py

One runnable file per feature, standard library only unless the user agrees to
more (numpy is available). Start it with this header:

```python
"""<Feature> - Python <re-implementation | simulation> of <binary>.

Reproduces:  <what, in one or two sentences>
Based on:    <function> @ 0x<address>, ... ; review/<card>.md, explain/<file>.md
Faithful:    <what follows the original exactly>
Simplified:  <what was left out or approximated, and why>
Unverified:  <parts written from hypotheses [H]>
Run:         python3 reimpl/<feature_slug>.py [args]
"""
```

In the code, name things as in the cards, and mark each non-obvious step with
the address or pseudocode line it comes from (`# 0x112e8a / L67-73`). A part that
rests on a hypothesis gets a `# [H]` comment. Give it a small `main()` with a
demo so that running the file shows something.

## Step 3 - Compare with the original

Pick the strongest comparison that is possible and write it as
`reimpl/test_<feature_slug>.py` (plain asserts, runnable with `python3`):

| Situation | Comparison |
| --- | --- |
| Native Linux program that only reads and prints | run it with harmless options and compare output; ask the user before the first run of the analyzed program |
| Function in a native shared library, pure computation | call the original through ctypes on many inputs and compare |
| Other architecture or not runnable here | emulate the function (Unicorn, or Ghidra's emulator) on chosen inputs |
| Files the program reads or writes | parse or produce a real sample and compare byte for byte |
| Nothing can run and no samples exist | say so; the port stays unverified |

Never run the analyzed program with options that change the system (kill, write,
install, network) and never as root. Output that depends on time or live system
state is compared by structure (columns, widths, formats), not byte for byte;
say so in the test.

Run the test. A mismatch is a finding: fix the port or correct the card it was
based on, and record the correction.

## Step 4 - Keep the records straight

- `reimpl/README.md`: one row per file - feature, kind, functions covered,
  comparison used, result (matches / matches by structure / unverified), date.
- If the work proved or refuted something, update `## Analysis` in the affected
  `review/` cards (never `## My notes`).

## Step 5 - Report

What the file reproduces, how it was compared and with what result, what is
simplified or unverified, and how to run it.
