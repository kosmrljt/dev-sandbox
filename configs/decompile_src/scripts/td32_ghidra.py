#!/usr/bin/env python3
# td32_ghidra.py - procedure names from Borland TD32 debug info (Delphi / C++Builder) -> Ghidra.
#@author td32
#@category Delphi
#@runtime PyGhidra
#
# TD32 is an "FB09" block appended to the end of the .exe (Borland/Embarcadero). It holds every
# procedure (S_LPROC32/S_GPROC32: segment, offset, size, name). Segment N = the N-th PE section
# (segment N maps to the N-th PE section; typically seg1 = .text, seg2 = .itext).
#
# IN GHIDRA (Script Manager -> category Delphi; the image already has /opt/scripts on the Ghidra
# script path, so this script shows up there):
#   - reads TD32 from the program's original file (path from the project, otherwise it asks);
#   - turns Borland names  @Unit@Class@Method$<params>  into namespace Unit::Class, name Method;
#   - creates missing functions (body size taken from TD32), renames existing ones;
#     a name you set by hand (USER_DEFINED) is kept, and the TD32 name is added as an extra label;
#   - stamps a plate comment with the original name.
#   Arguments (headless): [path_to_exe | json=symbols.json] [dry] [overwrite]
#
# NOTE: running a PyGhidra .py script from the GUI Script Manager needs Ghidra launched in
# PyGhidra mode. The headless `td32-import` wrapper (which uses the `pyghidra` launcher) is the
# reliable path and needs no GUI.
#
# WITHOUT GHIDRA (plain python3):
#   td32_ghidra.py extract program.exe symbols.json   # export to JSON (addr, size, name, mod)
#   td32_ghidra.py check   program.exe                # has TD32? how many procs? parse self-test
#
# See also: td32-import (headless import + rename into a fresh Ghidra project).

import json
import struct

CREATE_MISSING = True    # create functions Ghidra did not find
SET_COMMENTS = True      # stamp a plate comment with the original name


# ---------------------------------------------------------------------------------------------
# TD32 and PE - pure Python
# ---------------------------------------------------------------------------------------------

def pe_sections(b):
    """Return (image_base, [section VAs in order]) from the PE header."""
    if b[:2] != b'MZ':
        raise ValueError('not a PE (MZ)')
    pe = struct.unpack_from('<I', b, 0x3c)[0]
    if b[pe:pe + 4] != b'PE\0\0':
        raise ValueError('no PE signature')
    nsec = struct.unpack_from('<H', b, pe + 6)[0]
    optsz = struct.unpack_from('<H', b, pe + 20)[0]
    magic = struct.unpack_from('<H', b, pe + 24)[0]
    base = struct.unpack_from('<Q' if magic == 0x20b else '<I', b, pe + 24 + (24 if magic == 0x20b else 28))[0]
    vas = [base + struct.unpack_from('<I', b, pe + 24 + optsz + 40 * i + 12)[0] for i in range(nsec)]
    return base, vas


def td32_procs(b):
    """List of procedures from TD32: dict(seg, ofs, size, name, mod)."""
    if b[-8:-4] != b'FB09':
        raise ValueError('no TD32 debug info (FB09) at end of file')
    base = len(b) - struct.unpack_from('<I', b, len(b) - 4)[0]
    if b[base:base + 4] != b'FB09':
        raise ValueError('corrupt TD32 pointer')
    dir_off = base + struct.unpack_from('<I', b, base + 4)[0]
    cbh, cbe, cdir = struct.unpack_from('<HHI', b, dir_off)
    ents = []
    for i in range(cdir):
        sst, imod, lfo, cb = struct.unpack_from('<HHII', b, dir_off + cbh + i * cbe)
        ents.append((sst, imod, base + lfo, cb))
    names = [None]
    for sst, _, off, _ in ents:
        if sst == 0x130:                                  # sstNames
            n = struct.unpack_from('<I', b, off)[0]
            p = off + 4
            for _ in range(n):
                ln = b[p]
                names.append(b[p + 1:p + 1 + ln].decode('latin1'))
                p += ln + 2
    procs = []
    for sst, imod, off, cb in ents:
        if sst != 0x125:                                  # sstAlignSym
            continue
        p, end = off + 4, off + cb
        while p < end:
            ln, typ = struct.unpack_from('<HH', b, p)
            if ln == 0:
                break
            if typ in (0x204, 0x205):                     # S_LPROC32 / S_GPROC32
                size = struct.unpack_from('<I', b, p + 16)[0]
                ofs, seg = struct.unpack_from('<IH', b, p + 28)
                nidx = struct.unpack_from('<I', b, p + 40)[0]
                nm = names[nidx] if 0 < nidx < len(names) else None
                if nm:
                    procs.append(dict(seg=seg, ofs=ofs, size=size, name=nm, mod=imod))
            p += ln + 2
    return procs


