# Delphi / C++Builder binaries

Read this when decompile.yaml says `type: delphi`.

## Names

- With TD32 debug info (an "FB09" block at the end of the file) `re init` runs
  `td32-import` before the export, so the export carries the real procedure
  names. Check with `outq -b <id> info`: "qualified" > 0 means the names
  arrived. If it says 0, run `td32-import <id>` and `exportjson.sh <id>` again.
- `td32_ghidra.py check <binary>` shows without Ghidra whether TD32 is there and
  how many procedures it names; `td32_ghidra.py extract <binary> s.json` writes
  them as JSON.
- These are the author's names: they tell which function it is. What it does
  still comes from the code (CLAUDE.md, Evidence).

## Reading the code

- Register calling convention: arguments in EAX, EDX, ECX, the rest on the
  stack. In a method, EAX is Self.
- Every object (TObject) starts at offset 0 with a pointer to its class table
  (VMT).
- Strings and dynamic arrays point at their first element; the header sits
  before the data:

      Layout            Length     Reference count
      32-bit            at -4      at -8
      64-bit (usual)    at -8      at -16

  Trust what you measure in the binary over this table, and confirm it against
  calls to DynArraySetLength.
- Forms (DFM) are in RCDATA resources and name their event handlers: good entry
  points (`rabin2 -U`, or pefile/lief in Python).
- Runtime units (System, SysUtils, Classes; `@LStr*`, `@Halt*`) are library
  code: skip them unless the question is about them.

## Types to apply in the Ghidra window

Only with `ghidra_live` and only after the call pattern confirms the arguments
(set_function_prototype). Delphi names shown; Free Pascal uses fpc_*.

    DynArraySetLength(void** a, void* typeInfo, intptr dims, intptr* lens)
    RaiseExcept(TObject* exc)
    GetMem(int size)
