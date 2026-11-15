Decompile sandbox: user guide
=============================

Helps you understand a compiled program without its source: Ghidra and other
reverse-engineering tools, a few commands, and Claude Code with ready-made
procedures (skills). One rule runs through everything: a claim needs evidence
(an address, a value, a cross-reference); guesses are marked as such.

    1. First project         5. Skills                 9. Evidence first
    2. Project structure     6. Ghidra window         10. Upgrading a project
    3. Kinds of files        7. Delphi, Linux         11. If something goes wrong
    4. Commands              8. Several binaries


1  First project
----------------

The project folder is mounted at /app/<hash>. The program can be anywhere.

    cd /app/<hash>
    decompile-init                 # set up the project
    re init /path/to/program       # identify and export it (minutes)
    claude                         # ask

re init decides what kind of file it is (section 3), writes decompile.yaml,
restores real names for Delphi with debug info, exports all functions, and
prints what comes next. Then ask in your own words:

    What does this program do, and what are its main parts?
    How does the part that saves the data work?
    Show me step by step what happens when this function is called.
    Check that precisely. I want to be sure before I change it.
    Now describe that feature without references to the code.

Good order: top-down. First what the program offers to the outside (exports,
entry points, handlers), then the parts behind them, then single functions.


2  Project structure
--------------------

The same in every project, so that after a while you still know what is what.

Research data (what the research works on)

    decompile.yaml     binaries, which one is current, settings
    out.<id>.json      export of one binary; read with outq
    ghidra/            the Ghidra project ghidra/project.gpr; one program per binary
    src/<id>/          recovered source (.NET, Python only)
    work/              scripts, extracted tables, captured runs
    tools/queries.sql  saved queries (only when needed)

Working knowledge (what the research produces)

    NOTES.md           yours: purpose, what you know, agreements on scope
    LOG.md             Claude's: a few lines per session
    review/<id>/       one card per function, with evidence
    plan/              only when you work to a plan

Results (made from the knowledge)

    docs/              ARCHITECTURE.md, map/, explain/, spec/, walkthrough/

Setup: CLAUDE.md (rules), .claude/ (settings, skills, kb/ with knowledge per
kind of binary), .mcp.json (with --mcp). Folders appear when first needed;
nothing you have is overwritten.

Who writes what

    NOTES.md           you. Claude reads it every session, changes it only after asking.
    decompile.yaml     scripts write the binaries; settings, current and types
                       Claude changes only after asking.
    review/, LOG.md    Claude, without asking. "My notes" in a card is yours and
                       wins over Claude's reading.
    plan.md            Claude proposes in the conversation, you confirm.
    docs/              the skills, when you ask.

Claude asks in the conversation, not through approval prompts (in the
automatic permission mode they may not appear). Knowledge lives in the cards;
docs/ is made from them and never holds the only copy of a finding.

decompile.yaml

    current: app                        # binary you work on (also open in Ghidra)
    binaries:
      app:
        path: /data/legacy/App.exe
        type: delphi
        out_json: out.app.json
    settings:
      lang_docs: ""                     # language of cards, documents ("" = yours)
      lang_walkthrough: ""              # language of walkthroughs
      ghidra_live: false                # Claude works in the Ghidra window

Change it with re set / re use or an editor; re status checks it and names
the line of a mistake.

How work usually goes

  1. Ask. Claude answers in the chat, updates the cards it understood, adds
     a few lines to LOG.md. Next time it knows where you left off.
  2. Ask for a document when you want to keep something: "write up the
     architecture", "check that precisely", "show me step by step" (section 5).
  3. A plan only for a larger goal over several sessions: "let's plan this".

Working to a plan (/re-plan)

    plan/01-overview/plan.md, B-modules.md
    plan/02-file-format/plan.md, A-open-file.md, B-header.md   <- active (last)

A phase is a folder; a new one starts when the goal changes. Tasks are A, B,
C with title, description and status (todo, active, done, dropped); letters
are never reused, tasks never deleted. Details of a task go into its own file.
Work done for a task is marked with its reference (02/B) in LOG.md and in the
names of explanations made for it. Claude never starts a plan on its own.

Names of explanations: files in docs/explain/ and docs/walkthrough/ start
with a number in the order they were made (001-overview, 002-02B-header,
003-startup); the task reference follows only when made for a task.


