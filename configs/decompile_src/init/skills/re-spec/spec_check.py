#!/usr/bin/env python3
"""spec_check.py - make sure a description in docs/spec/ does not point into the binary.

Usage: spec_check.py docs/spec/<feature>.md [--export FILE ...]
  default: the exports of all binaries in decompile.yaml (else out.json)

Reports:
  - decompiler names (FUN_..., DAT_..., uVar1, param_1, local_18, ...)
  - "@ 0x..." references and pseudocode line references
  - hex numbers that are a function, string or data address in out.json
    (ordinary values such as sizes, masks and magic numbers are fine)
  - names of the program's own functions from out.json
It does not prescribe the structure of the document.
ERRORs exit with code 2; WARNINGs do not fail.
"""

import json
import os
import re
import sys


def default_exports():
    """Export files of all binaries in decompile.yaml (through outq), else out.json."""
    import subprocess
    try:
        r = subprocess.run(["outq", "path", "--all"], capture_output=True, text=True, timeout=30)
        files = [l.split("\t", 1)[1] for l in r.stdout.splitlines() if "\t" in l] if r.returncode == 0 else []
    except (OSError, subprocess.SubprocessError):
        files = []
    return files or ["out.json"]

DECOMP = re.compile(r"\b(?:thunk_)?(?:FUN|DAT|LAB|SUB|PTR|BYTE|WORD|DWORD|QWORD|switchD)_[0-9a-fA-F]{4,}\w*"
                    r"|(?<![\w])[a-z]{0,3}_?Var\d+\b|\bparam_\d+\b|\blocal_(?:res)?[0-9a-fA-F]+\b"
                    r"|\b(?:extraout|unaff)_[A-Za-z0-9_]+\b|\bin_(?:stack_[0-9a-fA-F]+|[A-Z][A-Z0-9_]*)\b"
                    r"|\b[a-z]{1,3}Stack_[0-9a-fA-F]+\b|\bs_\w+_[0-9a-fA-F]{8}\b"
                    r"|\bundefined[1248]\b|\bCONCAT\d+\b|\bSUB\d+\b|\bZEXT\d+\b|\bSEXT\d+\b")
HEX = re.compile(r"\b0x([0-9a-fA-F]{4,16})\b")
# names too ordinary to count as a leak when they appear as a normal word
COMMON = {"main", "entry", "start", "init", "open", "close", "read", "write", "send", "recv", "copy",
          "free", "alloc", "reset", "update", "process", "error", "check", "parse", "print", "exit",
          "run", "stop", "load", "save", "next", "find", "sort", "show", "draw", "clear", "flush"}


def main():
    args = sys.argv[1:]
    exports = []
    while "--export" in args:
        i = args.index("--export")
        exports.append(args[i + 1])
        del args[i:i + 2]
    if not exports:
        exports = default_exports()
    if len(args) != 1:
        print(__doc__)
        sys.exit(1)
    try:
        text = open(args[0], encoding="utf-8").read()
    except FileNotFoundError:
        sys.exit("spec_check: not found: " + args[0])
    errs, warns = [], []

    def where(pattern):
        for n, line in enumerate(text.splitlines(), 1):
            if re.search(pattern, line):
                return " (line %d)" % n
        return ""

    for m in sorted(set(x.group(0) for x in DECOMP.finditer(text))):
        errs.append("decompiler name '%s'%s" % (m, where(re.escape(m))))
    if re.search(r"@\s*0x[0-9a-fA-F]+", text):
        errs.append("'@ 0x...' address reference" + where(r"@\s*0x[0-9a-fA-F]+"))
    if re.search(r"\b(pseudocode|decompil\w*) line\b|\bL\d+-\d+\b", text, re.I):
        errs.append("reference to pseudocode lines")

    found = [e for e in exports if os.path.isfile(e)]
    if found:
        funcs = [f for e in found for f in json.load(open(e, encoding="utf-8"))]
        addrs, names = set(), set()
        for f in funcs:
            if f.get("address"):
                addrs.add(f["address"].lower().lstrip("0"))
            for r in f.get("strings", []) + f.get("data_refs", []):
                if r.get("addr"):
                    addrs.add(str(r["addr"]).lower().lstrip("0"))
            if not f.get("is_thunk") and not f.get("is_external"):
                for n in (f.get("name"), f.get("short")):
                    if n and len(n) >= 4 and n.lower() not in COMMON:
                        names.add(n)
        for h in sorted(set(HEX.findall(text))):
            if h.lower().lstrip("0") in addrs:
                errs.append("0x%s is an address in the binary; give the value, not the location%s"
                            % (h, where(r"\b0x%s\b" % h)))
        for n in sorted(names, key=len, reverse=True):
            pat = r"(?<![\w.])%s(?![\w.])" % re.escape(n)
            if re.search(pat, text):
                errs.append("name from the binary: '%s'; use your own name%s" % (n, where(pat)))
    else:
        warns.append("%s not found: names and addresses from the binary were not checked" % ", ".join(exports))

    if not re.search(r"^Based on:", text, re.M):
        warns.append("no 'Based on:' line saying which project documents this was written from")
    if "unverified" not in text.lower():
        warns.append("nothing is marked unverified and there is no 'Unknown and unverified' section")

    for w in warns:
        print("WARNING: " + w)
    for e in errs:
        print("ERROR: " + e)
    if errs:
        sys.exit(2)
    print("spec_check: OK - nothing points into the binary (%d warning%s)"
          % (len(warns), "" if len(warns) == 1 else "s"))


if __name__ == "__main__":
    main()
