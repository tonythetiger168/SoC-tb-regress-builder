# SPDX-License-Identifier: Apache-2.0
"""report.py -- cumulative regression report (HTML + Markdown) from one or more
regress.py output directories. Used by regress.py and covmerge.py.

Everything is plain Python + inline SVG: no plotting library, so it runs in CI
and on any workstation.
"""
import glob, html, json, math, os
from collections import Counter, OrderedDict, defaultdict

import covlib

LEVELS = ("soc", "subsystem", "vip")


# --------------------------------------------------------------------------- loading
def load_suites(dirs):
    """Merge suite data from every directory; a suite present in several
    directories (CI shards, several nights) is merged into one."""
    suites = OrderedDict()
    info = dict(sim=set(), profile=set(), skipped=[], generated=[], code_cov=False, wall=0.0)
    for d in dirs:
        ri = covlib.load_json(os.path.join(d, "run_info.json"), {})
        if ri:
            info["sim"].add(ri.get("sim", "?")); info["profile"].add(ri.get("profile", "?"))
            info["generated"].append(ri.get("generated", "")); info["code_cov"] |= ri.get("code_cov", False)
            info["wall"] += ri.get("wall", 0.0)
            info["skipped"] += ri.get("skipped", [])
        for sj in sorted(glob.glob(os.path.join(d, "suites", "*", "suite.json"))):
            sd = os.path.dirname(sj)
            meta = covlib.load_json(sj)
            cc = covlib.CodeCov(meta.get("cov_include"))
            cc.add_dat(os.path.join(sd, "coverage.dat"))
            fc = covlib.FuncCov.from_json(covlib.load_json(os.path.join(sd, "fcov.json"), []))
            lt = covlib.Latency.from_json(covlib.load_json(os.path.join(sd, "latency.json"), []))
            name = meta["name"]
            if name in suites:
                s = suites[name]
                s["cc"].merge(cc); s["fc"].merge(fc); s["lt"].merge(lt); s["runs"] += meta["runs"]
                s["dirs"].append(d)
            else:
                suites[name] = dict(meta=meta, cc=cc, fc=fc, lt=lt, runs=list(meta["runs"]), dirs=[d])
    ran = {n for n in suites}
    info["skipped"] = [x for x in {x["name"]: x for x in info["skipped"]}.values() if x["name"] not in ran]
    return suites, info


def bench_of(meta):
    return f"{meta['soc']}:{meta['top']}"


def merge_group(suites, names):
    cc, fc, lt = covlib.CodeCov(), covlib.FuncCov(), covlib.Latency()
    for n in names:
        s = suites[n]
        cc.merge(s["cc"])
        fc.merge(s["fc"], prefix=bench_of(s["meta"]))
        lt.merge(s["lt"])
    return cc, fc, lt


def pct(c, t):
    return (100.0 * c / t) if t else None


def fmt_pct(c, t):
    p = pct(c, t)
    return "-" if p is None else f"{p:.1f}%"


def run_stats(runs):
    n = len(runs)
    p = sum(r["status"] == "PASS" for r in runs)
    return p, n, sum(r.get("checks", 0) for r in runs)


