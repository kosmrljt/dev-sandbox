---
name: re-explain
description: For a compiled binary without source code - explain how one part of the analyzed program works (a function, a group of functions, a file format, a feature such as "how saving works"), write the explanation to a Markdown file under explain/, and verify every claim independently before presenting it. Use when the user asks how something works, what a function or feature does, or why the code does something.
argument-hint: "<function | address | feature question> [--lang sl|en]"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(contextpack.sh *), Bash(outq *), Bash(python3 ${CLAUDE_SKILL_DIR}/*), Bash(python3 .claude/skills/re-explain/*), Bash(rabin2 *), Bash(readelf *), Bash(file *)
---

# /re-explain - how one part of the analyzed binary works, with verified claims

Topic: `$ARGUMENTS` (a function name, an address, or a question such as
"how does saving work"). `--lang sl|en` sets the prose language (default `en`).

The user is learning reverse engineering. The goal is that they understand **how**
and **why** this part works, not just get names. Every statement in the explanation
must be backed by a claim that was checked.

## Step 1 - Scope

- Turn the topic into one precise question, e.g. "How does GAME.EXE write scores.dat?".
- Find the starting point: the named function, the address, or an anchor for the
  feature (string, import, resource, control ID). Read the cards in `review/` and
  `NOTES.md` first. `## My notes` in a card and NOTES.md are the user's and win;
  `## Analysis` is earlier work of yours and may be re-checked.
- Pick the subgraph that answers the question: the starting function plus callees
  down to 2 levels and the callers that matter. Skip library/runtime code.
  Read functions with `outq show <name> [from:to]` and search with
  `outq grep <regex> [name]`; `outq target` prints the binary's path.
  `contextpack.sh <binary> <file>.md <name>` gives the same as a file to keep.
- If the question is too broad for ~10 functions, say so and propose a narrower one.
- If another skill in this project covers the whole topic, use this one for a
  single part of it.

## Step 2 - Collect claims

While reading, write each fact you intend to use as a numbered claim (C1, C2, ...):
one checkable sentence, with its evidence (address, pseudocode line, constant value,
xref, string, import). No claim may rest on a name or a string alone.

## Step 3 - Verify every claim independently

For each claim pick the cheapest check that could prove it **wrong**, run it, and
record the result. Do not count re-reading the same pseudocode as a check.

| Check | Use for |
| --- | --- |
| second caller / other xref | meaning of a parameter or return value |
| known API documentation | types and meaning of values passed to OS/library calls |
| assembly next to the pseudocode | signedness, sizes, calling convention, decompiler mistakes |
| data in the binary (rabin2, ImHex, Python on the bytes) | constants, tables, embedded data |
| a data file the program uses | file formats, offsets, field sizes |
| Python re-implementation compared on examples | algorithms (checksums, encodings, math) |
| Ghidra emulation of the function (PyGhidra `EmulatorHelper`) or Unicorn | exact behaviour on chosen inputs |
| call the original through ctypes (native Linux .so) and compare outputs | algorithms; strongest check when the code can run |
| `ltrace` / `strace` / `gdb` breakpoint on a running native program | real argument and return values, call order |

Result is exactly one of:
- `verified` - the check agrees; say what you saw.
- `refuted` - the check disagrees; write the corrected claim as a new claim.
- `unverified` - no check was possible; say why.

**Independent review.** When the Agent/Task tool is available, give a fresh subagent
only the claims table (claim, evidence, binary path, out.json path) and ask it to try
to refute each claim with its own check. It must not see your explanation. Merge its
results: any disagreement makes the claim `refuted` or `unverified` until resolved.

The review comes on top of your own checks; it does not replace them. Every claim
needs a check of yours in the Check column. "Independent review" alone is not a
check, and `explain_check.py` rejects it for a `verified` claim.

Order matters: finish your checks, start the review, and WAIT for its results
before you write results into the table. While it runs you may draft the text,
but a claim whose only support so far is the pending review is `unverified`, and
the header counts say so. Do not report to the user before the review is merged.

## Step 4 - Write explain/<topic-slug>.md in exactly this structure

~~~markdown
# How <topic> works

Question: <the precise question>
Binary: <file> | Functions read: <n> | Claims: <v> verified, <r> refuted, <u> unverified

## 1. Short answer
<2 to 4 sentences, using only verified claims; cite them like [C1][C4].>

## 2. How it works
1. <step in plain words> [C2]
2. <next step> [C3][C5]
<Mechanism in order of execution. Each step cites claims. An unverified claim may
be used only with the word "(unverified)" right after its citation.>

```mermaid
<optional small flowchart or sequenceDiagram of the steps, max ~10 boxes>
```

## 3. Why it is built this way
<What the original source probably looked like (C-like sketch, short), compiler or
era habits visible here, design reasons. Mark guesses as such.>

## 4. Key data
| Name | Where | Layout / values | Claims |
| --- | --- | --- | --- |

## 5. Claims and verification
| ID | Claim | Evidence | Check | Result |
| --- | --- | --- | --- | --- |
| C1 | ... | `FUN_00402210` @ 0x00402210 line 7 | second caller FUN_00401500 passes a path | verified |

A `|` inside a cell (a format string, an OR expression) must be written as `\|`,
otherwise it splits the row.

## 6. Corrections
<Every refuted claim: what was wrong, what is true (new claim ID), how it was found.
"None" if nothing was refuted.>

## 7. What to learn from this
<1 to 3 general lessons for a beginner: patterns, compiler habits, techniques used.>

## 8. Open questions
- <what is still unknown and the check that would settle it>
~~~

The sections are recognised by their numbers, so with `--lang` (or when the user
writes in another language) translate the headings and prose and keep the numbering
and the claim IDs. There is no need to read `explain_check.py` to find this out.

## Step 5 - Check the file

```bash
python3 ${CLAUDE_SKILL_DIR}/explain_check.py explain/<topic-slug>.md
```

Fix every ERROR and run it again. Do not edit `explain_check.py`.

## Step 6 - Update the function cards

For every function you read closely, create or update its card `review/<file>.md`
(format and file naming: see the /re-code skill; if that skill is not installed,
use: `# <name> @ 0x<address>`, `## Analysis`, `## My notes`). Put into `## Analysis`
what this explanation established about that function: purpose, signature,
parameters, structure fields and constants, each with [C] for verified claims and
[H] otherwise, plus `See also: explain/<topic-slug>.md`. Do not paste the whole
explanation; the card is the per-function summary. Never touch `## My notes`.

Save tables, listings and helper scripts that the explanation relies on in `work/`
instead of a temporary directory, and mention them under Evidence.

## Step 7 - Answer the user

Give the short answer (section 1) and the counts of verified/refuted/unverified
claims, mention any correction, and point to the file and the cards you updated. Offer one next question that
would deepen understanding. If the user wants to learn by doing, offer to turn
section 2 into questions they answer first.
