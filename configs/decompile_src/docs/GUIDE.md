Decompile sandbox: user guide
=============================

This sandbox helps you understand a compiled program when you do not have
its source. You get Ghidra and other reverse-engineering tools, a few helper
scripts, and Claude Code with ready-made commands ("skills").

One rule runs through everything: a claim needs evidence (an address, a
value, a cross-reference). Guesses are kept apart and marked as such; see
section 8. All tools are on the PATH.

    1. Your first project            6. Delphi / C++Builder
    2. What kind of file is it?      7. Native Linux binaries
    3. Scripts                       8. The rule: evidence first
    4. Skills                        9. If something goes wrong
    5. Ghidra and the live loop


1  Your first project
---------------------

Your project folder is mounted in the sandbox at `/app/<hash>`.

    cd /app/<hash>
    mkdir target && cp /path/to/program target/   # 1. the file to study
    decompile-init --mcp                          # 2. set up the project
    file target/program                           # 3. what is it? (section 2)
    exportjson.sh target/program out.json         # 4. export for Claude
    ghidra-mcp-up                                 # 5. open Ghidra, connect
    claude                                        # 6. start asking

Step 5 starts Ghidra on the VNC desktop (section 5) and waits until Claude
can reach it. The very first time you have to import the binary in Ghidra,
open it in a CodeBrowser and enable the GhidraMCP plugin. After that Ghidra
reopens your last program by itself. If the step times out, do that and run
it again.

Good first questions inside claude:

    /re-doc                          how is this program built, overall?
    /re-explain what does main do    how does one part work?
    /re-code main                    readable code for a function
    /re-port the output format       a Python version of a feature

What decompile-init creates (it never overwrites your files):

    CLAUDE.md                the rules Claude follows
    NOTES.md                 your notes about the program
    review/                  function cards (section 4)
    .claude/skills/          the commands (section 4)
    .claude/settings.json    permissions
    .mcp.json                with --mcp: the connection to Ghidra

Claude may run the read-only tools (file, rabin2, readelf, objdump, strings,
outq, the export scripts) without asking. It still asks before it runs the
program you are analyzing, a debugger or a tracer, and before it changes
anything in Ghidra.

You now have two views of the same program:

    out.json         a snapshot of all functions. Good for overview,
                     searching and the skills. Changes only when you run
                     exportjson.sh again.

    Ghidra window    the live project you and Claude edit. Good for
                     renaming, structures and reading one function closely.
                     Changes immediately.

Names that you or Claude change in Ghidra do not appear in out.json by
themselves. For the latest names, have Claude read from Ghidra.

Without Ghidra's window you can skip --mcp and step 5. Everything except
the live loop still works.


2  What kind of file is it?
---------------------------

Run "file target/program", then find your case:

    ELF or PE executable, shared library
        exportjson.sh, then claude

    PE with Borland / Delphi strings
        td32-import first (section 6), then as above

    Mono/.Net assembly
        decompile-dotnet.sh target/App.exe

    Strings like _MEIPASS or python3X.dll
        unfreeze-python.sh target/app

    Installer (Inno Setup, InstallShield, CAB)
        unpack first: innoextract, unshield, cabextract

    Section names UPX0, UPX1
        unpack first: upx -d on a copy

Three more commands give a quick first impression of any binary:

    rabin2 -I target/program     # architecture, 32/64-bit, stripped or not
    rabin2 -i target/program     # imported functions: what it can do
    rabin2 -zz target/program    # strings: messages, file names, formats


3  Scripts
----------

Each script prints its usage when run without arguments. The Ghidra-based
ones take seconds for a small file and minutes for a large one.

`exportjson.sh <binary> [out.json]`

    Run it once per binary. Writes every function (name, address, calls,
    strings, pseudocode) to out.json. Claude and the skills read this file.
    The binary does not have to be in target/: the script remembers where
    it was.

        exportjson.sh target/prog out.json

`outq <command>`

    Looks into out.json so you never have to open it. Claude uses it too.

        outq info                 what is in the export, which binary
        outq target               path of the analyzed binary
        outq ls save              functions whose name matches
        outq roots                functions nobody calls (handlers, callbacks)
        outq show main 1:80       one function, or part of its pseudocode
        outq grep 'CreateFile'    search the pseudocode of all functions
        outq strings '\.dat'      who uses which string
        outq imports              external functions and their callers
        outq --help               the rest, and the format of out.json

`contextpack.sh <binary> [out.md] [name]`

    One function, or one class, as a readable Markdown file.

        contextpack.sh target/prog one.md parse_header

