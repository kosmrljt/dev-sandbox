---
name: re-code
description: For a compiled binary without source code - turn one function (and optionally its callees) into readable, commented code with meaningful names, types and structures, and save it as a function card in review/. Use when the user asks to decompile, clean up, rewrite readably, annotate or document a function, or to analyze a function and its callees.
argument-hint: "<function | address> [--depth N] [--lang sl|en]"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(outq *), Bash(contextpack.sh *), Bash(rabin2 *), Bash(readelf *), Bash(objdump *), Bash(file *)
---

# /re-code - readable code for a function, kept as a card in review/

Arguments: `$ARGUMENTS` (function name or address; `--depth N` also does its callees
down N levels, default 0; `--lang` sets the language of comments and prose, default `en`).

The product is the card `review/<name>.md` for each function: what it does, its
real signature, the data it uses, and a readable version of its code. Write a lot
and write it down: the card is what the user keeps.

## Step 1 - Select

- `outq show <name>` for the function; `outq target` for the binary.
- With `--depth N`: follow `callees` N levels, skip thunks, externals and library
  code. Work callees first, so each summary feeds its callers.
- More than ~15 functions selected: show the list and ask which part to do.
- Read existing cards and `NOTES.md`. In a card, `## My notes` is the user's and
  wins over your reading; `## Analysis` is earlier work of yours: reuse it, but
  re-check any claim your new reading depends on.

## Step 2 - Understand before renaming

For each function, from evidence only (CLAUDE.md, Grounding):
- parameters and return value: how callers pass and use them (`outq show <caller>`);
- constants: read their values from the binary; name them only when the value or
  its use proves the meaning;
- structures: collect every `base + offset` access with its size and build a field
  table; a field gets a name only when its use proves it, otherwise `field_0x18`;
- calls: what each callee does (its card, or a documented API);
- anything the decompiler shows oddly (missing float arguments, wrong parameter
  count, merged variables): check the assembly with `objdump -d` around that address.

With the Ghidra MCP tools connected, apply names, prototypes and structures there
too and re-decompile (CLAUDE.md, Live loop); the card records the result.

## Step 3 - Write review/<file>.md

File name: the function's full name from out.json with every character other than
letters, digits, `.`, `_`, `-` replaced by `_` (`Unit1::TForm::Save` -> `Unit1__TForm__Save.md`).
If the card exists, replace only its `## Analysis` section and leave `## My notes`
exactly as it is.

~~~markdown
# <full name> @ 0x<address>

## Analysis
Updated: <date> by /re-code

- Purpose: <one sentence> [C]
- Signature: `<return type> <readable name>(<type> <param>, ...)` [C] or [H]
- Parameters: <name> - <meaning, with evidence> [C] / [H]
- Returns: <meaning> [C] / [H]
- Called by: <the callers that matter> | Calls: <the callees that matter>
- Side effects: <globals written, files, output>
- See also: <explain/..., other cards>

### Data
| Name | Where | Layout / value | Evidence | Status |
| --- | --- | --- | --- | --- |

### Readable code
```c
/* Readable version of <auto name> @ 0x<address>. Line numbers in comments
   refer to `outq show <name>`. Names marked ?? are guesses. */
<return type> <readable name>(<params>)
{
    ...   /* L120-134: why this block exists, not what the syntax says */
}
```

### Hypotheses (unverified)
- <guess> - <what would settle it>

## My notes
<!-- Yours. Claude never changes anything below this heading. What you write
     here wins over the analysis above. -->
~~~

Rules for the readable code:
- Same behaviour as the original: do not simplify away branches, error paths or
  odd cases. Mark anything you left out with `/* omitted: ... */`.
- Every renamed variable and field traces to evidence; guesses carry `??`.
- Comment the reason for a block and keep `L<from>-<to>` references so the user
  can compare with the raw pseudocode.
- Keep it C-like. A Python version belongs to `/re-port`.

## Step 4 - Report

Per function: one line with its purpose and how many items are [C] / [H]. List the
cards written, and suggest the next function whose card would clear the most `??`.
