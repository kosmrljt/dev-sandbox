Decompile sandbox — guide
==========================

Reverse-engineer old binaries into readable, commented code. Reason from
pseudocode plus evidence (addresses, xrefs, referenced data), never from auto
names. All tools are on PATH; your project dir is mounted at /app/<hash>.


Start a project
---------------

    cd /app/<hash>
    decompile-init          # CLAUDE.md (agent rules) + review/
    decompile-init --mcp    # also .mcp.json + .claude/settings.json (live loop)


Identify, then pick a workflow
------------------------------

    file ./target

  Native C/C++ (ELF or PE)
      exportjson.sh ./target out.json     then run: claude
      (claude reads the JSON and writes its notes into review/)

  One function, readable
      contextpack.sh ./target one.md <name>

  Delphi / C++Builder
      td32-import ./App.exe ./App_ghidra   (real names from TD32; see below)

  .NET / C#
      decompile-dotnet.sh ./App.dll        ->  ./App_cs/

  Frozen Python (PyInstaller, ...)
      unfreeze-python.sh ./app


Live MCP loop (Ghidra + Claude Code)
------------------------------------

Let the agent rename, create structs/types, set prototypes, and re-decompile in
Ghidra until uVar/undefined are gone.

    ghidra-mcp-up           # start Ghidra, wait for :8089, read-only smoke test
    # once in Ghidra: File > Configure > enable GhidraMCP;
    #                 open the binary in a CodeBrowser
    decompile-init --mcp    # .mcp.json + .claude/settings.json
    claude                  # then /mcp  ->  ghidra connected

Read calls (get_*, list_*, find_*, search_*, decompile_*, read_*) run
automatically; every change (create_struct, rename_*, apply_data_type, save_*)
asks first. This is set in .claude/settings.json.

Port is 8089; change it in Ghidra (Edit > Tool Options > GhidraMCP HTTP Server)
and in .mcp.json. If /mcp shows "failed": Ghidra not open, plugin not enabled,
or no program loaded.

Rebuild MCP by hand if the plugin is missing (bethington fork, Maven + JDK 21):

    pip install --break-system-packages uv
    git clone https://github.com/bethington/ghidra-mcp && cd ghidra-mcp
    python3 -m tools.setup ensure-prereqs --ghidra-path /opt/ghidra
    python3 -m tools.setup build
    sudo unzip -o target/GhidraMCP-*.zip -d /opt/ghidra/Ghidra/Extensions
    pip install --break-system-packages .     # provides bridge-mcp-ghidra


Delphi / C++Builder details
---------------------------

Two layers: names (automatic, from TD32 debug symbols) and types (apply with
evidence).

    td32_ghidra.py check ./App.exe           # has TD32 (FB09)? how many procs?
    td32_ghidra.py extract ./App.exe s.json
    td32-import ./App.exe ./App_ghidra [--skip-analysis]    # new project + names

Types to apply via MCP once xrefs/offsets confirm them:

  TObject
      Offset 0 is a pointer to the VMT (class table).

  Dynamic array
      The variable points at element[0]; the header sits BEFORE the data.
      You measured length at -4 (32-bit layout: refcount:i32 @-8, length:i32
      @-4). On 64-bit Delphi it is usually length @-8, refcount @-16 — follow
      your -4 finding, but confirm it against DynArraySetLength calls.

  RTL signatures (Delphi names; FPC uses fpc_*)
      Set with set_function_prototype only after the call pattern confirms the
      arguments, e.g.
          DynArraySetLength(void** a, void* typeInfo, intptr dims, intptr* lens)
          RaiseExcept(TObject* exc)
          GetMem(int size)


VNC desktop + GUI tools
-----------------------

The GUI runs on a VNC desktop at 127.0.0.1:5901 (password $SANDBOX_VNC_PASS,
default "sandbox"). From another machine, tunnel it:

    ssh -L 5901:127.0.0.1:5901 -p 2232 dev@host

  ghidraRun / Ghidra        native decompiler, call graphs (JDK 21)
  cutter                    radare2 GUI
  imhex                     hex editor
  jadx-gui                  Java / APK
  geany                     light editor (review the C# / notes)
  r2, objdump, binwalk, exiftool    CLI triage

AppImages (Cutter/ImHex) run with extract-and-run (no FUSE). If one reports a
missing library, add it to PROFILE_decompile_DNF and rebuild.


Grounding (the rule)
--------------------

Back every claim with an address/line. Read constants from values, not guesses.
Keep name/string guesses in a separate "Hypotheses (unverified)" section. The
full rules are in CLAUDE.md, which Claude Code loads automatically.
