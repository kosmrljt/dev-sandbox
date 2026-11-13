#!/usr/bin/env python3
"""archdoc.py - check ARCHITECTURE.md and render it as a web page.

  archdoc.py --check   structure, statuses, evidence, names vs out.json / modules.json
  archdoc.py --html    check, then write map/architecture.html (Markdown + Mermaid)

Options: --doc ARCHITECTURE.md --export out.json --modules map/modules.json
         --out map/architecture.html

Sections are found by number ("## 1." ... "## 9."), so the prose may be in any
language. ERRORs exit with code 2; WARNINGs are printed but do not fail.
"""

import argparse
import html
import json
import os
import re
import sys

REQUIRED = {1: "Summary", 2: "Context", 3: "Archetype", 4: "Components", 5: "Runtime",
            6: "Data", 7: "Notable details", 8: "Hypotheses and open questions", 9: "Next steps"}
MERMAID_TYPES = ("flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram",
                 "stateDiagram-v2", "erDiagram", "block-beta", "packet-beta")
STATUS = re.compile(r"\[(C|H)\]")
FUNC = re.compile(r"`([A-Za-z_@?$][\w@?$:.]*)`\s*@\s*(0x[0-9a-fA-F]+)")
AUTO = re.compile(r"\b(FUN|thunk_FUN|LAB|DAT)_[0-9a-fA-F]{6,16}\b")


def sections(text):
    """{number: (title, body)} for '## N. Title' headings."""
    out, cur, buf = {}, None, []
    for line in text.splitlines():
        m = re.match(r"^##\s+(\d+)\.\s*(.*)$", line)
        if m:
            if cur:
                out[cur[0]] = (cur[1], "\n".join(buf))
            cur, buf = (int(m.group(1)), m.group(2).strip()), []
        elif cur:
            buf.append(line)
    if cur:
        out[cur[0]] = (cur[1], "\n".join(buf))
    return out


def subsections(body):
    """[(title, body)] for '### ...' headings inside a section."""
    parts = re.split(r"^###\s+", body, flags=re.M)
    res = []
    for p in parts[1:]:
        title, _, rest = p.partition("\n")
        res.append((title.strip(), rest))
    return res


def mermaid_blocks(text):
    return re.findall(r"^```mermaid\s*\n(.*?)^```", text, flags=re.M | re.S)


def check(doc, export_names, module_ids):
    errs, warns = [], []
    secs = sections(doc)
    if not doc.lstrip().startswith("# "):
        errs.append("first line must be the title '# Architecture: <program>'")
    for n, name in REQUIRED.items():
        if n not in secs:
            errs.append("missing section '## %d. %s'" % (n, name))
        elif not secs[n][1].strip():
            errs.append("section %d (%s) is empty" % (n, name))

    blocks = mermaid_blocks(doc)
    for i, b in enumerate(blocks, 1):
        first = b.strip().split(None, 1)[0] if b.strip() else ""
        if first not in MERMAID_TYPES:
            errs.append("mermaid block %d starts with '%s' (expected one of: %s)"
                        % (i, first, ", ".join(MERMAID_TYPES)))
        boxes = len(set(re.findall(r"\b([A-Za-z_][\w]*)\s*[\[\(\{>]", b)))
        if boxes > 14:
            warns.append("mermaid block %d has ~%d nodes; keep diagrams to ~12" % (i, boxes))
    for n, label in ((2, "context"), (4, "components")):
        if n in secs and not mermaid_blocks(secs[n][1]):
            errs.append("section %d needs a %s diagram (```mermaid)" % (n, label))
    if 5 in secs and "sequenceDiagram" not in secs[5][1]:
        errs.append("section 5 needs at least one sequenceDiagram (start-up)")

    if 3 in secs and not STATUS.search(secs[3][1]):
        errs.append("section 3: archetype statement needs [C] or [H]")

    if 4 in secs:
        comps = subsections(secs[4][1])
        if not 3 <= len(comps) <= 10:
            warns.append("section 4 has %d components (aim for 3 to 10)" % len(comps))
        for title, body in comps:
            if not STATUS.search(title):
                errs.append("component '%s': add [C] or [H] to its heading" % title)
            for key in ("Responsibility:", "How it works:", "Evidence:"):
                if key not in body:
                    errs.append("component '%s': missing '%s'" % (title, key))
            ev = re.search(r"Evidence:\s*(.*)", body)
            if ev and ev.group(1).strip() in ("", "-", "...", "TODO"):
                errs.append("component '%s': evidence is empty" % title)
            m = re.search(r"(?:re-map|archmap) module:\s*`?([\w-]+)`?", body)   # old label still accepted
            if m and module_ids is not None and m.group(1) not in ("-",) and m.group(1) not in module_ids:
                warns.append("component '%s': re-map module '%s' not in modules.json"
                             % (title, m.group(1)))

    if 1 in secs:
        sentences = len(re.findall(r"[.!?](\s|$)", secs[1][1].strip()))
        if sentences > 7:
            warns.append("summary has ~%d sentences (aim for 3 to 5)" % sentences)

    if export_names is not None:
        seen = set()
        for name, addr in FUNC.findall(doc):
            seen.add(name)
            if name not in export_names:
                warns.append("`%s` @ %s: no function with that name in out.json "
                             "(renamed later? re-export)" % (name, addr))
        for m in sorted(set(x.group(0) for x in AUTO.finditer(doc))):
            if m.startswith(("FUN_", "thunk_FUN_")) and m not in export_names and m not in seen:
                warns.append("%s not in out.json" % m)

    if len(STATUS.findall(doc)) == 0:
        errs.append("no [C]/[H] status anywhere")
    return errs, warns