def resolve(b, procs):
    """Add 'va' (int or None) based on PE sections."""
    _, vas = pe_sections(b)
    for pr in procs:
        s = pr['seg']
        pr['va'] = vas[s - 1] + pr['ofs'] if 1 <= s <= len(vas) else None
    return procs


def load_json(path):
    """JSON from an older td32_symbols.py ("addr": "00405384" or "seg2:14c") or from 'extract'."""
    out = []
    for s in json.load(open(path)):
        a = s.get('addr')
        if isinstance(a, str) and a.startswith('seg'):
            seg, ofs = a[3:].split(':')
            out.append(dict(seg=int(seg), ofs=int(ofs, 16), size=s.get('size', 0), name=s['name'],
                            mod=s.get('mod', 0), va=None))
        else:
            out.append(dict(seg=s.get('seg', 0), ofs=s.get('ofs', 0), size=s.get('size', 0), name=s['name'],
                            mod=s.get('mod', 0), va=int(a, 16) if isinstance(a, str) else s.get('va')))
    return out


# ---------------------------------------------------------------------------------------------
# Parsing Borland (Delphi) names
# ---------------------------------------------------------------------------------------------

def _scan_template(s, i):
    """s[i] == '%'. Return the index past the closing '%'. Nested names inside arguments are
    written with a length prefix (e.g. 15Myunit@TMyClass, 44System@%DelphiInterface$...%), so they
    are skipped by that length."""
    n = len(s)
    j = s.find('$', i + 1)                    # %Name$args%
    close = s.find('%', i + 1)
    if j < 0 or (0 <= close < j):
        return close + 1 if close >= 0 else n
    j += 1
    while j < n:
        c = s[j]
        if c == '%':
            return j + 1
        if c.isdigit():
            k = j
            while k < n and s[k].isdigit():
                k += 1
            ln = int(s[j:k])
            # it is a length prefix only if a name follows and it stays inside the string
            # (t1, i0, i255 are not lengths)
            if ln > 0 and k < n and (s[k].isalpha() or s[k] in '_@') and k + ln <= n:
                j = k + ln
            else:
                j = k
            continue
        j += 1
    return n


