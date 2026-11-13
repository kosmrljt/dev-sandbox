#!/usr/bin/env python3
"""explain_check.py - check an explain/<topic>.md written by the /re-explain skill.

Usage: explain_check.py explain/<topic>.md
       explain_check.py --claims-only <any .md with a claims table>   (used by other skills)

Enforces that the explanation only rests on checked claims:
  - sections "## 1." ... "## 8." exist (found by number, any language)
  - every claim in section 5 has evidence, a check and a result
    (verified | refuted | unverified)
  - the short answer (1) cites only verified claims
  - every step in "How it works" (2) cites at least one claim; never a refuted one;
    an unverified one only when followed by "(unverified)"
  - every refuted claim is explained in Corrections (6)
--claims-only checks any document that has a claims table
(| C1 | claim | evidence | check | result |): rows are complete, every [Cn] cited in
the text exists, the header counts match, and refuted claims are not cited outside
the table.
ERRORs exit with code 2; WARNINGs do not fail.
"""

import re
import sys

REQUIRED = {1: "Short answer", 2: "How it works", 3: "Why it is built this way", 4: "Key data",
            5: "Claims and verification", 6: "Corrections", 7: "What to learn from this",
            8: "Open questions"}
RESULTS = ("verified", "refuted", "unverified")
CITE = re.compile(r"\[(C\d+)\]")
EMPTY = ("", "-", "...", "todo", "n/a", "none")


def sections(text):
    out, cur, buf = {}, None, []
    for line in text.splitlines():
        m = re.match(r"^##\s+(\d+)\.\s*(.*)$", line)
        if m:
            if cur is not None:
                out[cur] = "\n".join(buf)
            cur, buf = int(m.group(1)), []
        elif cur is not None:
            buf.append(line)
    if cur is not None:
        out[cur] = "\n".join(buf)
    return out


def claims_table(body):
    rows = {}
    for line in body.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5 or not re.fullmatch(r"C\d+", cells[0]):
            continue
        rows[cells[0]] = {"claim": cells[1], "evidence": cells[2], "check": cells[3],
                          "result": cells[4].lower().strip("`* ")}
    return rows


def check_rows(claims, errs):
    for cid, c in claims.items():
        if c["result"] not in RESULTS:
            errs.append("%s: result '%s' must be one of %s" % (cid, c["result"], RESULTS))
        if c["evidence"].lower() in EMPTY:
            errs.append("%s: evidence is empty" % cid)
        if c["check"].lower() in EMPTY:
            errs.append("%s: check is empty (say which check, or why none was possible)" % cid)
        if re.search(r"\bre-?read", c["check"], re.I):
            errs.append("%s: re-reading the same code is not an independent check" % cid)


def check_counts(text, claims, errs, warns):
    m = re.search(r"(\d+)\s+verified,\s*(\d+)\s+refuted,\s*(\d+)\s+unverified", text)
    real = tuple(sum(1 for c in claims.values() if c["result"] == r) for r in RESULTS)
    if not m:
        warns.append("header line with 'N verified, N refuted, N unverified' not found")
    elif tuple(int(x) for x in m.groups()) != real:
        errs.append("header counts %s do not match the table %s (verified, refuted, unverified)"
                    % (m.groups(), real))
    return real


def claims_only(text):
    errs, warns = [], []
    claims = claims_table(text)
    if not claims:
        errs.append("no claims table rows found (| C1 | claim | evidence | check | result |)")
        report(errs, warns)
    check_rows(claims, errs)
    prose = "\n".join(l for l in text.splitlines()
                      if not re.match(r"^\|\s*C\d+\s*\|", l.strip()))
    cited = set(CITE.findall(prose))
    for cid in sorted(cited, key=lambda c: int(c[1:])):
        if cid not in claims:
            errs.append("text cites %s, which is not in the claims table" % cid)
        elif claims[cid]["result"] == "refuted":
            errs.append("text cites refuted %s; cite the corrected claim instead" % cid)
    for cid in claims:
        if cid not in cited and claims[cid]["result"] != "refuted":
            warns.append("%s is never cited in the text" % cid)
    real = check_counts(text, claims, errs, warns)
    report(errs, warns, len(claims), real)


def main():
    args = [a for a in sys.argv[1:] if a != "--claims-only"]
    if len(args) != 1:
        print(__doc__)
        sys.exit(1)
    try:
        text = open(args[0], encoding="utf-8").read()
    except FileNotFoundError:
        print("explain_check: not found: " + args[0], file=sys.stderr)
        sys.exit(1)
    if "--claims-only" in sys.argv:
        claims_only(text)

    errs, warns = [], []
    if not text.lstrip().startswith("# "):
        errs.append("first line must be the title '# How <topic> works'")
    secs = sections(text)
    for n, name in REQUIRED.items():
        if n not in secs or not secs[n].strip():
            errs.append("missing or empty section '## %d. %s'" % (n, name))
    if errs:
        report(errs, warns)

    claims = claims_table(secs[5])
    if not claims:
        errs.append("section 5 has no claims table rows (| C1 | claim | evidence | check | result |)")
    check_rows(claims, errs)

    def res(cid):
        return claims.get(cid, {}).get("result")

    for cid in CITE.findall(secs[1]):
        if cid not in claims:
            errs.append("short answer cites %s, which is not in the claims table" % cid)
        elif res(cid) != "verified":
            errs.append("short answer cites %s (%s); use verified claims only" % (cid, res(cid)))
    if not CITE.search(secs[1]):
        errs.append("short answer cites no claims")

    steps = [l for l in secs[2].splitlines() if re.match(r"^\s*\d+\.\s", l)]
    if not steps:
        errs.append("section 2 has no numbered steps")
    for s in steps:
        short = s.strip()[:60]
        cites = CITE.findall(s)
        if not cites:
            errs.append("step without a claim: '%s'" % short)
        for cid in cites:
            if cid not in claims:
                errs.append("step cites unknown %s: '%s'" % (cid, short))
            elif res(cid) == "refuted":
                errs.append("step cites refuted %s: '%s'" % (cid, short))
            elif res(cid) == "unverified" and not re.search(r"\[%s\]\s*\(unverified\)" % cid, s):
                errs.append("step cites unverified %s without '(unverified)' after it: '%s'" % (cid, short))

    for cid in (k for k, v in claims.items() if v["result"] == "refuted"):
        if cid not in secs[6]:
            errs.append("refuted %s is not explained in section 6 (Corrections)" % cid)

    used = set(CITE.findall(text.split("## 5.")[0]))
    for cid in claims:
        if cid not in used and res(cid) != "refuted":
            warns.append("%s is never cited in the explanation" % cid)

    real = check_counts(text, claims, errs, warns)

    report(errs, warns, len(claims), real)


def report(errs, warns, n=0, real=(0, 0, 0)):
    for w in warns:
        print("WARNING: " + w)
    for e in errs:
        print("ERROR: " + e)
    if errs:
        sys.exit(2)
    print("explain_check: OK - %d claims (%d verified, %d refuted, %d unverified), %d warning(s)"
          % ((n,) + real + (len(warns),)))
    sys.exit(0)


if __name__ == "__main__":
    main()