3  Kinds of files
-----------------

re init prints the type it chose and why:

    native-elf, native-pe   export, then ask
    delphi                  TD32 debug info, or Borland sections together with
                            Delphi strings; with TD32 real names first (td32-import)
    dotnet                  decompile-dotnet.sh <id>     C# into src/<id>/
    python-frozen           unfreeze-python.sh <id>      .py into src/<id>/
    packed (UPX)            upx -d on a copy, then re init the copy
    installer               innoextract / unshield / cabextract, then re init

Wrong type: re set binaries.<id>.type <type>. re init again keeps the type;
--retype determines it again. Quick look: rabin2 -I / -i / -zz <file>.


4  Commands
-----------

Commands that take [id] use the current binary when it is left out; a path
works too. --help on each.

    re init <binary> [--id ID] [--no-export] [--retype]
    re status                    binaries, settings, plan phase, next steps
    re use <id>                  make <id> current
    re get <key> / re set <key> <value>
                                 e.g. re set settings.lang_docs sl   ("" = default)

    outq info | ls [re] | roots | show NAME [A:B] | grep RE [NAME]
         | strings [RE] | imports           -b <id> picks a binary
    outq sql "SELECT ..."        anything else, over all binaries (DuckDB)
    outq selftest                checks the saved queries

    exportjson.sh [id]           the export (re init runs it)
    td32-import [id]             Delphi names from TD32 (re init runs it)
    contextpack.sh [id] [out] [name], decompile.sh [id] [out]   files in work/
    decompile-dotnet.sh [id], unfreeze-python.sh [id]          src/<id>/
    ghidra-bg start|stop|status|log, ghidra-mcp-up              section 6

outq show prints the first 150 lines; give a range for more. outq sql is
read-only (SELECT, EXPLAIN; files only under work/) with the tables
functions (column bin = binary), calls (bin, src, dst) and strings (bin,
function, addr, value):

    outq sql "SELECT bin, count(*) FROM functions GROUP BY bin"
    outq sql "SELECT * FROM 'work/runs.csv'"

Useful queries Claude saves in tools/queries.sql as macros with an example.
The Ghidra scripts run through ghidra-run in ghidra/project.gpr, so a binary
is imported and analyzed only once.

Optional: python3 /opt/ctx/extras/analyze.py (batch analysis through the
Anthropic API, billed separately; writes to analyze/, --list to preview).


5  Skills
---------

An ordinary question gets an answer in the chat. A skill is for a lasting
result; Claude uses one when you ask for it. Type / to see them.

    /re-doc            the big picture as a document       docs/ARCHITECTURE.md
                       --review: claims checked by a second agent
    /re-map            clickable map of modules and calls  docs/map/index.html
    /re-explain        verified explanation, every claim   docs/explain/NNN-...md
                       checked and reviewed by a second agent
    /re-walkthrough    step by step, visual, or a demo     docs/walkthrough/NNN-...
    /re-spec           what a feature does, without        docs/spec/<feature>.md
                       references to the code
    /re-plan           the research plan                   plan/NN-<phase>/

Open the .html files on your own machine; they work offline. [C] = confirmed
by evidence, [H] = hypothesis. Refuted claims stay with a correction. The
language comes from decompile.yaml; --lang overrides it once. Your own skills:
~/.config/decompile/skills/<name>/SKILL.md (copied by decompile-init).

To learn rather than get answers: "Here is my guess for FUN_00401a30 and my
evidence. Don't give me the answer; tell me which claims hold and what I
missed."


6  Ghidra window and the live loop
----------------------------------

VNC: 127.0.0.1:5901, password $SANDBOX_VNC_PASS (default "sandbox"); from
another machine ssh -L 5901:127.0.0.1:5901 -p 2232 dev@host.

    decompile-init --mcp               # .mcp.json, Ghidra read permissions
    re set settings.ghidra_live true
    ghidra-mcp-up                      # starts Ghidra, waits for the plugin
    claude                             # /mcp shows "ghidra"

The first time: in Ghidra open ghidra/project.gpr, open the program of the
current binary (named by its id), enable the GhidraMCP plugin (File >
Configure). Ghidra then reopens it by itself.

Claude reads freely (get_*, list_*, find_*, search_*, decompile_*, read_*).
It renames, retypes or creates structures only when you ask or agree, one
task at a time, and says first what it will change; each change asks for
approval. Names given in Ghidra are hypotheses, not evidence.

