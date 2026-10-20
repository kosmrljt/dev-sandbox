#!/usr/bin/env python3
"""
analyze.py — selective AI pass over Ghidra's JSON export.

Reads functions.json (from ExportJson.py), picks a SUBSET of functions
(not everything), and asks Claude to turn each one's grounded pseudocode into
readable, annotated code — reasoning from the code and referenced data, not
from names. Callees are analyzed before callers, and each callee's one-line
summary is fed up to its callers (the "recursive" part).

Selection (choose one; default = non-thunk, non-external functions):
  --seed NAME --depth N   start at NAME, follow callees N levels deep
  --func SUBSTR           only functions whose name contains SUBSTR
  --max N                 cap how many get sent to the API

Examples:
  export ANTHROPIC_API_KEY=sk-...
  analyze.py --in legacy.json --seed main --depth 2 --out review/
  analyze.py --in legacy.json --func parse --out review/
  analyze.py --in legacy.json --seed main --depth 3 --list   # dry run, no API
"""

import argparse
import json
import os
import sys

MODEL_DEFAULT = "claude-sonnet-5-5"   # balanced; --model claude-opus-5-5 for hard targets

SYSTEM = """Si reverse-engineering asistent za native psevdokodo (Ghidra).
Sklepaj IZ PSEVDOKODE in podanih dokazov (podpis, klicatelji, klicane funkcije,
referencirani nizi in podatki z naslovi in vrednostmi) — NE iz imen funkcij ali
spremenljivk; imena kot FUN_..., uVar1, undefined4 so avtomatska in brez pomena.

Za vsako funkcijo vrni v slovenščini:
1. Povzetek (grounded): kaj počne, s sklicem na naslove/vrstice. Konstante beri
   iz podanih vrednosti (npr. DAT = 500 -> meja), ne ugibaj.
2. Berljiva različica: psevdokodo prepiši s smiselnimi imeni spremenljivk/funkcij
   in komentarji. Ohrani logiko; kjer nisi prepričan, označi s TODO.
3. Predlogi tipov/struktur iz vzorca offsetov (base+0x8 ...), z dokazom.
4. Ugibanja iz imen/nizov drži v ločenem razdelku "Hipoteze (nepreverjeno)".

Na KONCU odgovora dodaj točno eno vrstico:
SUMMARY: <en stavek, kaj funkcija počne>
Ta vrstica se uporabi kot kontekst za funkcije, ki to kličejo."""


def build_prompt(fn, callee_summaries):
    parts = []
    parts.append("# Funkcija: %s  @ %s" % (fn["name"], fn["address"]))
    parts.append("Podpis: %s" % fn.get("signature", "?"))
    if fn.get("callers"):
        parts.append("Klicana od: " + ", ".join(fn["callers"]))
    if fn.get("callees"):
        parts.append("Kliče: " + ", ".join(fn["callees"]))
    known = [(c, callee_summaries[c]) for c in fn.get("callees", []) if c in callee_summaries]
    if known:
        parts.append("\nŽe analizirane klicane funkcije (kontekst):")
        for name, summ in known:
            parts.append("  - %s: %s" % (name, summ))
    if fn.get("strings"):
        parts.append("\nReferencirani nizi:")
        for s in fn["strings"]:
            parts.append("  - %s : %s" % (s["addr"], s["value"]))
    if fn.get("data_refs"):
        parts.append("\nReferencirani podatki/globali:")
        for d in fn["data_refs"]:
            parts.append("  - %s  %s  %s = %s" % (d["addr"], d["type"],
                                                  d.get("label", ""), d["value"]))
    parts.append("\nPsevdokoda:\n```c\n%s\n```" % (fn.get("pseudocode") or "// ni na voljo"))
    return "\n".join(parts)


