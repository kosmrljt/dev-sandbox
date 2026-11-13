#!/usr/bin/env python3
"""archmap.py - build an interactive architecture map (one HTML file) of a program.

Deterministic: the same inputs always give the same page. All interpretation
lives in modules.json (written by Claude via the /re-map skill, or by hand).

Inputs
  out.json       Ghidra export from exportjson.sh (facts: functions, calls, strings)
  modules.json   modules, external resources, data flows (interpretation + evidence)
  review/        optional notes, review/<function name>.md, shown in the side panel

Usage
  archmap.py [--export out.json] [--modules map/modules.json] [--review review]
             [--out map/index.html] [--check]

  --check   validate modules.json against out.json and exit (no HTML)
"""

import argparse
import html
import json
import os
import sys

STATUSES = ("confirmed", "hypothesis")
KINDS = ("file", "registry", "network", "ui", "device", "other")


def die(msg):
    print("archmap: " + msg, file=sys.stderr)
    sys.exit(1)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        die("not found: " + path)
    except json.JSONDecodeError as e:
        die("bad JSON in %s: %s" % (path, e))


def validate(mods, funcs):
    """Return a list of problems; empty = valid."""
    errs = []
    names = set(funcs)
    ids = set()
    owner = {}
    for i, m in enumerate(mods.get("modules", [])):
        where = "modules[%d]" % i
        for k in ("id", "name", "summary", "status", "functions", "evidence"):
            if k not in m:
                errs.append("%s: missing '%s'" % (where, k))
        if m.get("status") not in STATUSES:
            errs.append("%s: status must be one of %s" % (where, STATUSES))
        if not m.get("evidence"):
            errs.append("%s (%s): evidence is empty" % (where, m.get("id")))
        mid = m.get("id")
        if mid in ids:
            errs.append("%s: duplicate id '%s'" % (where, mid))
        ids.add(mid)
        for fn in m.get("functions", []):
            if fn not in names:
                errs.append("%s (%s): function '%s' not in export" % (where, mid, fn))
            if fn in owner:
                errs.append("function '%s' in two modules: %s, %s" % (fn, owner[fn], mid))
            owner[fn] = mid
    for i, r in enumerate(mods.get("resources", [])):
        where = "resources[%d]" % i
        for k in ("id", "kind", "name", "evidence"):
            if k not in r:
                errs.append("%s: missing '%s'" % (where, k))
        if r.get("kind") not in KINDS:
            errs.append("%s: kind must be one of %s" % (where, KINDS))
        if r.get("id") in ids:
            errs.append("%s: id '%s' clashes with another id" % (where, r.get("id")))
        ids.add(r.get("id"))
    for i, fl in enumerate(mods.get("flows", [])):
        where = "flows[%d]" % i
        for k in ("from", "to", "label", "status", "evidence"):
            if k not in fl:
                errs.append("%s: missing '%s'" % (where, k))
        for end in ("from", "to"):
            if fl.get(end) not in ids:
                errs.append("%s: '%s' = '%s' is not a module or resource id" % (where, end, fl.get(end)))
        if fl.get("status") not in STATUSES:
            errs.append("%s: status must be one of %s" % (where, STATUSES))
    for i, n in enumerate(mods.get("next", [])):
        if n.get("function") not in names:
            errs.append("next[%d]: function '%s' not in export" % (i, n.get("function")))
    return errs


