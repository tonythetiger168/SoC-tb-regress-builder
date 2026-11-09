# SPDX-License-Identifier: Apache-2.0
"""Load, validate and elaborate a socgen SoC spec (see SPEC.md)."""
import math
import re

import yaml


class SpecError(Exception):
    pass


SUFFIX = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30}
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def num(v, what):
    if isinstance(v, bool):
        raise SpecError(f"{what}: expected a number, got {v!r}")
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    if isinstance(v, str):
        s = v.strip().replace("_", "")
        m = re.fullmatch(r"(\d+)\s*([KMG])B?", s, re.I)
        if m:
            return int(m.group(1)) * SUFFIX[m.group(2).upper()]
        try:
            return int(s, 0)
        except ValueError:
            pass
    raise SpecError(f"{what}: expected a number, got {v!r}")


def keys(d, allowed, what, required=()):
    if not isinstance(d, dict):
        raise SpecError(f"{what}: expected a mapping, got {type(d).__name__}")
    extra = set(d) - set(allowed)
    if extra:
        raise SpecError(f"{what}: unknown key(s) {sorted(extra)}; allowed {sorted(allowed)}")
    for k in required:
        if k not in d:
            raise SpecError(f"{what}: missing required key '{k}'")


def ident(v, what):
    if not isinstance(v, str) or not IDENT.match(v):
        raise SpecError(f"{what}: {v!r} is not a valid identifier")
    return v


def pow2(v):
    return v > 0 and (v & (v - 1)) == 0


def bits(spec_bits, what):
    s = str(spec_bits)
    m = re.fullmatch(r"\s*(\d+)\s*(?::\s*(\d+)\s*)?", s)
    if not m:
        raise SpecError(f"{what}: bits {s!r} must be 'n' or 'msb:lsb'")
    msb = int(m.group(1))
    lsb = int(m.group(2)) if m.group(2) is not None else msb
    if lsb > msb or msb > 31:
        raise SpecError(f"{what}: bits {s!r} out of range")
    return lsb, msb - lsb + 1


ACCESS = {"RO", "RW", "W1C", "WO"}
QOS_CLASSES = {"rt", "nrt", "be"}
TESTS = ("smoke", "ral", "path_latency", "traffic", "scenario", "coherence")
PATTERNS = ("random", "linear", "block2d")


class Obj(dict):
    """dict with attribute access, used for the elaborated model"""
    __getattr__ = dict.__getitem__

    def __setattr__(self, k, v):
        self[k] = v


def load(path):
    with open(path) as f:
        raw = yaml.safe_load(f)
    return elaborate(raw, path)


