#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""8K TV SoC per-path latency report.

Reads the per-burst samples a tv8k bench writes (tv8k_latency.csv:
master,target,dir,cycles,bytes,t_end), or 'LAT <master> <slave> <R|W> <cycles>'
lines (lat_pkg format: a +LAT_FILE file or a sim log), merges any number of
them, and writes one self-contained HTML page:

  * headline tiles: samples, paths, read paths over their p99 budget
  * heatmaps master x target: average read, average write, p99 read latency
  * per-master DRAM read latency range (min, p50, p99, max) against its budget
  * per-master CDF small multiples, reads and writes
  * achieved bandwidth per master, reads and writes (needs bytes/t_end: CSV input)
  * the full table: n, min, avg, p50, p90, p95, p99, max per path and direction

    python3 tools/tv8k_latency_report.py run1/tv8k_latency.csv run2/log -o tv8k_latency.html
    python3 tools/tv8k_latency_report.py ... --spec socgen/specs/tv8k_soc.yaml --clk-ns 1.0

Budgets come from the spec's masters[].qos.latency_target (cycles, reads).
Latency is in clock cycles; bandwidth assumes --clk-ns per cycle.
"""
import argparse
import csv
import html
import math
import os
import re
from collections import defaultdict

MASTERS = ["cpu", "gpu", "npu", "vdec", "pq", "disp", "hdmirx", "tsd", "adsp", "dma", "sec", "netio"]
TARGETS = [f"dram{i}" for i in range(8)] + ["boot_sram", "periph", "vdec_regs", "gpu_regs", "npu_regs", "none"]
DEFAULT_BUDGET = {"cpu": 150, "pq": 250, "disp": 200, "hdmirx": 250, "tsd": 300, "adsp": 200}

# sequential blue ramp (light -> dark), reference palette steps 100..700
SEQ = ["#cde2fb", "#b7d3f6", "#9ec5f4", "#86b6ef", "#6da7ec", "#5598e7", "#3987e5",
       "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b"]
SEQ_DARK_TEXT_FROM = 6          # cells from this step on carry light text


def esc(s):
    return html.escape(str(s), quote=True)


# --------------------------------------------------------------------------- input
def load(paths):
    """-> samples[(master, target, dir)] = [cycles...], bw[(master, dir)] = bytes, span cycles"""
    samples = defaultdict(list)
    bw = defaultdict(int)
    t_min, t_max = None, None
    lat_re = re.compile(r"^LAT\s+(\S+)\s+(\S+)\s+([RW])\s+(\d+)\s*$")
    for p in paths:
        with open(p, newline="") as f:
            first = f.readline()
            f.seek(0)
            if first.startswith("master,target,dir,cycles"):
                for r in csv.DictReader(f):
                    k = (r["master"], r["target"], r["dir"])
                    samples[k].append(int(r["cycles"]))
                    if not r["target"].startswith("none"):
                        bw[(r["master"], r["dir"])] += int(r["bytes"])
                    t = int(r["t_end"])
                    t_min = t if t_min is None else min(t_min, t)
                    t_max = t if t_max is None else max(t_max, t)
            else:
                for line in f:
                    m = lat_re.match(line)
                    if m:
                        samples[(m[1], m[2], m[3])].append(int(m[4]))
    span = (t_max - t_min) if (t_min is not None and t_max > t_min) else 0
    return samples, bw, span


def spec_budgets(path):
    """masters[].qos.latency_target from a socgen spec (flow-style lines are enough)"""
    b = {}
    for line in open(path):
        m = re.search(r"name:\s*(\w+).*latency_target:\s*(\d+)", line)
        if m:
            b[m[1]] = int(m[2])
    return b


def pct(v, p):
    if not v:
        return 0
    i = max(0, min(len(v) - 1, (p * len(v) + 99) // 100 - 1))
    return v[i]


def stats(v):
    v = sorted(v)
    return {"n": len(v), "min": v[0], "avg": sum(v) / len(v), "p50": pct(v, 50), "p90": pct(v, 90),
            "p95": pct(v, 95), "p99": pct(v, 99), "max": v[-1]}


def ordered(names, known):
    return [x for x in known if x in names] + sorted(x for x in names if x not in known)


# --------------------------------------------------------------------------- charts
def nice_max(v):
    if v <= 0:
        return 1
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        if m * e >= v:
            return m * e
    return 10 * e


def ticks(vmax, n=4):
    step = vmax / n
    e = 10 ** math.floor(math.log10(step)) if step > 0 else 1
    step = next(m * e for m in (1, 2, 2.5, 5, 10) if m * e >= step)
    t, out = 0, []
    while t <= vmax + 1e-9:
        out.append(t)
        t += step
    return out


def heatmap(title, cell, masters, targets, vmax, unit="cycles"):
    """cell(m, t) -> (value or None, tooltip)"""
    cw, ch, lw, th = 46, 26, 64, 70
    W, H = lw + cw * len(targets) + 8, th + ch * len(masters) + 8
    o = [f'<svg class="hm" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="{esc(title)}">']
    for j, t in enumerate(targets):
        x = lw + j * cw + cw / 2
        o.append(f'<text class="ax" transform="translate({x + 4},{th - 6}) rotate(-50)">{esc(t)}</text>')
    for i, m in enumerate(masters):
        y = th + i * ch
        o.append(f'<text class="ax" x="{lw - 8}" y="{y + ch / 2 + 4}" text-anchor="end">{esc(m)}</text>')
        for j, t in enumerate(targets):
            v, tip = cell(m, t)
            x = lw + j * cw
            if v is None:
                o.append(f'<rect class="empty" x="{x + 1}" y="{y + 1}" width="{cw - 2}" height="{ch - 2}" rx="3"/>')
                continue
            k = min(len(SEQ) - 1, int(len(SEQ) * min(v, vmax) / vmax)) if vmax else 0
            fg = "#ffffff" if k >= SEQ_DARK_TEXT_FROM else "#0b0b0b"
            o.append(f'<g class="hit" data-tip="{esc(tip)}"><rect x="{x + 1}" y="{y + 1}" width="{cw - 2}" '
                     f'height="{ch - 2}" rx="3" fill="{SEQ[k]}"/>'
                     f'<text x="{x + cw / 2}" y="{y + ch / 2 + 4}" text-anchor="middle" fill="{fg}" '
                     f'class="cv">{v:.0f}</text></g>')
    o.append("</svg>")
    # legend: the ramp with its end values
    lg = ['<div class="ramp"><span>0</span>']
    lg += [f'<i style="background:{c}"></i>' for c in SEQ]
    lg.append(f'<span>{vmax:.0f} {unit}</span></div>')
    return f'<figure class="card"><figcaption>{esc(title)}</figcaption>{"".join(o)}{"".join(lg)}</figure>'


def range_chart(rows, budgets):
    """rows: [(master, stats)] DRAM reads; one track per master: min..max thin line,
    p50..p99 thick bar, budget tick"""
    lw, rw, rh, top = 64, 520, 24, 26
    vmax = nice_max(max([s["max"] for _, s in rows] + [budgets.get(m, 0) for m, _ in rows] + [1]))
    W, H = lw + rw + 110, top + rh * len(rows) + 30
    X = lambda v: lw + rw * v / vmax
    o = [f'<svg viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
         f'aria-label="DRAM read latency range per master">']
    for t in ticks(vmax):
        o.append(f'<line class="grid" x1="{X(t)}" x2="{X(t)}" y1="{top - 6}" y2="{H - 24}"/>'
                 f'<text class="ax" x="{X(t)}" y="{H - 8}" text-anchor="middle">{t:g}</text>')
    for i, (m, s) in enumerate(rows):
        y = top + i * rh + rh / 2
        b = budgets.get(m)
        over = b is not None and s["p99"] > b
        tip = (f"{m} -> dram reads: n={s['n']} min={s['min']} p50={s['p50']} avg={s['avg']:.1f} "
               f"p99={s['p99']} max={s['max']}" + (f" budget={b}" + (" OVER" if over else "") if b else ""))
        o.append(f'<g class="hit" data-tip="{esc(tip)}">'
                 f'<rect x="{lw}" y="{y - rh / 2}" width="{rw}" height="{rh}" fill="transparent"/>'
                 f'<text class="ax" x="{lw - 8}" y="{y + 4}" text-anchor="end">{esc(m)}</text>'
                 f'<line class="whisk" x1="{X(s["min"])}" x2="{X(s["max"])}" y1="{y}" y2="{y}"/>'
                 f'<rect class="iqr" x="{X(s["p50"])}" y="{y - 5}" width="{max(2, X(s["p99"]) - X(s["p50"]))}" '
                 f'height="10" rx="3"/>'
                 f'<circle class="p50" cx="{X(s["p50"])}" cy="{y}" r="4"/>')
        if b:
            o.append(f'<line class="budget" x1="{X(b)}" x2="{X(b)}" y1="{y - 9}" y2="{y + 9}"/>')
        o.append(f'<text class="lab" x="{lw + rw + 8}" y="{y + 4}">p99 {s["p99"]}'
                 f'{" ⚠ over" if over else ""}</text></g>')
    o.append("</svg>")
    key = ('<div class="key"><span><i class="k-whisk"></i>min to max</span><span><i class="k-iqr"></i>p50 to p99'
           '</span><span><i class="k-p50"></i>p50</span><span><i class="k-budget"></i>p99 budget (spec)</span></div>')
    return ('<figure class="card"><figcaption>DRAM read latency per master, cycles</figcaption>'
            f'{key}{"".join(o)}</figure>')


def cdf_multiples(samples, masters):
    """one small CDF per master over its DRAM traffic: reads (slot 1) and writes (slot 2)"""
    data = {}
    for m in masters:
        r = sorted(c for (mm, t, d), v in samples.items() if mm == m and t.startswith("dram") and d == "R" for c in v)
        w = sorted(c for (mm, t, d), v in samples.items() if mm == m and t.startswith("dram") and d == "W" for c in v)
        if r or w:
            data[m] = (r, w)
    if not data:
        return ""
    vmax = nice_max(max(max(r + w) for r, w in data.values()))
    cw, chh, pad = 210, 120, 26
    out = []
    for m, (r, w) in data.items():
        X = lambda v: pad + (cw - pad - 18) * v / vmax
        Y = lambda f: 8 + (chh - 30) * (1 - f)
        o = [f'<svg viewBox="0 0 {cw} {chh}" width="{cw}" height="{chh}" role="img" '
             f'aria-label="{esc(m)} latency CDF">']
        for f in (0, 0.5, 1):
            o.append(f'<line class="grid" x1="{pad}" x2="{cw - 18}" y1="{Y(f)}" y2="{Y(f)}"/>'
                     f'<text class="ax" x="{pad - 4}" y="{Y(f) + 3}" text-anchor="end">{int(f * 100)}</text>')
        for t in ticks(vmax, 2):
            o.append(f'<text class="ax" x="{X(t)}" y="{chh - 6}" text-anchor="middle">{t:g}</text>')
        for cls, v in (("s1", r), ("s2", w)):
            if not v:
                continue
            pts, n = [], len(v)
            for i, c in enumerate(v):
                pts.append(f"{X(c):.1f},{Y(i / n):.1f}")
                pts.append(f"{X(c):.1f},{Y((i + 1) / n):.1f}")
            o.append(f'<polyline class="{cls}" points="{" ".join(pts)}"/>')
        tip = (f"{m} dram: reads n={len(r)} p50={pct(r, 50)} p99={pct(r, 99)}; "
               f"writes n={len(w)} p50={pct(w, 50)} p99={pct(w, 99)}")
        o.append(f'<rect class="hit" data-tip="{esc(tip)}" x="0" y="0" width="{cw}" height="{chh}" fill="transparent"/>')
        o.append("</svg>")
        out.append(f'<div class="sm"><b>{esc(m)}</b>{"".join(o)}</div>')
    key = '<div class="key"><span><i class="k-s1"></i>reads</span><span><i class="k-s2"></i>writes</span></div>'
    return ('<figure class="card wide"><figcaption>Latency CDF per master, DRAM traffic '
            f'(x: cycles, shared scale; y: % of bursts)</figcaption>{key}<div class="grid-sm">{"".join(out)}</div></figure>')


def bw_chart(bw, span, clk_ns, masters):
    if not span:
        return ""
    sec = span * clk_ns
    rows = [(m, bw.get((m, "R"), 0) / sec * 1e3, bw.get((m, "W"), 0) / sec * 1e3) for m in masters]
    rows = [r for r in rows if r[1] + r[2] > 0]
    vmax = nice_max(max(r + w for _, r, w in rows))
    lw, rw, rh, top = 64, 520, 22, 8
    W, H = lw + rw + 80, top + rh * len(rows) + 26
    X = lambda v: rw * v / vmax
    o = [f'<svg viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="bandwidth per master">']
    for t in ticks(vmax):
        o.append(f'<line class="grid" x1="{lw + X(t)}" x2="{lw + X(t)}" y1="{top}" y2="{H - 22}"/>'
                 f'<text class="ax" x="{lw + X(t)}" y="{H - 6}" text-anchor="middle">{t:g}</text>')
    for i, (m, r, w) in enumerate(rows):
        y = top + i * rh + 4
        tip = f"{m}: read {r:.1f} MB/s, write {w:.1f} MB/s"
        o.append(f'<g class="hit" data-tip="{esc(tip)}"><text class="ax" x="{lw - 8}" y="{y + 11}" '
                 f'text-anchor="end">{esc(m)}</text>'
                 f'<rect class="f1" x="{lw}" y="{y}" width="{max(0, X(r) - 1)}" height="14" rx="2"/>'
                 f'<rect class="f2" x="{lw + X(r) + 1}" y="{y}" width="{max(0, X(w) - 1)}" height="14" rx="2"/>'
                 f'<text class="lab" x="{lw + X(r + w) + 6}" y="{y + 11}">{r + w:.0f}</text></g>')
    o.append("</svg>")
    key = '<div class="key"><span><i class="k-f1"></i>read</span><span><i class="k-f2"></i>write</span></div>'
    return (f'<figure class="card"><figcaption>Achieved bandwidth per master, MB/s at {1 / clk_ns:g} GHz '
            f'(bench traffic, not the use-case targets)</figcaption>{key}{"".join(o)}</figure>')


# --------------------------------------------------------------------------- page
CSS = """
.viz-root{color-scheme:light;--surface-1:#fcfcfb;--surface-2:#f3f2ef;--text-primary:#0b0b0b;
 --text-secondary:#52514e;--text-muted:#77766f;--grid:#e4e3de;--series-1:#2a78d6;--series-2:#eb6834;
 --critical:#c62828;font:13px/1.45 system-ui,-apple-system,Segoe UI,sans-serif;background:var(--surface-1);
 color:var(--text-primary);margin:0;padding:20px 24px}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])) .viz-root{color-scheme:dark;
 --surface-1:#1a1a19;--surface-2:#242423;--text-primary:#f0efec;--text-secondary:#c3c2b7;--text-muted:#9a998f;
 --grid:#33332f;--series-1:#3987e5;--series-2:#d95926;--critical:#ef6b6b}}
:root[data-theme="dark"] .viz-root{color-scheme:dark;--surface-1:#1a1a19;--surface-2:#242423;--text-primary:#f0efec;
 --text-secondary:#c3c2b7;--text-muted:#9a998f;--grid:#33332f;--series-1:#3987e5;--series-2:#d95926;--critical:#ef6b6b}
h1{font-size:20px;margin:0 0 4px} .sub{color:var(--text-secondary);margin:0 0 16px}
.tiles{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px}
.tile{background:var(--surface-2);border-radius:8px;padding:10px 16px;min-width:140px}
.tile b{display:block;font-size:24px;font-variant-numeric:tabular-nums} .tile span{color:var(--text-secondary)}
.tile.bad b{color:var(--critical)}
.cards{display:flex;flex-wrap:wrap;gap:16px}
.card{background:var(--surface-2);border-radius:8px;padding:12px 14px;margin:0}
.card.wide{flex-basis:100%}
figcaption{font-weight:600;margin-bottom:6px}
svg text{font:11px system-ui,sans-serif} .ax{fill:var(--text-secondary)} .lab{fill:var(--text-primary)}
.cv{font-size:10.5px;font-variant-numeric:tabular-nums}
.grid{stroke:var(--grid);stroke-width:1} .empty{fill:none;stroke:var(--grid);stroke-dasharray:2 3}
.whisk{stroke:var(--text-muted);stroke-width:2;stroke-linecap:round}
.iqr{fill:var(--series-1)} .p50{fill:var(--surface-1);stroke:var(--series-1);stroke-width:2}
.budget{stroke:var(--critical);stroke-width:2;stroke-dasharray:3 2}
.s1,.s2{fill:none;stroke-width:2;stroke-linejoin:round} .s1{stroke:var(--series-1)} .s2{stroke:var(--series-2)}
.f1{fill:var(--series-1)} .f2{fill:var(--series-2)}
.ramp{display:flex;align-items:center;gap:0;margin-top:6px;color:var(--text-secondary)}
.ramp i{width:14px;height:10px;display:inline-block} .ramp span{margin:0 6px}
.key{display:flex;gap:14px;color:var(--text-secondary);margin-bottom:4px}
.key i{display:inline-block;width:14px;height:8px;border-radius:2px;margin-right:5px;vertical-align:middle}
.k-whisk{background:var(--text-muted);height:2px!important} .k-iqr,.k-s1,.k-f1{background:var(--series-1)}
.k-p50{border:2px solid var(--series-1);border-radius:50%!important;width:6px!important;height:6px!important}
.k-budget{border-top:2px dashed var(--critical);height:0!important} .k-s2,.k-f2{background:var(--series-2)}
.grid-sm{display:flex;flex-wrap:wrap;gap:6px 14px} .sm b{display:block;color:var(--text-secondary);font-weight:600}
table{border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:12px}
th,td{padding:3px 8px;text-align:right;border-bottom:1px solid var(--grid)} th{color:var(--text-secondary)}
td:nth-child(-n+3),th:nth-child(-n+3){text-align:left} tr.over td{color:var(--critical)}
details{margin-top:16px} summary{cursor:pointer;font-weight:600}
#tip{position:fixed;pointer-events:none;background:var(--text-primary);color:var(--surface-1);padding:5px 8px;
 border-radius:6px;font-size:12px;max-width:360px;display:none;z-index:9}
.hit{cursor:default}
"""

JS = """
const tip=document.getElementById('tip');
document.querySelectorAll('[data-tip]').forEach(e=>{
 e.addEventListener('mousemove',ev=>{tip.textContent=e.dataset.tip;tip.style.display='block';
  tip.style.left=Math.min(ev.clientX+14,innerWidth-370)+'px';tip.style.top=(ev.clientY+14)+'px';});
 e.addEventListener('mouseleave',()=>{tip.style.display='none';});});
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="tv8k_latency.csv files, LAT files or sim logs")
    ap.add_argument("-o", "--out", default="tv8k_latency.html")
    ap.add_argument("--spec", help="socgen spec for the latency budgets (default: built-in tv8k budgets)")
    ap.add_argument("--clk-ns", type=float, default=1.0, help="NoC clock period for bandwidth (default 1.0)")
    ap.add_argument("--title", default="8K TV SoC: per-path latency")
    a = ap.parse_args()

    samples, bw, span = load(a.inputs)
    if not samples:
        raise SystemExit("no latency samples in " + ", ".join(a.inputs))
    budgets = spec_budgets(a.spec) if a.spec else dict(DEFAULT_BUDGET)
    st = {k: stats(v) for k, v in samples.items()}
    masters = ordered({k[0] for k in st}, MASTERS)
    targets = ordered({k[1] for k in st}, TARGETS)

    # DRAM aggregate per master and direction
    dram = {}
    for m in masters:
        for d in "RW":
            v = [c for (mm, t, dd), x in samples.items() if mm == m and dd == d and t.startswith("dram") for c in x]
            if v:
                dram[(m, d)] = stats(v)
    over = sorted(m for m in masters if (m, "R") in dram and m in budgets and dram[(m, "R")]["p99"] > budgets[m])

    def cell(metric, d):
        def f(m, t):
            s = st.get((m, t, d))
            if not s:
                return None, ""
            return s[metric], (f"{m} -> {t} {'reads' if d == 'R' else 'writes'}: n={s['n']} min={s['min']} "
                               f"avg={s['avg']:.1f} p50={s['p50']} p99={s['p99']} max={s['max']}")
        return f

    avg_max = max(s["avg"] for s in st.values())
    p99_max = max(s["p99"] for s in st.values())
    n_samples = sum(len(v) for v in samples.values())

    tiles = (f'<div class="tiles"><div class="tile"><b>{n_samples:,}</b><span>bursts timed</span></div>'
             f'<div class="tile"><b>{len(st)}</b><span>paths (master, target, R/W)</span></div>'
             f'<div class="tile{" bad" if over else ""}"><b>{len(over)}</b><span>masters over their p99 '
             f'read budget{(": " + ", ".join(over)) if over else ""}</span></div></div>')
    rows = [(m, dram[(m, "R")]) for m in masters if (m, "R") in dram]
    body = [tiles, '<div class="cards">',
            heatmap("Average read latency, master × target (cycles)", cell("avg", "R"), masters, targets, avg_max),
            heatmap("Average write latency, master × target (cycles)", cell("avg", "W"), masters, targets, avg_max),
            heatmap("p99 read latency, master × target (cycles)", cell("p99", "R"), masters, targets, p99_max),
            range_chart(rows, budgets) if rows else "",
            bw_chart(bw, span, a.clk_ns, masters),
            cdf_multiples(samples, masters), "</div>"]

    # table view
    t = ['<details><summary>All paths (table view)</summary><table><tr><th>master</th><th>target</th><th>dir</th>'
         + "".join(f"<th>{h}</th>" for h in ("n", "min", "avg", "p50", "p90", "p95", "p99", "max", "budget")) + "</tr>"]
    keys = sorted(st, key=lambda k: (masters.index(k[0]), targets.index(k[1]), k[2]))
    for m in masters:
        for d in "RW":
            if (m, d) in dram:
                keys.append((m, "dram (all)", d))
                st[(m, "dram (all)", d)] = dram[(m, d)]
    keys.sort(key=lambda k: (masters.index(k[0]), k[1] != "dram (all)", k[1], k[2]))
    for k in keys:
        s = st[k]
        b = budgets.get(k[0]) if k[2] == "R" else None
        o = b is not None and k[1] == "dram (all)" and s["p99"] > b
        t.append(f'<tr{" class=over" if o else ""}><td>{esc(k[0])}</td><td>{esc(k[1])}</td><td>{k[2]}</td>'
                 + "".join(f"<td>{s[x]}</td>" for x in ("n", "min")) + f"<td>{s['avg']:.1f}</td>"
                 + "".join(f"<td>{s[x]}</td>" for x in ("p50", "p90", "p95", "p99", "max"))
                 + f"<td>{b if b else ''}{' over' if o else ''}</td></tr>")
    t.append("</table></details>")
    body.append("".join(t))

    src = ", ".join(os.path.basename(os.path.dirname(os.path.abspath(p))) + "/" + os.path.basename(p) for p in a.inputs[:6])
    if len(a.inputs) > 6:
        src += f" and {len(a.inputs) - 6} more"
    page = (f'<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" '
            f'content="width=device-width,initial-scale=1"><title>{esc(a.title)}</title><style>{CSS}</style></head>'
            f'<body class="viz-root"><h1>{esc(a.title)}</h1><p class="sub">Latency in NoC clock cycles, address '
            f'handshake to last R beat (reads) or B (writes). From {esc(src)}.</p>{"".join(body)}'
            f'<div id="tip"></div><script>{JS}</script></body></html>')
    with open(a.out, "w") as f:
        f.write(page)
    print(f"{a.out}: {n_samples} samples, {len(st)} paths, over budget: {', '.join(over) or 'none'}")


if __name__ == "__main__":
    main()
