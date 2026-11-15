---
name: re-walkthrough
description: For a compiled binary without source code - make an explanation for the user's own understanding of how something in the analyzed program works, and how it could work otherwise (alternatives the user is curious about) - step by step, visual (diagrams, before/after data, an interactive page with "Try it" boxes), or as a small Python demo - saved under docs/walkthrough/. Use when the user asks to be shown, walked through, to see it step by step, visually, interactively, as a diagram, animation or demo. Not for a plain "how does it work" question (answer in the chat) or a verification (/re-explain). A general concept with no tie to the binary is /learn.
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

## Two kinds of steps

- **How the binary does it** (status `confirmed` / `hypothesis`): faithful to
  the analyzed code, with the rules below.
- **How it could work otherwise** (status `alternative`): the user's "what if",
  another method, a simpler or better variant. Allowed and welcome; it needs no
  evidence from the binary, but its data still comes from real computation, and
  the page must never let an alternative pass for what the binary does. When both
  appear, say in the text which one the binary uses, and end with a step that
  compares them on the same example.

When the curiosity goes past the binary altogether (the concept itself, how to
learn it), offer /learn in one line.

## Rules

- Build it from what the project already knows (cards in `review/<id>/`,
  `docs/explain/`, `docs/ARCHITECTURE.md`, this conversation). If that is not enough for the topic,
  investigate first and record the findings in the cards; then present.
- Show nothing about the binary that the knowledge does not support. A step
  that rests on a hypothesis is marked as such on the page.
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
  at its top explains the fields). Where changing the input teaches more than
  looking, give the step a `widget` ("Try it": e.g. edit a small grid or a byte
  buffer, move a slider) that recomputes with the same algorithm the page
  explains; a `check` ("Check yourself") question helps the idea stick. One self-contained file: no external
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

## Check the page

Before handing a page over, look at it. When `chromium-headless` is installed,
take a screenshot of each step and Read the image:
`chromium-headless --screenshot=work/<name>-<N>.png --window-size=1280,900 "file://$PWD/<page>.html#<N>"`
(`#N` opens step N). When jsdom is available (`node -e "require('jsdom')"`), click
through the steps, widgets and "Show answer" buttons in a small script and check
that no step shows "widget error". With Playwright (`python3 -c "import playwright"`)
the same can run in the real browser, with a screenshot after each click:
`p.chromium.launch(executable_path="/usr/lib64/chromium-browser/headless_shell")`;
close the browser in a `finally`. Afterwards `pgrep -f headless_shell` must print
nothing. Without these tools, say that the page was not looked at.

## Afterwards

Tell the user in one or two sentences what the walkthrough shows and where it
is, and add a line to LOG.md. If the user then asks for the description without references to the code,
that is `/re-spec`: write it from the same knowledge.
