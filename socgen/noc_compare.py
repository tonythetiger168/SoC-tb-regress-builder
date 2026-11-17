#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""noc_compare -- per-path latency of two regression suites, side by side

  python3 socgen/noc_compare.py regress_out/suites/phone_soc/latency.json \\
      regress_out/suites/phone_soc_mesh/latency.json -o phone_noc_compare.html

Inputs are the suites' latency.json (regress.py: [master, slave, R|W,
{cycles: count}] per path). Typically the behavioural NoC bench and the same
spec on the generated mesh RTL (socgen.py --noc-model mesh). Writes an HTML
page (charts + table) and, next to it, a .md table and a .csv.
"""
import argparse
import html
import json
import os


def load(p):
    out = {}
    for m, s, d, hist in json.load(open(p)):
        v = []
        for c, n in hist.items():
            v += [int(c)] * int(n)
        v.sort()
        out[(m, s, d)] = v
    return out


def stats(v):
    if not v:
        return None
    k = max(0, (99 * len(v) + 99) // 100 - 1)
    return dict(n=len(v), min=v[0], avg=sum(v) / len(v), p99=v[k], max=v[-1])


def svg_scatter(rows, la, lb, w=520, h=420):
    pts = [(r["a"]["avg"], r["b"]["avg"], r) for r in rows if r["a"] and r["b"]]
    if not pts:
        return ""
    hi = max(max(x, y) for x, y, _ in pts) * 1.08
    L, B, R, T = 54, 44, 16, 16
    sx = lambda x: L + x / hi * (w - L - R)
    sy = lambda y: h - B - y / hi * (h - B - T)
    o = [f'<svg viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-label="average latency per path">']
    step = max(5, int(hi / 6 / 5 + 1) * 5)
    for t in range(0, int(hi) + 1, step):
        o.append(f'<line x1="{L}" x2="{w - R}" y1="{sy(t):.1f}" y2="{sy(t):.1f}" class="grid"/>')
        o.append(f'<text x="{L - 6}" y="{sy(t) + 4:.1f}" text-anchor="end" class="tick">{t}</text>')
        o.append(f'<text x="{sx(t):.1f}" y="{h - B + 16}" text-anchor="middle" class="tick">{t}</text>')
    o.append(f'<line x1="{sx(0)}" y1="{sy(0)}" x2="{sx(hi)}" y2="{sy(hi)}" class="diag"/>')
    for x, y, r in pts:
        cls = "pr" if r["d"] == "R" else "pw"
        tip = f'{r["m"]} -> {r["s"]} {r["d"]}: {la} {x:.1f}, {lb} {y:.1f} cycles'
        o.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="4" class="{cls}" stroke="var(--bg)" stroke-width="1.5"><title>{html.escape(tip)}</title></circle>')
    o.append(f'<text x="{(L + w - R) / 2}" y="{h - 6}" text-anchor="middle" class="lab">{html.escape(la)} avg (cycles)</text>')
    o.append(f'<text x="14" y="{(T + h - B) / 2}" text-anchor="middle" class="lab" '
             f'transform="rotate(-90 14 {(T + h - B) / 2})">{html.escape(lb)} avg (cycles)</text>')
    o.append("</svg>")
    return "\n".join(o)


def svg_bars(rows, la, lb, w=720):
    """average read latency per master, both benches"""
    per = {}
    for r in rows:
        if r["d"] != "R":
            continue
        for k in ("a", "b"):
            if r[k]:
                per.setdefault(r["m"], {"a": [], "b": []})[k].append(r[k]["avg"])
    if not per:
        return ""
    ms = list(per)
    av = {m: {k: (sum(v) / len(v) if v else 0) for k, v in per[m].items()} for m in ms}
    hi = max(max(x.values()) for x in av.values()) * 1.1
    bh, gap, L, R = 9, 8, 90, 50
    h = len(ms) * (2 * bh + gap) + 30
    sx = lambda x: L + x / hi * (w - L - R)
    o = [f'<svg viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-label="average read latency per master">']
    y = 8
    for m in ms:
        o.append(f'<text x="{L - 8}" y="{y + bh + 3}" text-anchor="end" class="tick">{html.escape(m)}</text>')
        for k, cls, lab in (("a", "ba", la), ("b", "bb", lb)):
            v = av[m][k]
            o.append(f'<rect x="{L}" y="{y}" width="{sx(v) - L:.1f}" height="{bh - 2}" rx="2" class="{cls}">'
                     f'<title>{html.escape(f"{m} {lab}: {v:.1f} cycles")}</title></rect>')
            o.append(f'<text x="{sx(v) + 4:.1f}" y="{y + bh - 1}" class="val">{v:.1f}</text>')
            y += bh
        y += gap
    o.append("</svg>")
    return "\n".join(o)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", help="latency.json of the first bench (e.g. behavioural NoC)")
    ap.add_argument("b", help="latency.json of the second bench (e.g. generated mesh RTL)")
    ap.add_argument("--labels", default="behavioural,mesh RTL")
    ap.add_argument("--title", default="NoC latency: behavioural model vs generated mesh RTL")
    ap.add_argument("-o", "--out", default="noc_compare.html")
    a = ap.parse_args()
    la, lb = a.labels.split(",", 1)
    A, Bd = load(a.a), load(a.b)
    rows = []
    for k in sorted(set(A) | set(Bd)):
        rows.append(dict(m=k[0], s=k[1], d=k[2], a=stats(A.get(k, [])), b=stats(Bd.get(k, []))))

    both = [r for r in rows if r["a"] and r["b"]]
    ratio = [r["b"]["avg"] / r["a"]["avg"] for r in both if r["a"]["avg"]]
    summ = (f"{len(rows)} paths, {len(both)} measured in both. Average {lb} / {la} ratio "
            f"{sum(ratio) / len(ratio):.2f} (min {min(ratio):.2f}, max {max(ratio):.2f})." if ratio else "")

    def cell(s, f):
        return "-" if not s else (f"{s[f]:.1f}" if f == "avg" else str(s[f]))

    hdr = ["master", "slave", "dir"] + [f"{l} {f}" for l in (la, lb) for f in ("n", "min", "avg", "p99", "max")] + ["avg delta"]
    md = [f"# {a.title}", "", summ, "", "| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
    csv = [",".join(h.replace(" ", "_") for h in hdr)]
    trs = []
    for r in rows:
        dl = f'{r["b"]["avg"] - r["a"]["avg"]:+.1f}' if r["a"] and r["b"] else "-"
        cells = [r["m"], r["s"], r["d"]] + [cell(r[k], f) for k in ("a", "b") for f in ("n", "min", "avg", "p99", "max")] + [dl]
        md.append("| " + " | ".join(cells) + " |")
        csv.append(",".join(cells))
        trs.append("<tr>" + "".join(f"<td>{html.escape(c)}</td>" for c in cells) + "</tr>")
    base = os.path.splitext(a.out)[0]
    open(base + ".md", "w").write("\n".join(md) + "\n")
    open(base + ".csv", "w").write("\n".join(csv) + "\n")
    page = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>{html.escape(a.title)}</title>
<style>
:root {{ --fg:#0b0b0b; --mute:#52514e; --grid:#e6e5e0; --a:#2a78d6; --b:#eb6834; --bg:#fcfcfb; }}
@media (prefers-color-scheme: dark) {{ :root {{ --fg:#f0efec; --mute:#c3c2b7; --grid:#383835; --a:#3987e5; --b:#d95926; --bg:#1a1a19; }} }}
body {{ font: 14px/1.45 system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 24px; max-width: 1200px; }}
h1 {{ font-size: 20px; }} h2 {{ font-size: 16px; margin-top: 28px; }}
.grid {{ stroke: var(--grid); }} .diag {{ stroke: var(--mute); stroke-dasharray: 4 3; }}
.tick, .val {{ fill: var(--mute); font-size: 11px; }} .lab {{ fill: var(--fg); font-size: 12px; }}
.pr {{ fill: var(--a); }} .pw {{ fill: var(--b); }} .ba {{ fill: var(--a); }} .bb {{ fill: var(--b); }}
.key span {{ display: inline-block; width: 10px; height: 10px; margin: 0 4px 0 12px; border-radius: 2px; }}
table {{ border-collapse: collapse; font-size: 12px; }} td, th {{ padding: 3px 8px; border-bottom: 1px solid var(--grid); text-align: right; }}
td:nth-child(-n+3), th:nth-child(-n+3) {{ text-align: left; }}
.charts {{ display: flex; flex-wrap: wrap; gap: 32px; align-items: flex-start; }}
</style></head><body>
<h1>{html.escape(a.title)}</h1>
<p>{html.escape(summ)} Cycles from the first VALID to the last response beat, from the LAT lines of every test in each suite.</p>
<div class="charts">
<div><h2>Average per path: {html.escape(la)} (x) vs {html.escape(lb)} (y)</h2>
<div class="key"><span style="background:var(--a)"></span>read<span style="background:var(--b)"></span>write; dashed line: equal</div>
{svg_scatter(rows, la, lb)}</div>
<div><h2>Average read latency per master</h2>
<div class="key"><span style="background:var(--a)"></span>{html.escape(la)}<span style="background:var(--b)"></span>{html.escape(lb)}</div>
{svg_bars(rows, la, lb)}</div>
</div>
<h2>Every path</h2>
<table><thead><tr>{"".join(f"<th>{html.escape(h)}</th>" for h in hdr)}</tr></thead><tbody>
{chr(10).join(trs)}
</tbody></table>
<p>Inputs: {html.escape(a.a)} and {html.escape(a.b)}.</p>
</body></html>
"""
    open(a.out, "w").write(page)
    print(f"noc_compare: {len(rows)} paths -> {a.out}, {base}.md, {base}.csv")
    if summ:
        print(summ)


if __name__ == "__main__":
    main()