def elaborate(raw, path="<spec>"):
    keys(raw, ["socgen", "soc", "clock", "bus", "noc", "traffic", "masters", "iommus",
               "memories", "slaves", "register_blocks", "scenarios", "regress", "report", "chiplet", "chi"],
         path, required=["socgen", "soc", "noc", "masters"])
    if raw["socgen"] != 1:
        raise SpecError(f"{path}: socgen schema version {raw['socgen']!r} not supported (1)")
    m = Obj(path=path)

    # ---- soc / clock / bus ----
    soc = raw["soc"]
    keys(soc, ["name", "prefix", "desc"], "soc", required=["name"])
    m.name = ident(soc["name"], "soc.name")
    m.prefix = ident(soc.get("prefix", m.name), "soc.prefix")
    m.desc = soc.get("desc", "")
    clk = raw.get("clock", {})
    keys(clk, ["name", "period_ns"], "clock")
    m.clock = Obj(name=ident(clk.get("name", "aclk"), "clock.name"),
                  period_ns=float(clk.get("period_ns", 2.0)))
    if m.clock.period_ns < 2.0:
        raise SpecError("clock.period_ns: at least 2 ns (the bundled VIPs drive 1 ns after the clock edge)")
    bus = raw.get("bus", {})
    keys(bus, ["addr_width", "data_width", "id_width"], "bus")
    m.addr_width = num(bus.get("addr_width", 32), "bus.addr_width")
    m.data_width = num(bus.get("data_width", 32), "bus.data_width")
    m.id_width = num(bus.get("id_width", 4), "bus.id_width")
    if m.addr_width != 32 or m.data_width != 32:
        raise SpecError("bus: the bundled AXI4 VIP is 32-bit address / 32-bit data")
    if not 1 <= m.id_width <= 4:
        raise SpecError("bus.id_width: 1..4 (the NoC adds no ID bits; the VIP carries 8)")

    # ---- noc ----
    noc = raw["noc"]
    keys(noc, ["topology", "rows", "cols", "routing", "timing", "model", "rtl_module", "router",
               "buf_depth", "num_vc", "ni"], "noc", required=["topology"])
    topo = noc["topology"]
    if topo not in ("mesh", "crossbar"):
        raise SpecError(f"noc.topology: {topo!r} (mesh | crossbar)")
    rows = num(noc.get("rows", 1), "noc.rows") if topo == "mesh" else 1
    cols = num(noc.get("cols", 1), "noc.cols") if topo == "mesh" else 1
    if topo == "mesh" and ("rows" not in noc or "cols" not in noc):
        raise SpecError("noc: a mesh needs rows and cols")
    if noc.get("routing", "xy") != "xy":
        raise SpecError("noc.routing: only xy is supported")
    t = noc.get("timing", {})
    keys(t, ["ni_cycles", "router_cycles", "link_cycles"], "noc.timing")
    model = noc.get("model", "behavioral")
    if model not in ("behavioral", "rtl", "mesh"):
        raise SpecError(f"noc.model: {model!r} (behavioral | rtl | mesh)")
    if model == "rtl" and "rtl_module" not in noc:
        raise SpecError("noc: model rtl needs rtl_module")
    # model mesh: the generated <soc>_noc RTL (routers + network interfaces + protocol adapters)
    router = noc.get("router", "orca")
    if router not in ("orca", "open"):
        raise SpecError(f"noc.router: {router!r} (orca | open)")
    if router == "orca" and (rows > 4 or cols > 4):
        raise SpecError("noc.router: orca_noc_router has 2-bit mesh coordinates (at most 4x4); use router: open")
    ni = noc.get("ni") or {}
    keys(ni, ["max_bursts", "max_chunks", "slave_outstanding"], "noc.ni")
    m.noc_ni = Obj(maxb=num(ni.get("max_bursts", 4), "noc.ni.max_bursts"),
                   maxo=num(ni.get("max_chunks", 8), "noc.ni.max_chunks"),
                   outs=num(ni.get("slave_outstanding", 4), "noc.ni.slave_outstanding"))
    for k in ("maxb", "maxo", "outs"):
        if not pow2(m.noc_ni[k]) or not 2 <= m.noc_ni[k] <= 32:
            raise SpecError("noc.ni: max_bursts, max_chunks and slave_outstanding are powers of two, 2..32")
    m.noc = Obj(topology=topo, rows=rows, cols=cols, model=model,
                rtl_module=noc.get("rtl_module", "") if model != "mesh" else "",
                router_ip=router, buf_depth=num(noc.get("buf_depth", 8), "noc.buf_depth"),
                num_vc=num(noc.get("num_vc", 4), "noc.num_vc"),
                ni=num(t.get("ni_cycles", 1), "ni_cycles"),
                router=num(t.get("router_cycles", 1), "router_cycles"),
                link=num(t.get("link_cycles", 1), "link_cycles"))

    # ---- chiplet: several dies, one mesh each, joined by a UCIe die-to-die link ----
    ch = raw.get("chiplet")
    if ch is None:
        m.chiplet = Obj(dies=1, gateways=[], phy_cycles=0, retry=True, link="")
    else:
        keys(ch, ["dies", "link", "gateways", "phy_cycles", "retry"], "chiplet", required=["dies", "gateways"])
        nd = num(ch["dies"], "chiplet.dies")
        if nd != 2:
            raise SpecError("chiplet.dies: 2 (one UCIe link between two dies)")
        if model != "mesh":
            raise SpecError("chiplet: needs noc.model: mesh")
        if ch.get("link", "ucie") != "ucie":
            raise SpecError("chiplet.link: ucie")
        gws = ch["gateways"]
        if not isinstance(gws, list) or len(gws) != nd:
            raise SpecError("chiplet.gateways: one [x, y] router per die")
        m.chiplet = Obj(dies=nd, link="ucie", gateways=[_node(g, f"chiplet.gateways[{i}]", cols, rows)
                                                         for i, g in enumerate(gws)],
                        phy_cycles=num(ch.get("phy_cycles", 4), "chiplet.phy_cycles"),
                        retry=bool(ch.get("retry", True)))

    def die_of(d, what):
        v = num(d.get("die", 0), f"{what}.die")
        if not 0 <= v < m.chiplet.dies:
            raise SpecError(f"{what}.die: 0..{m.chiplet.dies - 1} (chiplet.dies)")
        return v

    def node(v, what):
        if topo == "crossbar":
            return (0, 0) if v is None else _node(v, what, 1, 1)
        if v is None:
            raise SpecError(f"{what}: node [x, y] required on a mesh")
        return _node(v, what, cols, rows)

    # ---- traffic profiles ----
    profiles = {}
    for pn, p in (raw.get("traffic") or {}).items():
        profiles[ident(pn, "traffic")] = _profile(p, f"traffic.{pn}")

    # ---- register blocks ----
    m.register_blocks = {}
    for bn, b in (raw.get("register_blocks") or {}).items():
        m.register_blocks[ident(bn, "register_blocks")] = _regblock(b, f"register_blocks.{bn}")

    # ---- iommus ----
    m.iommus = []
    for i, io in enumerate(raw.get("iommus") or []):
        w = f"iommus[{i}]"
        keys(io, ["name", "tlb_hit_cycles", "tlb_entries", "regs"], w, required=["name"])
        rb = io.get("regs", "iommu")
        if rb not in m.register_blocks:
            raise SpecError(f"{w}: register block {rb!r} not in register_blocks")
        m.iommus.append(Obj(name=ident(io["name"], f"{w}.name"), index=i,
                            tlb_hit=num(io.get("tlb_hit_cycles", 2), f"{w}.tlb_hit_cycles"),
                            tlb_entries=num(io.get("tlb_entries", 32), f"{w}.tlb_entries"),
                            regs=rb, masters=[]))
    iommu_by = {io.name: io for io in m.iommus}

    # ---- masters ----
    m.masters = []
    for i, ms in enumerate(raw["masters"]):
        w = f"masters[{i}]"
        keys(ms, ["name", "node", "traffic", "iommu", "qos", "kind", "rtl", "protocol", "die"], w, required=["name"])
        name = ident(ms["name"], f"{w}.name")
        tr = ms.get("traffic")
        if isinstance(tr, str):
            if tr not in profiles:
                raise SpecError(f"{w}.traffic: profile {tr!r} not defined")
            prof = profiles[tr]
        else:
            prof = _profile(tr or {}, f"{w}.traffic")
        q = ms.get("qos", {})
        keys(q, ["class", "priority", "latency_target"], f"{w}.qos")
        qc = q.get("class", "nrt")
        if qc not in QOS_CLASSES:
            raise SpecError(f"{w}.qos.class: {qc!r} ({' | '.join(sorted(QOS_CLASSES))})")
        pri = num(q.get("priority", 0), f"{w}.qos.priority")
        if not 0 <= pri <= 15:
            raise SpecError(f"{w}.qos.priority: 0..15")
        io = ms.get("iommu")
        if io is not None and io not in iommu_by:
            raise SpecError(f"{w}.iommu: {io!r} not in iommus")
        kind = ms.get("kind", "vip")
        if kind not in ("vip", "rtl"):
            raise SpecError(f"{w}.kind: vip | rtl")
        rtl = _rtl(ms.get("rtl"), f"{w}.rtl") if kind == "rtl" else None
        if kind != "rtl" and "rtl" in ms:
            raise SpecError(f"{w}: rtl only with kind rtl")
        mo = Obj(name=name, index=i, node=node(ms.get("node"), f"{w}.node"), traffic=prof, rtl=rtl,
                 iommu=io, qos_class=qc, priority=pri,
                 latency_target=num(q["latency_target"], f"{w}.qos.latency_target")
                 if "latency_target" in q else 0, kind=kind,
                 protocol=_protocol(ms, w, MASTER_PROTOCOLS, model, kind != "rtl"), die=die_of(ms, w))
        if io:
            iommu_by[io].masters.append(name)
        m.masters.append(mo)
    if not m.masters:
        raise SpecError("masters: at least one")
    if len(m.masters) > 16:
        raise SpecError("masters: at most 16")

    # ---- targets: memory channels first, then slaves ----
    m.memories, m.targets, m.slaves = [], [], []
    for i, mem in enumerate(raw.get("memories") or []):
        w = f"memories[{i}]"
        keys(mem, ["name", "kind", "base", "size", "channels", "interleave", "access_cycles",
                   "timing", "placement", "protocol", "die"], w, required=["name", "base", "size", "channels"])
        name = ident(mem["name"], f"{w}.name")
        base, size = num(mem["base"], f"{w}.base"), num(mem["size"], f"{w}.size")
        nch = num(mem["channels"], f"{w}.channels")
        if not pow2(nch):
            raise SpecError(f"{w}.channels: must be a power of two")
        il = mem.get("interleave", {})
        keys(il, ["granule", "hash"], f"{w}.interleave")
        gran = num(il.get("granule", 4096), f"{w}.interleave.granule")
        if not pow2(gran) or gran < 4096:
            raise SpecError(f"{w}.interleave.granule: power of two >= 4 KB")
        hsh = il.get("hash", "none")
        if hsh not in ("none", "xor"):
            raise SpecError(f"{w}.interleave.hash: none | xor")
        if base % size or not pow2(size):
            raise SpecError(f"{w}: size must be a power of two and base aligned to it")
        n = int(math.log2(nch))
        g = int(math.log2(gran))
        if g + n * (2 if hsh == "xor" else 1) > int(math.log2(size)):
            raise SpecError(f"{w}: size too small for {nch} channels x granule (x2 for the xor hash)")
        kind = mem.get("kind", "ddr")
        if kind not in ("lpddr5", "ddr", "hbm", "sram"):
            raise SpecError(f"{w}.kind: lpddr5 | ddr | hbm | sram")
        nodes = _placement(mem.get("placement"), nch, f"{w}.placement", node, topo, rows, cols)
        mo = Obj(name=name, kind=kind, base=base, size=size, channels=nch, granule=gran,
                 gbits=g, cbits=n, hash=hsh, access=num(mem.get("access_cycles", 20), w),
                 timing=str(mem.get("timing", "")), first=len(m.targets))
        m.memories.append(mo)
        for c in range(nch):
            m.targets.append(Obj(name=f"{name}{c}", kind="channel", mem=name, channel=c,
                                 base=base, size=size, node=nodes[c], access=mo.access,
                                 index=len(m.targets),
                                 protocol=_protocol(mem, w, SLAVE_PROTOCOLS, model, True),
                                 die=die_of(mem, w)))
    m.nch = sum(x.channels for x in m.memories)

    m.apb = None
    for i, sl in enumerate(raw.get("slaves") or []):
        w = f"slaves[{i}]"
        keys(sl, ["name", "kind", "base", "size", "node", "access_cycles", "slot_size",
                  "peripherals", "rtl", "protocol", "die"], w, required=["name", "kind", "base", "size"])
        name = ident(sl["name"], f"{w}.name")
        kind = sl["kind"]
        if kind not in ("memory", "apb_bridge", "vip", "rtl"):
            raise SpecError(f"{w}.kind: memory | apb_bridge | vip | rtl")
        if (kind == "rtl") != ("rtl" in sl):
            raise SpecError(f"{w}: kind rtl and an rtl block go together")
        base, size = num(sl["base"], f"{w}.base"), num(sl["size"], f"{w}.size")
        if base % 4096 or size % 4096:
            raise SpecError(f"{w}: base and size must be 4 KB aligned")
        to = Obj(name=name, kind=kind, base=base, size=size, node=node(sl.get("node"), f"{w}.node"),
                 access=num(sl.get("access_cycles", 4 if kind == "apb_bridge" else 2), w),
                 index=len(m.targets), rtl=_rtl(sl["rtl"], f"{w}.rtl") if kind == "rtl" else None,
                 protocol=_protocol(sl, w, SLAVE_PROTOCOLS, model, kind in ("memory", "vip")),
                 die=die_of(sl, w))
        if kind == "apb_bridge":
            if m.apb is not None:
                raise SpecError(f"{w}: only one apb_bridge per SoC")
            to.slot_size = num(sl.get("slot_size", 4096), f"{w}.slot_size")
            if to.slot_size != 4096:
                raise SpecError(f"{w}.slot_size: the open-ip APB wrappers decode 12 bits: 4 KB")
            to.slots = _apb_slots(sl.get("peripherals") or [], to, m, f"{w}.peripherals")
            m.apb = to
        elif "peripherals" in sl or "slot_size" in sl:
            raise SpecError(f"{w}: peripherals/slot_size only on an apb_bridge")
        m.targets.append(to)
        m.slaves.append(to)
    if m.iommus and m.apb is None:
        raise SpecError("iommus need an apb_bridge slave for their register blocks")
    if not m.targets:
        raise SpecError("no memories or slaves")
    if len(m.targets) > 63:
        raise SpecError("at most 63 NoC slave ports")
    _check_overlap(m)
    _check_names(m)
    _chi(m, raw.get("chi"), model, cols, rows)

    # ---- traffic targets resolve to target groups ----
    groups = {x.name for x in m.memories} | {x.name for x in m.slaves}
    for ms in m.masters:
        tg = ms.traffic.targets or sorted(x.name for x in m.memories) or [m.slaves[0].name]
        for t in tg:
            if t not in groups:
                raise SpecError(f"master {ms.name}: traffic target {t!r} is not a memory or slave")
        ms.traffic.targets = tg

    # ---- scenarios: per-master profile overrides, unlisted masters idle ----
    m.scenarios = []
    mnames = [x.name for x in m.masters]
    for si, (sn, sc) in enumerate((raw.get("scenarios") or {}).items()):
        w = f"scenarios.{sn}"
        keys(sc, ["desc", "masters"], w, required=["masters"])
        ov = {}
        for mn, pr in (sc["masters"] or {}).items():
            if mn not in mnames:
                raise SpecError(f"{w}.masters: {mn!r} is not a master")
            if isinstance(pr, str):
                if pr not in profiles:
                    raise SpecError(f"{w}.masters.{mn}: profile {pr!r} not defined")
                pr = Obj(profiles[pr])
            else:
                pr = _profile(pr or {}, f"{w}.masters.{mn}")
            pr.targets = list(pr.targets) or m.masters[mnames.index(mn)].traffic.targets
            for t in pr.targets:
                if t not in groups:
                    raise SpecError(f"{w}.masters.{mn}: target {t!r} is not a memory or slave")
            ov[mn] = pr
        m.scenarios.append(Obj(name=ident(sn, "scenarios"), index=si,
                               desc=str(sc.get("desc", "")), masters=ov))

    # ---- external sources (private IP repos fetched at build time) ----
    m.sources = []
    for i, src in enumerate(raw.get("sources") or []):
        w = f"sources[{i}]"
        keys(src, ["name", "repo", "ref"], w, required=["name", "repo"])
        m.sources.append(Obj(name=ident(src["name"], f"{w}.name"), repo=str(src["repo"]),
                             ref=str(src.get("ref", "main"))))

    # ---- regress / report ----
    rg = raw.get("regress") or {}
    keys(rg, ["ral_master", "lists"], "regress")
    m.ral_master = rg.get("ral_master", m.masters[0].name)
    if m.ral_master not in [x.name for x in m.masters]:
        raise SpecError(f"regress.ral_master: {m.ral_master!r} is not a master")
    lists = rg.get("lists") or {"testlist": [{"test": t, "seeds": 1} for t in TESTS
                                             if t != "coherence" or m.chi.rn]}
    m.lists = {}
    for ln, entries in lists.items():
        ident(ln, "regress.lists")
        out = []
        for j, e in enumerate(entries):
            keys(e, ["test", "seeds", "plusargs"], f"regress.lists.{ln}[{j}]", required=["test"])
            if e["test"] not in TESTS:
                raise SpecError(f"regress.lists.{ln}[{j}].test: {e['test']!r} ({', '.join(TESTS)})")
            if e["test"] == "coherence" and not m.chi.rn:
                raise SpecError(f"regress.lists.{ln}[{j}]: test coherence needs a chi section")
            pa = str(e.get("plusargs", ""))
            if e["test"] == "scenario" and "+SCENARIO=" not in pa:
                raise SpecError(f"regress.lists.{ln}[{j}]: test scenario needs +SCENARIO=<name>")
            for sn in re.findall(r"\+SCENARIO=(\w+)", pa):
                if sn not in [x.name for x in m.scenarios]:
                    raise SpecError(f"regress.lists.{ln}[{j}]: scenario {sn!r} not defined")
            out.append(Obj(test=e["test"], seeds=num(e.get("seeds", 1), "seeds"), plusargs=pa))
        m.lists[ln] = out
    rp = (raw.get("report") or {}).get("latency") or {}
    keys(raw.get("report") or {}, ["latency"], "report")
    keys(rp, ["percentiles", "split_rw", "zero_load_slack"], "report.latency")
    m.percentiles = [num(p, "percentiles") for p in rp.get("percentiles", [50, 90, 99])]
    if any(not 0 < p < 100 for p in m.percentiles):
        raise SpecError("report.latency.percentiles: each in 1..99")
    m.split_rw = bool(rp.get("split_rw", True))
    m.zero_load_slack = num(rp.get("zero_load_slack", 12), "zero_load_slack")

    _derive_latency(m)
    _derive_path_addrs(m)
    _derive_regions(m)
    return m


