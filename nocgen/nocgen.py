#!/usr/bin/env python3
"""nocgen: generate a UVM testbench and a memory/latency profile for an AXI NoC mesh.

Input : a YAML/JSON config with the mesh size, the AXI masters and slaves, the
        router/link timing and (optionally) a traffic matrix.
Output: <out>/tb/...       UVM testbench (params pkg, AXI interface, agents,
                           latency scoreboard, sequences, tests, top, and a
                           behavioral NoC stub so it runs without the real DUT)
        <out>/profile/...  memory profile: shortest-path latency per
                           master/slave pair, optimised slave placement and
                           address map, per-master "place hot data here" ranking.

Usage : python3 nocgen.py examples/mesh4x4.yaml -o out/mesh4x4
"""
from __future__ import annotations

import argparse
import heapq
import itertools
import json
import math
import os
import random
import sys
from dataclasses import dataclass, field

try:
    import yaml  # type: ignore
except ImportError:  # JSON configs still work without PyYAML
    yaml = None

from jinja2 import Environment, FileSystemLoader, StrictUndefined

HERE = os.path.dirname(os.path.abspath(__file__))


# --------------------------------------------------------------------------
# Config model
# --------------------------------------------------------------------------
@dataclass
class Endpoint:
    name: str
    kind: str                      # "master" | "slave"
    node: tuple[int, int] | None   # None = auto-place
    fixed: bool
    size: int = 0                  # slaves only
    base: int | None = None        # slaves only, None = auto-allocate
    latency: int = 0               # slave access cycles
    idx: int = 0
    memory: bool = True            # slaves only: False = device (holds no data regions)


@dataclass
class Region:
    """A block of data the masters call, e.g. a stack, ring or frame buffer."""
    name: str
    size: int                      # bytes, rounded up to 4 KB
    access: dict[str, float]       # master -> relative call count
    allowed: list[str]             # slaves that may hold it
    readonly: bool                 # read-only data may be copied next to each caller
    home: str | None               # current/hand-picked slave (baseline); None = first fit
    pin: bool                      # keep it on `home`
    group: str                     # original region name when split into chunks


@dataclass
class Config:
    name: str
    rows: int
    cols: int
    routing: str
    router_cycles: int
    link_cycles: int
    ni_cycles: int
    addr_width: int
    data_width: int
    id_width: int
    masters: list[Endpoint]
    slaves: list[Endpoint]
    traffic: dict[str, dict[str, float]]
    regions: list[Region]
    disabled_links: set[frozenset]
    max_masters_per_node: int
    max_slaves_per_node: int
    latency_tolerance: float
    zero_load_slack: int
    num_txns: int
    seed: int
    raw: dict = field(default_factory=dict)


def _int(v) -> int:
    """Integer with optional 0x prefix, underscores and K/M/G suffix (powers of 1024)."""
    if isinstance(v, int):
        return v
    t = str(v).replace("_", "").strip().upper()
    mul = 1
    if t[-1:] in ("K", "M", "G") and not t.startswith("0X"):
        mul = 1 << {"K": 10, "M": 20, "G": 30}[t[-1]]
        t = t[:-1]
    return int(t, 0) * mul