# --------------------------------------------------------------------------- html helpers
CSS = """
.viz-root{color-scheme:light;--surface-0:#f5f5f3;--surface-1:#fcfcfb;--border:#e2e1dc;--grid:#ecebe7;
 --text-primary:#0b0b0b;--text-secondary:#52514e;--text-muted:#7a7974;--series-1:#2a78d6;--series-2:#eb6834;
 --range:#b9b8b2;--good:#0ca30c;--critical:#d03b3b;--meter-bg:#ecebe7;
 --ink-lo:#0b0b0b;--ink-hi:#ffffff;--seq-100:#cde2fb;--seq-200:#9ec5f4;--seq-300:#6da7ec;--seq-400:#3987e5;--seq-500:#256abf;--seq-600:#184f95;--seq-700:#0d366b}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])) .viz-root{color-scheme:dark;
 --surface-0:#121211;--surface-1:#1a1a19;--border:#34332f;--grid:#2a2a27;--text-primary:#f0efec;--text-secondary:#c3c2b7;
 --text-muted:#8f8e86;--series-1:#3987e5;--series-2:#d95926;--range:#5b5a55;--meter-bg:#2a2a27;
 --ink-lo:#f0efec;--ink-hi:#0b0b0b;--seq-100:#0d366b;--seq-200:#104281;--seq-300:#184f95;--seq-400:#1c5cab;--seq-500:#2a78d6;--seq-600:#5598e7;--seq-700:#9ec5f4}}
:root[data-theme="dark"] .viz-root{color-scheme:dark;--surface-0:#121211;--surface-1:#1a1a19;--border:#34332f;
 --grid:#2a2a27;--text-primary:#f0efec;--text-secondary:#c3c2b7;--text-muted:#8f8e86;--series-1:#3987e5;
 --series-2:#d95926;--range:#5b5a55;--meter-bg:#2a2a27;--ink-lo:#f0efec;--ink-hi:#0b0b0b;--seq-100:#0d366b;--seq-200:#104281;--seq-300:#184f95;
 --seq-400:#1c5cab;--seq-500:#2a78d6;--seq-600:#5598e7;--seq-700:#9ec5f4}
body{margin:0;background:var(--surface-0)}
.viz-root{font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:var(--text-primary);
 background:var(--surface-0);padding:24px 32px;max-width:1400px;margin:auto}
h1{font-size:22px;margin:0 0 4px} h2{font-size:18px;margin:32px 0 8px;border-bottom:1px solid var(--border);padding-bottom:4px}
h3{font-size:15px;margin:20px 0 6px} .sub{color:var(--text-secondary)} .muted{color:var(--text-muted)}
a{color:var(--series-1)}
.tiles{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0}
.tile{background:var(--surface-1);border:1px solid var(--border);border-radius:8px;padding:10px 14px;min-width:120px}
.tile .v{font-size:24px;font-weight:600} .tile .k{color:var(--text-secondary);font-size:12px}
table{border-collapse:collapse;background:var(--surface-1);border:1px solid var(--border);margin:6px 0 12px;font-size:13px}
th,td{padding:4px 10px;border-bottom:1px solid var(--grid);text-align:left;white-space:nowrap}
th{color:var(--text-secondary);font-weight:600} td.n{text-align:right;font-variant-numeric:tabular-nums}
.ok{color:var(--good);font-weight:600} .bad{color:var(--critical);font-weight:600}
.meter{display:inline-block;width:70px;height:6px;background:var(--meter-bg);border-radius:3px;vertical-align:middle;margin-right:6px}
.meter i{display:block;height:6px;border-radius:3px;background:var(--series-1)}
.card{background:var(--surface-1);border:1px solid var(--border);border-radius:8px;padding:12px 14px;margin:10px 0;overflow-x:auto}
.legend{display:flex;gap:16px;font-size:12px;color:var(--text-secondary);margin:4px 0 6px}
.legend span::before{content:"";display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px;background:var(--c)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px}
svg text{fill:var(--text-secondary);font-size:11px} svg .lbl{fill:var(--text-primary)}
svg .ax{stroke:var(--border)} svg text.ink-lo{fill:var(--ink-lo)} svg text.ink-hi{fill:var(--ink-hi)} svg .gl{stroke:var(--grid)}
[data-tip]{cursor:default} #tip{position:fixed;pointer-events:none;background:var(--surface-1);color:var(--text-primary);
 border:1px solid var(--border);border-radius:6px;padding:6px 8px;font-size:12px;white-space:pre;display:none;
 box-shadow:0 2px 8px rgba(0,0,0,.15);z-index:9}
details summary{cursor:pointer;color:var(--text-secondary)} code{font-size:12px}
"""

JS = """
const tip=document.getElementById('tip');
document.addEventListener('mousemove',e=>{const t=e.target.closest('[data-tip]');
 if(!t){tip.style.display='none';return;} tip.textContent=t.getAttribute('data-tip');tip.style.display='block';
 const x=Math.min(e.clientX+14,innerWidth-tip.offsetWidth-8),y=Math.min(e.clientY+14,innerHeight-tip.offsetHeight-8);
 tip.style.left=x+'px';tip.style.top=y+'px';});
"""


def esc(s):
    return html.escape(str(s), quote=True)


def meter(c, t):
    p = pct(c, t)
    if p is None:
        return '<td class="n muted">-</td>'
    return (f'<td class="n" data-tip="{c} of {t} covered"><span class="meter"><i style="width:{p:.0f}%"></i></span>'
            f'{p:.1f}%</td>')


def page(title, subtitle, body):
    return (f'<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>{esc(title)}</title>'
            f'<meta name="viewport" content="width=device-width,initial-scale=1"><style>{CSS}</style></head>'
            f'<body><div class="viz-root"><h1>{esc(title)}</h1><div class="sub">{subtitle}</div>{body}</div>'
            f'<div id="tip"></div><script>{JS}</script></body></html>')