MASTER_PROTOCOLS = ("axi4", "axi4lite", "ahb", "chi")
SLAVE_PROTOCOLS = ("axi4", "axi4lite", "ahb", "apb")


def _protocol(d, what, allowed, model, may_convert):
    """AMBA protocol of a NoC port (model mesh puts the protocol adapter in the generated NoC)"""
    p = d.get("protocol", "axi4")
    if p not in allowed:
        raise SpecError(f"{what}.protocol: {p!r} ({' | '.join(allowed)})")
    if p != "axi4" and model != "mesh":
        raise SpecError(f"{what}.protocol: {p} needs noc.model: mesh (the generated NoC has the adapters)")
    if p != "axi4" and not may_convert:
        raise SpecError(f"{what}.protocol: RTL endpoints and the apb_bridge slave connect as axi4")
    return p


def _chi(m, c, model, cols, rows):
    """CHI coherence: one HN-F on the mesh keeps the `coherent` memories coherent
    for the `protocol: chi` masters (RN-F, each with a cache bridge in the bench)
    and the AMBA masters (RN-I)"""
    rn = [x for x in m.masters if x.protocol == "chi"]
    if c is None:
        if rn:
            raise SpecError(f"masters {rn[0].name}: protocol chi needs a chi section")
        m.chi = Obj(home=None, coherent=[], lines=0, rn=[], coh_targets=set())
        return
    keys(c, ["home", "coherent", "cache_lines"], "chi", required=["home", "coherent"])
    if model != "mesh":
        raise SpecError("chi: needs noc.model: mesh")
    if m.chiplet.dies > 1:
        raise SpecError("chi: not supported with chiplet yet (one die)")
    if not rn:
        raise SpecError("chi: at least one master with protocol: chi")
    for x in rn:
        if x.kind != "vip":
            raise SpecError(f"masters {x.name}: protocol chi only on a VIP master (the bench's RN-F cache bridge)")
    coh = c["coherent"]
    if not isinstance(coh, list) or not coh:
        raise SpecError("chi.coherent: a list of memory names")
    ts = set()
    base = None
    for n in coh:
        mem = [x for x in m.memories if x.name == n]
        sl = [x for x in m.slaves if x.name == n and x.kind == "memory"]
        if mem:
            ts |= {mem[0].first + k for k in range(mem[0].channels)}
        elif sl:
            ts.add(sl[0].index)
        if base is None and (mem or sl):
            base = (mem or sl)[0].base
        else:
            raise SpecError(f"chi.coherent: {n!r} is not a memory (memories, or a slave of kind memory)")
    lines = num(c.get("cache_lines", 64), "chi.cache_lines")
    if not pow2(lines) or not 4 <= lines <= 1024:
        raise SpecError("chi.cache_lines: power of two, 4..1024")
    m.chi = Obj(home=_node(c["home"], "chi.home", cols, rows), coherent=list(coh), lines=lines,
                rn=[x.index for x in rn], coh_targets=ts, base=base)


