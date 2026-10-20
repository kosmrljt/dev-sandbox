# ContextPack.py — Ghidra post-script: emit GROUNDED context packs per function.
#
# For each function it writes: signature, callers, callees, referenced strings
# and data/globals (with real addresses + values), and the decompiled C. This
# gives an AI evidence to reason from the actual code and data-flow — not from
# function names or strings alone.
#
# Args: <output.md> [name_substring_filter]
#   e.g. -postScript ContextPack.py /work/out.md parse_header

from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor

args = getScriptArgs()
outpath = args[0] if len(args) >= 1 else "/work/context.md"
name_filter = args[1] if len(args) >= 2 else None

prog = currentProgram
listing = prog.getListing()
refmgr = prog.getReferenceManager()
monitor = ConsoleTaskMonitor()

decomp = DecompInterface()
decomp.openProgram(prog)


def refs_in_function(func):
    """Collect data/string references made from inside a function body."""
    strings = []
    datas = []
    seen = set()
    for addr in func.getBody().getAddresses(True):
        for ref in refmgr.getReferencesFrom(addr):
            to = ref.getToAddress()
            if to is None or to in seen:
                continue
            d = listing.getDataAt(to)
            if d is None:
                continue
            seen.add(to)
            dt = str(d.getDataType())
            label = d.getLabel()
            try:
                val = d.getValue()
            except:
                val = None
            if "string" in dt.lower() or "char" in dt.lower():
                strings.append((to, val))
            else:
                datas.append((to, dt, label, val))
    return strings, datas


f = open(outpath, "w")
try:
    f.write("# Grounded context pack: %s\n\n" % prog.getName())
    f.write("Reason from the code and the referenced data below. "
            "Addresses are ground truth; names may be auto-generated.\n\n")

    for func in prog.getFunctionManager().getFunctions(True):
        if name_filter and name_filter not in func.getName():
            continue

        f.write("## %s  @ %s\n\n" % (func.getName(), func.getEntryPoint()))
        f.write("Signature: `%s`\n\n" % func.getSignature())

        callers = sorted(set(c.getName() for c in func.getCallingFunctions(monitor)))
        callees = sorted(set(c.getName() for c in func.getCalledFunctions(monitor)))
        f.write("Called by: %s\n\n" % (", ".join(callers) or "(no known callers)"))
        f.write("Calls: %s\n\n" % (", ".join(callees) or "(no calls)"))

        strings, datas = refs_in_function(func)
        if strings:
            f.write("Referenced strings:\n")
            for addr, val in strings:
                f.write("  - %s : %r\n" % (addr, val))
            f.write("\n")
        if datas:
            f.write("Referenced data / globals:\n")
            for addr, dt, label, val in datas:
                f.write("  - %s  %s  %s = %r\n" % (addr, dt, label, val))
            f.write("\n")

        res = decomp.decompileFunction(func, 60, monitor)
        f.write("```c\n")
        if res is not None and res.decompileCompleted():
            f.write(res.getDecompiledFunction().getC())
        else:
            f.write("// [decompile failed]\n")
        f.write("```\n\n---\n\n")
finally:
    f.close()

print("ContextPack written to %s" % outpath)
