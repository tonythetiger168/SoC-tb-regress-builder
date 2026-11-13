#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Score a merged Verilator coverage file against a scope and a waiver list.

  score_cov.py merged.dat --scope 'rtl/soc/' [--scope ...] [--exclude FILE]
               [--exclude-opt FILE] [--json OUT]

Metrics: line, branch, toggle (code coverage of files whose path matches a
--scope regex), user (SVA cover properties, any file) and covergroup
(functional coverage bins, any file). A point is named
"<metric> <hierarchy> <comment> [<file>[:<line>]]", e.g.
"toggle soc_tb_top.dut.u_bridge paddr[16]:0->1 rtl/soc/axi2apb_bridge.sv"
(Verilator may merge instances of one module into a "u_*" hierarchy). An exclude file holds
"<metric> <regex> # reason" lines; a matching point is waived. Exit status 1
if any point in scope is neither hit nor waived, or a waiver of an --exclude
file matches nothing (--exclude-opt files, e.g. socgen's generated
<soc>_cov_waivers.txt, may hold waivers that match nothing).
"""
import argparse, json, re, sys
from collections import defaultdict

CODE = ("line", "branch", "toggle")


def points(path):
    for ln in open(path, errors="replace"):
        if not ln.startswith("C '"):
            continue
        body, cnt = ln.rstrip("\n").rsplit("' ", 1)
        kv = dict(x.split("\x02", 1) for x in body[3:].split("\x01") if "\x02" in x)
        yield kv, int(cnt)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dat")
    ap.add_argument("--scope", action="append", default=[], help="regex on the source path (code metrics)")
    ap.add_argument("--exclude", action="append", default=[])
    ap.add_argument("--exclude-opt", action="append", default=[])
    ap.add_argument("--json", default=None)
    a = ap.parse_args()

    waivers = []
    for path, required in [(f, True) for f in a.exclude] + [(f, False) for f in a.exclude_opt]:
        for ln in open(path):
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            rule, _, why = ln.partition(" # ")
            metric, rx = rule.split(None, 1)
            waivers.append([metric, re.compile(rx.strip()), why.strip(), 0 if required else -1])

    # merge points with the same name (Verilator keeps one per source location)
    hits = {}
    for kv, cnt in points(a.dat):
        t = kv.get("t", "")
        f = kv.get("f", "")
        if t in CODE:
            if not any(re.search(s, f) for s in a.scope):
                continue
        elif t not in ("user", "covergroup"):
            continue
        name = f"{t} {kv.get('h', '')} {kv.get('o', kv.get('bin', ''))}"
        if t == "line" or t == "branch":
            name += f" {f}:{kv.get('l', '')}"
        elif t == "toggle":
            name += f" {f}"
        if t == "covergroup":
            name = f"covergroup {f}:{kv.get('l', '')} {kv.get('h', '')}"
        hits[name] = hits.get(name, 0) + cnt

    tot, hit, waived, holes = defaultdict(int), defaultdict(int), defaultdict(int), []
    for name, cnt in sorted(hits.items()):
        metric = name.split(" ", 1)[0]
        tot[metric] += 1
        if cnt > 0:
            hit[metric] += 1
            continue
        w = next((w for w in waivers if w[0] == metric and w[1].search(name)), None)
        if w:
            w[3] = max(w[3], 0) + 1
            waived[metric] += 1
        else:
            holes.append(name)

    unused = [f"{w[0]} {w[1].pattern}" for w in waivers if w[3] == 0]   # -1: optional, unused
    rep = {}
    for m in CODE + ("user", "covergroup"):
        if tot[m]:
            pct = 100.0 * (hit[m] + waived[m]) / tot[m]
            rep[m] = {"points": tot[m], "hit": hit[m], "waived": waived[m], "pct": round(pct, 2)}
            print(f"{m:10s} {hit[m]:6d} hit + {waived[m]:4d} waived / {tot[m]:6d}  {pct:6.2f}%")
    for h in holes:
        print("HOLE", h)
    for u in unused:
        print("UNUSED_WAIVER", u)
    closed = not holes and not unused
    print("CLOSED" if closed else f"OPEN: {len(holes)} holes, {len(unused)} unused waivers")
    if a.json:
        json.dump({"metrics": rep, "holes": holes, "unused_waivers": unused, "closed": closed},
                  open(a.json, "w"), indent=1)
    return 0 if closed else 1


if __name__ == "__main__":
    sys.exit(main())
