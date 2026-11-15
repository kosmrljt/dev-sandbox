# What's New in This Version

This release introduces a cleaner project layout, single-command initialization, multi-binary support, and SQL queries across exported binaries. It is designed to get you from a fresh binary to interactive analysis with minimal setup while keeping your workspace organized as projects grow.

---

## Core Principles

- **Zero-ceremony start, progressive features:** Starting a new analysis takes a single command (`re init <binary>`) and your first question. Advanced features—multi-binary workflows, structured plans, live Ghidra integration, and .NET or Python paths—stay out of the way until you need them.
- **Consistent project structure:** Every project follows the same layout, cleanly separating **raw analysis data**, **working knowledge**, and **final deliverables (`docs/`)**.

---

## 1. Project Layout & Configuration

| Previous Version | Current Version | Benefit |
|---|---|---|
| `out.json` + `out.json.target` | `decompile.yaml` | A single source of truth tracking binaries (path, type, export), the active binary (`current`), and project settings. |
| Separate `<bin>_ghidra` folders next to binaries | Shared `ghidra/project.gpr` in the project root | All binaries live in one Ghidra project (indexed by `id`). Imported symbols (e.g., `td32-import`) automatically carry over to exports, and binaries with identical filenames no longer collide. |
| `review/*.md` | `review/<id>/*.md` | Analyze multiple binaries in one project without overwriting function cards that share the same name. |
| Deliverables in the project root | Grouped under `docs/` | `ARCHITECTURE.md`, `map/`, `explain/`, `spec/`, and `walkthrough/` are neatly separated from working files. |
| Mixed user & AI notes in `NOTES.md` | `NOTES.md` (yours) + `LOG.md` (Claude's) | Clear ownership. Claude never edits your `NOTES.md` and records session progress in `LOG.md` instead. |
| — | `plan/NN-<phase>/` *(optional)* | Structured phase and task tracking for larger reverse-engineering goals. |
| — | `tools/queries.sql` *(optional)* | Reusable DuckDB SQL macros loaded automatically by `outq`. |

### Configuration (`decompile.yaml`)

`decompile.yaml` is a commented configuration file managing registered binaries and three optional settings:
- `lang_docs` — Language for generated documentation (empty = default/conversation language).
- `lang_walkthrough` — Language for walkthroughs.
- `ghidra_live` — Enables live Ghidra MCP integration when set.

> **Note:** Claude will always ask in chat before changing settings, the active binary, `NOTES.md`, or your project plan.

---

## 2. New & Updated CLI Tools

### `re` — Project Management & Triage

The new `re` command replaces separate helper scripts with a single entry point:

| Command | Description |
|---|---|
| `re init <binary> [--id ID] [--no-export]` | Triages the binary (detects PE/ELF, TD32 symbols, .NET CLR, PyInstaller, UPX, and installers), registers it in `decompile.yaml`, runs `td32-import` for Delphi binaries if applicable, and exports analysis data to JSON. |
| `re status` | Displays registered binaries, active settings, current plan phase, and suggested next steps (also validates `decompile.yaml`). |
| `re use <id>` | Switches the active (`current`) binary. |
| `re get` / `re set` | Reads or updates project settings with validation. |

*Tip: Running `re init` in an older project automatically adopts an existing `out.json` as `out.<id>.json` and moves flat `review/*.md` cards into `review/<id>/`.*

### `outq` — Querying Exports & DuckDB SQL

- **Multi-binary selection (`-b <id>`):** Target any registered binary by its `id` (defaults to `current`).
- **Smart pagination (`outq show`):** Outputs the first 150 lines by default with a prompt on how to view the rest, preventing massive functions from flooding the context window.
- **Improved `imports`:** External function calls (such as `KERNEL32.DLL::…`) are now reliably listed even when not locally defined.
- **SQL queries (`outq sql "…"`):** Run fast DuckDB SQL queries across **all** registered binaries at once using the `functions`, `calls`, and `strings` tables (each includes a `bin` column). Ideal for recursive call chains, cross-binary call graphs, and statistics.
- **Saved macros (`tools/queries.sql`):** Define custom SQL macros for your project and test them with `outq selftest`.

### Export & Decompilation Scripts

- **ID-aware:** `exportjson.sh`, `td32-import`, `contextpack.sh`, `decompile.sh`, `decompile-dotnet.sh`, and `unfreeze-python.sh` now accept a binary `id` or a file path (and default to `current` if omitted).
- **Shared Ghidra project & lock detection:** All Ghidra scripts operate on `ghidra/project.gpr`. If the project is currently open in the Ghidra GUI, scripts detect the lock and print clear instructions instead of failing with an obscure error.
- **Richer JSON exports (`ExportJson.py`):** Now includes external functions (`is_external`) and UTF-16 (`unicode`) strings.

---

## 3. Smarter Claude Workflow & Permissions

### How Claude Works (`CLAUDE.md`)

- **Session continuity:** At the start of every session, Claude reads `decompile.yaml`, your `NOTES.md`, recent entries in `LOG.md`, and any active plan so you can pick up right where you left off.
- **Strict evidence rules ("Names are not evidence"):** Function names from debug symbols or previous renaming sessions are treated as hypotheses `[H]` until verified against actual code. This prevents circular reasoning.
- **Less noise, more focus:**
  - Function cards in `review/<id>/` are updated in batch at the end of a turn, only for functions with new findings.
  - Live Ghidra actions run only when requested, one task at a time.
  - Skills are invoked only when you want a permanent document or artifact; otherwise, Claude answers directly in chat.

### Streamlined Permissions (`.claude/settings.json`)

- **Fewer confirmation prompts:** Read-only queries (`outq`, `re status`, `re get`) and updates to working files (`review/**`, `work/**`, `LOG.md`, `plan/**`) run without interrupting your flow.
- **Protected user files:** Claude cannot modify `NOTES.md`, `decompile.yaml`, `tools/queries.sql`, or `docs/` without confirmation.

---

## 4. Skills (`/re-*`)

Skills now write all outputs under `docs/`, log their completion in `LOG.md`, and respect your `lang_docs` / `lang_walkthrough` settings:

| Skill | When to Use It |
|---|---|
| `/re-doc` | Generate or update the **architecture document** (`docs/ARCHITECTURE.md`). Add `--review` for an independent subagent verification pass. |
| `/re-map` | Build an interactive, clickable **architecture graph** (`docs/map/`). |
| `/re-explain` | Produce a deeply verified, evidence-backed **explanation** of a mechanism or function (`docs/explain/`). |
| `/re-walkthrough` | Create a **step-by-step visual walkthrough** (`docs/walkthrough/`). |
| `/re-spec` | Write a clean **specification without implementation code** (`docs/spec/`). |
| `/re-plan` *(new)* | Organize complex reverse-engineering goals into **phases and lettered tasks** (`plan/NN-<phase>/`). |

*Note: Explanations and walkthroughs are automatically numbered in order of creation (e.g., `001-...`, or `003-02B-header` when linked to task `02/B` of a plan).*

---

## 5. Upgrading an Existing Project

To upgrade a project created with a previous version:

1. Run the migration command inside your project folder:
   ```bash
   decompile-init --migrate
   ```
   - Updates `CLAUDE.md`, skills, permissions, and knowledge base files (your previous versions are safely backed up to `.claude/old/`).
   - Moves existing deliverables (`ARCHITECTURE.md`, `map/`, `explain/`, etc.) into `docs/`.
2. Initialize your binary with `re`:
   ```bash
   re init <path-to-binary>
   ```
   - Adopts your existing `out.json` as `out.<id>.json` without re-running Ghidra, and moves existing `review/*.md` cards into `review/<id>/`.