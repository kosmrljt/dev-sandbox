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
WARNINGS = []
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


def validate(mods, funcs, stubs=()):
    """Return a list of problems; empty = valid. stubs = names of thunks/externals."""
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
            elif fn in stubs:
                WARNINGS.append("%s (%s): '%s' is a thunk or external stub; modules normally hold "
                                "the program's own functions (a library belongs under resources)"
                                % (where, mid, fn))
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
 html,body{height:100%}
 body{margin:0;font:14px system-ui,sans-serif;display:grid;grid-template-columns:1fr 430px;grid-template-rows:auto 1fr;height:100vh;color:#1d1d1f;background:#fff}
 header{grid-column:1/3;padding:8px 14px;border-bottom:1px solid #ddd;display:flex;gap:14px;align-items:center;flex-wrap:wrap;background:#fafafa}
 header h1{font-size:15px;margin:0}
 #crumb{font-size:14px} #crumb a{color:#1a5fb4;cursor:pointer;text-decoration:none} #crumb b{font-weight:600}
 header label{font-size:13px;white-space:nowrap} header input[type=text]{font:13px system-ui;padding:3px 6px;width:230px}
 header button{font:13px system-ui;padding:3px 8px}
 #cy{border-right:1px solid #ddd;min-height:0}
 #hint{position:absolute;left:14px;bottom:10px;font-size:12px;color:#666;background:#ffffffd9;padding:3px 8px;border-radius:6px}
 aside{overflow:auto;padding:14px 16px;min-height:0}
 aside h2{font-size:16px;margin:2px 0 8px} aside h3{font-size:12px;margin:16px 0 4px;color:#666;text-transform:uppercase;letter-spacing:.04em}
 aside p{margin:6px 0;line-height:1.45}
 pre{background:#f6f6f6;padding:8px;overflow:auto;font-size:12px;white-space:pre;border-radius:4px;max-height:420px}
 code{font-size:12.5px}
 .tag{display:inline-block;padding:1px 7px;border-radius:9px;font-size:11px;margin-left:6px;vertical-align:middle}
 .confirmed{background:#dff3e4}.hypothesis{background:#fdf0d5}.kind{background:#eee}
 ul{padding-left:18px;margin:4px 0} li{margin:3px 0;line-height:1.35} a{cursor:pointer;color:#1a5fb4}
 .muted{color:#777;font-size:12.5px}
 .open{display:inline-block;margin:6px 0 2px;padding:5px 10px;border:1px solid #1a5fb4;border-radius:6px;color:#1a5fb4;font-size:13px}
 .legend{font-size:12px;color:#555;margin-left:auto} .legend span{margin-left:12px;white-space:nowrap}
 .sw{display:inline-block;width:18px;height:0;border-top:3px solid #888;vertical-align:middle;margin-right:4px}
</style></head><body>
<header>
 <h1>__TITLE__</h1>
 <span id="crumb"></span>
 <label><input type="checkbox" id="calls" checked> calls</label>
 <label><input type="checkbox" id="flows" checked> data flows</label>
 <label><input type="checkbox" id="conf"> confirmed only</label>
 <input type="text" id="q" placeholder="find function, string, address  (Enter)">
 <span class="legend"><span><i class="sw" style="border-color:#8a8f98"></i>calls</span><span><i class="sw" style="border-color:#c2691c"></i>data flow</span><span><i class="sw" style="border-top-style:dashed"></i>hypothesis</span></span>
</header>
<div id="cy"></div><div id="hint"></div>
<aside id="side"></aside>
<script>
const G = __DATA__;
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const N = {}; G.nodes.forEach(n => N[n.data.id] = n.data);
const MODS = G.nodes.map(n => n.data).filter(d => d.type === 'module');
const RESS = G.nodes.map(n => n.data).filter(d => d.type === 'resource');
const FUNS = G.nodes.map(n => n.data).filter(d => d.type === 'function');
const CALLS = G.edges.map(e => e.data).filter(d => d.type === 'call');
const byMod = {}; FUNS.forEach(f => (byMod[f.module] = byMod[f.module] || []).push(f));
/* module -> module calls, with the function pairs behind them */
const MODCALL = {};
CALLS.forEach(e => { const a = N[e.source].module, b = N[e.target].module; if (a === b) return;
  const k = a + '>' + b; (MODCALL[k] = MODCALL[k] || {id:'mc:'+k, source:a, target:b, pairs:[]}).pairs.push([e.source, e.target]); });
/* flows merged per pair of ends */
const FLOW = {};
G.edges.map(e => e.data).filter(d => d.type === 'flow').forEach(e => { const k = e.source + '>' + e.target;
  const f = FLOW[k] = FLOW[k] || {id:'fl:'+k, source:e.source, target:e.target, items:[], status:'confirmed'};
  f.items.push(e); if (e.status === 'hypothesis') f.status = 'hypothesis'; });
const ENTRY = ['entry','_start','start','main','winmain','wwinmain','dllmain'];
const entryFn = FUNS.filter(f => ENTRY.includes(String(f.label).toLowerCase()))
  .sort((a, b) => ENTRY.indexOf(a.label.toLowerCase()) - ENTRY.indexOf(b.label.toLowerCase()))[0];

/* ---- layered layout: columns by call depth, order by neighbours ---- */
function layered(ids, edges, roots) {
  const out = {}, inn = {}; ids.forEach(i => { out[i] = []; inn[i] = []; });
  edges.forEach(e => { if (out[e.s] && out[e.t] && e.s !== e.t) { out[e.s].push(e.t); inn[e.t].push(e.s); } });
  let start = (roots || []).filter(r => out[r]);
  if (!start.length) start = ids.filter(i => !inn[i].length);
  if (!start.length && ids.length) start = [ids.slice().sort((a, b) => out[b].length - out[a].length)[0]];
  const state = {}, back = new Set();
  const dfs = u => { state[u] = 1; out[u].forEach(v => { if (state[v] === 1) back.add(u + '>' + v); else if (!state[v]) dfs(v); }); state[u] = 2; };
  start.forEach(r => { if (!state[r]) dfs(r); }); ids.forEach(i => { if (!state[i]) dfs(i); });
  const rank = {}; const fwd = u => out[u].filter(v => !back.has(u + '>' + v));
  const indeg = {}; ids.forEach(i => indeg[i] = 0); ids.forEach(u => fwd(u).forEach(v => indeg[v]++));
  const q = ids.filter(i => !indeg[i]); q.forEach(i => rank[i] = 0);
  while (q.length) { const u = q.shift(); fwd(u).forEach(v => { rank[v] = Math.max(rank[v] || 0, rank[u] + 1); if (!--indeg[v]) q.push(v); }); }
  ids.forEach(i => { if (rank[i] === undefined) rank[i] = 0; });
  const cols = []; ids.forEach(i => (cols[rank[i]] = cols[rank[i]] || []).push(i));
  for (let c = 0; c < cols.length; c++) cols[c] = cols[c] || [];
  const pos = {}; cols.forEach(col => col.forEach((id, k) => pos[id] = k));
  const bary = (id, nb) => { const v = nb[id].filter(x => pos[x] !== undefined); return v.length ? v.reduce((s, x) => s + pos[x], 0) / v.length : pos[id]; };
  for (let it = 0; it < 6; it++) {
    for (let c = 1; c < cols.length; c++) { cols[c].sort((a, b) => bary(a, inn) - bary(b, inn)); cols[c].forEach((id, k) => pos[id] = k); }
    for (let c = cols.length - 2; c >= 0; c--) { cols[c].sort((a, b) => bary(a, out) - bary(b, out)); cols[c].forEach((id, k) => pos[id] = k); }
  }
  return cols;
}
/* Place ranks either left-to-right or top-to-bottom, whichever shows the graph
   larger in the available area. A long rank is split so the picture stays compact. */
function place(cols, o) {
  const split = []; cols.forEach(col => { const parts = Math.max(1, Math.ceil(col.length / o.maxPer)), per = Math.ceil(col.length / parts);
    for (let p = 0; p < parts; p++) split.push(col.slice(p * per, (p + 1) * per)); });
  const ranks = split.filter(c => c.length), widest = Math.max(1, ...ranks.map(c => c.length));
  const area = document.getElementById('cy').getBoundingClientRect(), W = Math.max(300, area.width - 80 - (o.extraW || 0)), H = Math.max(200, area.height - 80 - (o.extraH || 0));
  const lr = {w: ranks.length * o.lrRank, h: widest * o.lrOrder}, tb = {w: widest * o.tbOrder, h: ranks.length * o.tbRank};
  const zoom = d => Math.min(W / d.w, H / d.h), vertical = zoom(tb) > zoom(lr);
  const P = {}; ranks.forEach((col, r) => col.forEach((id, k) => { const off = k - (col.length - 1) / 2;
    P[id] = vertical ? {x: off * o.tbOrder, y: r * o.tbRank} : {x: r * o.lrRank, y: off * o.lrOrder}; }));
  const xs = Object.values(P).map(p => p.x), ys = Object.values(P).map(p => p.y);
  return {P: P, vertical: vertical, minX: Math.min(0, ...xs), maxX: Math.max(0, ...xs), minY: Math.min(0, ...ys), maxY: Math.max(0, ...ys)};
}

const cy = cytoscape({container: document.getElementById('cy'), maxZoom: 1.8, minZoom: 0.15, wheelSensitivity: 0.3,
 style: [
  {selector:'node', style:{'label':'data(text)','font-size':12,'text-wrap':'wrap','text-max-width':'data(tw)','text-valign':'center','text-halign':'center','color':'#1d1d1f','background-color':'#fff','border-width':1.5,'border-color':'#8a8f98','shape':'round-rectangle','width':'data(w)','height':'data(h)','line-height':1.25}},
  {selector:'node[kind="module"]', style:{'font-size':13,'font-weight':600,'border-color':'#1a5fb4','background-color':'#eaf1fb','border-width':2}},
  {selector:'node[kind="resource"]', style:{'text-overflow-wrap':'anywhere','shape':'round-tag','border-color':'#c2691c','background-color':'#fdf3e7'}},
  {selector:'node[kind="port"]', style:{'border-color':'#1a5fb4','background-color':'#f3f6fb','border-style':'dotted','color':'#33507a','font-size':11.5}},
  {selector:'node[kind="function"]', style:{'font-family':'ui-monospace, SFMono-Regular, Menlo, monospace','font-size':11.5}},
  {selector:'node[?entry]', style:{'border-width':3}},
  {selector:'node[status="hypothesis"]', style:{'border-style':'dashed'}},
  {selector:'edge', style:{'opacity':0.8,'width':'data(wd)','line-color':'#a9aeb6','target-arrow-color':'#a9aeb6','target-arrow-shape':'triangle','arrow-scale':0.9,'curve-style':'bezier','font-size':10.5,'color':'#333','text-background-color':'#fff','text-background-opacity':0.92,'text-background-padding':2,'text-rotation':'autorotate'}},
  {selector:'edge[kind="flow"]', style:{'line-color':'#c2691c','target-arrow-color':'#c2691c'}},
  {selector:'edge[status="hypothesis"]', style:{'line-style':'dashed'}},
  {selector:'edge.lbl', style:{'label':'data(text)','z-index':20}},
  {selector:'.faded', style:{'opacity':0.13}},
  {selector:'node.sel', style:{'border-color':'#c01c28','border-width':3.5}},
  {selector:'edge.sel', style:{'line-color':'#c01c28','target-arrow-color':'#c01c28','z-index':30}},
  {selector:'node.path', style:{'border-color':'#c01c28','border-width':3}},
  {selector:'edge.path', style:{'line-color':'#c01c28','target-arrow-color':'#c01c28','width':3,'z-index':30}}
 ]});
let VIEW = {type:'overview'};
const opt = id => document.getElementById(id).checked;
const okStatus = s => !(opt('conf') && s === 'hypothesis');
const wd = n => Math.min(5, 1.2 + Math.log2(n + 1) * 0.7);
const box = (label, sub) => sub ? label + '\n' + sub : label;

function overview(keep) {
  VIEW = {type:'overview'};
  const mods = MODS.filter(m => okStatus(m.status)), mset = new Set(mods.map(m => m.id));
  const mc = opt('calls') ? Object.values(MODCALL).filter(e => mset.has(e.source) && mset.has(e.target)) : [];
  const allmc = Object.values(MODCALL).filter(e => mset.has(e.source) && mset.has(e.target));
  const fl = opt('flows') ? Object.values(FLOW).filter(f => okStatus(f.status) && (mset.has(f.source) || N[f.source].type === 'resource') && (mset.has(f.target) || N[f.target].type === 'resource')) : [];
  const usedRes = new Set(); fl.forEach(f => [f.source, f.target].forEach(x => { if (N[x].type === 'resource') usedRes.add(x); }));
  const ress = RESS.filter(r => usedRes.has(r.id));
  const roots = entryFn && mset.has(entryFn.module) ? [entryFn.module] : [];
  const cols = layered(mods.map(m => m.id), allmc.map(e => ({s:e.source, t:e.target})), roots);
  const L = place(cols, {maxPer: 6, lrRank: 280, lrOrder: 104, tbOrder: 236, tbRank: 132, extraW: 330}), P = L.P;
  const maxX = L.maxX, midY = (L.minY + L.maxY) / 2;
  /* resources: one column on the right, ordered by the modules they connect to */
  const ry = r => { const ys = fl.filter(f => f.source === r.id || f.target === r.id).map(f => P[f.source === r.id ? f.target : f.source]).filter(Boolean).map(p => p.y); return ys.length ? ys.reduce((a, b) => a + b, 0) / ys.length : 0; };
  ress.sort((a, b) => ry(a) - ry(b)).forEach((r, k) => P[r.id] = {x: maxX + 330, y: midY + (k - (ress.length - 1) / 2) * 76});
  const els = [];
  mods.forEach(m => els.push({data:{id:m.id, kind:'module', status:m.status, text:box(m.label, m.count + (m.count === 1 ? ' function' : ' functions')), w:200, h:58, tw:184, entry: roots.includes(m.id) ? 1 : 0}, position:P[m.id]}));
  ress.forEach(r => els.push({data:{id:r.id, kind:'resource', text:box(r.label, r.kind), w:230, h:(String(r.label).length > 26 ? 60 : 46), tw:186}, position:P[r.id]}));
  mc.forEach(e => els.push({data:{id:e.id, source:e.source, target:e.target, kind:'modcall', wd:wd(e.pairs.length), text:e.pairs.length + (e.pairs.length === 1 ? ' call' : ' calls')}}));
  fl.forEach(f => els.push({data:{id:f.id, source:f.source, target:f.target, kind:'flow', status:f.status, wd:2, text:[...new Set(f.items.map(i => i.label))].join(', ')}}));
  draw(els, keep);
  crumb(); hint('Click a module or arrow for details. Double-click a module to see its functions.');
}

function moduleView(mid, selectId) {
  const m = N[mid]; if (!m) return overview();
  VIEW = {type:'module', id:mid};
  const fs = byMod[mid] || [], fset = new Set(fs.map(f => f.id));
  const inner = CALLS.filter(e => fset.has(e.source) && fset.has(e.target));
  const roots = fs.filter(f => CALLS.some(e => e.target === f.id && !fset.has(e.source))).map(f => f.id);
  if (entryFn && fset.has(entryFn.id)) roots.unshift(entryFn.id);
  const cols = layered(fs.map(f => f.id), inner.map(e => ({s:e.source, t:e.target})), roots);
  const fw = Math.min(260, Math.max(90, ...fs.map(f => String(f.label).length * 7.3 + 18)));
  const L = place(cols, {maxPer: 12, lrRank: fw + 80, lrOrder: 48, tbOrder: fw + 26, tbRank: 92, extraW: 0, extraH: 0}), P = L.P;
  const ins = {}, outs = {};
  if (opt('calls')) CALLS.forEach(e => {
    if (fset.has(e.target) && !fset.has(e.source)) { const o = N[e.source].module; (ins[o] = ins[o] || {}); (ins[o][e.target] = ins[o][e.target] || []).push(e.source); }
    if (fset.has(e.source) && !fset.has(e.target)) { const o = N[e.target].module; (outs[o] = outs[o] || {}); (outs[o][e.source] = outs[o][e.source] || []).push(e.target); } });
  const els = [];
  fs.forEach(f => els.push({data:{id:f.id, kind:'function', text:f.label, w:Math.max(70, String(f.label).length * 7.3 + 18), h:28, tw:400, entry: entryFn && f.id === entryFn.id ? 1 : 0}, position:P[f.id]}));
  const side = (group, pre, arrowIn) => { const keys = Object.keys(group), ax = L.vertical ? 'x' : 'y';
    const at = k => { const v = Object.keys(group[k]).map(f => P[f][ax]); return v.reduce((a, b) => a + b, 0) / v.length; };
    const mid = L.vertical ? (L.minX + L.maxX) / 2 : (L.minY + L.maxY) / 2;
    keys.sort((a, b) => at(a) - at(b)).forEach((k, i) => { const id = pre + k, off = i - (keys.length - 1) / 2;
      const pos = L.vertical ? {x: mid + off * 214, y: arrowIn ? L.minY - 120 : L.maxY + 120} : {x: arrowIn ? L.minX - fw / 2 - 190 : L.maxX + fw / 2 + 190, y: mid + off * 66};
      els.push({data:{id:id, kind:'port', mod:k, text:box(N[k].label, arrowIn ? 'calls into this module' : 'called from this module'), w:196, h:46, tw:180}, position:pos});
      Object.keys(group[k]).forEach(f => { const n = group[k][f].length;
        els.push({data:{id:id + '|' + f, source: arrowIn ? id : f, target: arrowIn ? f : id, kind:'portcall', wd:wd(n), text:n + (n === 1 ? ' call' : ' calls'), other:k, fn:f, list:group[k][f], dirIn: arrowIn ? 1 : 0}}); }); }); };
  side(ins, 'in:', true); side(outs, 'out:', false);
  inner.forEach(e => els.push({data:{id:e.id, source:e.source, target:e.target, kind:'call', wd:1.3, text:''}}));
  draw(els, false);
  crumb(m.label); hint((L.vertical ? 'Top: modules that call in. Bottom: modules this one calls.' : 'Left: modules that call in. Right: modules this one calls.') + ' Double-click one to go there. Esc = back.');
  if (selectId && cy.$id(selectId).length) select(cy.$id(selectId)); else show(m);
}

function draw(els, keep) {
  const vp = keep ? {zoom: cy.zoom(), pan: cy.pan()} : null;
  cy.elements().remove(); cy.add(els);
  if (vp) cy.viewport(vp); else cy.fit(undefined, 56);
  if (cy.zoom() > 1.25) { cy.zoom(1.25); cy.center(); }
  show({});
}
function crumb(name) { document.getElementById('crumb').innerHTML = name ? '<a id="back">\u2039 Overview</a> &nbsp;/&nbsp; <b>' + esc(name) + '</b>' : '<b>Overview</b>';
  const b = document.getElementById('back'); if (b) b.onclick = () => overview(); }
function hint(t) { document.getElementById('hint').textContent = t; }

function select(ele) {
  cy.elements().removeClass('sel faded lbl path');
  const hood = ele.isNode() ? ele.closedNeighborhood() : ele.union(ele.connectedNodes());
  cy.elements().not(hood).addClass('faded'); ele.addClass('sel'); hood.edges().addClass('lbl');
  const d = ele.data();
  if (d.kind === 'module' || d.kind === 'resource') show(N[d.id]);
  else if (d.kind === 'function') show(N[d.id]);
  else if (d.kind === 'port') show(N[d.mod]);
  else if (d.kind === 'modcall') show({type:'modcall', e:MODCALL[d.id.slice(3)]});
  else if (d.kind === 'flow') show({type:'flowgroup', f:FLOW[d.id.slice(3)]});
  else if (d.kind === 'portcall') show({type:'portcall', d:d});
  else if (d.kind === 'call') show({type:'onecall', d:d});
}
function clearSel() { cy.elements().removeClass('sel faded lbl path'); show(VIEW.type === 'module' ? N[VIEW.id] : {}); }

const fnLink = id => N[id] ? '<a data-fn="' + esc(id) + '">' + esc(N[id].full || N[id].label) + '</a>' : esc(String(id).replace(/^f:/, ''));
const modLink = id => '<a data-mod="' + esc(id) + '">' + esc(N[id].label) + '</a>';
const list = (xs, f) => xs.length ? '<ul>' + xs.map(x => '<li>' + (f ? f(x) : esc(x)) + '</li>').join('') + '</ul>' : '<p class="muted">none</p>';
const nameLink = n => N['f:' + n] ? fnLink('f:' + n) : esc(n) + ' <span class="muted">(not on the map)</span>';
const tag = s => s ? '<span class="tag ' + s + '">' + s + '</span>' : '';

function show(d) {
  const s = document.getElementById('side'); let h = '';
  if (d.type === 'module') {
    const callsOut = Object.values(MODCALL).filter(e => e.source === d.id), callsIn = Object.values(MODCALL).filter(e => e.target === d.id);
    const fl = Object.values(FLOW).filter(f => f.source === d.id || f.target === d.id);
    h = '<h2>' + esc(d.label) + tag(d.status) + '</h2><p>' + esc(d.summary) + '</p>'
      + (VIEW.type === 'overview' ? '<a class="open" data-mod="' + esc(d.id) + '">Show its ' + d.count + ' functions \u203a</a>' : '')
      + '<h3>Evidence</h3>' + list(d.evidence || [])
      + '<h3>Calls</h3>' + list(callsOut, e => modLink(e.target) + ' <span class="muted">' + e.pairs.length + '\u00d7</span>')
      + '<h3>Called by</h3>' + list(callsIn, e => modLink(e.source) + ' <span class="muted">' + e.pairs.length + '\u00d7</span>')
      + '<h3>Data flows</h3>' + list(fl, f => esc(N[f.source].label) + ' \u2192 ' + esc(N[f.target].label) + ': ' + esc([...new Set(f.items.map(i => i.label))].join(', ')) + tag(f.status))
      + '<h3>Functions (' + d.count + ')</h3>' + list((byMod[d.id] || []).map(f => f.id), fnLink);
  } else if (d.type === 'resource') {
    const fl = Object.values(FLOW).filter(f => f.source === d.id || f.target === d.id);
    h = '<h2>' + esc(d.label) + '<span class="tag kind">' + esc(d.kind) + '</span></h2><h3>Evidence</h3>' + list(d.evidence || [])
      + '<h3>Used by</h3>' + list(fl, f => { const o = f.source === d.id ? f.target : f.source; return (N[o].type === 'module' ? modLink(o) : esc(N[o].label)) + ': ' + esc(f.items.map(i => i.label).join(', ')) + tag(f.status); });
  } else if (d.type === 'function') {
    h = '<h2>' + esc(d.full || d.label) + '</h2><p><code>0x' + esc(d.address) + '</code> &nbsp; in ' + modLink(d.module) + '<br><code>' + esc(d.signature) + '</code></p>'
      + '<p><a data-path="' + esc(d.id) + '">Show path from entry</a></p>'
      + (d.note ? '<h3>Card (review/)</h3><pre>' + esc(d.note) + '</pre>' : '')
      + '<h3>Called by</h3>' + list(d.callers || [], nameLink) + '<h3>Calls</h3>' + list(d.callees || [], nameLink)
      + ((d.strings || []).length ? '<h3>Strings</h3>' + list(d.strings) : '')
      + '<h3>Pseudocode</h3><pre>' + esc(d.pseudocode || '(none in the export)') + '</pre>';
  } else if (d.type === 'modcall') {
    h = '<h2>' + esc(N[d.e.source].label) + ' \u2192 ' + esc(N[d.e.target].label) + '</h2><p>' + d.e.pairs.length + ' calls between the two modules.</p><h3>Calls</h3>'
      + list(d.e.pairs, p => fnLink(p[0]) + ' \u2192 ' + fnLink(p[1]));
  } else if (d.type === 'flowgroup') {
    h = '<h2>' + esc(N[d.f.source].label) + ' \u2192 ' + esc(N[d.f.target].label) + tag(d.f.status) + '</h2><h3>Data flows</h3>'
      + list(d.f.items, i => '<b>' + esc(i.label) + '</b>' + tag(i.status) + '<br><span class="muted">' + esc(i.evidence) + '</span>');
  } else if (d.type === 'portcall') {
    h = '<h2>' + (d.d.dirIn ? esc(N[d.d.other].label) + ' \u2192 ' + esc(N[d.d.fn].label) : esc(N[d.d.fn].label) + ' \u2192 ' + esc(N[d.d.other].label)) + '</h2><h3>' + (d.d.dirIn ? 'Callers' : 'Callees') + '</h3>' + list(d.d.list, fnLink);
  } else if (d.type === 'onecall') {
    h = '<h2>Call</h2><p>' + fnLink(d.d.source) + ' \u2192 ' + fnLink(d.d.target) + '</p>';
  } else if (d.type === 'path') {
    h = '<h2>Path from entry</h2>' + (d.path ? '<p class="muted">Shortest call chain; functions reached only through pointers have none.</p><ol style="padding-left:20px">' + d.path.map(id => '<li>' + fnLink(id) + ' <span class="muted">' + esc(N[N[id].module].label) + '</span></li>').join('') + '</ol>'
      : '<p>No direct call chain from <code>' + esc(d.from) + '</code> to ' + fnLink(d.to) + '. It is probably reached through a function pointer (handler, callback, table).</p>');
  } else h = overviewPanel();
  s.innerHTML = h; s.scrollTop = 0;
  s.querySelectorAll('[data-fn]').forEach(a => a.onclick = () => goFn(a.dataset.fn));
  s.querySelectorAll('[data-mod]').forEach(a => a.onclick = () => moduleView(a.dataset.mod));
  s.querySelectorAll('[data-path]').forEach(a => a.onclick = () => pathTo(a.dataset.path));
}
function overviewPanel() {
  const hyp = MODS.filter(m => m.status === 'hypothesis').length;
  return '<h2>' + esc(G.program || 'Program') + '</h2><p>' + MODS.length + ' modules (' + (MODS.length - hyp) + ' confirmed, ' + hyp + ' hypothesis), ' + FUNS.length + ' functions placed, ' + G.unplaced.length + ' not placed.</p>'
    + '<p class="muted">Modules are ordered by call depth, starting from the one with the entry point (thick border). External resources are on the right. Click anything for details.</p>'
    + '<h3>Modules</h3>' + list(MODS, m => modLink(m.id) + ' <span class="muted">' + m.count + '</span>' + (m.status === 'hypothesis' ? tag(m.status) : '') + '<br><span class="muted">' + esc(m.summary) + '</span>')
    + (G.next.length ? '<h3>Analyze next</h3>' + list(G.next, n => nameLink(n.function) + ': ' + esc(n.why)) : '')
    + (G.skipped.length ? '<h3>Skipped</h3>' + list(G.skipped, k => esc(k.pattern) + ': ' + esc(k.reason)) : '')
    + '<h3>Not placed in a module (' + G.unplaced.length + ')</h3>' + list(G.unplaced.slice(0, 300));
}
function goFn(id) { const f = N[id]; if (!f) return; if (VIEW.type !== 'module' || VIEW.id !== f.module) moduleView(f.module, id); else select(cy.$id(id));
  const n = cy.$id(id); if (n.length) cy.animate({center:{eles:n}, duration:200}); }
function pathTo(id) {
  if (!entryFn) return show({type:'path', path:null, from:'entry', to:id});
  const prev = {}; prev[entryFn.id] = null; const q = [entryFn.id]; const adj = {}; CALLS.forEach(e => (adj[e.source] = adj[e.source] || []).push(e.target));
  while (q.length) { const u = q.shift(); if (u === id) break; (adj[u] || []).forEach(v => { if (!(v in prev)) { prev[v] = u; q.push(v); } }); }
  if (!(id in prev)) return show({type:'path', path:null, from:entryFn.label, to:id});
  const path = []; for (let u = id; u; u = prev[u]) path.unshift(u);
  show({type:'path', path:path});
  cy.elements().removeClass('sel faded lbl path');
  path.forEach((u, i) => { cy.$id(u).addClass('path'); if (i) cy.edges().filter(e => e.data('source') === path[i - 1] && e.data('target') === u).addClass('path'); });
}

cy.on('tap', 'node, edge', e => select(e.target));
cy.on('tap', e => { if (e.target === cy) clearSel(); });
cy.on('dbltap', 'node', e => { const d = e.target.data(); if (d.kind === 'module') moduleView(d.id); else if (d.kind === 'port') moduleView(d.mod); });
cy.on('mouseover', 'edge', e => e.target.addClass('lbl'));
cy.on('mouseout', 'edge', e => { if (!e.target.hasClass('sel') && !cy.$('node.sel').closedNeighborhood().contains(e.target)) e.target.removeClass('lbl'); });
['calls','flows','conf'].forEach(id => document.getElementById(id).onchange = () => VIEW.type === 'module' ? moduleView(VIEW.id) : overview(true));
document.addEventListener('keydown', e => { if (e.key === 'Escape' && document.activeElement.id !== 'q') { if (cy.$('.sel').length) clearSel(); else if (VIEW.type === 'module') overview(); } });
document.getElementById('q').onkeydown = e => {
  if (e.key !== 'Enter') return; const q = e.target.value.trim().toLowerCase(); if (!q) return;
  const score = f => [f.label, f.full].some(v => String(v || '').toLowerCase() === q) ? 0 : [f.label, f.full, f.address].some(v => String(v || '').toLowerCase().includes(q.replace(/^0x/, ''))) ? 1 : (f.strings || []).some(v => String(v).toLowerCase().includes(q)) ? 2 : 9;
  const hits = FUNS.map(f => [score(f), f]).filter(x => x[0] < 9).sort((a, b) => a[0] - b[0]).map(x => x[1]);
  if (!hits.length) { document.getElementById('side').innerHTML = '<h2>Search</h2><p>Nothing on the map matches <code>' + esc(q) + '</code>.</p>'; return; }
  goFn(hits[0].id);
  if (hits.length > 1) document.getElementById('side').insertAdjacentHTML('afterbegin', '<p class="muted">' + hits.length + ' matches: ' + hits.slice(0, 12).map(f => fnLink(f.id)).join(', ') + '</p>');
  document.getElementById('side').querySelectorAll('[data-fn]').forEach(a => a.onclick = () => goFn(a.dataset.fn));
};
window.addEventListener('resize', () => cy.resize());
overview();
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
    stubs = {f["name"] for f in export if f.get("is_thunk") or f.get("is_external")}
    errs = validate(mods, {f["name"] for f in export}, stubs)
    if errs:
        print("modules.json has %d problem(s):" % len(errs), file=sys.stderr)
        for e in errs:
            print("  - " + e, file=sys.stderr)
        sys.exit(2)
    for w in WARNINGS:
        print("WARNING: " + w)
    own = len(export) - len(stubs)
    placed = {fn for m in mods.get("modules", []) for fn in m["functions"]}
    counts = ("%d functions in the export = %d thunks/externals + %d of the program's own; "
              "of those %d placed in modules, %d not placed%s"
              % (len(export), len(stubs), own, len(placed - stubs), own - len(placed - stubs),
                 "; plus %d stubs placed" % len(placed & stubs) if placed & stubs else ""))
    if a.check:
        print("modules.json OK")
        print(counts)
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
    print("archmap: " + counts)
    print("archmap: library %s" % ("embedded, the page works offline" if embedded
                                   else "linked from a CDN, the page needs internet access"))


if __name__ == "__main__":
    main()