def select(funcs_by_name, args):
    if args.func:
        return [n for n in funcs_by_name if args.func in n]
    if args.seed:
        if args.seed not in funcs_by_name:
            sys.exit("Seed '%s' ni v JSON." % args.seed)
        seen = set()
        frontier = [(args.seed, 0)]
        while frontier:
            n, d = frontier.pop()
            if n in seen or n not in funcs_by_name:
                continue
            seen.add(n)
            if d < args.depth:
                for callee in funcs_by_name[n]["callees"]:
                    frontier.append((callee, d + 1))
        return list(seen)
    # default: skip library stubs
    return [n for n, f in funcs_by_name.items()
            if not f.get("is_thunk") and not f.get("is_external")]


def order_callees_first(selected, funcs_by_name):
    """Topological order so callees come before callers; cycle-safe."""
    sel = set(selected)
    order, visited, temp = [], set(), set()

    def visit(n):
        if n in visited or n not in sel or n in temp:
            return
        temp.add(n)
        for callee in funcs_by_name[n]["callees"]:
            if callee in sel:
                visit(callee)
        temp.discard(n)
        visited.add(n)
        order.append(n)

    for n in selected:
        visit(n)
    return order


def main():
    ap = argparse.ArgumentParser(description="Selective AI pass over Ghidra JSON.")
    ap.add_argument("--in", dest="infile", required=True, help="functions.json from ExportJson.py")
    ap.add_argument("--out", default="review", help="output directory")
    ap.add_argument("--seed", help="start function for recursive selection")
    ap.add_argument("--depth", type=int, default=2, help="callee depth for --seed")
    ap.add_argument("--func", help="only functions whose name contains this")
    ap.add_argument("--max", type=int, default=40, help="cap number sent to API")
    ap.add_argument("--model", default=MODEL_DEFAULT)
    ap.add_argument("--system", help="path to a custom system prompt (e.g. AGENT_PROMPT.md)")
    ap.add_argument("--list", action="store_true", help="print selection and exit (no API calls)")
    args = ap.parse_args()

    with open(args.infile) as f:
        funcs = json.load(f)
    by_name = {fn["name"]: fn for fn in funcs}

    selected = select(by_name, args)
    ordered = order_callees_first(selected, by_name)
    if args.max and len(ordered) > args.max:
        ordered = ordered[:args.max]

    print("Izbranih funkcij: %d" % len(ordered))
    for n in ordered:
        print("  - %s" % n)
    if args.list:
        return

    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("Nastavi ANTHROPIC_API_KEY (ali uporabi --list za suhi tek).")

    try:
        import anthropic
    except ImportError:
        sys.exit("Manjka paket 'anthropic' (pip install anthropic).")

    system = SYSTEM
    if args.system:
        with open(args.system) as f:
            system = f.read()

    client = anthropic.Anthropic()
    os.makedirs(args.out, exist_ok=True)
    summaries = {}
    combined = []

    for i, name in enumerate(ordered, 1):
        fn = by_name[name]
        prompt = build_prompt(fn, summaries)
        print("[%d/%d] %s ..." % (i, len(ordered), name))
        msg = client.messages.create(
            model=args.model,
            max_tokens=4096,
            system=system,
            messages=[{"role": "user", "content": prompt}],
        )
        text = "".join(b.text for b in msg.content if getattr(b, "type", None) == "text")

        for line in text.splitlines():
            if line.strip().startswith("SUMMARY:"):
                summaries[name] = line.split("SUMMARY:", 1)[1].strip()
                break

        safe = name.replace("/", "_")
        with open(os.path.join(args.out, safe + ".md"), "w") as fo:
            fo.write("# %s @ %s\n\n%s\n" % (name, fn["address"], text))
        combined.append("## %s @ %s\n\n%s" % (name, fn["address"], text))

    with open(os.path.join(args.out, "review.md"), "w") as fo:
        fo.write("\n\n---\n\n".join(combined))
    with open(os.path.join(args.out, "summaries.json"), "w") as fo:
        json.dump(summaries, fo, indent=2, ensure_ascii=False)

    print("\nKončano. Rezultati v: %s/  (review.md, summaries.json, <funkcija>.md)" % args.out)


if __name__ == "__main__":
    main()