def lib_tag(filename, cdn_url, embedded):
    """<script> for a library: embedded from vendor/ when the file is there (works
    offline), otherwise a link to the same version on a CDN."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor", filename)
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            embedded.append(filename)
            return "<script>" + f.read().replace("</script", "<\\/script") + "</script>"
    return '<script src="%s"></script>' % cdn_url


PAGE = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>__TITLE__</title>
__LIBS__
<style>
 body{margin:0;font:15px/1.55 system-ui,sans-serif;color:#222;display:grid;grid-template-columns:240px 1fr}
 nav{position:sticky;top:0;height:100vh;overflow:auto;border-right:1px solid #ddd;padding:16px;font-size:13px;box-sizing:border-box}
 nav a{display:block;color:#1a5fb4;text-decoration:none;margin:3px 0} nav a.sub{margin-left:12px;color:#555}
 main{max-width:960px;padding:24px 40px 80px}
 h1{font-size:24px} h2{font-size:19px;border-bottom:1px solid #eee;padding-bottom:4px;margin-top:36px} h3{font-size:16px;margin-top:24px}
 table{border-collapse:collapse;margin:8px 0;font-size:13px} th,td{border:1px solid #ddd;padding:4px 8px;vertical-align:top;text-align:left} th{background:#f6f6f6}
 code{background:#f3f3f3;padding:0 3px;border-radius:3px;font-size:13px} pre{background:#f6f6f6;padding:10px;overflow:auto}
 .C{background:#dff3e4;border-radius:6px;padding:0 5px;font-size:12px;font-weight:600}
 .H{background:#fdf0d5;border-radius:6px;padding:0 5px;font-size:12px;font-weight:600}
 .mermaid{margin:12px 0;text-align:center} .bar{font-size:12px;color:#666}
</style></head><body>
<nav id="toc"></nav>
<main id="doc"></main>
<script>
const MD = __MD__;
const MAP = __MAP__;
const r = new marked.Renderer();
r.code = function(t, lang){ if (typeof t === 'object') { lang = t.lang; t = t.text; }
  if (lang === 'mermaid') return '<pre class="mermaid">' + t.replace(/</g,'&lt;') + '</pre>';
  return '<pre><code>' + t.replace(/&/g,'&amp;').replace(/</g,'&lt;') + '</code></pre>'; };
let h = marked.parse(MD, {renderer: r});
h = h.replace(/\[(C|H)\]/g, (m, s) => '<span class="' + s + '">' + (s === 'C' ? 'confirmed' : 'hypothesis') + '</span>');
const doc = document.getElementById('doc');
doc.innerHTML = (MAP ? '<p class="bar">Drill down: <a href="index.html">architecture map (functions)</a></p>' : '') + h;
const toc = document.getElementById('toc'); let i = 0;
doc.querySelectorAll('h1,h2,h3').forEach(e => { e.id = 's' + (i++); const a = document.createElement('a');
  a.href = '#' + e.id; a.textContent = e.textContent; if (e.tagName === 'H3') a.className = 'sub'; toc.appendChild(a); });
if (window.mermaid) {
  mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:'neutral'});
  mermaid.run({querySelector:'.mermaid'});
} else {
  doc.insertAdjacentHTML('afterbegin', '<p class="bar">Diagrams are shown as text: the Mermaid library could not be loaded (no internet access and no embedded copy).</p>');
}
</script></body></html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--doc", default="ARCHITECTURE.md")
    ap.add_argument("--export", default="out.json")
    ap.add_argument("--modules", default="map/modules.json")
    ap.add_argument("--out", default="map/architecture.html")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--html", action="store_true")
    a = ap.parse_args()
    if not (a.check or a.html):
        a.check = True

    try:
        with open(a.doc, encoding="utf-8") as f:
            doc = f.read()
    except FileNotFoundError:
        print("archdoc: not found: " + a.doc, file=sys.stderr)
        sys.exit(1)
    names = None
    if os.path.isfile(a.export):
        with open(a.export, encoding="utf-8") as f:
            names = {fn["name"] for fn in json.load(f)}
    mids = None
    if os.path.isfile(a.modules):
        with open(a.modules, encoding="utf-8") as f:
            mids = {m["id"] for m in json.load(f).get("modules", [])}

    errs, warns = check(doc, names, mids)
    for w in warns:
        print("WARNING: " + w)
    for e in errs:
        print("ERROR: " + e)
    if errs:
        sys.exit(2)
    print("archdoc: %s OK (%d warning%s)" % (a.doc, len(warns), "" if len(warns) == 1 else "s"))

    if a.html:
        title = doc.lstrip().splitlines()[0].lstrip("# ").strip()
        embedded = []
        libs = (lib_tag("marked.umd.js", "https://cdn.jsdelivr.net/npm/marked@18.2.0/lib/marked.umd.js", embedded)
                + "\n"
                + lib_tag("mermaid.min.js", "https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js", embedded))
        page = (PAGE.replace("__TITLE__", html.escape(title))
                    .replace("__MD__", json.dumps(doc).replace("</", "<\\/"))
                    .replace("__MAP__", "true" if os.path.isfile(os.path.join(os.path.dirname(a.out) or ".", "index.html")) else "false")
                    .replace("__LIBS__", libs))
        os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(page)
        print("archdoc: wrote " + a.out)
        missing = [n for n in ("marked.umd.js", "mermaid.min.js") if n not in embedded]
        print("archdoc: libraries embedded, the page works offline" if not missing else
              "archdoc: %s linked from a CDN, the page needs internet access" % ", ".join(missing))


if __name__ == "__main__":
    main()