`decompile.sh <binary> [out.c]`

    All pseudocode in one file, to search through.

        decompile.sh target/prog all.c

`decompile-dotnet.sh <assembly>`

    For .NET files. Gives a C# project.

        decompile-dotnet.sh target/App.exe

`unfreeze-python.sh <app>`

    For frozen Python apps. Gives .py files.

        unfreeze-python.sh target/app

`td32-import <program.exe>`

    Delphi / C++Builder binary with debug info: restores the real names.
    See section 6.

        td32-import target/App.exe

`ghidra-bg start | stop | status | log`

    Starts or stops the Ghidra window on the VNC desktop.

`ghidra-mcp-up`

    Connects Claude to the open Ghidra window. See section 5.

`analyze.py --in out.json ...`

    Batch analysis through the Anthropic API, without the chat. Needs
    ANTHROPIC_API_KEY and "pip install anthropic"; it is billed separately.
    Preview what it would do with --list:

        analyze.py --in out.json --seed main --depth 2 --list


4  Skills (commands inside Claude Code)
---------------------------------------

A skill is a prepared procedure with a fixed output format. Type the
command, or just ask in your own words and Claude picks the matching skill.
Type / to see all skills in your project. The ones for binaries start with
"re-" (reverse engineering), so they are not confused with skills for
source code.

    /re-code <function>
        Readable, commented code for one function, saved as a card.
        Add --depth 1 to do its callees too.
        Writes: review/<function>.md

    /re-port <feature>
        A Python version or simulation of one feature, compared with the
        original where the original can run.
        Writes: reimpl/<feature>.py and its test

    /re-explain <function or question>
        How one part works, step by step, with every claim checked.
        Writes: explain/<topic>.md

    /re-doc
        The big picture: what kind of program it is, its components, how
        it runs.
        Writes: ARCHITECTURE.md and map/architecture.html

    /re-map
        A clickable map of modules and functions.
        Writes: map/index.html

Open the .html files in a browser on your own machine (the project folder
is shared). The libraries they need are embedded, so they work without
internet.

Where things are written

Everything worth keeping lands in the project folder, each kind in its
place:

    review/            one card per function: what it does, its signature
                       and data, readable code
    explain/           answers to "how does X work", with checked claims
    reimpl/            Python versions of features, with tests
    ARCHITECTURE.md    the big picture
    map/               the clickable map and the rendered architecture
    work/              extracted tables, listings, helper scripts
    NOTES.md           your notes about the whole program

A card in review/ has two parts. Claude keeps "Analysis" up to date.
"My notes" is yours: Claude never edits it, and what you write there wins
over its own reading. Use it when you know something the binary cannot
show (how a device behaves, what a button does), when Claude got something
wrong, or when you tested a hypothesis yourself.

Reading the results

  - [C] means confirmed: backed by evidence.
    [H] means hypothesis: plausible, not proven.
  - Claim tables say verified, refuted or unverified. Refuted claims stay
    in the document with a correction; they show where first impressions
    were wrong.

Working with skills

  - Add --lang sl (or another language) to get the text in that language.
  - Learned something new? Run the skill again with --refresh. It changes
    only what the new evidence supports.
  - Your notes win. What you write under "My notes" in a card, or in
    NOTES.md, overrides Claude's own reading, so correct things there.
  - A skill is missing from the / list? Run decompile-init again.
  - Your own skills: put a folder with a SKILL.md into
    ~/.config/decompile/skills/. decompile-init copies it into every new
    project, and it stays out of this repository.

If you want to learn, not just get answers, write your own guess first and
ask Claude to check it:

    Here is my guess for FUN_00401a30 and my evidence. Don't give me the
    answer. Tell me which claims hold, which are wrong, and what I missed.


5  Ghidra window and the live loop
----------------------------------

Ghidra runs on a VNC desktop. Connect a VNC client to 127.0.0.1:5901
(password $SANDBOX_VNC_PASS, default "sandbox"). From another machine:

    ssh -L 5901:127.0.0.1:5901 -p 2232 dev@host

In the live loop, Claude works inside your open Ghidra project: it renames
things, creates structures and re-decompiles until the code reads well.
Section 1 shows how to start it (decompile-init --mcp, ghidra-mcp-up,
claude). Inside claude, type /mcp to see whether "ghidra" is connected.

What Claude may do there is set in .claude/settings.json:

    Read      get_*, list_*, find_*, search_*, decompile_*, read_*
              These run automatically.

    Change    create_struct, rename_*, apply_data_type,
              set_function_prototype, save_*
              Claude asks you first.

