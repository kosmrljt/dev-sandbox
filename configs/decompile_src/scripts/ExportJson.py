# ExportJson.py — PyGhidra script: emit the whole program as structured JSON.
#
# One object per function: namespace-qualified name ("name"; "short" is the bare
# name), signature, call-graph edges, referenced strings/data (addr + value) and
# the decompiled pseudocode. External functions (imports) are included with
# is_external=true and no pseudocode, so `outq imports` and `outq sql` see them
# for ELF and PE alike. Read with outq; run through exportjson.sh.
#
# Short strings that Ghidra leaves undefined (DAT_* holding "%s", "(%s)", " gid=%ju")
# are read from memory and listed under "strings" with type "cstring?" (guessed),
# so `outq strings` and `outq sql` see them; they stay in data_refs as well.
#
# Next to <output.json> it writes <output>.asm.json: {"<name>@<address>": [lines]},
# the disassembly with Ghidra's names (CALL print_group, not CALL 0x104e80); read it
# with `outq asm`. It is a separate file so that outq does not load it for every query.
#
# Args: <output.json>

import json
from ghidra.app.decompiler import DecompInterface
from ghidra.program.model.listing import CodeUnitFormat
from ghidra.util.task import ConsoleTaskMonitor

args = getScriptArgs()
outpath = args[0] if args else "/work/functions.json"

prog = currentProgram
listing = prog.getListing()
refmgr = prog.getReferenceManager()
monitor = ConsoleTaskMonitor()

decomp = DecompInterface()
decomp.openProgram(prog)
memory = prog.getMemory()
CSTR_MAX = 512


def guess_cstring(addr):
    """Text at addr if it reads as a NUL-terminated string of printable ASCII
    (tab/newline allowed) of at least 2 characters in an initialized, non-executable
    block; else None. Used only for data Ghidra did not define as a string."""
    blk = memory.getBlock(addr)
    if blk is None or not blk.isInitialized() or blk.isExecute():
        return None
    out = []
    try:
        a = addr
        for _ in range(CSTR_MAX):
            b = memory.getByte(a) & 0xFF
            if b == 0:
                break
            if not (32 <= b < 127 or b in (9, 10, 13)):
                return None
            out.append(chr(b))
            a = a.next()
        else:
            return None
    except Exception:
        return None
    return "".join(out) if len(out) >= 2 else None


def refs(func):
    strings = []
    datas = []
    seen = set()
    for addr in func.getBody().getAddresses(True):
        for r in refmgr.getReferencesFrom(addr):
            to = r.getToAddress()
            if to is None or to in seen:
                continue
            d = listing.getDataAt(to)
            if d is None:
                continue
            seen.add(to)
            dt = str(d.getDataType())
            try:
                val = d.getValue()
            except:
                val = None
            entry = {"addr": str(to), "type": dt,
                     "value": (str(val) if val is not None else None)}
            low = dt.lower()
            if "string" in low or "char" in low or "unicode" in low:
                strings.append(entry)
            else:
                entry["label"] = d.getLabel()
                datas.append(entry)
                if low.startswith("undefined") or low in ("byte", "char"):
                    txt = guess_cstring(to)
                    if txt is not None:
                        strings.append({"addr": str(to), "type": "cstring?", "value": txt})
    return strings, datas


fmt = CodeUnitFormat.DEFAULT


def disasm(func):
    lines = []
    for ins in listing.getInstructions(func.getBody(), True):
        try:
            text = fmt.getRepresentationString(ins)
        except Exception:
            text = str(ins)
        lines.append("%s  %s" % (ins.getAddress(), text))
    return lines


def qname(f):
    """Namespace-qualified name (Unit::Class::Method); plain name for globals."""
    try:
        return f.getName(True)
    except:
        return f.getName()


out = []
asm = {}
fm = prog.getFunctionManager()
for func in fm.getFunctions(True):
    strings, datas = refs(func)
    asm[qname(func) + "@" + str(func.getEntryPoint())] = disasm(func)
    res = decomp.decompileFunction(func, 60, monitor)
    code = res.getDecompiledFunction().getC() if (res and res.decompileCompleted()) else None
    out.append({
        "name": qname(func),          # qualified, so same-named methods stay distinct
        "short": func.getName(),
        "address": str(func.getEntryPoint()),
        "signature": str(func.getSignature()),
        "is_thunk": func.isThunk(),
        "is_external": func.isExternal(),
        "callers": sorted(set(qname(c) for c in func.getCallingFunctions(monitor))),
        "callees": sorted(set(qname(c) for c in func.getCalledFunctions(monitor))),
        "strings": strings,
        "data_refs": datas,
        "pseudocode": code,
    })

for func in fm.getExternalFunctions():
    out.append({
        "name": qname(func),
        "short": func.getName(),
        "address": str(func.getEntryPoint()),
        "signature": str(func.getSignature()),
        "is_thunk": False,
        "is_external": True,
        "callers": sorted(set(qname(c) for c in func.getCallingFunctions(monitor))),
        "callees": [],
        "strings": [],
        "data_refs": [],
        "pseudocode": None,
    })

f = open(outpath, "w")
json.dump(out, f, indent=1)
f.close()
asmpath = (outpath[:-5] if outpath.endswith(".json") else outpath) + ".asm.json"
f = open(asmpath, "w")
json.dump(asm, f)
f.close()
print("Exported %d functions to %s (disassembly: %s)" % (len(out), outpath, asmpath))
