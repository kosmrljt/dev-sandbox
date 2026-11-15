---
name: re-walkthrough
description: For a compiled binary without source code - make an explanation for the user's own understanding of how something in the analyzed program works - step by step, visual (diagrams, before/after data, small interactive page), or as a small Python demo - saved under docs/walkthrough/. Use when the user asks to be shown, walked through, to see it step by step, visually, interactively, as a diagram, animation or demo. Not for a plain "how does it work" question (answer in the chat) or a verification (/re-explain).
argument-hint: "<topic> [--lang sl|en]"
---

# /re-walkthrough - show the user how it works

Arguments: `$ARGUMENTS` (the topic; `--lang` sets the language, default:
`settings.lang_walkthrough` in decompile.yaml, else the language the user writes in).

## Name

Every walkthrough gets the next free 3-digit number in `docs/walkthrough/`, so
the files sort in the order they were made: `docs/walkthrough/<NNN>-<topic-slug>`.
Only when the walkthrough is made for a task of the plan, as part of the planned
research, add the task reference after the number: `003-02B-file-header`
(phase 02, task B), and link it from that task's detail file. Outside the plan:
no reference. The slug is in the walkthrough's language.

A walkthrough is for understanding. It is a presentation of what is known, not
a place where knowledge is kept: the user may delete it and ask for a new one.

## Rules

- Build it from what the project already knows (cards in `review/<id>/`,
  `docs/explain/`, `docs/ARCHITECTURE.md`, this conversation). If that is not enough for the topic,
  investigate first and record the findings in the cards; then present.
- Show nothing that the knowledge does not support. A step that rests on a
  hypothesis is marked as such on the page.
- Data shown at each step (values, buffers, images, output) must come from real
  computation: the original code, an emulation, or a re-implementation that was
  compared with the original. If it is only an illustration, label it
  "illustration".
- Explain for a person, not for the record: plain words first, one idea per
  step, a concrete example running through all steps. References to the code
  (function, address) are optional small print; leave them out if the user
  asked for no references.
- Keep it small: 4 to 10 steps. A bigger topic gets several walkthroughs.

## Form

Pick what fits the question:

- **Interactive page** `docs/walkthrough/<name>.html`: copy
  `${CLAUDE_SKILL_DIR}/template.html` and fill in the `STEPS` list (the comment
  at its top explains the fields). One self-contained file: no external
  scripts, fonts or images; embed pictures as SVG or `data:` URIs. If a skill
  for interactive HTML explanations is installed, you may follow that one
  instead, with the rules above.
- **Text** `docs/walkthrough/<name>.md`: numbered steps with small diagrams
  (Mermaid or ASCII) when a page would be too much.
- **Python demo** `docs/walkthrough/<name>.py`: a short runnable script that
  prints or plots what happens, when seeing it run explains more than a picture.
  Say at its top what is faithful to the original and what is simplified.

When data for the page is computed (intermediate values, images), let a script
produce it and paste or embed its output; keep that script in `work/`.

## Afterwards

Tell the user in one or two sentences what the walkthrough shows and where it
is, and add a line to LOG.md. If the user then asks for the description without references to the code,
that is `/re-spec`: write it from the same knowledge.