The export does not see changes made in Ghidra, and the scripts cannot open
the project while the window holds it; they stop and print the steps. With
ghidra_live Claude reads from Ghidra, so re-export only when needed (outq sql,
skills over many functions): save, File > Close Project, exportjson.sh <id>,
open it again.

/mcp "failed": Ghidra not open, plugin not enabled, or no program loaded.
Port 8089 (Edit > Tool Options > GhidraMCP HTTP Server, and .mcp.json).

Desktop tools: ghidraRun, cutter, imhex, jadx-gui, geany; terminal: r2,
rabin2, objdump, readelf, binwalk, exiftool.


7  Delphi, Linux
----------------

Delphi / C++Builder: re init runs td32-import when the binary has TD32 debug
info; outq info shows "qualified" > 0 when the names arrived (otherwise
td32-import <id>, then exportjson.sh <id>). Without Ghidra: td32_ghidra.py
check|extract <file>. How to read Delphi code (registers, VMT, string
headers) and which prototypes to apply is in .claude/kb/delphi.md, which
Claude reads for every Delphi binary.

Linux programs and libraries can run here: readelf -d / --dyn-syms, strace
-f, ltrace, gdb, or call a function from Python (ctypes) and compare with
your own version, the strongest proof. Claude proposes such runs and starts
them only with your approval. Run only binaries you trust in this container,
never on the host.


8  Several binaries
-------------------

    re init /path/to/core.dll --id core
    re use core                    # optional

All binaries share the Ghidra project (one program each, named by id); each
has its export and cards (review/<id>/); docs/ and plan/ describe the whole
program. Claude names the binary in every command. If you switch current
yourself, tell Claude or start it again; a new session reads decompile.yaml,
NOTES.md, LOG.md and the plan. Calls into another binary appear as imports
(CORE.DLL::Calculate, or Ordinal_17); Claude follows them with outq sql.


9  Evidence first
-----------------

  - Every claim has an address or a line of pseudocode. No evidence, no claim.
  - FUN_00401a30, uVar1, undefined4 mean nothing. Reason from what the code
    does, who calls it, what data it uses. Read constants from their values.
  - Names are never evidence: a name given in Ghidra is an earlier hypothesis;
    one from debug info says which function it is, not what it does.
  - Guesses from names or strings go under "Hypotheses (unverified)".
  - What you wrote (NOTES.md, "My notes") wins over Claude's reading.

The full rules are in CLAUDE.md, loaded in every session.


10  Upgrading a project made with an older version
--------------------------------------------------

    decompile-init --migrate     # new CLAUDE.md, skills, kb, permissions;
                                 # results move under docs/
    re init /path/to/program     # out.json -> out.<id>.json, cards -> review/<id>/

Replaced files are kept in .claude/old/. NOTES.md stays as it is (the new
template is /opt/ctx/init/NOTES.md); Claude's log now goes to LOG.md. The old
<program>_ghidra project is not used; the binary is imported into ghidra/
once.


11  If something goes wrong
---------------------------

    Script: project open in the Ghidra window   close it there (or ghidra-bg
                                                stop), run again (section 6)
    ghidra-run: pyghidra too old                pip install -U pyghidra, or rebuild
    re: yq missing / not mikefarah              the image installs it in
                                                /usr/local/bin; dnf's yq differs
    decompile.yaml not valid YAML               indentation; re status names the line
    Ghidra or Java missing                      rebuild; echo $GHIDRA_INSTALL_DIR,
                                                java -version
    unfreeze-python.sh: empty .py files         Python too new: pycdas file.pyc
    GUI tool: missing library                   add it to PROFILE_decompile_DNF
    Diagrams show as text                       Mermaid not downloaded at build
                                                (WARN in the log); CDN with internet
    Claude states something without address     ask for the evidence (CLAUDE.md)

GhidraMCP plugin missing after a build:

    pip install --break-system-packages uv
    git clone https://github.com/bethington/ghidra-mcp && cd ghidra-mcp
    python3 -m tools.setup ensure-prereqs --ghidra-path /opt/ghidra
    python3 -m tools.setup build
    sudo unzip -o target/GhidraMCP-*.zip -d /opt/ghidra/Ghidra/Extensions
    pip install --break-system-packages .