# --------------------------------------------------------------------------- charts
SEQ = ["--seq-100", "--seq-200", "--seq-300", "--seq-400", "--seq-500", "--seq-600", "--seq-700"]


def nice_max(v):
    if v <= 0:
        return 1
    e = 10 ** math.floor(math.log10(v))
    for m in (1, 2, 2.5, 5, 10):
        if m * e >= v:
            return m * e
    return 10 * e


def ticks(vmax, n=5):
    step = nice_max(vmax / n)
    return [i * step for i in range(int(vmax / step) + 1)]


def tipstats(name, st):
    return (f"{name}\nn={st['n']}  min={st['min']}  avg={st['avg']:.1f}\n"
            f"p50={st['p50']}  p95={st['p95']}  p99={st['p99']}  max={st['max']}  (cycles)")


def heatmap(lt):
    comb = lt.combined()
    if not comb:
        return ""
    masters = sorted({m for m, _ in comb})
    slaves = sorted({s for _, s in comb})
    by = {(m, s, d): covlib.Latency.stats(c) for (m, s, d), c in lt.h.items()}
    avgs = {k: covlib.Latency.stats(c)["avg"] for k, c in comb.items() if sum(c.values())}
    lo, hi = min(avgs.values()), max(avgs.values())
    cw = max(18, min(56, 900 // max(1, len(slaves))))
    ch = 22 if cw < 34 else 26
    lw = 16 + int(7.5 * max(len(m) for m in masters))
    top = 8 + int(6.2 * max(len(s) for s in slaves)) if cw < 50 else 24
    W, H = lw + cw * len(slaves) + 10, top + ch * len(masters) + 52
    o = [f'<svg width="{W}" height="{H}" role="img" aria-label="average latency heatmap, masters by slaves">']
    for j, s in enumerate(slaves):
        x = lw + j * cw + cw / 2
        if cw < 50:
            o.append(f'<text transform="translate({x + 4},{top - 6}) rotate(-60)">{esc(s)}</text>')
        else:
            o.append(f'<text x="{x}" y="{top - 8}" text-anchor="middle">{esc(s)}</text>')
    for i, m in enumerate(masters):
        y = top + i * ch
        o.append(f'<text class="lbl" x="{lw - 6}" y="{y + ch / 2 + 4}" text-anchor="end">{esc(m)}</text>')
        for j, s in enumerate(slaves):
            x = lw + j * cw
            if (m, s) not in avgs:
                o.append(f'<rect x="{x + 1}" y="{y + 1}" width="{cw - 2}" height="{ch - 2}" rx="3" '
                         f'fill="none" stroke="var(--grid)" data-tip="{esc(m)} -> {esc(s)}: no traffic"/>')
                continue
            v = avgs[(m, s)]
            k = 0 if hi == lo else min(6, int((v - lo) / (hi - lo) * 7))
            tipl = [f"{m} -> {s}"]
            for d in ("R", "W"):
                st = by.get((m, s, d))
                if st:
                    tipl.append(f"{d}: n={st['n']} min={st['min']} avg={st['avg']:.1f} p95={st['p95']} max={st['max']}")
            o.append(f'<rect x="{x + 1}" y="{y + 1}" width="{cw - 2}" height="{ch - 2}" rx="3" '
                     f'fill="var({SEQ[k]})" data-tip="{esc(chr(10).join(tipl))}"/>')
            if cw >= 34:
                o.append(f'<text class="{"ink-hi" if k >= 4 else "ink-lo"}" x="{x + cw / 2}" y="{y + ch / 2 + 4}" '
                         f'text-anchor="middle" style="pointer-events:none">{v:.0f}</text>')
    # colour scale legend
    ly = top + ch * len(masters) + 18
    o.append(f'<text x="{lw}" y="{ly + 9}">avg cycles  {lo:.0f}</text>')
    for k in range(7):
        o.append(f'<rect x="{lw + 92 + k * 22}" y="{ly}" width="20" height="10" rx="2" fill="var({SEQ[k]})"/>')
    o.append(f'<text x="{lw + 92 + 7 * 22 + 6}" y="{ly + 9}">{hi:.0f}</text>')
    o.append("</svg>")
    return "".join(o)


def range_chart(lt, limit=40):
    rows = lt.table()
    if not rows:
        return "", 0
    paths = defaultdict(dict)
    for m, s, d, st in rows:
        paths[(m, s)][d] = st
    order = sorted(paths, key=lambda k: -max(st["p95"] for st in paths[k].values()))
    shown = order[:limit]
    vmax = nice_max(max(max(st["max"] for st in paths[k].values()) for k in shown))
    lw = 16 + int(7 * max(len(f"{m} -> {s}") for m, s in shown))
    pw, rh = 620, 10
    gh = 2 * rh + 10
    top = 20
    W, H = lw + pw + 30, top + gh * len(shown) + 30
    X = lambda v: lw + v / vmax * pw
    o = [f'<svg width="{W}" height="{H}" role="img" aria-label="latency range per path">']
    for t in ticks(vmax):
        o.append(f'<line class="gl" x1="{X(t)}" x2="{X(t)}" y1="{top - 4}" y2="{H - 26}"/>'
                 f'<text x="{X(t)}" y="{H - 12}" text-anchor="middle">{t:g}</text>')
    o.append(f'<text x="{lw + pw}" y="{H - 0}" text-anchor="end">cycles</text>')
    for i, k in enumerate(shown):
        y0 = top + i * gh
        o.append(f'<text class="lbl" x="{lw - 8}" y="{y0 + rh + 4}" text-anchor="end">{esc(k[0])} -&gt; {esc(k[1])}</text>')
        for j, d in enumerate(("R", "W")):
            st = paths[k].get(d)
            if not st:
                continue
            y = y0 + j * (rh + 2)
            col = "var(--series-1)" if d == "R" else "var(--series-2)"
            tip = esc(tipstats(f"{k[0]} -> {k[1]} {'read' if d == 'R' else 'write'}", st))
            o.append(f'<g data-tip="{tip}"><rect x="{lw}" y="{y - 1}" width="{pw}" height="{rh + 2}" fill="transparent"/>'
                     f'<line x1="{X(st["min"])}" x2="{X(st["max"])}" y1="{y + rh / 2}" y2="{y + rh / 2}" '
                     f'stroke="var(--range)" stroke-width="2"/>'
                     f'<rect x="{X(st["p50"])}" y="{y}" width="{max(2, X(st["p95"]) - X(st["p50"]))}" height="{rh}" '
                     f'rx="3" fill="{col}"/>'
                     f'<circle cx="{X(st["avg"])}" cy="{y + rh / 2}" r="4" fill="{col}" stroke="var(--surface-1)" '
                     f'stroke-width="2"/></g>')
    o.append("</svg>")
    return "".join(o), len(order)


def histograms(lt, limit=12, nbins=24):
    comb = lt.combined()
    if not comb:
        return ""
    busiest = sorted(comb, key=lambda k: -sum(comb[k].values()))[:limit]
    cards = []
    for (m, s) in busiest:
        r = lt.h.get((m, s, "R"), Counter())
        w = lt.h.get((m, s, "W"), Counter())
        allv = r + w
        lo, hi = min(allv), max(allv)
        width = max(1, math.ceil((hi - lo + 1) / nbins))
        nb = max(1, math.ceil((hi - lo + 1) / width))
        br, bw = [0] * nb, [0] * nb
        for v, c in r.items():
            br[(v - lo) // width] += c
        for v, c in w.items():
            bw[(v - lo) // width] += c
        cmax = nice_max(max(a + b for a, b in zip(br, bw)))
        W, H, L, B = 290, 150, 34, 24
        pw, ph = W - L - 8, H - B - 10
        bwid = pw / nb
        o = [f'<svg width="{W}" height="{H}" role="img" aria-label="latency histogram {esc(m)} to {esc(s)}">']
        for t in ticks(cmax, 3):
            y = 10 + ph - t / cmax * ph
            o.append(f'<line class="gl" x1="{L}" x2="{L + pw}" y1="{y}" y2="{y}"/>'
                     f'<text x="{L - 4}" y="{y + 4}" text-anchor="end">{t:g}</text>')
        for i in range(nb):
            x = L + i * bwid
            a, b = br[i], bw[i]
            lo_i, hi_i = lo + i * width, lo + (i + 1) * width - 1
            tip = esc(f"{m} -> {s}\n{lo_i}" + (f"-{hi_i}" if hi_i != lo_i else "") + f" cycles\nR {a}  W {b}")
            hr, hw = a / cmax * ph, b / cmax * ph
            yb = 10 + ph
            o.append(f'<g data-tip="{tip}"><rect x="{x}" y="10" width="{bwid}" height="{ph}" fill="transparent"/>')
            if a:
                o.append(f'<rect x="{x + 1}" y="{yb - hr}" width="{max(1, bwid - 2)}" height="{hr}" fill="var(--series-1)"/>')
            if b:
                gap = 2 if a else 0
                o.append(f'<rect x="{x + 1}" y="{yb - hr - hw}" width="{max(1, bwid - 2)}" '
                         f'height="{max(0, hw - gap)}" fill="var(--series-2)"/>')
            o.append("</g>")
        o.append(f'<line class="ax" x1="{L}" x2="{L + pw}" y1="{10 + ph}" y2="{10 + ph}"/>'
                 f'<text x="{L}" y="{H - 6}">{lo}</text><text x="{L + pw}" y="{H - 6}" text-anchor="end">{hi} cycles</text>')
        o.append("</svg>")
        st = covlib.Latency.stats(allv)
        cards.append(f'<div class="card"><b>{esc(m)} &rarr; {esc(s)}</b> <span class="muted">n={st["n"]}, '
                     f'avg {st["avg"]:.1f}, p95 {st["p95"]}</span><br>{"".join(o)}</div>')
    return f'<div class="grid">{"".join(cards)}</div>'


def latency_table(lt):
    rows = lt.table()
    out = ['<table><tr><th>Master</th><th>Slave</th><th>Dir</th><th>Samples</th><th>Min</th><th>Avg</th>'
           '<th>p50</th><th>p95</th><th>p99</th><th>Max</th></tr>']
    for m, s, d, st in rows:
        out.append(f'<tr><td>{esc(m)}</td><td>{esc(s)}</td><td>{d}</td><td class="n">{st["n"]}</td>'
                   f'<td class="n">{st["min"]}</td><td class="n">{st["avg"]:.1f}</td><td class="n">{st["p50"]}</td>'
                   f'<td class="n">{st["p95"]}</td><td class="n">{st["p99"]}</td><td class="n">{st["max"]}</td></tr>')
    out.append("</table>")
    return "".join(out)


def latency_section(lt, title):
    if not len(lt):
        return f'<h3>{esc(title)}</h3><p class="muted">No latency samples in this group (its benches do not feed lat_pkg).</p>'
    rc, n = range_chart(lt)
    legend = ('<div class="legend"><span style="--c:var(--series-1)">read</span>'
              '<span style="--c:var(--series-2)">write</span>'
              '<span class="muted" style="--c:transparent">bar = p50 to p95, dot = average, line = min to max</span></div>')
    return (f'<h3>{esc(title)}</h3><div class="muted">{len(lt)} samples over {len(lt.h)} path/direction pairs, '
            f'in clock cycles (address handshake to last R beat or B). Hover any mark for exact numbers.</div>'
            f'<div class="card"><b>Average latency, master &times; slave</b> (reads and writes together)<br>{heatmap(lt)}</div>'
            f'<div class="card"><b>Latency range per path</b>'
            f'{" (the 40 slowest of " + str(n) + " paths by p95)" if n > 40 else ""}{legend}{rc}</div>'
            f'<div class="card"><b>Latency distribution</b> (the busiest paths){legend.replace("bar = p50 to p95, dot = average, line = min to max", "stacked: reads below, writes above")}'
            f'{histograms(lt)}</div>'
            f'<details><summary>Per-path table ({len(lt.h)} rows)</summary>{latency_table(lt)}</details>')


# --------------------------------------------------------------------------- coverage sections
def code_cov_rows(cc):
    tot, mods = cc.summary()
    return tot, mods


def module_table(mods):
    out = ['<table><tr><th>Module</th><th>Line</th><th>Branch</th><th>Toggle</th><th>Expr</th></tr>']
    for mod in sorted(mods):
        t = mods[mod]
        out.append(f'<tr><td>{esc(mod)}</td>{meter(*t["line"])}{meter(*t["branch"])}{meter(*t["toggle"])}'
                   f'{meter(*t["expr"])}</tr>')
    out.append("</table>")
    return "".join(out)


def holes_block(cc):
    pts = cc.design_points()
    lines = sorted(((m, l, t, c) for (t, m, l, col, c), n in pts.items() if n == 0 and t in ("line", "branch")))
    ntog = sum(1 for (t, *_), n in pts.items() if n == 0 and t == "toggle")
    if not lines and not ntog:
        return '<p class="ok">No uncovered line or branch points.</p>'
    body = "".join(f"<tr><td>{esc(m)}</td><td class='n'>{l}</td><td>{t}</td><td><code>{esc(c)}</code></td></tr>"
                   for m, l, t, c in lines[:300])
    more = f"<p class='muted'>... {len(lines) - 300} more</p>" if len(lines) > 300 else ""
    return (f'<details><summary>{len(lines)} uncovered line/branch points, {ntog} untoggled signal bits</summary>'
            f'<table><tr><th>Module</th><th>Line</th><th>Type</th><th>Point</th></tr>{body}</table>{more}'
            f'<p class="muted">Annotated source: <code>verilator_coverage --annotate annotated/ '
            f'cumulative/coverage.dat</code></p></details>')


def fcov_model_table(fc):
    bm = fc.by_model()
    if not bm:
        return '<p class="muted">No functional coverage reported.</p>'
    out = ['<table><tr><th>Model</th><th>Point</th><th>Bins</th><th>Holes</th></tr>']
    for m in sorted(bm):
        for p in sorted(bm[m]):
            c, t, holes = bm[m][p]
            out.append(f'<tr><td>{esc(m)}</td><td>{esc(p)}</td>{meter(c, t)}<td class="muted">'
                       f'{esc(", ".join(sorted(holes)[:8]))}{" ..." if len(holes) > 8 else ""}</td></tr>')
    out.append("</table>")
    return "".join(out)


def fcov_inst_table(fc):
    bg = fc.by_group()
    out = ['<table><tr><th>Instance</th><th>Model</th><th>Bins</th></tr>']
    for (m, i) in sorted(bg, key=lambda k: (k[1], k[0])):
        c = sum(v[0] for v in bg[(m, i)].values())
        t = sum(v[1] for v in bg[(m, i)].values())
        out.append(f'<tr><td>{esc(i)}</td><td>{esc(m)}</td>{meter(c, t)}</tr>')
    out.append("</table>")
    return "".join(out)


def cg_note(cc):
    cg = cc.covergroup_bins()
    if not cg:
        return ""
    c = sum(1 for v in cg.values() if v)
    return (f'<p class="muted">Native SystemVerilog covergroups (recorded by the simulator, instances folded): '
            f'{c}/{len(cg)} bins hit ({fmt_pct(c, len(cg))}).</p>')


# --------------------------------------------------------------------------- main writer
def suite_row(name, s, link=True):
    m = s["meta"]
    p, n, chk = run_stats(s["runs"])
    tot, _ = s["cc"].summary()
    fcc, fct = s["fc"].totals()
    nm = f'<a href="suites/{esc(name)}/index.html">{esc(name)}</a>' if link else esc(name)
    st = f'<span class="{"ok" if p == n else "bad"}">{p}/{n}</span>'
    return (f'<tr><td>{nm}</td><td>{m["level"]}</td><td>{esc(m["soc"])}</td><td>{esc(m.get("subsystem") or "-")}</td>'
            f'<td class="n">{st}</td><td class="n">{chk}</td>{meter(*tot["line"])}{meter(*tot["branch"])}'
            f'{meter(*tot["toggle"])}{meter(fcc, fct)}<td class="n">{len(s["lt"])}</td>'
            f'<td class="muted">{esc(m.get("note") or "")}</td></tr>')


SUITE_HDR = ('<tr><th>Suite</th><th>Level</th><th>SoC</th><th>Subsystem</th><th>Runs passed</th><th>Checks</th>'
             '<th>Line</th><th>Branch</th><th>Toggle</th><th>Functional</th><th>Latency samples</th><th></th></tr>')


def rollup_groups(suites):
    groups = [("All suites (cumulative)", list(suites))]
    for lv in LEVELS:
        ns = [n for n, s in suites.items() if s["meta"]["level"] == lv]
        if ns:
            groups.append((f"Level: {lv}", ns))
    for soc in sorted({s["meta"]["soc"] for s in suites.values()}):
        ns = [n for n, s in suites.items() if s["meta"]["soc"] == soc]
        groups.append((f"SoC: {soc}", ns))
        subs = [n for n in ns if suites[n]["meta"]["level"] == "subsystem"]
        if subs and len(subs) < len(ns):
            groups.append((f"SoC: {soc}, subsystem suites only", subs))
    return groups


def write_reports(dirs, out):
    suites, info = load_suites(dirs)
    os.makedirs(os.path.join(out, "cumulative"), exist_ok=True)
    allcc, allfc, alllt = merge_group(suites, list(suites))
    allcc.write_dat(os.path.join(out, "cumulative", "coverage.dat"))
    covlib.save_json(os.path.join(out, "cumulative", "fcov.json"), allfc.to_json())
    lat_by_soc = {}
    for soc in sorted({s["meta"]["soc"] for s in suites.values()}):
        lt = covlib.Latency()
        for s in suites.values():
            if s["meta"]["soc"] == soc:
                lt.merge(s["lt"])
        lat_by_soc[soc] = lt
    covlib.save_json(os.path.join(out, "cumulative", "latency.json"),
                     {soc: lt.to_json() for soc, lt in lat_by_soc.items()})

    allruns = [r for s in suites.values() for r in s["runs"]]
    p, n, chk = run_stats(allruns)
    tot, mods = allcc.summary()
    fcc, fct = allfc.totals()
    sims = ", ".join(sorted(info["sim"])) or "?"
    sub = (f'{len(suites)} suites, {n} runs, simulator {esc(sims)}, profile {esc(", ".join(sorted(info["profile"])))}'
           f'{", merged from " + str(len(dirs)) + " output directories" if len(dirs) > 1 else ""}. '
           f'Generated {esc(max(info["generated"]) if info["generated"] else "")}.')
    tiles = "".join(f'<div class="tile"><div class="v">{v}</div><div class="k">{k}</div></div>' for k, v in [
        ("runs passed", f'<span class="{"ok" if p == n else "bad"}">{p}/{n}</span>'),
        ("scoreboard checks", f"{chk:,}"),
        ("line coverage", fmt_pct(*tot["line"])), ("branch coverage", fmt_pct(*tot["branch"])),
        ("toggle coverage", fmt_pct(*tot["toggle"])), ("functional bins", fmt_pct(fcc, fct)),
        ("latency samples", f"{len(alllt):,}")])
    body = [f'<div class="tiles">{tiles}</div>']
    if not info["code_cov"]:
        body.append('<p class="muted">Code coverage was not collected (non-Verilator simulator or --no-cov).</p>')
    body.append(f'<h2>Suites</h2><table>{SUITE_HDR}{"".join(suite_row(nm, s) for nm, s in suites.items())}</table>')
    if info["skipped"]:
        body.append("<p class='muted'>Not run: " + "; ".join(f"{esc(x['name'])} ({esc(x['note'])})"
                                                           for x in info["skipped"]) + "</p>")
    # rollups
    rows = []
    for title, ns in rollup_groups(suites):
        cc, fc, lt = merge_group(suites, ns)
        t, _ = cc.summary()
        c1, t1 = fc.totals()
        pp, nn, ck = run_stats([r for x in ns for r in suites[x]["runs"]])
        rows.append(f'<tr><td>{esc(title)}</td><td class="n">{len(ns)}</td><td class="n">'
                    f'<span class="{"ok" if pp == nn else "bad"}">{pp}/{nn}</span></td>{meter(*t["line"])}'
                    f'{meter(*t["branch"])}{meter(*t["toggle"])}{meter(c1, t1)}</tr>')
    body.append('<h2>Coverage roll-ups</h2><div class="muted">Coverage adds up: a design point counts as covered '
                'if any run of any suite in the group hit it. Code coverage is merged per RTL module and source line, '
                'so an IP exercised by both its subsystem bench and the SoC bench is credited once with the union. '
                'Functional bins are merged per bench and coverage instance.</div>'
                '<table><tr><th>Group</th><th>Suites</th><th>Runs passed</th><th>Line</th><th>Branch</th>'
                f'<th>Toggle</th><th>Functional</th></tr>{"".join(rows)}</table>')
    body.append(f'<h2>Code coverage by RTL module (cumulative)</h2>{module_table(mods)}{holes_block(allcc)}')
    body.append(f'<h2>Functional coverage (cumulative)</h2><h3>By coverage model, all instances and benches folded</h3>'
                f'{fcov_model_table(allfc)}<details><summary>By bench and instance</summary>'
                f'{fcov_inst_table(allfc)}</details>{cg_note(allcc)}')
    body.append("<h2>Per-path latency</h2>")
    for soc, lt in lat_by_soc.items():
        body.append(latency_section(lt, f"SoC: {soc}"))
    with open(os.path.join(out, "index.html"), "w") as f:
        f.write(page("SoC regression: cumulative coverage and latency", sub, "".join(body)))

    # per-suite pages
    for nm, s in suites.items():
        sd = os.path.join(out, "suites", nm)
        os.makedirs(sd, exist_ok=True)
        m = s["meta"]
        t, md = s["cc"].summary()
        runs = "".join(f'<tr><td>{esc(r["tag"])}</td><td class="n">{r["seed"]}</td>'
                       f'<td class="{"ok" if r["status"] == "PASS" else "bad"}">{r["status"]}</td>'
                       f'<td class="n">{r["checks"]}</td><td class="n">{r["secs"]:.1f}</td>'
                       f'<td>{esc(r["detail"])}</td><td><a href="logs/{esc(os.path.basename(r["log"]))}">log</a></td></tr>'
                       for r in sorted(s["runs"], key=lambda r: (r["tag"], r["seed"])))
        b = [f'<p><a href="../../index.html">&larr; cumulative report</a></p>',
             f'<table>{SUITE_HDR}{suite_row(nm, s, link=False)}</table>',
             f'<p class="muted">{esc(m.get("description", ""))} Bench <code>{esc(m["filelist"])}</code> :: '
             f'<code>{esc(m["top"])}</code>, defined in <code>{esc(m["_path"])}</code>.</p>',
             f'<h2>Runs</h2><table><tr><th>Test</th><th>Seed</th><th>Status</th><th>Checks</th><th>Seconds</th>'
             f'<th>Detail</th><th></th></tr>{runs}</table>',
             f'<h2>Code coverage</h2>{module_table(md)}{holes_block(s["cc"])}',
             f'<h2>Functional coverage</h2>{fcov_model_table(s["fc"])}<details><summary>By instance</summary>'
             f'{fcov_inst_table(s["fc"])}</details>',
             '<h2>Per-path latency</h2>' + latency_section(s["lt"], nm)]
        with open(os.path.join(sd, "index.html"), "w") as f:
            f.write(page(f"Suite {nm}", f'{m["level"]} suite of SoC {esc(m["soc"])}', "".join(b)))

    write_markdown(suites, info, allcc, allfc, lat_by_soc, os.path.join(out, "summary.md"))


def write_markdown(suites, info, allcc, allfc, lat_by_soc, path):
    allruns = [r for s in suites.values() for r in s["runs"]]
    p, n, chk = run_stats(allruns)
    tot, _ = allcc.summary()
    fcc, fct = allfc.totals()
    L = [f"# Regression summary\n",
         f"{p}/{n} runs passed over {len(suites)} suites ({chk:,} scoreboard checks). Cumulative coverage: "
         f"line {fmt_pct(*tot['line'])}, branch {fmt_pct(*tot['branch'])}, toggle {fmt_pct(*tot['toggle'])}, "
         f"functional {fmt_pct(fcc, fct)}. Full report: `index.html`.\n",
         "| Suite | Level | SoC | Subsystem | Runs passed | Checks | Line | Branch | Toggle | Functional | Failing |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for nm, s in suites.items():
        m = s["meta"]
        pp, nn, ck = run_stats(s["runs"])
        t, _ = s["cc"].summary()
        c1, t1 = s["fc"].totals()
        fails = " ".join(sorted({f"{r['tag']}:s{r['seed']}" for r in s["runs"] if r["status"] != "PASS"})[:6]) or "-"
        L.append(f"| {nm} | {m['level']} | {m['soc']} | {m.get('subsystem') or '-'} | {pp}/{nn} | {ck} | "
                 f"{fmt_pct(*t['line'])} | {fmt_pct(*t['branch'])} | {fmt_pct(*t['toggle'])} | {fmt_pct(c1, t1)} | {fails} |")
    L += ["", "## Roll-ups (coverage adds up across suites)", "",
          "| Group | Suites | Runs passed | Line | Branch | Toggle | Functional |", "|---|---|---|---|---|---|---|"]
    for title, ns in rollup_groups(suites):
        cc, fc, lt = merge_group(suites, ns)
        t, _ = cc.summary()
        c1, t1 = fc.totals()
        pp, nn, _ = run_stats([r for x in ns for r in suites[x]["runs"]])
        L.append(f"| {title} | {len(ns)} | {pp}/{nn} | {fmt_pct(*t['line'])} | {fmt_pct(*t['branch'])} | "
                 f"{fmt_pct(*t['toggle'])} | {fmt_pct(c1, t1)} |")
    for soc, lt in lat_by_soc.items():
        rows = lt.table()
        if not rows:
            continue
        L += ["", f"## Latency, SoC {soc} (cycles; slowest 20 by p95)", "",
              "| Master | Slave | Dir | n | min | avg | p50 | p95 | p99 | max |", "|---|---|---|---|---|---|---|---|---|---|"]
        for m, s, d, st in sorted(rows, key=lambda r: -r[3]["p95"])[:20]:
            L.append(f"| {m} | {s} | {d} | {st['n']} | {st['min']} | {st['avg']:.1f} | {st['p50']} | {st['p95']} | "
                     f"{st['p99']} | {st['max']} |")
    if info["skipped"]:
        L += ["", "Not run: " + "; ".join(f"{x['name']} ({x['note']})" for x in info["skipped"])]
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")