def _node(v, what, cols, rows):
    if not (isinstance(v, (list, tuple)) and len(v) == 2):
        raise SpecError(f"{what}: expected [x, y]")
    x, y = num(v[0], what), num(v[1], what)
    if not (0 <= x < cols and 0 <= y < rows):
        raise SpecError(f"{what}: [{x}, {y}] outside the {cols}x{rows} mesh")
    return (x, y)


def _rtl(r, what):
    keys(r, ["module", "prefix", "clock", "reset", "params", "files", "filelist", "apb", "fallback"],
         what, required=["module"])
    fb = r.get("fallback", "none")
    if fb not in ("vip", "none"):
        raise SpecError(f"{what}.fallback: vip | none")
    return Obj(module=ident(r["module"], f"{what}.module"), prefix=str(r.get("prefix", "")),
               clock=ident(r.get("clock", "clk"), f"{what}.clock"),
               reset=ident(r.get("reset", "rst_n"), f"{what}.reset"),
               params=dict(r.get("params") or {}), files=[str(f) for f in r.get("files") or []],
               filelist=str(r["filelist"]) if "filelist" in r else None,
               apb=r.get("apb"), fallback=fb)


def _profile(p, what):
    keys(p, ["read_pct", "beats", "targets", "outstanding", "bandwidth_mbps", "pattern",
             "region", "block", "stride", "gap", "pace"], what)
    rp = num(p.get("read_pct", 50), f"{what}.read_pct")
    if not 0 <= rp <= 100:
        raise SpecError(f"{what}.read_pct: 0..100")
    b = p.get("beats", [1, 16])
    if isinstance(b, int):
        b = [b, b]
    lo, hi = num(b[0], what), num(b[1], what)
    if not 1 <= lo <= hi <= 256:
        raise SpecError(f"{what}.beats: 1 <= min <= max <= 256")
    out = num(p.get("outstanding", 1), f"{what}.outstanding")
    if out != 1:
        raise SpecError(f"{what}.outstanding: the bundled AXI master VIP has one burst in flight")
    pat = p.get("pattern", "random")
    if pat not in PATTERNS:
        raise SpecError(f"{what}.pattern: {pat!r} ({' | '.join(PATTERNS)})")
    region = None
    if "region" in p:
        r = p["region"]
        keys(r, ["offset", "size"], f"{what}.region", required=["offset", "size"])
        region = (num(r["offset"], f"{what}.region.offset"), num(r["size"], f"{what}.region.size"))
        if region[0] % 4096 or region[1] % 4096 or region[1] == 0:
            raise SpecError(f"{what}.region: offset and size must be 4 KB multiples")
    blk, stride = (0, 0), 0
    if pat == "block2d":
        if "block" not in p or "stride" not in p:
            raise SpecError(f"{what}: block2d needs block: [w_bytes, h_lines] and stride")
        blk = (num(p["block"][0], what), num(p["block"][1], what))
        stride = num(p["stride"], f"{what}.stride")
        if blk[0] % 4 or not 4 <= blk[0] <= 4096 or blk[1] < 1 or stride < blk[0] or stride % 4:
            raise SpecError(f"{what}: block width a multiple of 4 up to 4 KB, stride >= width")
    elif "block" in p or "stride" in p:
        raise SpecError(f"{what}: block/stride only with pattern block2d")
    bw = num(p["bandwidth_mbps"], what) if "bandwidth_mbps" in p else 0
    pace = p.get("pace", False)
    if not isinstance(pace, bool):
        raise SpecError(f"{what}.pace: true or false")
    if pace and not bw:
        raise SpecError(f"{what}.pace needs bandwidth_mbps")
    if pace and p.get("gap"):
        raise SpecError(f"{what}: pace and gap both set; pace derives the gap from bandwidth_mbps")
    return Obj(read_pct=rp, beats=(lo, hi), targets=list(p.get("targets") or []),
               bandwidth=bw, pace=pace,
               pattern=pat, region=region, block=blk, stride=stride,
               gap=num(p.get("gap", 0), f"{what}.gap"))


