---
name: re-spec
description: For a compiled binary without source code - write a detailed description of what one feature does, without any reference to the code (no addresses, no names from the decompilation, no decompiled code), so that the user can build their own implementation from it. Use when the user asks for a specification, a functional description, or a description without references to the code or the binary - also as a follow-up to an explanation or walkthrough.
argument-hint: "<feature> [--lang sl|en]"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(outq *), Bash(re status), Bash(re get *), Bash(python3 ${CLAUDE_SKILL_DIR}/*), Bash(python3 .claude/skills/re-spec/*)
---

# /re-spec - what a feature does, described without the code

Arguments: `$ARGUMENTS` (the feature; `--lang` sets the language, default:
`settings.lang_docs` in decompile.yaml, else the language the user writes in).

Writes one file, `docs/spec/<feature-slug>.md`. A reader who has never seen the binary
should be able to implement the feature from it.

## Where the content comes from

A description is a summary of what is already known in the project: the cards in
`review/<id>/`, `docs/explain/`, `docs/ARCHITECTURE.md`, `NOTES.md`, and what was worked out in
this conversation. If the feature is not understood well enough yet, investigate
first (CLAUDE.md, How to work), record the findings in the cards, and then write.
Do not fill gaps with guesses; say what is unknown.

## How to write it

- Describe behaviour: what must happen for which input. Use rules, formulas,
  tables, step lists and diagrams in neutral notation. Do not copy or lightly
  rewrite decompiled code, and do not mirror its variables or loop order where
  the behaviour does not require it.
- Use your own clear names for fields, states and operations. No name from the
  binary or the decompiler, no addresses, no pseudocode line numbers.
- Values that are part of the behaviour belong in it, as values: constants,
  table contents, format strings, magic numbers, field offsets inside a data
  format.
- Be as detailed as an implementer needs: types, units, ranges, byte order,
  rounding, limits, what happens on bad input.
- Mark what is not proven with "(unverified)" right where it is stated.
- Where the original's behaviour looks like a defect, describe it as "observed
  behaviour" and say in one sentence what a sensible implementation might do.

Choose the sections the feature needs. Typical ones, in this order: purpose and
scope; terms; inputs and outputs; data formats; behaviour; states and sequences;
errors and edge cases; constants and tables; examples. Always end with these two:

    ## Unknown and unverified
    <what could not be established; every "(unverified)" item and what would settle it>

    Based on: <the project documents this was written from, e.g. docs/explain/003-x.md,
    review/app/y.md, docs/ARCHITECTURE.md section 4.2>

Examples (input and expected output) are worth a lot to an implementer. Take
them from the original (a run, an emulation, captured data) when that is
possible, and say so; do not compute them from your own description.

## Check

```bash
python3 ${CLAUDE_SKILL_DIR}/spec_check.py docs/spec/<feature-slug>.md
```

It only looks for things that point into the binary (addresses and names found
in the exports of all binaries, decompiler names). Fix what it reports.

## Report

One or two sentences: what the description covers and what is still unverified.
Add a line to LOG.md.