def _round4k(n: int) -> int:
    return -(-n // 4096) * 4096


def _node(v, rows, cols, what):
    if v is None or v == "auto":
        return None
    x, y = int(v[0]), int(v[1])
    if not (0 <= x < cols and 0 <= y < rows):
        sys.exit(f"error: {what} node {v} is outside the {cols}x{rows} mesh (x<cols, y<rows)")
    return (x, y)


def load_config(path: str) -> Config:
    with open(path) as f:
        text = f.read()
    if path.endswith((".yaml", ".yml")):
        if yaml is None:
            sys.exit("error: PyYAML is not installed; use a .json config or pip install pyyaml")
        raw = yaml.safe_load(text)
    else:
        raw = json.loads(text)

    mesh = raw["mesh"]
    rows, cols = int(mesh["rows"]), int(mesh["cols"])
    t = raw.get("timing", {})
    axi = raw.get("axi", {})
    default_slave_lat = int(t.get("slave_cycles", 2))

    masters = []
    for i, m in enumerate(raw["masters"]):
        n = _node(m.get("node"), rows, cols, m["name"])
        masters.append(Endpoint(m["name"], "master", n, n is not None, idx=i))
    slaves = []
    for i, s in enumerate(raw["slaves"]):
        n = _node(s.get("node"), rows, cols, s["name"])
        base = s.get("base")
        slaves.append(Endpoint(
            s["name"], "slave", n, n is not None,
            size=_int(s["size"]),
            base=None if base in (None, "auto") else _int(base),
            latency=int(s.get("latency", default_slave_lat)), idx=i,
            memory=s.get("kind", "memory") == "memory"))

    names = [e.name for e in masters + slaves]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        sys.exit(f"error: duplicate endpoint names: {sorted(dup)}")
    for e in masters + slaves:
        if not e.name.isidentifier():
            sys.exit(f"error: endpoint name '{e.name}' must be a valid identifier")

    for s in slaves:
        if s.latency < 1:
            sys.exit(f"error: {s.name} latency must be >= 1 cycle")
    dw = int(axi.get("data_width", 64))
    if dw < 32 or dw & (dw - 1):
        sys.exit("error: axi.data_width must be a power of two >= 32")

    traffic = {}
    for m, row in (raw.get("traffic") or {}).items():
        if m not in {x.name for x in masters}:
            sys.exit(f"error: traffic names unknown master '{m}'")
        for s, w in row.items():
            if s not in {x.name for x in slaves}:
                sys.exit(f"error: traffic for '{m}' names unknown slave '{s}'")
        traffic[m] = {s: float(w) for s, w in row.items()}

    regions = []
    mem_slaves = [x.name for x in slaves if x.memory]
    for r in raw.get("regions", []) or []:
        name = r["name"]
        if not name.isidentifier():
            sys.exit(f"error: region name '{name}' must be a valid identifier")
        size = _round4k(_int(r["size"]))
        access = {m: float(w) for m, w in (r.get("access") or {}).items()}
        for m in access:
            if m not in {x.name for x in masters}:
                sys.exit(f"error: region {name} names unknown master '{m}'")
        allowed = r.get("allowed") or mem_slaves
        for a in allowed + ([r["home"]] if r.get("home") else []):
            if a not in mem_slaves:
                sys.exit(f"error: region {name} names '{a}', which is not a memory slave")
        if r.get("pin") and not r.get("home"):
            sys.exit(f"error: region {name} has pin: true but no home")
        split = _round4k(_int(r["split"])) if r.get("split") else 0
        n = max(1, -(-size // split)) if split else 1
        for k in range(n):
            csize = split if split and k < n - 1 else size - (n - 1) * split if split else size
            regions.append(Region(
                name=f"{name}_{k}" if n > 1 else name, size=csize,
                access={m: w * csize / size for m, w in access.items()},
                allowed=list(allowed), readonly=bool(r.get("readonly", False)),
                home=r.get("home"), pin=bool(r.get("pin", False)), group=name))
    rnames = [r.name for r in regions]
    if len(set(rnames)) != len(rnames):
        sys.exit("error: duplicate region names")

    disabled = set()
    for a, b in raw.get("disabled_links", []) or []:
        a = _node(a, rows, cols, "disabled link"); b = _node(b, rows, cols, "disabled link")
        if abs(a[0] - b[0]) + abs(a[1] - b[1]) != 1:
            sys.exit(f"error: disabled link {a}-{b} does not join neighbouring routers")
        disabled.add(frozenset((a, b)))

    routing = raw.get("routing", "xy")
    if routing not in ("xy", "shortest"):
        sys.exit("error: routing must be 'xy' or 'shortest'")

    tb = raw.get("testbench", {})
    return Config(
        name=raw.get("name", "noc"), rows=rows, cols=cols, routing=routing,
        router_cycles=int(t.get("router_cycles", 2)), link_cycles=int(t.get("link_cycles", 1)),
        ni_cycles=int(t.get("ni_cycles", 1)),
        addr_width=int(axi.get("addr_width", 32)), data_width=int(axi.get("data_width", 64)),
        id_width=int(axi.get("id_width", 4)),
        masters=masters, slaves=slaves, traffic=traffic, regions=regions, disabled_links=disabled,
        max_masters_per_node=int(raw.get("max_masters_per_node", 1)),
        max_slaves_per_node=int(raw.get("max_slaves_per_node", 1)),
        latency_tolerance=float(tb.get("latency_tolerance", 3.0)),
        zero_load_slack=int(tb.get("zero_load_slack", 8)),
        num_txns=int(tb.get("num_txns", 200)), seed=int(raw.get("seed", 1)),
        raw=raw)


# --------------------------------------------------------------------------
# Latency model
# --------------------------------------------------------------------------
class Mesh:
    """Shortest-path latency between routers.

    One traversal from NI to NI over h links costs
        ni_cycles (inject) + (h+1)*router_cycles + h*link_cycles
    A read's minimum first-beat latency is request path + slave access + response
    path; request and response are routed separately (XY is not symmetric once
    links are disabled).
    """

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._cache: dict = {}

    def neighbours(self, n):
        x, y = n
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < self.cfg.cols and 0 <= ny < self.cfg.rows:
                if frozenset(((x, y), (nx, ny))) not in self.cfg.disabled_links:
                    yield (nx, ny)

    def hops(self, a, b) -> int | None:
        key = (a, b)
        if key not in self._cache:
            self._cache[key] = self._xy(a, b) if self.cfg.routing == "xy" else self._dijkstra(a, b)
        return self._cache[key]

    def _xy(self, a, b):
        x, y = a
        h = 0
        while (x, y) != b:
            nx, ny = (x + (1 if b[0] > x else -1), y) if x != b[0] else (x, y + (1 if b[1] > y else -1))
            if frozenset(((x, y), (nx, ny))) in self.cfg.disabled_links:
                return None  # XY path is broken; caller reports it
            x, y, h = nx, ny, h + 1
        return h

    def _dijkstra(self, a, b):
        dist = {a: 0}
        pq = [(0, a)]
        while pq:
            d, n = heapq.heappop(pq)
            if n == b:
                return d
            if d > dist[n]:
                continue
            for m in self.neighbours(n):
                if d + 1 < dist.get(m, math.inf):
                    dist[m] = d + 1
                    heapq.heappush(pq, (d + 1, m))
        return None

    def path_cycles(self, a, b) -> int | None:
        h = self.hops(a, b)
        if h is None:
            return None
        c = self.cfg
        return c.ni_cycles + (h + 1) * c.router_cycles + h * c.link_cycles

    def read_latency(self, m_node, s_node, slave_lat) -> int | None:
        req, rsp = self.path_cycles(m_node, s_node), self.path_cycles(s_node, m_node)
        if req is None or rsp is None:
            return None
        return req + slave_lat + rsp


# --------------------------------------------------------------------------
# Memory profile: endpoint placement + data-region placement
#
# The cost being minimised is the call-weighted sum of minimum read latency:
#     sum over direct traffic  w(m,s) * lat(m,s)
#   + sum over data regions    sum_m a(r,m) * min over copies c of r: lat(m,c)
# Three levers, applied jointly:
#   1. where auto masters/slaves sit in the mesh,
#   2. which memory each data region lives in (capacity-limited),
#   3. read-only regions copied into spare memory next to their callers.
# --------------------------------------------------------------------------
UNROUTABLE = 1e9


class Model:
    def __init__(self, cfg: Config, mesh: Mesh):
        self.cfg, self.mesh = cfg, mesh
        self.slave = {s.name: s for s in cfg.slaves}
        self.mem = [s for s in cfg.slaves if s.memory]
        if cfg.traffic or cfg.regions:
            self.direct = {(m.name, s.name): cfg.traffic.get(m.name, {}).get(s.name, 0.0)
                           for m in cfg.masters for s in cfg.slaves}
        else:  # nothing given: uniform traffic
            self.direct = {(m.name, s.name): 1.0 for m in cfg.masters for s in cfg.slaves}
        self.total_w = sum(self.direct.values()) + sum(sum(r.access.values()) for r in cfg.regions)

    def lat(self, place, m, s):
        return self.mesh.read_latency(place[m], place[s], self.slave[s].latency)

    def cost(self, place, assign) -> float:
        tot = 0.0
        L = {}
        for m in self.cfg.masters:
            for s in self.cfg.slaves:
                l = self.lat(place, m.name, s.name)
                if l is None:  # every pair must be routable, used or not
                    return UNROUTABLE
                L[m.name, s.name] = l
                tot += self.direct[m.name, s.name] * l
        for r in self.cfg.regions:
            for m, a in r.access.items():
                tot += a * min(L[m, c] for c in assign[r.name])
        return tot

    def avg(self, place, assign):
        c = self.cost(place, assign)
        if c >= UNROUTABLE:
            return None
        return c / self.total_w if self.total_w else 0.0

    def split_avg(self, place, assign):
        """(network cycles, slave access cycles) per average call."""
        net = acc = 0.0
        for (m, s), w in self.direct.items():
            l = self.lat(place, m, s); a = self.slave[s].latency
            net += w * (l - a); acc += w * a
        for r in self.cfg.regions:
            for m, a in r.access.items():
                c = min(assign[r.name], key=lambda c: self.lat(place, m, c))
                net += a * (self.lat(place, m, c) - self.slave[c].latency)
                acc += a * self.slave[c].latency
        tw = self.total_w or 1
        return net / tw, acc / tw

    def floor(self, assign):
        """Lower bound if every caller sat on the same router as its data (0 hops)."""
        c = self.cfg
        zero = 2 * (c.ni_cycles + c.router_cycles)
        tot = sum(w * (zero + self.slave[s].latency) for (m, s), w in self.direct.items())
        for r in c.regions:
            best = min(self.slave[x].latency for x in r.allowed)
            tot += sum(r.access.values()) * (zero + best)
        return tot / self.total_w if self.total_w else 0.0

    def eff_weights(self, place, assign):
        """Calls per (master, slave) once each region access goes to its nearest copy."""
        W = dict(self.direct)
        for r in self.cfg.regions:
            for m, a in r.access.items():
                c = min(assign[r.name], key=lambda c: (self.lat(place, m, c), c))
                W[m, c] += a
        return W


# ---- 1. endpoint placement -------------------------------------------------
def naive_placement(cfg) -> dict[str, tuple[int, int]]:
    """Row-major fill in declaration order: the 'before' picture."""
    place = {e.name: e.node for e in cfg.masters + cfg.slaves if e.fixed}
    for kind, eps, cap in (("m", cfg.masters, cfg.max_masters_per_node),
                           ("s", cfg.slaves, cfg.max_slaves_per_node)):
        used = {}
        for e in eps:
            if e.fixed:
                used[e.node] = used.get(e.node, 0) + 1
        nodes = [(x, y) for y in range(cfg.rows) for x in range(cfg.cols)]
        for e in eps:
            if e.fixed:
                continue
            for n in nodes:
                if used.get(n, 0) < cap:
                    place[e.name] = n
                    used[n] = used.get(n, 0) + 1
                    break
            else:
                sys.exit(f"error: no free mesh node for {e.name}; raise max_{'masters' if kind == 'm' else 'slaves'}_per_node or grow the mesh")
    return place


def optimise_placement(cfg, costf, start, restarts=40, seed=None):
    """Local search (move to a free node / swap two endpoints) with random restarts."""
    nodes = [(x, y) for y in range(cfg.rows) for x in range(cfg.cols)]
    auto = [e for e in cfg.masters + cfg.slaves if not e.fixed]
    if not auto:
        return dict(start)
    cap = {"master": cfg.max_masters_per_node, "slave": cfg.max_slaves_per_node}
    rng = random.Random(cfg.seed if seed is None else seed)

    def occupancy(place, kind):
        occ = {}
        for e in (cfg.masters if kind == "master" else cfg.slaves):
            occ[place[e.name]] = occ.get(place[e.name], 0) + 1
        return occ

    def descend(place):
        best = costf(place)
        improved = True
        while improved:
            improved = False
            for e in auto:
                occ = occupancy(place, e.kind)
                for n in nodes:  # move
                    if n == place[e.name] or occ.get(n, 0) >= cap[e.kind]:
                        continue
                    old = place[e.name]; place[e.name] = n
                    c = costf(place)
                    if c < best - 1e-9:
                        best, improved = c, True
                        occ = occupancy(place, e.kind)
                    else:
                        place[e.name] = old
            for a, b in itertools.combinations(auto, 2):  # swap
                if a.kind != b.kind or place[a.name] == place[b.name]:
                    continue
                place[a.name], place[b.name] = place[b.name], place[a.name]
                c = costf(place)
                if c < best - 1e-9:
                    best, improved = c, True
                else:
                    place[a.name], place[b.name] = place[b.name], place[a.name]
        return place, best

    best_place, best_cost = descend(dict(start))
    for _ in range(restarts):
        p = {e.name: e.node for e in cfg.masters + cfg.slaves if e.fixed}
        for kind in ("master", "slave"):
            occ = {}
            for e in (cfg.masters if kind == "master" else cfg.slaves):
                if e.fixed:
                    occ[e.node] = occ.get(e.node, 0) + 1
            for e in (cfg.masters if kind == "master" else cfg.slaves):
                if e.fixed:
                    continue
                n = rng.choice([n for n in nodes if occ.get(n, 0) < cap[kind]])
                p[e.name] = n
                occ[n] = occ.get(n, 0) + 1
        p, c = descend(p)
        if c < best_cost - 1e-9:
            best_place, best_cost = p, c
    return best_place


# ---- 2. + 3. data-region placement and read-only copies ----------------------
def baseline_assignment(cfg, model):
    """Regions on their `home`, else first memory (declaration order) with room."""
    used = {s.name: 0 for s in model.mem}
    assign = {}
    for r in cfg.regions:
        order = ([r.home] if r.home else []) + [s for s in r.allowed if s != r.home]
        for s in order:
            if used[s] + r.size <= model.slave[s].size:
                assign[r.name] = [s]; used[s] += r.size
                break
        else:
            sys.exit(f"error: region {r.name} (0x{r.size:x} bytes) fits in none of {r.allowed}")
    return assign


def optimise_assignment(cfg, model, place, start):
    regs = {r.name: r for r in cfg.regions}
    lat = {(m.name, s.name): model.lat(place, m.name, s.name) for m in cfg.masters for s in model.mem}
    rc = {(r.name, s): sum(a * lat[m, s] for m, a in r.access.items()) for r in cfg.regions for s in r.allowed}

    assign = {k: [v[0]] for k, v in start.items()}  # drop old copies; re-add below
    used = {s.name: 0 for s in model.mem}
    for k, v in assign.items():
        used[v[0]] += regs[k].size

    movable = [r for r in cfg.regions if not r.pin]
    improved = True
    while improved:
        improved = False
        for r in movable:  # move a region to a cheaper memory with room
            cur = assign[r.name][0]
            for s in r.allowed:
                if s != cur and used[s] + r.size <= model.slave[s].size and rc[r.name, s] < rc[r.name, cur] - 1e-9:
                    used[cur] -= r.size; used[s] += r.size
                    assign[r.name] = [s]; cur = s; improved = True
        for a, b in itertools.combinations(movable, 2):  # swap two regions
            sa, sb = assign[a.name][0], assign[b.name][0]
            if sa == sb or sb not in a.allowed or sa not in b.allowed:
                continue
            if used[sa] - a.size + b.size > model.slave[sa].size or used[sb] - b.size + a.size > model.slave[sb].size:
                continue
            if rc[a.name, sb] + rc[b.name, sa] < rc[a.name, sa] + rc[b.name, sb] - 1e-9:
                used[sa] += b.size - a.size; used[sb] += a.size - b.size
                assign[a.name], assign[b.name] = [sb], [sa]
                improved = True

    # Copy read-only regions into leftover space, biggest saving per byte first.
    while True:
        best = None
        for r in cfg.regions:
            if not r.readonly:
                continue
            for s in r.allowed:
                if s in assign[r.name] or used[s] + r.size > model.slave[s].size:
                    continue
                gain = sum(a * max(0, min(lat[m, c] for c in assign[r.name]) - lat[m, s])
                           for m, a in r.access.items())
                if gain > 1e-9 and (best is None or gain / r.size > best[0]):
                    best = (gain / r.size, r, s)
        if best is None:
            break
        _, r, s = best
        assign[r.name].append(s); used[s] += r.size
    return assign


def best_assignment(cfg, model, place, a0, warm=None):
    """Best data layout found for a fixed placement: local search from the
    baseline and from a warm start, each refined once more."""
    cands = []
    for start in [a0] + ([warm] if warm else []):
        a = optimise_assignment(cfg, model, place, start)
        cands += [a, optimise_assignment(cfg, model, place, a)]
    return min(cands, key=lambda a: model.cost(place, a))


def optimise_all(cfg, model, place0, assign0, restarts=40):
    """Joint search: every placement the search tries is scored with the best
    data layout for that placement."""
    if not cfg.regions:
        p = optimise_placement(cfg, lambda p: model.cost(p, assign0), place0, restarts)
        return p, assign0
    cache = {}

    def layout(p):
        key = tuple(sorted(p.items()))
        if key not in cache:
            cache[key] = best_assignment(cfg, model, p, assign0)
        return cache[key]

    place = optimise_placement(cfg, lambda p: model.cost(p, layout(p)), place0, restarts)
    return place, layout(place)


# --------------------------------------------------------------------------
# Address map
# --------------------------------------------------------------------------
def pow2_ceil(n):
    return 1 << max(0, (n - 1).bit_length())


def allocate_addresses(cfg: Config):
    top = 1 << cfg.addr_width
    ranges = []
    for s in cfg.slaves:
        if s.base is not None:
            if s.base % 4096:
                sys.exit(f"error: {s.name} base 0x{s.base:x} is not 4 KB aligned")
            ranges.append((s.base, s.base + s.size, s.name))
    # Auto slaves: biggest first, each aligned to its own (pow2) size so decode
    # is a mask compare and no burst can straddle two slaves.
    for s in sorted([s for s in cfg.slaves if s.base is None], key=lambda s: -s.size):
        align = max(4096, pow2_ceil(s.size))
        cand = 0
        while True:
            clash = [r for r in ranges if cand < r[1] and r[0] < cand + s.size]
            if not clash:
                break
            cand = ((max(r[1] for r in clash) + align - 1) // align) * align
        if cand + s.size > top:
            sys.exit(f"error: address space ({cfg.addr_width} bits) too small for {s.name}")
        s.base = cand
        ranges.append((cand, cand + s.size, s.name))
    ranges.sort()
    for (a0, a1, an), (b0, b1, bn) in zip(ranges, ranges[1:]):
        if b0 < a1:
            sys.exit(f"error: address ranges of {an} and {bn} overlap")
    for s in cfg.slaves:
        if s.base + s.size > top:
            sys.exit(f"error: {s.name} does not fit in {cfg.addr_width}-bit address space")
        if s.size % 4096:
            sys.exit(f"error: {s.name} size 0x{s.size:x} must be a multiple of 4 KB")


def region_addresses(cfg, model, assign):
    """Lay regions (and copies) out inside each memory, biggest first, 4 KB aligned.
    Returns {(region, slave): base}."""
    regs = {r.name: r for r in cfg.regions}
    out = {}
    for s in model.mem:
        here = sorted((k for k, v in assign.items() if s.name in v), key=lambda k: (-regs[k].size, k))
        off = 0
        for k in here:
            out[k, s.name] = s.base + off
            off += regs[k].size
        assert off <= s.size, s.name
    return out


# --------------------------------------------------------------------------
# Profile
# --------------------------------------------------------------------------
def build_profile(cfg, model, stages, place, assign):
    mesh = model.mesh
    W = model.eff_weights(place, assign)
    pairs = []
    unreachable = []
    for m in cfg.masters:
        for s in cfg.slaves:
            a, b = place[m.name], place[s.name]
            h_req, h_rsp = mesh.hops(a, b), mesh.hops(b, a)
            if h_req is None or h_rsp is None:
                unreachable.append((m.name, s.name))
                continue
            req, rsp = mesh.path_cycles(a, b), mesh.path_cycles(b, a)
            pairs.append(dict(master=m.name, slave=s.name, m_idx=m.idx, s_idx=s.idx,
                              hops_req=h_req, hops_rsp=h_rsp, req=req, rsp=rsp,
                              slave_cycles=s.latency,
                              min_read=req + s.latency + rsp,
                              weight=W[(m.name, s.name)]))
    if unreachable:
        sys.exit("error: no route (check disabled_links / routing) for: " +
                 ", ".join(f"{m}->{s}" for m, s in unreachable))

    ranking = {}
    for m in cfg.masters:
        rows = sorted((p for p in pairs if p["master"] == m.name), key=lambda p: (p["min_read"], p["slave"]))
        ranking[m.name] = [dict(slave=p["slave"], min_read=p["min_read"],
                                base=cfg.slaves[p["s_idx"]].base,
                                size=cfg.slaves[p["s_idx"]].size) for p in rows]

    raddr = region_addresses(cfg, model, assign)
    regions = []
    for r in cfg.regions:
        callers = {}
        for m, a in r.access.items():
            c = min(assign[r.name], key=lambda c: (model.lat(place, m, c), c))
            callers[m] = dict(copy=c, base=raddr[r.name, c], min_read=model.lat(place, m, c), calls=a)
        regions.append(dict(name=r.name, group=r.group, size=r.size, readonly=r.readonly,
                            home_before=stages["before"]["assign"][r.name][0],
                            copies=[dict(slave=s, base=raddr[r.name, s], node=list(place[s]))
                                    for s in assign[r.name]],
                            callers=callers))

    hole, cur = None, 0
    for r in sorted(cfg.slaves, key=lambda s: s.base):
        if r.base > cur:
            break
        cur = max(cur, r.base + r.size)
    if cur < (1 << cfg.addr_width):
        hole = cur
    net, acc = model.split_avg(place, assign)
    return dict(
        name=cfg.name, hole=hole, mesh=dict(rows=cfg.rows, cols=cfg.cols), routing=cfg.routing,
        timing=dict(router_cycles=cfg.router_cycles, link_cycles=cfg.link_cycles, ni_cycles=cfg.ni_cycles),
        stages={k: dict(avg=None if v["avg"] is None else round(v["avg"], 3), label=v["label"])
                for k, v in stages.items()},
        floor=round(model.floor(assign), 3),
        after_network_cycles=round(net, 3), after_access_cycles=round(acc, 3),
        placement_before={k: list(v) for k, v in stages["before"]["place"].items()},
        placement_after={k: list(v) for k, v in place.items()},
        weighted_avg_read_latency_before=None if stages["before"]["avg"] is None else round(stages["before"]["avg"], 3),
        weighted_avg_read_latency_after=round(stages["after"]["avg"], 3),
        address_map=[dict(slave=s.name, base=s.base, size=s.size, node=list(place[s.name]),
                          access_cycles=s.latency, kind="memory" if s.memory else "device") for s in cfg.slaves],
        regions=regions, pairs=pairs, ranking=ranking)


def mesh_ascii(cfg, place):
    cells = {}
    for e in cfg.masters + cfg.slaves:
        n = tuple(place[e.name])
        cells.setdefault(n, []).append(("M:" if e.kind == "master" else "S:") + e.name)
    w = max([len(",".join(v)) for v in cells.values()] + [7])
    lines = []
    for y in range(cfg.rows):
        row = []
        for x in range(cfg.cols):
            row.append(",".join(cells.get((x, y), [f"({x},{y})"])).center(w))
        lines.append(" | ".join(row))
    return "\n".join(lines)


def _sz(n):
    for unit, k in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= k and n % k == 0:
            return f"{n // k} {unit}"
    return f"0x{n:x}"


def write_profile(cfg, prof, outdir):
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "profile.json"), "w") as f:
        json.dump(prof, f, indent=2)
    hx = (cfg.addr_width + 3) // 4

    md = []
    md.append(f"# Memory and latency profile: {cfg.name}\n")
    md.append(f"Mesh {cfg.cols}x{cfg.rows}, routing `{cfg.routing}`, "
              f"router {cfg.router_cycles} cy, link {cfg.link_cycles} cy, NI {cfg.ni_cycles} cy.\n")
    md.append("Minimum read latency (first data beat) = request path + slave access + response path, where one "
              "path over h links = NI + (h+1)·router + h·link cycles. The testbench scoreboard checks every "
              "transaction against this number. All averages below are weighted by call count.\n")
    md.append("## Result\n")
    md.append("| Step | Avg min read latency (cycles) | vs. before |\n|---|---|---|")
    b = prof["stages"]["before"]["avg"]
    for k, v in prof["stages"].items():
        if v["avg"] is None:
            md.append(f"| {v['label']} | no route for some pairs | |")
        else:
            vs = "" if k == "before" or b is None else f"{(1 - v['avg'] / b) * 100:.1f}% lower"
            md.append(f"| {v['label']} | {v['avg']} | {vs} |")
    md.append("")
    md.append(f"After optimisation an average call spends **{prof['after_network_cycles']} cycles in the network** "
              f"and **{prof['after_access_cycles']} cycles in the memory itself**. The floor, if every caller sat on "
              f"the same router as its data in the fastest memory it may use, is {prof['floor']} cycles. "
              "Endpoints with a fixed `node` and regions with `pin: true` are not moved.\n")
    md.append("## Placement\n")
    md.append("Before:\n```\n" + mesh_ascii(cfg, prof["placement_before"]) + "\n```\n")
    md.append("After (use this placement):\n```\n" + mesh_ascii(cfg, prof["placement_after"]) + "\n```\n")
    md.append("## Address map\n")
    md.append("| Slave | Kind | Base | Size | Node (x,y) | Access cycles |\n|---|---|---|---|---|---|")
    for r in prof["address_map"]:
        md.append(f"| {r['slave']} | {r['kind']} | 0x{r['base']:0{hx}x} | {_sz(r['size'])} | "
                  f"({r['node'][0]},{r['node'][1]}) | {r['access_cycles']} |")
    md.append("")
    if prof["regions"]:
        md.append("## Data placement\n")
        md.append("Where each data region should live. A region with more than one copy is read-only and has been "
                  "copied next to its callers; each caller should use the copy listed for it.\n")
        md.append("| Region | Size | Was in | Now in (address) | Callers: copy used, min read cycles |\n|---|---|---|---|---|")
        for r in prof["regions"]:
            copies = ", ".join(f"{c['slave']} (0x{c['base']:0{hx}x})" for c in r["copies"])
            callers = ", ".join(f"{m}: {v['copy']} {v['min_read']} cy" for m, v in
                                sorted(r["callers"].items(), key=lambda kv: -kv[1]["calls"]))
            moved = "" if r["copies"][0]["slave"] == r["home_before"] and len(r["copies"]) == 1 else " **moved**"
            md.append(f"| {r['name']}{' (RO)' if r['readonly'] else ''} | {_sz(r['size'])} | {r['home_before']} | "
                      f"{copies}{moved} | {callers} |")
        md.append("")
    md.append("## Memory ranking per master\n")
    md.append("Memories ranked by minimum read latency from each master: where to put any data not listed above.\n")
    for m, rows in prof["ranking"].items():
        md.append(f"**{m}**: " + ", ".join(f"{r['slave']} ({r['min_read']} cy)" for r in rows))
    md.append("")
    md.append("## Per-pair latency\n")
    md.append("| Master | Slave | Hops req/rsp | Req cy | Slave cy | Rsp cy | Min read cy | Calls |\n"
              "|---|---|---|---|---|---|---|---|")
    for p in prof["pairs"]:
        md.append(f"| {p['master']} | {p['slave']} | {p['hops_req']}/{p['hops_rsp']} | {p['req']} | "
                  f"{p['slave_cycles']} | {p['rsp']} | {p['min_read']} | {p['weight']:g} |")
    with open(os.path.join(outdir, "profile.md"), "w") as f:
        f.write("\n".join(md) + "\n")

    # C header so software can place hot data where the profile says.
    g = cfg.name.upper()
    h = [f"/* Generated by nocgen for {cfg.name}. Do not edit. */",
         f"#ifndef NOC_MEMMAP_{g}_H", f"#define NOC_MEMMAP_{g}_H", ""]
    for r in prof["address_map"]:
        h.append(f"#define NOC_{r['slave'].upper()}_BASE 0x{r['base']:x}ULL")
        h.append(f"#define NOC_{r['slave'].upper()}_SIZE 0x{r['size']:x}ULL")
    if prof["regions"]:
        h += ["", "/* Data regions. <MASTER>_<REGION>_BASE is the copy that master should use. */"]
        for r in prof["regions"]:
            h.append(f"#define NOC_{r['name'].upper()}_BASE 0x{r['copies'][0]['base']:x}ULL  /* {r['copies'][0]['slave']} */")
            h.append(f"#define NOC_{r['name'].upper()}_SIZE 0x{r['size']:x}ULL")
            for m, v in r["callers"].items():
                h.append(f"#define NOC_{m.upper()}_{r['name'].upper()}_BASE 0x{v['base']:x}ULL  /* {v['copy']}, {v['min_read']} cy */")
    h += ["", "/* Nearest memory (lowest minimum read latency) per master. */"]
    mems = {r["slave"] for r in prof["address_map"] if r["kind"] == "memory"}
    for m, rows in prof["ranking"].items():
        rows = [x for x in rows if x["slave"] in mems] or rows
        h.append(f"#define NOC_{m.upper()}_NEAREST_BASE NOC_{rows[0]['slave'].upper()}_BASE"
                 f"  /* {rows[0]['min_read']} cycles */")
    h += ["", "#endif", ""]
    with open(os.path.join(outdir, "noc_memmap.h"), "w") as f:
        f.write("\n".join(h))


# --------------------------------------------------------------------------
# Testbench
# --------------------------------------------------------------------------
def write_tb(cfg, prof, outdir):
    os.makedirs(outdir, exist_ok=True)
    env = Environment(loader=FileSystemLoader(os.path.join(HERE, "templates")),
                      undefined=StrictUndefined, keep_trailing_newline=True,
                      trim_blocks=True, lstrip_blocks=True)
    nm, ns = len(cfg.masters), len(cfg.slaves)
    req = [[0] * ns for _ in range(nm)]
    rsp = [[0] * ns for _ in range(nm)]
    W = [[0.0] * ns for _ in range(nm)]
    for p in prof["pairs"]:
        req[p["m_idx"]][p["s_idx"]] = p["req"]
        rsp[p["m_idx"]][p["s_idx"]] = p["rsp"]
        W[p["m_idx"]][p["s_idx"]] = p["weight"]
    # Integer traffic weights for the slave picker (smallest non-zero weight -> 10).
    nz = [w for row in W for w in row if w > 0]
    scale = 10.0 / min(nz) if nz else 1.0
    Wi = [[int(round(w * scale)) for w in row] for row in W]
    for i, row in enumerate(Wi):
        if not any(row):  # a master with no traffic still gets uniform traffic
            Wi[i] = [1] * ns
    ctx = dict(
        cfg=cfg, nm=nm, ns=ns, req=req, rsp=rsp, wi=Wi,
        aw=cfg.addr_width, dw=cfg.data_width, idw=cfg.id_width,
        hexw=(cfg.addr_width + 3) // 4,
        slaves=cfg.slaves, masters=cfg.masters, prof=prof,
        placement=prof["placement_after"],
    )
    files = ["noc_params_pkg.sv", "axi_if.sv", "noc_tb_pkg.sv", "noc_mesh_stub.sv",
             "tb_top.sv", "files.f", "Makefile"]
    for fn in files:
        with open(os.path.join(outdir, fn), "w") as f:
            f.write(env.get_template(fn + ".j2").render(**ctx))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("config")
    ap.add_argument("-o", "--out", default="out")
    ap.add_argument("--no-optimise", action="store_true", help="keep the baseline placement and data layout")
    ap.add_argument("--restarts", type=int, default=40, help="random restarts for the placement search")
    args = ap.parse_args()

    cfg = load_config(args.config)
    mesh = Mesh(cfg)
    allocate_addresses(cfg)
    model = Model(cfg, mesh)
    p0 = naive_placement(cfg)
    a0 = baseline_assignment(cfg, model)
    stages = {"before": dict(label="Before: naive placement, data where the config puts it",
                             place=p0, assign=a0)}
    if args.no_optimise:
        place, assign = p0, a0
    else:
        p1 = optimise_placement(cfg, lambda p: model.cost(p, a0), p0, args.restarts)
        stages["placement"] = dict(label="Endpoint placement only", place=p1, assign=a0)
        place, assign = optimise_all(cfg, model, p1, a0, args.restarts)
        if cfg.regions:
            stages["after"] = dict(label="Placement + data placement + read-only copies",
                                   place=place, assign=assign)
        else:
            stages["after"] = stages.pop("placement")
            stages["after"].update(place=place, assign=assign)
    if "after" not in stages:
        stages["after"] = dict(label="Not optimised (--no-optimise)", place=place, assign=assign)
    for v in stages.values():
        v["avg"] = model.avg(v["place"], v["assign"])
    for e in cfg.masters + cfg.slaves:
        e.node = place[e.name]
    prof = build_profile(cfg, model, stages, place, assign)
    write_profile(cfg, prof, os.path.join(args.out, "profile"))
    write_tb(cfg, prof, os.path.join(args.out, "tb"))
    print(f"{cfg.name}: {len(cfg.masters)} masters, {len(cfg.slaves)} slaves, {len(cfg.regions)} data regions "
          f"on {cfg.cols}x{cfg.rows} mesh")
    for v in prof["stages"].values():
        print(f"  {v['label']}: {v['avg'] if v['avg'] is not None else 'unroutable'} cycles")
    print(f"  floor: {prof['floor']} cycles")
    print(f"wrote {args.out}/tb and {args.out}/profile")


if __name__ == "__main__":
    main()