def _regblock(b, what):
    keys(b, ["desc", "regs", "rtl_only"], what, required=["regs"])
    regs, offs = [], set()
    for i, r in enumerate(b["regs"]):
        w = f"{what}.regs[{i}]"
        keys(r, ["name", "offset", "access", "reset", "volatile", "desc", "fields"], w,
             required=["name", "offset", "access"])
        acc = r["access"]
        if acc not in ACCESS:
            raise SpecError(f"{w}.access: {acc!r} ({', '.join(sorted(ACCESS))})")
        off = num(r["offset"], f"{w}.offset")
        if off % 4 or off >= 4096 or off in offs:
            raise SpecError(f"{w}.offset: 0x{off:x} must be word aligned, < 4 KB and unique")
        offs.add(off)
        reset = num(r.get("reset", 0), f"{w}.reset")
        fields = []
        for j, f in enumerate(r.get("fields") or []):
            fw = f"{w}.fields[{j}]"
            keys(f, ["name", "bits", "access", "reset", "desc"], fw, required=["name", "bits"])
            lsb, width = bits(f["bits"], fw)
            facc = f.get("access", acc)
            if facc not in ACCESS:
                raise SpecError(f"{fw}.access: {facc!r}")
            fr = num(f["reset"], fw) if "reset" in f else (reset >> lsb) & ((1 << width) - 1)
            fields.append(Obj(name=ident(f["name"], fw), lsb=lsb, width=width, access=facc,
                              reset=fr, volatile=False))
        if not fields:
            fields = [Obj(name="VAL", lsb=0, width=32, access=acc, reset=reset, volatile=False)]
        used = 0
        for f in fields:
            mask = ((1 << f.width) - 1) << f.lsb
            if used & mask:
                raise SpecError(f"{w}: fields overlap")
            used |= mask
        reset = sum(f.reset << f.lsb for f in fields)
        regs.append(Obj(name=ident(r["name"], w), offset=off, access=acc, reset=reset,
                        volatile=bool(r.get("volatile", False)), desc=str(r.get("desc", "")),
                        fields=fields, core=False))
    return Obj(desc=b.get("desc", ""), regs=sorted(regs, key=lambda r: r.offset),
               rtl_only=bool(b.get("rtl_only", False)))


