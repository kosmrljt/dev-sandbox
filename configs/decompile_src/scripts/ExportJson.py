# ExportJson.py — Ghidra post-script: emit the whole program as structured JSON.
#
# This is the machine-readable ("API") output: one object per function with its
# signature, call graph edges, referenced strings/data (addr + value), and the
# decompiled pseudocode. analyze.py consumes this to drive selective LLM passes.
#
# Args: <output.json>

import json
from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor

args = getScriptArgs()
outpath = args[0] if args else "/work/functions.json"

prog = currentProgram
listing = prog.getListing()
refmgr = prog.getReferenceManager()
monitor = ConsoleTaskMonitor()

decomp = DecompInterface()
decomp.openProgram(prog)


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
            if "string" in dt.lower() or "char" in dt.lower():
                strings.append(entry)
            else:
                entry["label"] = d.getLabel()
                datas.append(entry)
    return strings, datas


out = []
for func in prog.getFunctionManager().getFunctions(True):
    strings, datas = refs(func)
    res = decomp.decompileFunction(func, 60, monitor)
    code = res.getDecompiledFunction().getC() if (res and res.decompileCompleted()) else None
    out.append({
        "name": func.getName(),
        "address": str(func.getEntryPoint()),
        "signature": str(func.getSignature()),
        "is_thunk": func.isThunk(),
        "is_external": func.isExternal(),
        "callers": sorted(set(c.getName() for c in func.getCallingFunctions(monitor))),
        "callees": sorted(set(c.getName() for c in func.getCalledFunctions(monitor))),
        "strings": strings,
        "data_refs": datas,
        "pseudocode": code,
    })

f = open(outpath, "w")
json.dump(out, f, indent=2)
f.close()
print("Exported %d functions to %s" % (len(out), outpath))
