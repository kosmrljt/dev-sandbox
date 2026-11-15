# ExportJson.py — PyGhidra script: emit the whole program as structured JSON.
#
# One object per function: namespace-qualified name ("name"; "short" is the bare
# name), signature, call-graph edges, referenced strings/data (addr + value) and
# the decompiled pseudocode. External functions (imports) are included with
# is_external=true and no pseudocode, so `outq imports` and `outq sql` see them
# for ELF and PE alike. Read with outq; run through exportjson.sh.
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
            low = dt.lower()
            if "string" in low or "char" in low or "unicode" in low:
                strings.append(entry)
            else:
                entry["label"] = d.getLabel()
                datas.append(entry)
    return strings, datas


def qname(f):
    """Namespace-qualified name (Unit::Class::Method); plain name for globals."""
    try:
        return f.getName(True)
    except:
        return f.getName()


out = []
fm = prog.getFunctionManager()
for func in fm.getFunctions(True):
    strings, datas = refs(func)
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
print("Exported %d functions to %s" % (len(out), outpath))