The goal of the loop is pseudocode without uVar, param_1 or undefined
names: Claude names and types things, re-decompiles, and repeats.

If /mcp shows "failed": Ghidra is not open, the plugin is not enabled, or
no program is loaded. The port is 8089. Change it in Ghidra under
Edit > Tool Options > GhidraMCP HTTP Server, and in .mcp.json.

Tools on the desktop and in the terminal:

    ghidraRun    Ghidra: decompiler, call graphs (runs on JDK 25)
    cutter       radare2 with a GUI
    imhex        hex editor with patterns for file formats
    jadx-gui     Java / APK
    geany        light editor for notes and decompiled C#
    r2, rabin2, objdump, readelf, binwalk, exiftool
                 quick look from the terminal

Cutter and ImHex are AppImages and run in extract-and-run mode (no FUSE
needed). If one reports a missing library, add the package to
PROFILE_decompile_DNF and rebuild.


6  Delphi / C++Builder
----------------------

There are two layers: names, which come automatically from TD32 debug info
when the binary still has it, and types, which you apply once the evidence
confirms them.

Names

    td32_ghidra.py check target/App.exe     # TD32 (FB09) there? how many?
    td32_ghidra.py extract target/App.exe s.json     # optional: as JSON
    td32-import target/App.exe              # Ghidra project, real names
    exportjson.sh target/App.exe out.json
    outq info                               # "qualified" > 0: names arrived

td32-import takes an optional project directory as a second argument, and
--skip-analysis to reuse an already analyzed project. If outq info reports
0 qualified names, use the live loop (section 5) on the project that
td32-import created.

Reading Delphi code

  - Arguments are passed in registers EAX, EDX, ECX. In a method, EAX is
    Self.
  - Every object (TObject) starts at offset 0 with a pointer to its class
    table (VMT).
  - Strings and dynamic arrays point at their first element. The header
    sits before the data:

        Layout            Length     Reference count
        32-bit            at -4      at -8
        64-bit (usual)    at -8      at -16

    Trust what you measure in the binary over this table, and confirm it
    against calls to DynArraySetLength.

Types to apply in the live loop

Set these with set_function_prototype only after the call pattern confirms
the arguments. Delphi names are shown; Free Pascal uses fpc_*.

    DynArraySetLength(void** a, void* typeInfo, intptr dims, intptr* lens)
    RaiseExcept(TObject* exc)
    GetMem(int size)


7  Native Linux binaries
------------------------

Linux programs and libraries can run inside the sandbox, so you can watch
what they really do instead of relying on pseudocode alone.

    readelf -d target/lib.so            # which libraries it needs
    readelf --dyn-syms target/lib.so    # exported functions: entry points
    strace -f ./target/program          # system calls
    ltrace ./target/program             # library calls
    gdb ./target/program                # breakpoints, memory

You can also call a library function directly from Python (ctypes) and
compare its output with your own version. That is the strongest proof that
you understood it.

Only run binaries you trust enough to run in this container, and never on
the host.


8  The rule: evidence first
---------------------------

  - Back every claim with an address or a line of pseudocode. No evidence,
    no claim.
  - Names such as FUN_00401a30, uVar1 and undefined4 are generated and
    mean nothing. Reason from what the code does, who calls it, and what
    data it uses.
  - Read constants from their values, not from guesses about them.
  - Keep guesses based on names or strings in a separate
    "Hypotheses (unverified)" section until something confirms them.

The full rules are in CLAUDE.md, which Claude Code loads automatically in
every project.


9  If something goes wrong
--------------------------

A script says Ghidra or Java is missing

    Rebuild the profile. Check "echo $GHIDRA_INSTALL_DIR" and
    "java -version".

unfreeze-python.sh produces empty .py files

    The Python version is too new for the decompiler. Read the bytecode
    instead: pycdas file.pyc

A GUI tool reports a missing library

    Add the package to PROFILE_decompile_DNF and rebuild.

Diagrams in architecture.html show as text

    The Mermaid library was not downloaded when the image was built (look
    for a WARN line in the build log). With internet access the page loads
    it from a CDN.

Claude states something without an address

    Ask for the evidence. It is a rule in CLAUDE.md.

The GhidraMCP plugin is missing after a build

    Build it by hand:

        pip install --break-system-packages uv
        git clone https://github.com/bethington/ghidra-mcp && cd ghidra-mcp
        python3 -m tools.setup ensure-prereqs --ghidra-path /opt/ghidra
        python3 -m tools.setup build
        sudo unzip -o target/GhidraMCP-*.zip -d /opt/ghidra/Ghidra/Extensions
        pip install --break-system-packages .