def _placement(pl, nch, what, node, topo, rows, cols):
    if topo == "crossbar":
        return [(0, 0)] * nch
    if pl is None:
        raise SpecError(f"{what}: required on a mesh")
    keys(pl, ["rows", "fill", "nodes"], what)
    if "nodes" in pl:
        ns = [node(v, f"{what}.nodes") for v in pl["nodes"]]
        if len(ns) != nch:
            raise SpecError(f"{what}.nodes: {len(ns)} nodes for {nch} channels")
        return ns
    rs = [num(r, what) for r in pl.get("rows", [])]
    if not rs or any(not 0 <= r < rows for r in rs):
        raise SpecError(f"{what}.rows: rows inside the mesh")
    routers = [(x, y) for y in rs for x in range(cols)]
    fill = pl.get("fill", "round_robin")
    if fill == "round_robin":
        return [routers[c % len(routers)] for c in range(nch)]
    if fill == "block":
        per = -(-nch // len(routers))
        return [routers[c // per] for c in range(nch)]
    raise SpecError(f"{what}.fill: block | round_robin")


def _apb_slots(periphs, br, m, what):
    nslots = br.size // br.slot_size
    slots, used = [], {}
    entries = list(periphs)
    for io in m.iommus:
        entries.append({"name": f"{io.name}_regs", "regs": io.regs, "_iommu": io.name})
    for i, p in enumerate(entries):
        w = f"{what}[{i}]"
        io = p.pop("_iommu", None) if isinstance(p, dict) else None
        keys(p, ["name", "slot", "ip", "regs", "vip", "rtl_master", "ral", "params", "pins", "base"], w,
             required=["name"])
        src = [k for k in ("ip", "regs", "vip", "rtl_master") if k in p]
        if len(src) != 1:
            raise SpecError(f"{w}: exactly one of ip / regs / vip / rtl_master")
        if "ral" in p and src[0] != "rtl_master":
            raise SpecError(f"{w}: ral only with rtl_master")
        if "base" in p:
            b = num(p["base"], f"{w}.base")
            if (b - br.base) % br.slot_size or not br.base <= b < br.base + br.size:
                raise SpecError(f"{w}.base: 0x{b:x} is not a slot of {br.name}")
            slot = (b - br.base) // br.slot_size
            if "slot" in p and num(p["slot"], w) != slot:
                raise SpecError(f"{w}: slot and base disagree")
        elif "slot" in p:
            slot = num(p["slot"], f"{w}.slot")
        else:
            slot = next(s for s in range(nslots + 1) if s not in used)
        if not 0 <= slot < nslots:
            raise SpecError(f"{w}: slot {slot} outside the {nslots} slots of {br.name}")
        if slot in used:
            raise SpecError(f"{w}: slot {slot} already used by {used[slot]}")
        used[slot] = p["name"]
        kind = src[0]
        if kind == "vip" and p["vip"] != "apb":
            raise SpecError(f"{w}.vip: only 'apb'")
        if kind == "regs" and p["regs"] not in m.register_blocks:
            raise SpecError(f"{w}.regs: {p['regs']!r} not in register_blocks")
        if kind == "regs" and m.register_blocks[p["regs"]].rtl_only:
            raise SpecError(f"{w}.regs: {p['regs']!r} is rtl_only (use rtl_master + ral)")
        if kind == "rtl_master":
            rm = next((x for x in m.masters if x.name == p["rtl_master"]), None)
            if rm is None or rm.kind != "rtl":
                raise SpecError(f"{w}.rtl_master: {p['rtl_master']!r} is not a kind rtl master")
            if "ral" in p and p["ral"] not in m.register_blocks:
                raise SpecError(f"{w}.ral: {p['ral']!r} not in register_blocks")
            rm.rtl.apb = p["name"]
        slots.append(Obj(name=ident(p["name"], f"{w}.name"), slot=slot, kind=kind,
                         ip=p.get("ip"), regs=p.get("regs") or p.get("ral"), iommu=io,
                         rtl_master=p.get("rtl_master"),
                         params=dict(p.get("params") or {}), pins=dict(p.get("pins") or {}),
                         base=br.base + slot * br.slot_size))
    return sorted(slots, key=lambda s: s.slot)


def _check_overlap(m):
    wins = [(x.base, x.base + x.size - 1, x.name) for x in m.memories] + \
           [(x.base, x.base + x.size - 1, x.name) for x in m.slaves]
    for x in wins:
        if x[1] >= 1 << m.addr_width:
            raise SpecError(f"{x[2]}: window above the {m.addr_width}-bit address space")
    wins.sort()
    for a, b in zip(wins, wins[1:]):
        if b[0] <= a[1]:
            raise SpecError(f"address windows of {a[2]} and {b[2]} overlap")


def _check_names(m):
    seen = {}
    names = [x.name for x in m.masters] + [x.name for x in m.targets] + \
            [x.name for x in m.memories] + [x.name for x in m.iommus]
    if m.apb:
        names += [s.name for s in m.apb.slots]
    for n in names:
        key = n.upper()
        if key in seen and seen[key] != n or names.count(n) > 1 and n not in \
                [x.name for x in m.memories]:
            raise SpecError(f"name {n!r} is used twice")
        seen[key] = n


# ---------------------------------------------------------------------------
def hops(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


# Zero-load timing of the generated NoC RTL (noc.model: mesh), measured with
# socgen/specs/mini_mesh_soc.yaml (orca_noc_router and noc_router_open give the
# same numbers): a single-beat read costs MESH_REQ + MESH_RSP + 2 * hops + access
# cycles from AR to R, plus the protocol adapters' cycles; writes about 2 more.
MESH_REQ, MESH_RSP, MESH_HOP = 5, 4, 1
MESH_ADAPTER = {"axi4": 0, "axi4lite": 2, "ahb": 4, "apb": 5}
# chiplet: one way across the UCIe link (gateways + two UCIe adapters, measured with
# socgen/specs/chiplet_soc.yaml), plus the PHY delay each way
MESH_D2D = 5
# CHI (measured with socgen/specs/chi_mesh_soc.yaml): a CHI master, and an AMBA
# master's access to coherent memory, go through the HN-F: master -> home ->
# slave -> home -> master, 2 x MESH_REQ + 2 x MESH_RSP + CHI_HN + 2 x (hops to the
# home + hops from the home to the slave) + access. A CHI master's ideal is its
# worst zero-load case: for coherent memory a miss (ReadUnique / ReadShared, two
# memory chunks, two CompData, CompAck: + CHI_MISS); elsewhere a WriteNoSnpPtl
# (DBIDResp and the data flit: + CHI_NOSNP_WR + 2 x hops to the home). A miss
# that first writes back a dirty victim costs up to CHI_VICTIM more; cache hits
# take 2 cycles, so the lower bound is not checked for CHI masters.
MESH_ADAPTER["chi"] = 0
CHI_HN, CHI_MISS, CHI_NOSNP_WR, CHI_VICTIM = 1, 32, 9, 64


def path_hops(m, a, b):
    """router hops from endpoint a to endpoint b; across dies via the two gateways"""
    if a.die == b.die:
        return hops(a.node, b.node)
    g = m.chiplet.gateways
    return hops(a.node, g[a.die]) + hops(g[b.die], b.node)


def d2d_cycles(m, a, b):
    return 0 if a.die == b.die else MESH_D2D + m.chiplet.phy_cycles


def _derive_latency(m):
    n = m.noc
    iom = {io.name: io for io in m.iommus}
    mesh = n.model == "mesh"
    for ms in m.masters:
        ms.hops, ms.req, ms.rsp, ms.ideal = [], [], [], []
        # the behavioural NoC adds the IOMMU TLB hit time; the mesh RTL has no IOMMU
        extra = iom[ms.iommu].tlb_hit if ms.iommu and not mesh else 0
        for t in m.targets:
            h = path_hops(m, ms, t)
            ms.hops.append(h)
            via_hn = mesh and m.chi.rn and (ms.protocol == "chi" or t.index in m.chi.coh_targets)
            if via_hn:
                h1, h2 = hops(ms.node, m.chi.home), hops(m.chi.home, t.node)
                rq = 2 * MESH_REQ + (h1 + h2) * MESH_HOP + CHI_HN + MESH_ADAPTER[ms.protocol] + MESH_ADAPTER[t.protocol]
                rs = 2 * MESH_RSP + (h1 + h2) * MESH_HOP
                if ms.protocol == "chi":
                    rq += CHI_MISS if t.index in m.chi.coh_targets else CHI_NOSNP_WR + 2 * h1 * MESH_HOP
                ms.req.append(rq)
                ms.rsp.append(rs)
                ms.ideal.append(rq + t.access + rs)
                continue
            if mesh:
                x = d2d_cycles(m, ms, t)
                rq = MESH_REQ + h * MESH_HOP + MESH_ADAPTER[ms.protocol] + MESH_ADAPTER[t.protocol] + x
                rs = MESH_RSP + h * MESH_HOP + x
                ms.req.append(rq)
                ms.rsp.append(rs)
                ms.ideal.append(rq + t.access + rs)
                continue
            one = 2 * n.ni + (h + 1) * n.router + h * n.link
            ms.req.append(one + extra)
            ms.rsp.append(one)
            ms.ideal.append(one + extra + t.access + one)


def chan_of(mem, a):
    off = a - mem.base
    c = (off >> mem.gbits) & (mem.channels - 1)
    if mem.hash == "xor":
        c ^= (off >> (mem.gbits + mem.cbits)) & (mem.channels - 1)
    return c


def local_of(mem, a):
    """channel-local address: the offset with the channel-select bits removed"""
    off = a - mem.base
    lo = off & ((1 << mem.gbits) - 1)
    return ((off >> (mem.gbits + mem.cbits)) << mem.gbits) | lo


def decode(m, a):
    for mem in m.memories:
        if mem.base <= a < mem.base + mem.size:
            return mem.first + chan_of(mem, a)
    for s in m.slaves:
        if s.base <= a < s.base + s.size:
            return s.index
    return len(m.targets)


def _derive_path_addrs(m):
    """Per master, a private slice of every target, and one sample address per
    (master, target) path that decodes to that target."""
    nm = len(m.masters)
    for mem in m.memories:
        sl = (mem.size // nm) & ~(mem.granule - 1)
        mem.slice = sl
    for s in m.slaves:
        if s.kind in ("memory", "vip", "rtl"):
            s.slice = (s.size // nm) & ~0xFFF
            if s.slice == 0:
                raise SpecError(f"{s.name}: too small for a 4 KB slice per master")
    for ms in m.masters:
        ms.path_addr = []
        for t in m.targets:
            if t.kind == "channel":
                mem = next(x for x in m.memories if x.name == t.mem)
                a = mem.base + ms.index * mem.slice
                while chan_of(mem, a) != t.channel:
                    a += mem.granule
                if a >= mem.base + (ms.index + 1) * mem.slice:
                    raise SpecError(f"{mem.name}: slice too small to reach every channel")
                ms.path_addr.append(a + 0x40 * ms.index % mem.granule)
            elif t.kind == "apb_bridge":
                ms.path_addr.append(t.slots[0].base if t.slots else t.base)
            else:
                ms.path_addr.append(t.base + ms.index * t.slice)


def group(m, name):
    for x in m.memories:
        if x.name == name:
            return x
    return next(x for x in m.slaves if x.name == name)


def _derive_regions(m):
    """Resolve each (master, profile, target group) to an address window and
    check the windows of different masters never overlap (the scoreboard
    predicts read data per master)."""
    def resolve(ms, prof, what):
        out = []
        for g in prof.targets:
            gr = group(m, g)
            if gr.kind == "apb_bridge":
                out.append(Obj(group=g, kind="apb", base=gr.base, size=gr.size))
                continue
            if prof.region:
                off, size = prof.region
                if off + size > gr.size:
                    raise SpecError(f"{what}: region 0x{off:x}+0x{size:x} outside {g}")
                base = gr.base + off
            else:
                base, size = gr.base + ms.index * gr.slice, gr.slice
            if prof.pattern == "block2d" and prof.stride * prof.block[1] > size:
                raise SpecError(f"{what}: block2d frame (stride x lines) larger than its region in {g}")
            out.append(Obj(group=g, kind="mem", base=base, size=size))
        return out

    def check(entries, what):
        wins = sorted((e.base, e.base + e.size - 1, mn) for mn, es in entries.items()
                      for e in es if e.kind == "mem")
        for a, b in zip(wins, wins[1:]):
            if b[0] <= a[1] and a[2] != b[2]:
                raise SpecError(f"{what}: traffic regions of {a[2]} and {b[2]} overlap "
                                f"(0x{b[0]:x}); give each master its own region")

    base = {}
    for ms in m.masters:
        ms.windows = resolve(ms, ms.traffic, f"master {ms.name}")
        base[ms.name] = ms.windows
    check(base, "default traffic")
    for sc in m.scenarios:
        sc.windows = {}
        for mn, prof in sc.masters.items():
            ms = next(x for x in m.masters if x.name == mn)
            sc.windows[mn] = resolve(ms, prof, f"scenario {sc.name}, master {mn}")
        check(sc.windows, f"scenario {sc.name}")


def unmapped(m):
    """a 4 KB-aligned address no window covers, or None"""
    wins = sorted([(x.base, x.base + x.size) for x in m.memories] +
                  [(x.base, x.base + x.size) for x in m.slaves])
    a = 0
    for lo, hi in wins:
        if a < lo:
            return a
        a = max(a, hi)
    return a if a < (1 << m.addr_width) else None
