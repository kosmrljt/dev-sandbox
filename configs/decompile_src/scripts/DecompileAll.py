# DecompileAll.py — Ghidra post-script (runs inside Ghidra's Python/Jython).
# Decompiles every function in the loaded program to C and writes one file.
#
# Invoked by decompile.sh via:  -postScript DecompileAll.py <output.c>

from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor

args = getScriptArgs()
outpath = args[0] if args else "/work/decompiled.c"

decomp = DecompInterface()
decomp.openProgram(currentProgram)
monitor = ConsoleTaskMonitor()

ok = 0
failed = 0

f = open(outpath, "w")
try:
    f.write("// Decompiled from: %s\n" % currentProgram.getName())
    f.write("// Ghidra pseudocode. NOT the original source; read and verify.\n\n")

    functions = currentProgram.getFunctionManager().getFunctions(True)
    for func in functions:
        result = decomp.decompileFunction(func, 60, monitor)
        if result is not None and result.decompileCompleted():
            f.write(result.getDecompiledFunction().getC())
            f.write("\n\n")
            ok += 1
        else:
            f.write("// [decompile failed] %s @ %s\n\n"
                    % (func.getName(), func.getEntryPoint()))
            failed += 1
finally:
    f.close()

print("DecompileAll: %d functions decompiled, %d failed -> %s"
      % (ok, failed, outpath))
