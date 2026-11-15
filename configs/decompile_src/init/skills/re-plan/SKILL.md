---
name: re-plan
description: Research plan - phases as folders under plan/, tasks A, B, C with title, short description and status, details per task in their own file. Use ONLY when the user explicitly asks for a plan ("let's plan this", "make a plan", /re-plan), or when plan/ already exists and the user asks where the research stands or wants a task or phase added, changed or closed. Never start a plan on your own; at most offer one in a line when the user describes a goal that clearly spans several sessions.
argument-hint: "[new <phase-name> | status | task <letter> ...]"
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(ls *), Bash(re status), Bash(outq *)
---

# /re-plan - a plan that keeps the thread

Arguments: `$ARGUMENTS`

A plan is optional. Research usually starts without one; a plan is made when the
user has a goal big enough to span several sessions. Its purpose is **the red
thread and traceability**: what the goal is, what was done for it and why, and
for every finding or explanation, which task it came from.

## Layout

```
plan/
├── 01-<phase-name>/
│   ├── plan.md                 goal of the phase, tasks A, B, C ... with status
│   ├── A-<task-name>.md        details of task A (only when there is something to write)
│   └── B-<task-name>.md
└── 02-<phase-name>/            the active phase is the one with the highest number
```

- A **phase** is a folder `NN-<name>` (two digits, short name with hyphens, in
  the language of `settings.lang_docs`). A new phase starts when the goal
  changes or widens; earlier phases are never changed afterwards.
- **Tasks** are lettered A, B, C ... within a phase. A letter is never reused and
  a task is never deleted (a dropped one gets status `dropped`), so references
  stay valid. After Z comes AA.
- The **reference** to a task, used everywhere in the project, is
  `<phase>/<letter>`, e.g. `02/B`.

## plan.md

```markdown
# Phase 02: <name>

## Goal
<What the user wants to find out and why. When the answer is good enough.>

## Comes from
<Phase 01 task B, or for the first phase: what was known before the plan,
from LOG.md and the cards, with links.>

## Tasks

### A. <title>
Status: done
Description: <one to three lines>
Details: A-<task-name>.md

### B. <title>
Status: active
Description: ...

## Side paths
- <details the user went into that are not part of the goal; kept, not lost>

## Conclusion
<at the end of the phase: what was achieved, what stays open>
```

Status is one of `todo`, `active`, `done`, `dropped`. The line `Details:` is added
when the detail file is created.

## Detail file of a task (`B-<task-name>.md`)

What does not fit into plan.md: how to approach the task, what was tried, interim
results with links to the cards (`review/app/ParseHeader.md`), open questions,
links to explanations (`docs/explain/`, `docs/walkthrough/`). **Findings about the
code stay in the cards**; the detail file points to them and says what they mean
for the goal. Create it only when there is something to write.

## How the plan changes

- The plan is made with the user in the conversation. You propose changes (new
  task, status, new phase, conclusion) in the chat and write them after the user
  agrees; an approval prompt is not a substitute, it may not appear. Collect
  several status changes into one question and one edit at the end of an answer.
- Goal and questions are the user's. Change them only when the user asks.
- New tasks: propose them when the work shows they are needed; add them after
  the user agrees.
- Detail files you write without asking; they are your working notes.
- When the user goes into a detail outside the active task, answer it, and say
  in one line whether it belongs to the task or is a side path; offer to note a
  side path.

## Commands

- `new <phase-name>` - start a phase: next number, plan.md with Goal (ask the
  user), Comes from (from the previous phase's conclusion, or for the first
  phase from LOG.md and the cards), first tasks proposed with the user.
- `status` (or no argument) - one line: phase, how many tasks done, the active
  task and what is next.
- `task <letter> ...` - change a task as the user says (status, description).

## Traceability elsewhere

- Explanations and walkthroughs made for a task of the plan, as part of the
  planned research, carry the reference after the number, e.g.
  `docs/walkthrough/003-02B-file-header/`, and the task's detail file links them.
  Explanations made outside the plan get no reference.
- LOG.md: an entry for work on a task names the task.
- Cards carry no task references: they describe the function, wherever the
  finding came from.