def split_top(s):
    """Split on '@' outside templates %...% up to the start of parameters (the first '$' outside
    a template that is not at the start of a part - '$bctr'/'$bdtr' are names). Returns
    (parts[], params_or_None)."""
    parts, cur, i, n = [], [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '%':
            e = _scan_template(s, i)
            cur.append(s[i:e])
            i = e
            continue
        if c == '$':
            if not cur:                       # $bctr / $bdtr: name up to the next '$'
                e = s.find('$', i + 1)
                e = n if e < 0 else e
                cur.append(s[i:e])
                i = e
                continue
            parts.append(''.join(cur))
            return parts, s[i + 1:]
        if c == '@':
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    parts.append(''.join(cur))
    return parts, None


def _clean_template(p):
    """%TList__1$p15Myunit@TMyClass%  ->  TList__1<p15Myunit.TMyClass>"""
    if not (p.startswith('%') and p.endswith('%') and len(p) > 1):
        return p
    body = p[1:-1]
    k = body.find('$')
    if k < 0:
        return body
    return '%s<%s>' % (body[:k], body[k + 1:].replace('@', '.').replace('%', ''))


def _sanitize(x):
    x = x.replace(' ', '_').replace('::', '.')
    return x or '_'


def parse_borland(mangled):
    """Return (namespace[], name, params_or_None).
    '@Myunit@TMyClass@DrawItem$qqrv'        -> (['Myunit', 'TMyClass'], 'DrawItem', 'qqrv')
    '@System@@GetMem$qqri'                  -> (['System'], '@GetMem', 'qqri')      (compiler helper)
    '@System@Rtti@TPrivateHeap@$bctr$qqrv'  -> (['System','Rtti','TPrivateHeap'], '$bctr', 'qqrv')
    '@System@Sysutils@TLanguages@Create@'   -> (['System','Sysutils','TLanguages'], 'Create@', None)
    'IsValidVMTAddress'                     -> ([], 'IsValidVMTAddress', None)"""
    if not mangled.startswith('@'):
        return [], _sanitize(mangled), None
    parts, params = split_top(mangled[1:])
    last = parts[-1]
    ns = parts[:-1]
    if ns and ns[-1] == '':                   # '@@Name'
        ns = ns[:-1]
        last = '@' + last
    if last == '' and ns:                     # '@Class@Create@' (in .itext; likely class constructor)
        last = ns.pop() + '@'
    ns = [_sanitize(_clean_template(p)) for p in ns if p != '']
    return ns, _sanitize(_clean_template(last)), params


def suspicious(ns, nm):
    return not nm or nm == '_' or '%' in nm or any('%' in p or '@' in p[1:] for p in ns)


# ---------------------------------------------------------------------------------------------
# Ghidra
# ---------------------------------------------------------------------------------------------

def _ghidra_run():
    import os
    from ghidra.program.model.symbol import SourceType
    from ghidra.program.model.address import AddressSet
    from ghidra.program.model.listing import CodeUnit

    args = [str(a) for a in getScriptArgs()]
    dry = 'dry' in args
    overwrite = 'overwrite' in args
    args = [a for a in args if a not in ('dry', 'overwrite')]

    prog = currentProgram
    if args and args[0].startswith('json='):
        procs = load_json(args[0][5:])
        src = args[0][5:]
    else:
        path = args[0] if args else prog.getExecutablePath()
        if not path or not os.path.isfile(path):
            path = askFile('Original .exe file (with TD32)', 'Choose').getAbsolutePath()
        b = open(path, 'rb').read()
        procs = resolve(b, td32_procs(b))
        src = path
    print('TD32: %d procedures from %s' % (len(procs), src))

    fm = prog.getFunctionManager()
    st = prog.getSymbolTable()
    listing = prog.getListing()
    space = prog.getAddressFactory().getDefaultAddressSpace()
    mem = prog.getMemory()
    gns = prog.getGlobalNamespace()
    ns_cache = {}

    def get_ns(parts):
        parent = gns
        for i, p in enumerate(parts):
            k = tuple(parts[:i + 1])
            if k not in ns_cache:
                ex = st.getNamespace(p, parent)
                ns_cache[k] = ex if ex is not None else st.createNameSpace(parent, p, SourceType.IMPORTED)
            parent = ns_cache[k]
        return parent

    stat = dict(renamed=0, created=0, kept_user=0, same=0, no_address=0, failed=0)
    fails = []
    monitor.initialize(len(procs))
    monitor.setMessage('TD32 import')

    for pr in procs:
        if monitor.isCancelled():
            break
        monitor.incrementProgress(1)
        mangled = pr['name']
        if pr.get('va') is None:
            stat['no_address'] += 1
            continue
        addr = space.getAddress(pr['va'])
        if not mem.contains(addr):
            stat['no_address'] += 1
            continue
        try:
            ns_parts, name, _ = parse_borland(mangled)
        except Exception:  # noqa: BLE001
            ns_parts, name = [], _sanitize(mangled)
        if dry:
            print('%08x  %s :: %s' % (pr['va'], '::'.join(ns_parts) or '<global>', name))
            continue
        try:
            ns = get_ns(ns_parts) if ns_parts else gns
            fn = fm.getFunctionAt(addr)
            if fn is None:
                if not CREATE_MISSING:
                    stat['failed'] += 1
                    fails.append((pr['va'], mangled, 'no function'))
                    continue
                if listing.getInstructionAt(addr) is None:
                    disassemble(addr)
                size = int(pr.get('size') or 0)
                if size > 0:
                    try:
                        fn = fm.createFunction(name, ns, addr, AddressSet(addr, addr.add(size - 1)),
                                               SourceType.IMPORTED)
                    except Exception:  # noqa: BLE001  (overlap with an existing function, etc.)
                        fn = None
                if fn is None:
                    fn = createFunction(addr, name)
                    if fn is not None:
                        fn.setParentNamespace(ns)
                        fn.setName(name, SourceType.IMPORTED)
                if fn is None:
                    stat['failed'] += 1
                    fails.append((pr['va'], mangled, 'createFunction failed'))
                    continue
                stat['created'] += 1
            else:
                sym = fn.getSymbol()
                if sym.getName() == name and fn.getParentNamespace().equals(ns):
                    stat['same'] += 1
                elif sym.getSource() == SourceType.USER_DEFINED and not overwrite:
                    st.createLabel(addr, name, ns, SourceType.IMPORTED)
                    stat['kept_user'] += 1
                else:
                    fn.setParentNamespace(ns)
                    fn.setName(name, SourceType.IMPORTED)
                    stat['renamed'] += 1
            if SET_COMMENTS:
                cu = listing.getCodeUnitAt(addr)
                if cu is not None:
                    tag = 'TD32: %s (size %d, mod %d)' % (mangled, pr.get('size', 0), pr.get('mod', 0))
                    old = cu.getComment(CodeUnit.PLATE_COMMENT)
                    if old is None:
                        cu.setComment(CodeUnit.PLATE_COMMENT, tag)
                    elif 'TD32:' not in old:
                        cu.setComment(CodeUnit.PLATE_COMMENT, old + '\n' + tag)
        except Exception as e:  # noqa: BLE001
            stat['failed'] += 1
            fails.append((pr['va'], mangled, str(e)))

    print('TD32 import: %s' % stat)
    for f in fails[:50]:
        print('  ERROR %08x %s: %s' % f)
    if len(fails) > 50:
        print('  ... %d more errors' % (len(fails) - 50))


def _cli(argv):
    import sys
    if len(argv) < 3 or argv[1] not in ('extract', 'check'):
        print(__doc__ or '', 'Usage:\n  td32_ghidra.py extract program.exe [symbols.json]\n'
              '  td32_ghidra.py check program.exe', file=sys.stderr)
        return 2
    b = open(argv[2], 'rb').read()
    procs = resolve(b, td32_procs(b))
    if argv[1] == 'extract':
        out = argv[3] if len(argv) > 3 else argv[2].rsplit('.', 1)[0] + '_td32.json'
        json.dump([dict(addr='%08x' % p['va'] if p['va'] is not None else 'seg%d:%x' % (p['seg'], p['ofs']),
                        size=p['size'], name=p['name'], mod=p['mod']) for p in procs], open(out, 'w'))
        print('%d procedures -> %s' % (len(procs), out))
        return 0
    from collections import Counter
    bad = [p for p in procs if suspicious(*parse_borland(p['name'])[:2])]
    print('procedures: %d, by segment: %s, without address: %d, suspicious names: %d' % (
        len(procs), dict(Counter(p['seg'] for p in procs)), sum(p['va'] is None for p in procs), len(bad)))
    for p in procs[:3] + bad[:5]:
        print('  %s  %s -> %s' % ('%08x' % p['va'] if p['va'] is not None else '?', p['name'], parse_borland(p['name'])[:2]))
    return 0


try:
    currentProgram  # noqa: B018  (injected in Ghidra/PyGhidra; otherwise NameError)
    _IN_GHIDRA = True
except NameError:
    _IN_GHIDRA = False

if _IN_GHIDRA:
    _ghidra_run()
elif __name__ == '__main__':
    import sys
    sys.exit(_cli(sys.argv))