def build(export, mods, review_dir):
    funcs = {f["name"]: f for f in export}
    owner = {}
    for m in mods.get("modules", []):
        for fn in m["functions"]:
            owner[fn] = m["id"]

    nodes, edges = [], []
    for m in mods.get("modules", []):
        nodes.append({"data": {
            "id": "m:" + m["id"], "label": m["name"], "type": "module",
            "status": m["status"], "summary": m["summary"],
            "evidence": m["evidence"], "count": len(m["functions"])}})
    for r in mods.get("resources", []):
        nodes.append({"data": {
            "id": "m:" + r["id"], "label": r["name"], "type": "resource",
            "kind": r["kind"], "status": "confirmed", "evidence": r["evidence"]}})

    # function nodes (only functions placed in a module)
    for fn, mid in sorted(owner.items()):
        f = funcs[fn]
        note = None
        for cand in (fn, fn.replace("/", "_"), f.get("short") or fn,
                     "".join(c if c.isalnum() or c in "._-" else "_" for c in fn)):
            p = os.path.join(review_dir, cand + ".md") if review_dir else None
            if p and os.path.isfile(p):
                with open(p, encoding="utf-8", errors="replace") as fh:
                    note = fh.read()
                break
        nodes.append({"data": {
            "id": "f:" + fn, "label": f.get("short") or fn, "full": fn, "type": "function", "module": "m:" + mid,
            "address": f.get("address"), "signature": f.get("signature"),
            "callers": f.get("callers", []), "callees": f.get("callees", []),
            "strings": [s.get("value") for s in f.get("strings", []) if s.get("value")][:40],
            "pseudocode": f.get("pseudocode") or "", "note": note}})

    # function call edges + module edges aggregated from them
    agg = {}
    for fn in sorted(owner):
        for callee in funcs[fn].get("callees", []):
            if callee in owner and callee != fn:
                edges.append({"data": {"id": "c:%s>%s" % (fn, callee), "source": "f:" + fn,
                                       "target": "f:" + callee, "type": "call"}})
                a, b = owner[fn], owner[callee]
                if a != b:
                    agg[(a, b)] = agg.get((a, b), 0) + 1
    for (a, b), n in sorted(agg.items()):
        edges.append({"data": {"id": "a:%s>%s" % (a, b), "source": "m:" + a, "target": "m:" + b,
                               "type": "modcall", "label": "%d call%s" % (n, "" if n == 1 else "s")}})
    for i, fl in enumerate(mods.get("flows", [])):
        edges.append({"data": {"id": "flow:%d" % i, "source": "m:" + fl["from"], "target": "m:" + fl["to"],
                               "type": "flow", "label": fl["label"], "status": fl["status"],
                               "evidence": fl["evidence"]}})

    unplaced = sorted(n for n, f in funcs.items()
                      if n not in owner and not f.get("is_thunk") and not f.get("is_external"))
    return {"program": mods.get("program", ""), "nodes": nodes, "edges": edges,
            "skipped": mods.get("skipped", []), "next": mods.get("next", []),
            "unplaced": unplaced, "total": len(funcs)}


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
<html lang="en"><head><meta charset="utf-8">
<title>__TITLE__</title>
__LIBS__
<style>
 body{margin:0;font:14px system-ui,sans-serif;display:grid;grid-template-columns:1fr 420px;grid-template-rows:auto 1fr;height:100vh;color:#222}
 header{grid-column:1/3;padding:8px 12px;border-bottom:1px solid #ddd;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
 header h1{font-size:16px;margin:0 12px 0 0}
 #cy{border-right:1px solid #ddd}
 aside{overflow:auto;padding:12px}
 aside h2{font-size:15px;margin:4px 0 8px} aside h3{font-size:13px;margin:14px 0 4px;color:#555}
 pre{background:#f6f6f6;padding:8px;overflow:auto;font-size:12px;white-space:pre}
 .tag{display:inline-block;padding:1px 6px;border-radius:8px;font-size:11px;margin-left:6px}
 .confirmed{background:#dff3e4}.hypothesis{background:#fdf0d5}
 ul{padding-left:18px;margin:4px 0} li{margin:2px 0} a{cursor:pointer;color:#1a5fb4}
 .legend span{margin-right:12px;font-size:12px}
</style></head><body>
<header>
 <h1>__TITLE__</h1>
 <label><input type="checkbox" id="fn"> show functions</label>
 <label><input type="checkbox" id="conf"> confirmed only</label>
 <input id="q" placeholder="search function, string, address" size="30">
 <button id="path">path from entry</button>
 <span class="legend"><span>━ confirmed</span><span>┅ hypothesis</span><span>▭ module</span><span>⬠ resource</span></span>
</header>
<div id="cy"></div>
<aside id="side"></aside>
<script>
const G = __DATA__;
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const cy = cytoscape({container: document.getElementById('cy'), maxZoom: 1.6, elements: [...G.nodes, ...G.edges],
 style: [
  {selector:'node', style:{'label':'data(label)','font-size':11,'text-wrap':'wrap','text-max-width':140,'text-valign':'center','background-color':'#fff','border-width':1.5,'border-color':'#888','shape':'round-rectangle','width': e => Math.max(40, String(e.data('label')).length * 6.6 + 18),'height':26}},
  {selector:'node[type="module"]', style:{'font-size':13,'font-weight':600,'width': e => Math.max(60, String(e.data('label')).length * 8 + 24),'height':34,'border-color':'#1a5fb4','background-color':'#eaf1fb'}},
  {selector:'node[type="resource"]', style:{'shape':'round-tag','border-color':'#a35200','background-color':'#fdf3e7','width': e => Math.max(50, String(e.data('label')).length * 6.6 + 28),'height':30}},
  {selector:':parent', style:{'text-valign':'top','text-halign':'center','text-margin-y':-4,'padding':18,'background-opacity':0.5}},
  {selector:'node[status="hypothesis"]', style:{'border-style':'dashed'}},
  {selector:'edge', style:{'width':1.2,'line-color':'#999','target-arrow-color':'#999','target-arrow-shape':'triangle','curve-style':'bezier','font-size':10,'text-background-color':'#fff','text-background-opacity':1}},
  {selector:'edge[type="modcall"]', style:{'label':'data(label)','width':2}},
  {selector:'edge[type="flow"]', style:{'label':'data(label)','line-color':'#a35200','target-arrow-color':'#a35200','width':2}},
  {selector:'edge[status="hypothesis"]', style:{'line-style':'dashed'}},
  {selector:'node.hl', style:{'border-color':'#c01c28','border-width':3}},
  {selector:'edge.hl', style:{'line-color':'#c01c28','target-arrow-color':'#c01c28','width':3}},
  {selector:'.hidden', style:{'display':'none'}}
 ]});
function apply(){
 const showFn = document.getElementById('fn').checked, conf = document.getElementById('conf').checked;
 cy.batch(() => {
  cy.elements().removeClass('hidden');
  cy.nodes('[type="function"]').toggleClass('hidden', !showFn);
  cy.edges('[type="call"]').toggleClass('hidden', !showFn);
  cy.edges('[type="modcall"]').toggleClass('hidden', showFn);
  if (conf) cy.elements('[status="hypothesis"]').addClass('hidden');
  if (conf) cy.nodes('.hidden').connectedEdges().addClass('hidden');
 });
 if (showFn) { cy.nodes('[type="function"]').forEach(n => n.move({parent: n.data('module')})); }
 else { cy.nodes('[type="function"]').forEach(n => n.move({parent: null})); }
 const vis = cy.elements().not('.hidden');
 vis.layout({name:'cose', animate:false, randomize:true, numIter:3000, nodeOverlap:40, componentSpacing:120, nodeRepulsion: () => 20000, idealEdgeLength: () => 100, nestingFactor: 0.8, gravity: 0.5, padding: 30}).run();
 cy.fit(vis, 30);
}
function list(xs, fnLinks){ return '<ul>' + (xs||[]).map(x => '<li>' + (fnLinks && cy.$id('f:'+x).length ? '<a data-go="f:'+esc(x)+'">'+esc(x)+'</a>' : esc(x)) + '</li>').join('') + '</ul>'; }
function show(d){
 const s = document.getElementById('side'); let h = '';
 const tag = d.status ? '<span class="tag '+d.status+'">'+d.status+'</span>' : '';
 if (d.type === 'module'){
  h = '<h2>'+esc(d.label)+tag+'</h2><p>'+esc(d.summary)+'</p><h3>Evidence</h3>'+list(d.evidence)+'<h3>Functions ('+d.count+')</h3>'+list(cy.nodes().filter(n => n.data('module') === d.id).map(n => n.data('full')), true);
 } else if (d.type === 'resource'){
  h = '<h2>'+esc(d.label)+' <span class="tag">'+esc(d.kind)+'</span></h2><h3>Evidence</h3>'+list(d.evidence);
 } else if (d.type === 'function'){
  h = '<h2>'+esc(d.full || d.label)+'</h2><p><code>'+esc(d.address)+'</code><br><code>'+esc(d.signature)+'</code></p>'
   + (d.note ? '<h3>My notes (review/)</h3><pre>'+esc(d.note)+'</pre>' : '')
   + '<h3>Callers</h3>'+list(d.callers, true)+'<h3>Callees</h3>'+list(d.callees, true)
   + (d.strings.length ? '<h3>Strings</h3>'+list(d.strings) : '')
   + '<h3>Pseudocode</h3><pre>'+esc(d.pseudocode)+'</pre>';
 } else if (d.type === 'flow'){
  h = '<h2>'+esc(d.label)+tag+'</h2><h3>Evidence</h3><p>'+esc(d.evidence)+'</p>';
 }
 s.innerHTML = h || overview();
 s.querySelectorAll('[data-go]').forEach(a => a.onclick = () => go(a.dataset.go));
}
function overview(){
 return '<h2>Overview</h2><p>'+G.total+' functions exported; '+cy.nodes('[type="function"]').length+' placed in modules; '+G.unplaced.length+' not placed.</p>'
  + (G.next.length ? '<h3>Analyze next</h3><ul>'+G.next.map(n => '<li><a data-go="f:'+esc(n.function)+'">'+esc(n.function)+'</a>: '+esc(n.why)+'</li>').join('')+'</ul>' : '')
  + (G.skipped.length ? '<h3>Skipped</h3><ul>'+G.skipped.map(k => '<li>'+esc(k.pattern)+': '+esc(k.reason)+'</li>').join('')+'</ul>' : '')
  + '<h3>Not placed in a module</h3>'+list(G.unplaced.slice(0,300));
}
function go(id){
 const n = cy.$id(id); if (!n.length) return;
 if (n.data('type') === 'function' && !document.getElementById('fn').checked){ document.getElementById('fn').checked = true; apply(); }
 cy.elements().removeClass('hl'); n.addClass('hl'); cy.animate({fit:{eles:n.closedNeighborhood().not('.hidden'), padding:80}, duration:300}); show(n.data());
}
cy.on('tap', 'node, edge', e => { cy.elements().removeClass('hl'); e.target.addClass('hl'); show(e.target.data()); });
cy.on('tap', e => { if (e.target === cy) { cy.elements().removeClass('hl'); show({}); } });
document.getElementById('fn').onchange = apply;
document.getElementById('conf').onchange = apply;
document.getElementById('q').onkeydown = e => {
 if (e.key !== 'Enter') return; const q = e.target.value.toLowerCase(); if (!q) return;
 const hit = cy.nodes().filter(n => [n.data('label'), n.data('full'), n.data('address'), ...(n.data('strings')||[])].some(v => String(v||'').toLowerCase().includes(q)));
 if (!hit.length) return; cy.elements().removeClass('hl'); hit.addClass('hl'); go(hit[0].id());
};
document.getElementById('path').onclick = () => {
 const sel = cy.$('node.hl[type="function"]'); if (!sel.length) { alert('Select a function first.'); return; }
 const pref = ['entry','_start','start','main','winmain'];
 const roots = cy.nodes('[type="function"]').filter(n => pref.includes(String(n.data('label')).toLowerCase()))
   .sort((a, b) => pref.indexOf(a.data('label').toLowerCase()) - pref.indexOf(b.data('label').toLowerCase()));
 if (!roots.length) { alert('No entry/main/WinMain placed in a module.'); return; }
 const calls = cy.edges('[type="call"]');
 const r = cy.elements().aStar({root: roots[0], goal: sel[0], directed: true, weight: () => 1});
 if (!r.found) { alert('No call path from ' + roots[0].data('label')); return; }
 if (!document.getElementById('fn').checked){ document.getElementById('fn').checked = true; apply(); }
 cy.elements().removeClass('hl'); r.path.addClass('hl'); cy.fit(r.path, 60);
};
apply(); show({});
</script></body></html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--export", default="out.json")
    ap.add_argument("--modules", default="map/modules.json")
    ap.add_argument("--review", default="review")
    ap.add_argument("--out", default="map/index.html")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    export = load_json(a.export)
    mods = load_json(a.modules)
    errs = validate(mods, {f["name"] for f in export})
    if errs:
        print("modules.json has %d problem(s):" % len(errs), file=sys.stderr)
        for e in errs:
            print("  - " + e, file=sys.stderr)
        sys.exit(2)
    if a.check:
        print("modules.json OK")
        return

    data = build(export, mods, a.review)
    title = "Architecture map: " + (data["program"] or os.path.basename(a.export))
    embedded = []
    libs = lib_tag("cytoscape.min.js", "https://unpkg.com/cytoscape@3.35.0/dist/cytoscape.min.js", embedded)
    page = (PAGE.replace("__TITLE__", html.escape(title))
                .replace("__DATA__", json.dumps(data).replace("</", "<\\/"))
                .replace("__LIBS__", libs))
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(page)
    placed = sum(1 for n in data["nodes"] if n["data"]["type"] == "function")
    print("archmap: %s  (%d modules, %d functions placed, %d not placed)"
          % (a.out, len(mods.get("modules", [])), placed, len(data["unplaced"])))
    print("archmap: library %s" % ("embedded, the page works offline" if embedded
                                   else "linked from a CDN, the page needs internet access"))


if __name__ == "__main__":
    main()
