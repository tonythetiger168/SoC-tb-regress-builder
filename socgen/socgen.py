#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""socgen -- generate a SoC UVM testbench from one YAML SoC spec.

  python3 socgen/socgen.py socgen/specs/phone_soc.yaml --ip-root ../open-ip-portfolio
  python3 socgen/socgen.py SPEC --check            # validate only
  make build TB=<soc> && make run TB=<soc> TEST=<soc>_smoke_test

Outputs go to socgen/out/<soc>/ (see SPEC.md, "What gets generated"), plus
regress/<soc>_<list>.txt and regress/suites/<soc>.yaml in the repo root.
"""
import argparse
import math
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "lib"))

import jinja2  # noqa: E402

import nocgen  # noqa: E402
import openip  # noqa: E402
import openvip  # noqa: E402
import spec as specmod  # noqa: E402
from spec import Obj, SpecError  # noqa: E402

AXI_SIGS = ["awid", "awaddr", "awlen", "awsize", "awburst", "awprot", "awvalid", "awready",
            "wdata", "wstrb", "wlast", "wvalid", "wready", "bid", "bresp", "bvalid", "bready",
            "arid", "araddr", "arlen", "arsize", "arburst", "arprot", "arvalid", "arready",
            "rid", "rdata", "rresp", "rlast", "rvalid", "rready"]
# generic NoC RTL for noc.model: mesh (configured by the generated noc_cfg_pkg)
NOC_RTL = ["rtl/noc/noc_router_open.sv", "rtl/noc/noc_mesh.sv", "rtl/noc/noc_ni_mst.sv",
           "rtl/noc/noc_ni_slv.sv", "rtl/noc/noc_axi2lite.sv", "rtl/noc/noc_axi2ahb.sv",
           "rtl/noc/noc_ahb2axi.sv", "rtl/noc/noc_apb2axi.sv", "rtl/noc/noc_d2d_gw.sv", "rtl/noc/noc_d2d_phy.sv",
           "rtl/noc/noc_ni_chi.sv", "rtl/noc/noc_hnf.sv", "rtl/noc/noc_chi_rnf.sv",
           "rtl/noc/noc_acelite2axi.sv", "rtl/noc/noc_axi2acelite.sv"]
ORCA_RTL = ["+incdir+ext/xuanji-core/rtl/common", "ext/xuanji-core/rtl/common/clock_gate.sv",
            "ext/xuanji-core/rtl/noc/orca_noc_router.sv"]
AXI_SLAVE_OUT = {"awready", "wready", "bid", "bresp", "bvalid", "arready", "rid", "rdata", "rresp", "rlast", "rvalid"}
# repo files every generated bench compiles (from PR #1's VIPs and bridge)
VIP_ROOT = os.environ.get("OPEN_VIP_ROOT", os.path.join(ROOT, "..", "open-vip-portfolio"))
COMMON = ["rtl/soc/axi2apb_bridge.sv", "vip/axi4/axi4_if.sv", "vip/apb/apb_if.sv",
          "vip/axi4/axi4_sva.sv", "vip/apb/apb_sva.sv", "vip/mem/mem_vip_pkg.sv",
          "vip/axi4/axi4_pkg.sv", "vip/apb/apb_pkg.sv"]


def env():
    e = jinja2.Environment(loader=jinja2.FileSystemLoader(os.path.join(HERE, "templates")),
                           undefined=jinja2.StrictUndefined, keep_trailing_newline=True,
                           trim_blocks=False, lstrip_blocks=False)
    e.filters["sv_str"] = lambda s: '"%s"' % s
    e.filters["sv_h32"] = lambda v: "32'h%08X" % v
    e.filters["is_rtl"] = lambda k: "1'b1" if k == "rtl" else "1'b0"
    return e


def ral_blocks(m, ip_root):
    """one RAL block type per distinct register source"""
    blocks, by_src = [], {}
    if not m.apb:
        return blocks, []
    ids = []
    for s in m.apb.slots:
        if s.kind == "vip" or (s.kind == "rtl_master" and not s.regs):
            s.ral_type = None
            ids.append(0)
            continue
        src = f"ip:{s.ip}" if s.kind == "ip" else f"regs:{s.regs}"
        if src not in by_src:
            if s.kind == "ip":
                r = openip.registers(ip_root, s.ip)
                b = Obj(type=f"{m.name}_{s.ip.lower()}_blk", src=f"open-ip {r.doc}", regs=r.regs,
                        id=r.id if any(x.name == "ID" and x.offset == 0 for x in r.regs) else 0)
            else:
                rb = m.register_blocks[s.regs]
                regs = []
                for x in rb.regs:
                    vol = x.volatile or x.access in ("W1C",)
                    regs.append(Obj(name=x.name, offset=x.offset, access=x.access, reset=x.reset,
                                    volatile=vol, testable=not vol and x.access != "WO",
                                    fields=[Obj(f, volatile=vol) for f in x.fields]))
                idr = next((x for x in rb.regs if x.name == "ID"), None)
                b = Obj(type=f"{m.name}_{s.regs}_blk", src=f"register_blocks.{s.regs}", regs=regs,
                        id=idr.reset if idr and idr.offset == 0 else 0)   # the scoreboard reads offset 0
            by_src[src] = b
            blocks.append(b)
        s.ral_type = by_src[src].type
        ids.append(by_src[src].id or 0)
    return blocks, ids


def resolve_rtl(m):
    """RTL masters whose sources are not present fall back to VIP traffic"""
    notes = []
    for x in m.masters:
        if x.kind != "rtl":
            continue
        missing = [f for f in ([x.rtl.filelist] if x.rtl.filelist else []) + x.rtl.files
                   if not os.path.exists(os.path.join(ROOT, f))]
        if not missing:
            continue
        if x.rtl.fallback != "vip":
            raise SpecError(f"master {x.name}: RTL source(s) {missing} not found (fetch them, or set fallback: vip)")
        notes.append(f"master {x.name}: {missing[0]} not found, using a VIP master")
        x.kind, x.fallback_from = "vip", x.rtl.module
        if m.apb:
            for s in m.apb.slots:
                if s.kind == "rtl_master" and s.rtl_master == x.name:
                    s.kind = "vip"
    return notes


def generate(m, out, ip_root, spec_path, write_repo_files=True, vip_root=None):
    e = env()
    notes = resolve_rtl(m)
    for n in notes:
        print(f"socgen: {n}")
    M = m.name.upper()
    spec_rel = os.path.relpath(os.path.abspath(spec_path), ROOT)
    if m.apb:
        nslots = m.apb.size // m.apb.slot_size
        slot_bits = max(1, math.ceil(math.log2(nslots)))
        for s in m.apb.slots:
            s.dev = None
            if s.kind == "ip":
                s.wrapper = openip.wrapper(ip_root, s.ip, s.params)
                for p in s.pins:
                    if p not in [x.name for x in s.wrapper.pins if x.dir == "input"]:
                        raise SpecError(f"peripheral {s.name}: {s.ip}_apb has no input pin {p!r}")
                s.pin_expr = dict(s.pins)
                s.axi_ports = []
                if s.axi_slave:                   # a slave of kind periph: export the IP's AXI port
                    byname = {x.name: x for x in s.wrapper.pins}
                    pre = s.axi_slave.prefix
                    for sig in AXI_SIGS:
                        p = byname.get(pre + sig)
                        is_out = sig in AXI_SLAVE_OUT
                        if p is None:
                            if is_out:
                                raise SpecError(f"slave {s.axi_slave.name}: {s.ip}_apb has no AXI output {pre}{sig}")
                            continue
                        if p.dir != ("output" if is_out else "input"):
                            raise SpecError(f"slave {s.axi_slave.name}: {s.ip}_apb {pre}{sig} is {p.dir}")
                        if p.name in s.pins:
                            raise SpecError(f"peripheral {s.name}: pin {p.name} is the AXI port of slave "
                                            f"{s.axi_slave.name}, not a pins entry")
                        s.axi_ports.append(Obj(sig=sig, pin=p.name, dir=p.dir, width=p.width,
                                               port=f"{s.name}_axi_{sig}"))
                        if not is_out:
                            s.pin_expr[p.name] = f"{s.name}_axi_{sig}"
                pv = s.pins_vip
                if pv:
                    if pv.vip:
                        text, where = openvip.model_source(vip_root or VIP_ROOT, pv.vip, pv.model)
                        where = f"open-vip {pv.vip} tb/top_tb.sv"
                        pv.sources = [(f"{pv.model}.sv", f"// {pv.model}: cut by socgen from {where}\n" + text)]
                    else:
                        pv.sources = []
                        text = ""
                        for f in pv.files:
                            fp = f if os.path.isabs(f) else os.path.join(ROOT, f)
                            if not os.path.exists(fp):
                                raise SpecError(f"peripheral {s.name}.pins_vip.files: {f} not found")
                            pv.sources.append((None, f))
                            text += open(fp).read() + "\n"
                    mparams, ports = openvip.header(text, pv.model)
                    s.dev = openvip.wire(s, pv, ports, mparams, s.wrapper.pins)
                    s.pin_expr.update(s.dev.ip_inputs)
    else:
        nslots = slot_bits = 0
    for b in m.register_blocks.values():
        for r in b.regs:
            for f in r.fields:
                f.mask = ((1 << f.width) - 1) << f.lsb
    blocks, slot_ids = ral_blocks(m, ip_root)
    ip_commit = openip.commit(ip_root) if any(s.kind == "ip" for s in (m.apb.slots if m.apb else [])) else ""
    vip_slots = [s for s in m.apb.slots if s.kind == "vip"] if m.apb else []
    ext_slots = [s for s in m.apb.slots if s.kind in ("vip", "rtl_master")] if m.apb else []
    axi_slaves = [t for t in m.targets if t.kind in ("channel", "memory", "vip")]
    ctx = dict(m=m, CHI_VICTIM=specmod.CHI_VICTIM, M=M, spec_rel=spec_rel, apb_slot_bits=slot_bits, apb_nslots=nslots,
               slot_ids=slot_ids, iommu_of=[next((io.index for io in m.iommus if io.name == x.iommu), -1)
                                            for x in m.masters],
               unmapped=specmod.unmapped(m), ral_blocks=blocks, ip_commit=ip_commit,
               vip_slots=vip_slots, ext_slots=ext_slots, axi_slaves=axi_slaves, axi_sigs=AXI_SIGS,
               rtl_axi_sigs=[x for x in AXI_SIGS if not x.endswith("prot")],
               rtl_masters=[x for x in m.masters if x.kind == "rtl"],
               rtl_slaves=[t for t in m.slaves if t.kind == "rtl"],
               noc_hookup=nocgen.tb_hookup(m) if m.noc.model == "mesh" else "",
               axi_slots=[s for s in m.apb.slots if s.kind == "ip" and s.axi_slave] if m.apb else [])

    if os.path.isdir(out):
        shutil.rmtree(out)
    for d in ("rtl", "rtl/ip", "rtl/vip", "tb", "sim", "doc"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    written = []

    def put(rel, text):
        p = os.path.join(out, rel)
        with open(p, "w") as f:
            f.write(text)
        written.append(p)

    def render(tpl, rel, **extra):
        put(rel, e.get_template(tpl).render(**ctx, **extra))

    render("pkg.sv.j2", f"rtl/{m.name}_pkg.sv")
    rtl_files = [f"rtl/{m.name}_pkg.sv"]
    noc_files = []
    orca = m.noc.model == "mesh" and m.noc.router_ip == "orca"
    if m.noc.model == "mesh":
        put("rtl/noc_cfg_pkg.sv", nocgen.cfg_pkg(m))
        put(f"rtl/{m.name}_noc.sv", nocgen.noc_module(m))
        rtl_files += ["rtl/noc_cfg_pkg.sv", f"rtl/{m.name}_noc.sv"]
        # router: xuanji-core orca_noc_router (private, scripts/fetch_private_ip.sh puts it in
        # ext/); sim/files_open.f is the same bench with the open router, used when it is missing
        noc_files = (ORCA_RTL if orca else ["+define+NOC_OPEN_ROUTER"]) + NOC_RTL
        if m.chiplet.dies > 1:             # the open-ip UCIe D2D adapter on each die
            shutil.copy(os.path.join(ip_root, "rtl", "UCIe_top.sv"), os.path.join(out, "rtl", "ip", "UCIe_top.sv"))
            noc_files.insert(-len(NOC_RTL), f"{os.path.relpath(out, ROOT)}/rtl/ip/UCIe_top.sv")
    ip_files = []
    if m.apb:
        for bn in sorted({s.regs for s in m.apb.slots if s.kind == "regs"}):
            if m.register_blocks[bn].rtl_only:
                continue
            render("regs.sv.j2", f"rtl/{m.name}_{bn}_regs.sv", bn=bn, b=m.register_blocks[bn])
            rtl_files.append(f"rtl/{m.name}_{bn}_regs.sv")
        for ip in sorted({s.ip for s in m.apb.slots if s.kind == "ip"}):
            for f in (f"{ip}_top.sv", f"{ip}_apb.sv"):
                shutil.copy(os.path.join(ip_root, "rtl", f), os.path.join(out, "rtl", "ip", f))
                ip_files.append(f"rtl/ip/{f}")
            for extra in _includes(ip_root, ip):
                shutil.copy(os.path.join(ip_root, "rtl", extra), os.path.join(out, "rtl", "ip", extra))
        dev_files = []
        for s in m.apb.slots:
            if s.dev:
                for name, src in s.pins_vip.sources:
                    if name is None:
                        dev_files.append(src)                 # repo or absolute path, as given
                    else:
                        put(f"rtl/vip/{name}", src)
                        dev_files.append(f"{os.path.relpath(out, ROOT)}/rtl/vip/{name}")
        render("apb_subsys.sv.j2", f"rtl/{m.name}_apb_subsys.sv")
        rtl_files.append(f"rtl/{m.name}_apb_subsys.sv")
    render("ral_pkg.sv.j2", f"tb/{m.name}_ral_pkg.sv")
    render("env_pkg.sv.j2", f"tb/{m.name}_env_pkg.sv")
    render("test_pkg.sv.j2", f"tb/{m.name}_test_pkg.sv")
    render("tb_top.sv.j2", f"tb/{m.name}_tb_top.sv")

    rel_out = os.path.relpath(out, ROOT)
    rtl_objs = [x for x in m.masters if x.kind == "rtl"] + [t for t in m.slaves if t.rtl]
    ext = [f for x in rtl_objs for f in x.rtl.files] + \
          [f"-f {x.rtl.filelist}" for x in rtl_objs if x.rtl.filelist]
    fl = ["// generated by socgen: paths relative to the repo root",
          "+incdir+vip/mem", "+incdir+vip/axi4", "+incdir+vip/apb", f"+incdir+{rel_out}/rtl/ip"]
    fl += noc_files[:-len(NOC_RTL)] if noc_files else []      # orca router or +define+NOC_OPEN_ROUTER
    fl += COMMON[:1] + [f"{rel_out}/{f}" for f in ip_files] + ext + (dev_files if m.apb else [])
    for f in rtl_files:
        fl.append(f"{rel_out}/{f}")
        if f == "rtl/noc_cfg_pkg.sv":
            fl += NOC_RTL                       # generic NoC RTL right after its configuration
    fl = list(dict.fromkeys(fl))          # several RTL masters may share one filelist
    # PR #5's coverage/latency packages: axi4_pkg / apb_pkg import them where they exist
    common = [f for f in COMMON[1:] if f != "vip/mem/mem_vip_pkg.sv"]
    pre = [f for f in ("vip/common/fcov_pkg.sv", "vip/common/lat_pkg.sv") if os.path.exists(os.path.join(ROOT, f))]
    i = common.index("vip/axi4/axi4_pkg.sv")
    common[i:i] = pre + ["vip/mem/mem_vip_pkg.sv"]
    fl += common + [f"{rel_out}/tb/{m.name}_{x}.sv" for x in ("ral_pkg", "env_pkg", "test_pkg", "tb_top")]
    put("sim/files.f", "\n".join(fl) + "\n")
    mk = (f"# generated by socgen from {spec_rel}\n"
          f"TOP_{m.name} := {m.name}_tb_top\nFLIST_{m.name} := {rel_out}/sim/files.f\n")
    if orca:
        op = ["+define+NOC_OPEN_ROUTER" if f == ORCA_RTL[0] else f for f in fl if f not in ORCA_RTL[1:]]
        put("sim/files_open.f", "\n".join(op) + "\n")
        mk += (f"ifeq ($(wildcard {ORCA_RTL[-1]}),)\n"
               f"FLIST_{m.name} := {rel_out}/sim/files_open.f\n"
               f"endif\n")
    put("socgen.mk", mk)
    if m.sources:
        put("fetch_sources.sh", _fetch_script(m))
        os.chmod(os.path.join(out, "fetch_sources.sh"), 0o755)
    put(f"doc/{m.name}.md", _doc(m, spec_rel, slot_ids, ip_commit))
    put(f"doc/{m.name}_memmap.h", _header(m))
    put(f"doc/{m.name}_paths.csv", _paths_csv(m))
    put(f"doc/{m.name}_cov_waivers.txt", _cov_waivers(m, spec_rel))

    if write_repo_files:
        os.makedirs(os.path.join(ROOT, "regress", "suites"), exist_ok=True)
        for ln, entries in m.lists.items():
            p = os.path.join(ROOT, "regress", f"{m.name}_{ln}.txt")
            with open(p, "w") as f:
                f.write(f"# generated by socgen from {spec_rel}: <tb> <test> <seeds> [plusargs]\n")
                for x in entries:
                    f.write(f"{m.name} {m.name}_{x.test}_test {x.seeds}"
                            f"{(' ' + x.plusargs) if x.plusargs else ''}\n")
            written.append(p)
        ext_src = sorted({f for x in m.masters if x.kind == "rtl"
                          for f in ([x.rtl.filelist] if x.rtl.filelist else []) + x.rtl.files
                          if f.startswith("ext/")})
        p = os.path.join(ROOT, "regress", "suites", f"{m.name}.yaml")
        first = next(iter(m.lists))
        lists = "".join(f"  {'default' if ln == first else ln}: regress/{m.name}_{ln}.txt\n" for ln in m.lists)
        with open(p, "w") as f:
            f.write(f"# generated by socgen from {spec_rel}\n"
                    f"name: {m.name}\nlevel: soc\nsoc: {m.prefix}\n"
                    f"filelist: {rel_out}/sim/files.f\ntop: {m.name}_tb_top\n"
                    f"list:\n{lists}"
                    f"cov_include: ['{rel_out}/rtl/*']\n"
                    + (f"requires: [{ORCA_RTL[-1]}]\nfallback: {{filelist: {rel_out}/sim/files_open.f}}\n"
                       if orca else
                       # RTL masters from the private repos (fetched into ext/): the bench was
                       # generated with them, so without them the suite is reported as not run
                       f"requires: [{', '.join(ext_src)}]\n" if ext_src else ""))
        written.append(p)
    return written


def _includes(ip_root, ip):
    import re
    out = []
    for f in (f"{ip}_top.sv", f"{ip}_apb.sv"):
        for inc in re.findall(r'`include\s+"([^"]+)"', open(os.path.join(ip_root, "rtl", f)).read()):
            if os.path.exists(os.path.join(ip_root, "rtl", inc)):
                out.append(inc)
    return out


def _fetch_script(m):
    lines = ["#!/usr/bin/env bash", "# generated by socgen: fetch the external IP sources into socgen/ext/",
             "set -euo pipefail", 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"',
             'mkdir -p "$ROOT/socgen/ext"']
    for s in m.sources:
        d = f'"$ROOT/socgen/ext/{s.name}"'
        lines.append(f'[ -d {d} ] || git clone -q {s.repo} {d}')
        lines.append(f'git -C {d} fetch -q origin {s.ref} && git -C {d} checkout -q FETCH_HEAD')
    return "\n".join(lines) + "\n"


def _doc(m, spec_rel, slot_ids, ip_commit):
    if m.noc.model == "mesh":
        noc = (f"NoC: generated RTL `{m.name}_noc` ({m.noc.cols}x{m.noc.rows} mesh of "
               f"{'orca_noc_router (open router when xuanji-core is not fetched)' if m.noc.router_ip == 'orca' else 'noc_router_open'}"
               f", XY routing). Zero-load single-beat read = {specmod.MESH_REQ} + {specmod.MESH_RSP} + "
               f"2*hops + access cycles, plus the AMBA adapters "
               f"({', '.join(f'{k} {v}' for k, v in specmod.MESH_ADAPTER.items() if v)}). Clock {m.clock.period_ns} ns.")
        ports = ["", "## NoC ports", "", "| Port | Protocol | Router |", "|---|---|---|"]
        ports += [f"| master {x.name} | {nocgen.PROTO_NAME[x.protocol]} | {list(x.node)} |" for x in m.masters]
        ports += [f"| slave {t.name} | {nocgen.PROTO_NAME[t.protocol]} | {list(t.node)} |" for t in m.targets]
    else:
        noc = (f"NoC: {m.noc.topology} {m.noc.cols}x{m.noc.rows}, XY routing, one way = "
               f"2*{m.noc.ni} + (hops+1)*{m.noc.router} + hops*{m.noc.link} cycles, clock {m.clock.period_ns} ns.")
        ports = []
    L = [f"# {m.name}", "", f"Generated by socgen from `{spec_rel}`. {m.desc}", "", noc] + ports + ["",
         "## Address map", "", "| Window | Base | Size | Target |", "|---|---|---|---|"]
    for x in m.memories:
        L.append(f"| {x.name} | 0x{x.base:08X} | 0x{x.size:X} | {x.channels} x {x.kind} ports S_{x.name.upper()}0.."
                 f"{x.channels - 1}, {x.granule // 1024} KB granule, hash {x.hash} |")
    for s in m.slaves:
        L.append(f"| {s.name} | 0x{s.base:08X} | 0x{s.size:X} | {s.kind} S_{s.name.upper()} |")
    if m.apb:
        L += ["", f"## APB slots ({m.apb.name})", "", "| Slot | Base | Name | Block | ID |", "|---|---|---|---|---|"]
        for s, i in zip(m.apb.slots, slot_ids):
            blk = f"open-ip {s.ip}" if s.kind == "ip" else (f"register_blocks.{s.regs}" if s.kind == "regs" else "APB VIP")
            L.append(f"| {s.slot} | 0x{s.base:08X} | {s.name} | {blk} | {'0x%08X' % i if i else '-'} |")
        if ip_commit:
            L += ["", f"open-ip-portfolio commit `{ip_commit}`."]
    L += ["", "## Placement", "", "| Endpoint | Node [x, y] | Notes |", "|---|---|---|"]
    for x in m.masters:
        notes = [x.qos_class, f"prio {x.priority}"] + ([f"IOMMU {x.iommu}"] if x.iommu else []) + \
                ([f"target {x.latency_target} cyc"] if x.latency_target else []) + ([f"rtl {x.rtl.module}"] if x.rtl else [])
        L.append(f"| master {x.name} | {list(x.node)} | {', '.join(notes)} |")
    for t in m.targets:
        L.append(f"| port {t.name} | {list(t.node)} | access {t.access} |")
    L += ["", "## Ideal zero-load read latency (cycles, single beat)", "",
          "| master | " + " | ".join(t.name for t in m.targets) + " |",
          "|---|" + "---|" * len(m.targets)]
    for x in m.masters:
        L.append(f"| {x.name} | " + " | ".join(str(v) for v in x.ideal) + " |")
    if m.scenarios:
        L += ["", "## Scenarios", ""]
        for sc in m.scenarios:
            L.append(f"* `{sc.name}`: {sc.desc} ({', '.join(sc.masters)})")
    return "\n".join(L) + "\n"


def _header(m):
    g = f"{m.name.upper()}_MEMMAP_H"
    L = [f"/* generated by socgen: {m.name} address map */", f"#ifndef {g}", f"#define {g}"]
    for x in m.memories:
        L += [f"#define {x.name.upper()}_BASE 0x{x.base:08X}u", f"#define {x.name.upper()}_SIZE 0x{x.size:08X}u",
              f"#define {x.name.upper()}_CHANNELS {x.channels}u", f"#define {x.name.upper()}_GRANULE 0x{x.granule:X}u"]
    for s in m.slaves:
        L += [f"#define {s.name.upper()}_BASE 0x{s.base:08X}u", f"#define {s.name.upper()}_SIZE 0x{s.size:08X}u"]
    if m.apb:
        for s in m.apb.slots:
            L.append(f"#define {s.name.upper()}_BASE 0x{s.base:08X}u")
    L.append(f"#endif")
    return "\n".join(L) + "\n"


def _bits(mask_zero):
    """regex alternation of the set bit positions of a 32-bit mask"""
    return "|".join(str(b) for b in range(32) if mask_zero >> b & 1)


def _rtl_line(f, text, nth=0):
    """line number of the nth line of rtl/noc/<f> that contains text"""
    hits = [i + 1 for i, ln in enumerate(open(os.path.join(ROOT, "rtl", "noc", f))) if text in ln]
    if len(hits) <= nth:
        raise SystemExit(f"socgen: '{text}' not found in rtl/noc/{f} (coverage waiver anchor)")
    return hits[nth]


def _mesh_flows(m):
    """(die, router, in port, out port) hops of every flit the AMBA mesh
    carries: master -> slave requests and slave -> master responses, XY
    routed; a flit for the other die goes to this die's gateway and leaves the
    other die's gateway. Ports: 0 N (y+1), 1 S, 2 E (x+1), 3 W, 4 local."""
    nodes = [(x.die if m.chiplet.dies > 1 else 0, x.node[0], x.node[1]) for x in m.masters]
    nodes += [(t.die if m.chiplet.dies > 1 else 0, t.node[0], t.node[1]) for t in m.targets]
    gws = [(d, g[0], g[1]) for d, g in enumerate(m.chiplet.gateways)] if m.chiplet.dies > 1 else []
    nodes += gws
    nm, ns = len(m.masters), len(m.targets)
    hops = set()

    def route(die, x, y, dx, dy):
        inp = 4
        while True:
            out = 2 if dx > x else 3 if dx < x else 0 if dy > y else 1 if dy < y else 4
            hops.add((die, y * m.noc.cols + x, inp, out))
            if out == 4:
                return
            x, y = {2: (x + 1, y), 3: (x - 1, y), 0: (x, y + 1), 1: (x, y - 1)}[out]
            inp = {2: 3, 3: 2, 0: 1, 1: 0}[out]          # entering from the opposite side
    pairs = [(a, b) for a in range(nm) for b in range(nm, nm + ns)]
    pairs += [(b, a) for a, b in pairs]
    if m.chi.homes:
        # CHI: requests and responses through the homes, snoops, DMT data from a
        # slave straight to a requester, DCT data between RN-Fs: any endpoint
        # may talk to any other (an over-approximation: fewer waivers, never wrong)
        nodes += [(h.die if m.chiplet.dies > 1 else 0, h.node[0], h.node[1]) for h in m.chi.homes]
        hn = list(range(nm + ns + len(gws), len(nodes)))
        rn = set(m.chi.rn)
        coh = set(m.chi.coh_targets)
        pairs = []
        for a in range(nm):                     # RN-I: direct to non-coherent slaves, else via a home
            if a in rn:
                pairs += [(a, h) for h in hn]   # RN-F: everything through its homes (REQ, RSP, DAT, SNP back)
                if m.chi.dct:
                    pairs += [(a, b) for b in rn if b != a]      # DCT: CompData between RN-Fs
            else:
                pairs += [(a, nm + t) for t in range(ns) if t not in coh] + [(a, h) for h in hn]
        pairs += [(h, nm + t) for h in hn for t in range(ns)]  # homes: memory, forwarded NoSnp / chunks
        if m.chi.dmt:
            pairs += [(nm + t, a) for t in coh for a in rn]    # DMT: CompData from the slave
        pairs = sorted(set(pairs) | {(b, a) for a, b in pairs})
    for a, b in pairs:
        (da, xa, ya), (db, xb, yb) = nodes[a], nodes[b]
        if da == db:
            route(da, xa, ya, xb, yb)
        else:
            route(da, xa, ya, gws[da][1], gws[da][2])
            route(db, gws[db][1], gws[db][2], xb, yb)
    return nodes, hops


def _mesh_cov_waivers(m):
    """noc.model mesh (rtl/noc/ NIs, adapters, open router): what the generated
    NoC structurally cannot do in this SoC (AMBA, chiplet and CHI meshes)."""
    L = []
    MESH = "\\.u_mesh(_d\\S+)?"
    nm = len(m.masters)
    ni = m.noc_ni
    lg = lambda n: max(1, (n - 1).bit_length())           # noqa: E731  clog2
    rng = lambda lo, hi: "|".join(str(b) for b in range(lo, hi))   # noqa: E731
    T = lambda h, pt, f, why: L.append(f"toggle {h} {pt}\\S* \\S*{f} # {why}")   # noqa: E731
    NOC = f"{m.name}_noc\\.sv$"
    ALL = "\\S+"
    # ---- whole NoC ----
    T(ALL, "rst_n:1->0", "rtl/noc/noc_\\w+\\.sv$|" + NOC, "power-on reset only: the benches do not reset mid-run")
    T(ALL, "(ej_ready(\\[\\d+\\])?|l_tx_r\\[\\d+\\]|local_tx_ready):1->0",
      "rtl/noc/noc_(ni_slv|ni_mst|mesh|router_open|d2d_gw)\\.sv$|" + NOC,
      "every NI ejects at once (master NI: a response slot per chunk in flight; slave NI: request queues "
      "sized for every chunk all masters can have in flight), so the local output is always ready")
    T(ALL, "out_r\\[4\\]:1->0", "noc_router_open\\.sv$", "local output: every NI ejects at once (see ej_ready)")
    L.append(f"branch {MESH} if \\S*rtl/noc/noc_mesh\\.sv:{_rtl_line('noc_mesh.sv', '!ej_ready[e]) l_tx_r')}$ "
             "# no NI ever deasserts ej_ready")
    nb0 = _rtl_line("noc_mesh.sv", "function automatic int nb(")
    L.append(f"line {MESH} \\S+ \\S*rtl/noc/noc_mesh\\.sv:({rng(nb0, nb0 + 8)})$ "
             "# nb(): elaboration-time neighbour function (generate localparams), never called at run time")
    L.append(f"branch {MESH} \\S+ \\S*rtl/noc/noc_mesh\\.sv:({rng(nb0, nb0 + 8)})$ "
             "# nb(): elaboration-time neighbour function")
    pkg = nocgen.cfg_pkg(m).split("\n")
    for fn, why in (("ep_name(", "ep_name() names endpoints in messages only"),
                    ("hn_ep(", "hn_ep(): CHI home lookup, no CHI home nodes here")):
        if fn == "hn_ep(" and m.chi.homes:
            continue
        a = next(i for i, ln in enumerate(pkg) if "function automatic" in ln and fn in ln) + 1
        b = next(i for i in range(a, len(pkg)) if "endfunction" in pkg[i]) + 1
        L.append(f"line noc_cfg_pkg \\S+ \\S*/noc_cfg_pkg\\.sv:({rng(a, b + 1)})$ # {why}")
    for f, txt in (("noc_ahb2axi.sv", "default: st <= IDLE;"), ("noc_axi2ahb.sv", "default: st <= IDLE;"),
                   ("noc_axi2lite.sv", "default: st <= IDLE;"), ("noc_apb2axi.sv", "default: st <= IDLE;")):
        L.append(f"line \\S+ case \\S*rtl/noc/{f.replace('.', '[.]')}:{_rtl_line(f, txt)}$ "
                 "# FSM default arm: every state encoding in use is decoded")
    a2h = _rtl_line("noc_axi2ahb.sv", "ADDR:  if (hready)")
    L.append(f"branch \\S+ else \\S*rtl/noc/noc_axi2ahb[.]sv:{a2h}$ # HREADY is high in the address phase: "
             "this master never pipelines (address phase only after the previous data phase completed), and an "
             "AHB slave inserts wait states only in a data phase")
    # ---- mesh links and routers (noc_router_open) ----
    X, Y = m.noc.cols, m.noc.rows
    nodes, hops = _mesh_flows(m)
    dname = ["north", "south", "east", "west"]
    for n in range(X * Y):
        x, y = n % X, n // X
        edge = [d for d, ok in enumerate((y + 1 < Y, y > 0, x + 1 < X, x > 0)) if not ok]
        R = f"{MESH}\\.g_r\\[{n}\\]\\.u_rt"          # the dies' routers n share one coverage scope
        for d in edge:
            T(MESH, f"(rx_v|tx_v|tx_r|rx_r)\\[{n}\\]\\[{d}\\]", "rtl/noc/noc_mesh\\.sv$",
              f"router {n} [{x}, {y}] {dname[d]} side is the mesh edge (tied off)")
            T(R, f"({dname[d]}_(rx|tx)_(valid|ready)|(in_v|in_r|ne|nempty|pop|ov|out_r)\\[{d}\\]|"
                 f"g_in\\[{d}\\]\\.\\w+|rr\\[{d}\\]|win\\[{d}\\])", "noc_router_open\\.sv$",
              f"router {n} [{x}, {y}] {dname[d]} port is on the mesh edge: nothing enters or leaves there")
        T(R, "test_en", "noc_router_open\\.sv$", "test_en is tied to 0")
        # inputs / outputs no flit of this SoC uses (XY routing, endpoint placement)
        used_in = {i for (dd, r, i, o) in hops if r == n}
        used_out = {o for (dd, r, i, o) in hops if r == n}
        for p in range(5):
            if p in edge:
                continue
            if p not in used_in:
                T(R, f"((in_v|in_r|ne|nempty|pop)\\[{p}\\]|g_in\\[{p}\\]\\.\\w+)", "noc_router_open\\.sv$",
                  f"router {n} input {p}: no XY route of this SoC enters here")
            if p not in used_out:
                T(R, f"((ov|out_r)\\[{p}\\]|rr\\[{p}\\]|win\\[{p}\\])", "noc_router_open\\.sv$",
                  f"router {n} output {p}: no XY route of this SoC leaves here")
                continue
            ins = sorted({i for (dd, r, i, o) in hops if r == n and o == p})
            rrv = {(i + 1) % 5 for i in ins}
            for b in range(3):
                if not any(i >> b & 1 for i in ins):
                    T(R, f"win\\[{p}\\]\\[{b}\\]", "noc_router_open\\.sv$",
                      f"router {n} output {p} is fed by inputs {ins} only (XY routes of this SoC)")
                if not any(v >> b & 1 for v in rrv):
                    T(R, f"rr\\[{p}\\]\\[{b}\\]", "noc_router_open\\.sv$",
                      f"router {n} output {p}: round-robin pointer takes {sorted(rrv)} only")
                elif all(v >> b & 1 for v in rrv):
                    T(R, f"rr\\[{p}\\]\\[{b}\\]:1->0", "noc_router_open\\.sv$",
                      f"router {n} output {p}: round-robin pointer takes {sorted(rrv)} only")
        # an input whose flits all eject here, into a local output nothing else feeds:
        # the ejection port is always ready, so the FIFO drains a flit every cycle
        # one arrives and never holds two
        for p in range(4):
            outs = {o for (dd, r, i, o) in hops if r == n and i == p}
            if outs == {4} and {i for (dd, r, i, o) in hops if r == n and o == 4} == {p}:
                T(R, f"g_in\\[{p}\\]\\.cnt\\[[1-9]\\]", "noc_router_open\\.sv$",
                  f"router {n} input {p} only feeds the local output, which no other input uses and whose "
                  "ejection is always ready: the FIFO never holds more than one flit")
        # dir_of() arms and output muxes that need a neighbour on that side
        arm = {2: "> X_POS) r = 2", 3: "< X_POS) r = 3", 0: "> Y_POS) r = 0", 1: "< Y_POS) r = 1"}
        mux = {d: f"assign {dname[d]}_tx_valid" for d in range(4)}
        for d in edge:
            L.append(f"line {R} \\S+ \\S*rtl/noc/noc_router_open[.]sv:{_rtl_line('noc_router_open.sv', arm[d])}$ "
                     f"# router {n} [{x}, {y}]: no destination lies {dname[d]} of the mesh edge")
            L.append(f"branch {R} cond_then \\S*rtl/noc/noc_router_open[.]sv:"
                     f"{_rtl_line('noc_router_open.sv', mux[d])}$ # router {n}: {dname[d]} output on the mesh edge")
        # node mux: the endpoints on this router (per die)
        for die in range(max(1, m.chiplet.dies)):
            H = "\\.u_mesh" if m.chiplet.dies < 2 else f"\\.u_mesh_d{die}"
            here = [e for e, nd in enumerate(nodes) if nd == (die, x, y)]
            nep = len(nodes)
            rrv = {(e + 1) % nep for e in here}
            pick = set(here) | rrv               # (0 before the first injection)
            for b in range(lg(nep)):
                if not any(v >> b & 1 for v in pick):
                    T(H, f"g_r\\[{n}\\]\\.pick\\[{b}\\]", "rtl/noc/noc_mesh\\.sv$",
                      f"router {n} node mux: endpoints {here} only")
                elif all(v >> b & 1 for v in pick):
                    T(H, f"g_r\\[{n}\\]\\.pick\\[{b}\\]:1->0", "rtl/noc/noc_mesh\\.sv$",
                      f"router {n} node mux picks among {sorted(pick)} only")
                if not any(v >> b & 1 for v in rrv):
                    T(H, f"g_r\\[{n}\\]\\.rr\\[{b}\\]", "rtl/noc/noc_mesh\\.sv$",
                      f"router {n} node mux pointer takes {sorted(rrv)} only")
                elif all(v >> b & 1 for v in rrv):
                    T(H, f"g_r\\[{n}\\]\\.rr\\[{b}\\]:1->0", "rtl/noc/noc_mesh\\.sv$",
                      f"router {n} node mux pointer takes {sorted(rrv)} only")
    if m.chiplet.dies > 1:
        for t in ("if (tx_cnt == (QB+1)'(QD) && !tx_pop)", "if (rx_cnt == (QB+1)'(QD) && !rx_pop)"):
            L.append(f"branch \\.u_gw\\d+ if \\S*rtl/noc/noc_d2d_gw[.]sv:{_rtl_line('noc_d2d_gw.sv', t)}$ "
                     "# overflow check: the queues hold every flit all masters can have in flight")
        for die in range(m.chiplet.dies):
            other = [e for e, nd in enumerate(nodes) if nd[0] != die]
            T(f"\\.u_mesh_d{die}", f"(ej_valid|inj_ready)\\[({'|'.join(map(str, other))})\\]",
              "rtl/noc/noc_mesh\\.sv$", f"endpoints on another die are tied off in die {die}'s mesh")
        L.append(f"branch \\.u_noc if \\S*/{m.name}_noc[.]sv:"
                 f"{next(i for i, ln in enumerate(nocgen.noc_module(m).split(chr(10))) if 'gw_ovf[0] || gw_ovf[1]' in ln) + 1}$ "
                 "# d2d_error: no gateway overflow (queues sized for every flit in flight) and no unrecoverable "
                 "link error (UCIe Retry recovers the injected errors; link failure is UCIe_top's own function)")
        T("\\.u_gw\\d+", "overflow", "noc_d2d_gw\\.sv$", "the queues hold every flit all masters can have in flight")
        T("\\.u_phy", "([ab]_sb_(tx|rx)_msg|abs_m\\[\\d+\\]|bas_m\\[\\d+\\])\\[", "noc_d2d_phy\\.sv$",
          "sideband messages are UCIe_top's link-management codes (IP function, closed by its own bench); "
          "the PHY model only delays them")
        T("\\.u_phy", f"n_err\\[({rng(6, 32)})\\]", "noc_d2d_phy\\.sv$",
          "error-injection statistics counter (observability only, no RTL decision reads it): the "
          "+D2D_ERR_EVERY run corrupts about 100 flits; bits 6 and up need 64 to 2^31 corrupted flits")
    # ---- master NIs (noc_ni_mst, DW = 32) and their adapters ----
    one = [x for x in m.masters if x.protocol in ("axi4lite", "ahb")]
    BR = "(rb\\[\\d+\\]|rh|wh|whb\\.b)"
    for x in m.masters:
        N = f"\\.u_ni_{x.name}"
        T(N, f"(s_a[rw]size|{BR}\\.size)\\[2\\]", "noc_ni_mst\\.sv$", "32-bit data bus: AxSIZE <= 2")
        T("\\.u_noc", f"{x.name}_(ax_)?a[rw]size\\[2\\]", NOC, "32-bit data bus: AxSIZE <= 2")
        T(N, "whb\\.(nchunk|nrsp)\\[[6-7]\\]", "noc_ni_mst\\.sv$",
          "at most 32 chunks per burst (256 beats, 8 beats per chunk; WRAP <= 16 beats)")
        if x.protocol != "ace_lite":
            T(N, f"(s_a[rw]nosnp|{BR}\\.nosnp)", "noc_ni_mst\\.sv$",
              f"{x.name} is not ACE-Lite: nosnp tied 0 (coherent memory always through its home)")
            for txt in ("rh_dst  = rh.nosnp", "wh_dst   = wh.nosnp"):
                L.append(f"branch {N} cond_then \\S*rtl/noc/noc_ni_mst[.]sv:{_rtl_line('noc_ni_mst.sv', txt)}$ "
                         f"# {x.name} is not ACE-Lite: nosnp tied 0")
        if x in one:
            why = (f"{x.name} is an {'AHB-Lite' if x.protocol == 'ahb' else 'AXI4-Lite'} port: single beats, "
                   f"ID 0, INCR, one transfer in flight")
            pts = (f"(s_a[rw](id|len)\\[|s_[br]id\\[|s_a[rw]burst\\[1\\]|s_a[rw]burst\\[0\\]:1->0|s_wlast:1->0|"
                   f"{BR}\\.(id|len)\\[|{BR}\\.burst\\[1\\]|{BR}\\.burst\\[0\\]:1->0|(rb_i|wb_i|wc_n|rs_k)\\[|"
                   f"wc_(data|strb)\\[[1-7]\\]|whb\\.(nchunk|nrsp)\\[[1-7]\\]|(rb_cnt|wb_cnt|wb_pend|rs_cnt|w_infl)\\[[1-9]\\]|"
                   f"s_a[rw]ready:1->0|(r_slot_end|rh_last|wh_lastc):1->0)")
            T(N, pts, "noc_ni_mst\\.sv$", why)
            T(f"\\.u_{x.name}_ahb", "m_a[rw]ready:1->0", "rtl/noc/noc_ahb2axi\\.sv$", why)
            if x.protocol == "ahb":
                L.append(f"branch \\.u_{x.name}_ahb else \\S*rtl/noc/noc_ahb2axi[.]sv:"
                         f"{_rtl_line('noc_ahb2axi.sv', 'RA: if (m_arready)')}$ # {why}: the master NI always has a "
                         "free read-burst slot, so ARREADY is high")
            T("\\.u_noc", f"{x.name}_ax_(a[rw](id|len)\\[|[br]id\\[|a[rw]burst\\[1\\]|a[rw]burst\\[0\\]:1->0|"
                          f"wlast:1->0|a[rw]ready:1->0)", NOC, why)
            for f, txt, kind in (("noc_ni_mst.sv", "default: r = (i == 0) ? b.addr", "cond_else"),
                                 ("noc_ni_mst.sv", "if (rh_last) begin", "else"),
                                 ("noc_ni_mst.sv", "if (r_slot_end) begin", "else"),
                                 ("noc_ni_mst.sv", "if (w_cdone) begin", "else"),
                                 ("noc_ni_mst.sv", "if (wh_lastc) begin", "else"),
                                 ("noc_ni_mst.sv", "if (done || i + k > int'(b.len)", "else")):
                L.append(f"branch {N} {kind} \\S*rtl/noc/noc_ni_mst[.]sv:{_rtl_line(f, txt)}$ # {why}")
            L.append(f"line {N} \\S+ \\S*rtl/noc/noc_ni_mst[.]sv:{_rtl_line('noc_ni_mst.sv', chr(39).join(['2', 'b10: begin']))}$ "
                     f"# {why}: no WRAP bursts")
            if x.protocol == "axi4lite":
                T(f"({N}|\\.u_noc)", f"((s_a[rw]size|{BR}\\.size|{x.name}_ax_a[rw]size)\\[[02]\\]|"
                  f"(s_a[rw]size|{BR}\\.size|{x.name}_ax_a[rw]size)\\[1\\]:1->0)", "noc_ni_mst\\.sv$|" + NOC,
                  "AXI4-Lite has no AxSIZE: tied to 2")
            else:
                T(f"({N}|\\.u_noc)", f"(s_a[rw]prot|{BR}\\.prot|{x.name}_ax_a[rw]prot)\\[1\\]",
                  "noc_ni_mst\\.sv$|" + NOC, "AHB has no secure bit: noc_ahb2axi drives AxPROT[1] = 0")
                T("\\.u_noc", f"{x.name}_(hburst\\[|hprot\\[[23]\\]|htrans\\[0\\]|hsel:1->0|hsize\\[2\\])", NOC,
                  "the AHB test shim (noc_axi2ahb) issues SINGLE NONSEQ transfers, HPROT[3:2] = 0, "
                  "HSIZE <= 2, HSEL tied high")
        # DW = 32: the 64-bit beat merge never runs
        for txt in ("if (rhs.rresp[rs_k + 3'(w)] > s_rresp)",):
            L.append(f"branch {N} if \\S*rtl/noc/noc_ni_mst[.]sv:{_rtl_line('noc_ni_mst.sv', txt)}$ "
                     "# DW = 32: one word per beat, nothing to merge")
        for k in range(2):
            L.append(f"branch {N} cond_then \\S*rtl/noc/noc_ni_mst[.]sv:"
                     f"{_rtl_line('noc_ni_mst.sv', '(R == 2) ? 3' + chr(39) + 'd2', k)}$ # DW = 32: R = 1")
        L.append(f"branch {N} cond_then \\S*rtl/noc/noc_ni_mst[.]sv:"
                 f"{_rtl_line('noc_ni_mst.sv', '8' + chr(39) + '(rsp_w && OW' + chr(39) + '(ej_pkt.tag) == OW' + chr(39) + '(wb_ip))')}$ "
                 "# a burst's chunks all decode alike (windows are 4 KB aligned and an AXI burst stays in "
                 "4 KB), so a DECERR chunk never meets a response of the same burst")
    # merged adapter instances (Verilator merges the coverage of a module's instances: u_*)
    T(ALL, "(m_a[rw](id|len)\\[|m_[br]id\\[|m_a[rw]burst\\[1\\]|m_a[rw]burst\\[0\\]:1->0|m_wlast:1->0|"
      "(m_a[rw]size|size_q|hsize)\\[2\\]|hburst\\[|hprot\\[[23]\\]|htrans\\[0\\]|hsel:1->0|(m_a[rw]prot|prot_q)\\[1\\])",
      "rtl/noc/noc_ahb2axi\\.sv$", "noc_ahb2axi issues single INCR beats with ID 0 and AxPROT[1] = 0; its AHB "
      "masters (noc_axi2ahb) issue SINGLE NONSEQ transfers, HSIZE <= 2, HPROT[3:2] = 0, HSEL tied high")
    T(ALL, "((s_a[rw]size|size_q|hsize)\\[2\\]|hburst\\[|hprot\\[[23]\\]|htrans\\[0\\]|s_[br]resp\\[0\\])",
      "rtl/noc/noc_axi2ahb\\.sv$", "noc_axi2ahb: 32-bit bus (size <= 2), SINGLE NONSEQ transfers, HPROT[3:2] = 0, "
      "answers OKAY / SLVERR only")
    T(ALL, "(s_a[rw]size|size_q)\\[2\\]", "rtl/noc/noc_axi2lite\\.sv$", "32-bit data bus: AxSIZE <= 2")
    T(ALL, "(m_a[rw](id|len)\\[|m_[br]id\\[|m_a[rw]burst\\[1\\]|m_a[rw]burst\\[0\\]:1->0|m_wlast:1->0|"
      "m_a[rw]size\\[[02]\\]|m_a[rw]size\\[1\\]:1->0)", "rtl/noc/noc_apb2axi\\.sv$",
      "noc_apb2axi issues single 32-bit INCR beats with ID 0")
    # ---- slave NIs (noc_ni_slv) ----
    cap = sum(ni.maxo if x.protocol in ("axi4", "ace_lite") else 1 for x in m.masters)
    epb = lg(len(nodes) + 1)
    for j, t in enumerate(m.targets):
        N = f"\\.u_ni_{t.name}"
        P = f"\\.u_noc {t.name}_(ax_)?"
        why_id = "the slave NI issues ID 0 (one ID, in-order answers)"
        T(N, "m_a[rw]id\\[", "noc_ni_slv\\.sv$", why_id)
        T("\\.u_noc", f"{t.name}_(ax_)?(awid|arid|bid|rid)\\[", NOC, why_id)
        T(N, "m_a[rw]len\\[[3-7]\\]", "noc_ni_slv\\.sv$", "one burst per chunk: at most 8 beats")
        T("\\.u_noc", f"{t.name}_(ax_)?a[rw]len\\[[3-7]\\]", NOC, "one burst per chunk: at most 8 beats")
        T(N, "m_a[rw]burst\\[1\\]", "noc_ni_slv\\.sv$", "chunks are FIXED or INCR (WRAP bursts split at the wrap point)")
        T("\\.u_noc", f"{t.name}_(ax_)?a[rw]burst\\[1\\]", NOC, "chunks are FIXED or INCR")
        T(N, "m_a[rw]size\\[2\\]", "noc_ni_slv\\.sv$", "32-bit data bus: AxSIZE <= 2")
        ngw = len(m.chiplet.gateways) if m.chiplet.dies > 1 else 0
        hn = list(range(nm + len(m.targets) + ngw, nm + len(m.targets) + ngw + len(m.chi.homes)))
        coh = bool(m.chi.homes) and t.index in m.chi.coh_targets

        def vals(field, vs, why, pre="(rp|wp)"):
            """waive the bits of an NI request field that the values vs never move"""
            w = {"src": epb, "hnid": epb, "copc": 6, "cresp": 3, "dataid": 2}[field]
            for b in range(w):
                if not any(v >> b & 1 for v in vs):
                    T(N, f"{pre}\\[\\d+\\]\\.{field}\\[{b}\\]", "noc_ni_slv\\.sv$", why)
                elif all(v >> b & 1 for v in vs):
                    T(N, f"{pre}\\[\\d+\\]\\.{field}\\[{b}\\]:1->0", "noc_ni_slv\\.sv$", why)
        if not m.chi.homes:
            T(N, "(rp|wp)\\[\\d+\\]\\.(copc|cresp|dataid|hnid)\\[", "noc_ni_slv\\.sv$",
              "CHI fields: zero without CHI home nodes")
            vals("src", list(range(nm)), f"requesters are masters 0..{nm - 1}")
        elif not coh:
            T(N, "(rp|wp)\\[\\d+\\]\\.(copc|cresp|dataid|hnid)\\[", "noc_ni_slv\\.sv$",
              "CHI fields: zero (no DMT read to a slave outside the coherent memory)")
            vals("src", hn + [i for i in range(nm) if i not in m.chi.rn],
                 f"requesters are the homes {hn} (RN-F NoSnp) and the RN-I masters")
        else:
            # the homes that send this slave its lines (address interleave)
            g = m.chi.granule
            mine = sorted({hn[specmod.home_of(m, a)] for a in range(t.base & ~(g - 1), t.base + t.size, g)[:4096]
                           if specmod.decode(m, a) == t.index} or set(hn))
            why = f"writes to coherent memory come from its homes {mine} (write-backs, RN-I chunks): no CHI fields"
            T(N, "wp\\[\\d+\\]\\.(copc|cresp|dataid|hnid)\\[", "noc_ni_slv\\.sv$", why)
            vals("src", mine, why, "wp")
            if m.chi.dmt:
                why = (f"reads come from its homes {mine} and, with DMT, carry the requesting RN-F {list(m.chi.rn)} "
                       "as source, CompData, state I / SC / UC, DataID 0 / 2 and the home as HomeNID")
                vals("src", mine + list(m.chi.rn), why, "rp")
                vals("copc", [0, 4], why, "rp")
                vals("cresp", [0, 1, 2], why, "rp")
                vals("dataid", [0, 2], why, "rp")
                vals("hnid", [0] + mine, why, "rp")
            else:
                why = f"reads come from its homes {mine}: no CHI fields (no DMT)"
                T(N, "rp\\[\\d+\\]\\.(copc|cresp|dataid|hnid)\\[", "noc_ni_slv\\.sv$", why)
                vals("src", mine, why, "rp")
        hw = (lg(m.chi.slots) + 2) if m.chi.homes else 0     # a home's tag: {slot, kind}
        if not (coh and m.chi.dmt):                           # DMT reads carry the RN-F's TxnID
            T(N, f"rp\\[\\d+\\]\\.tag\\[({rng(max(lg(ni.maxo), hw), 6)})\\]", "noc_ni_slv\\.sv$",
              f"read tag = the master NI's response slot (< MAXO = {ni.maxo})"
              + (f" or a home's {{slot, kind}} ({hw} bits)" if hw else ""))
        T(N, f"wp\\[\\d+\\]\\.tag\\[({rng(max(lg(ni.maxb), hw), 6)})\\]", "noc_ni_slv\\.sv$",
          f"write tag = the master NI's burst slot (< MAXB = {ni.maxb})"
          + (f" or a home's {{slot, kind}} ({hw} bits)" if hw else ""))
        T(N, f"(rq_cnt|wq_cnt)\\[({rng(cap.bit_length(), 8)})\\]", "noc_ni_slv\\.sv$",
          f"at most {cap} chunks in flight to one slave (MAXO = {ni.maxo} per AXI4 master, one per "
          "AXI4-Lite / AHB master)")
        w = (t.size - 1).bit_length()
        if w < 32:
            bits = rng(w, 32)
            why = f"window 0x{t.base:08X} / 0x{t.size:X}: address bits {w}..31 are constant"
            T(N, f"m_a[rw]addr\\[({bits})\\]", "noc_ni_slv\\.sv$", why)
            T("\\.u_noc", f"{t.name}_(ax_)?(a[rw]addr|haddr|paddr)\\[({bits})\\]", NOC, why)
            T(f"\\.u_{t.name}_shim", f"(m_a[rw]addr|paddr|haddr|addr_q)\\[({bits})\\]", "rtl/noc/noc_\\w+\\.sv$", why)
        if t.protocol in ("ahb", "axi4lite", "apb") or t.kind == "apb_bridge":
            ad = {"ahb": "noc_axi2ahb", "axi4lite": "noc_axi2lite"}.get(t.protocol, "axi2apb_bridge")
            T(N, "(rp_cnt|wp_cnt)\\[[1-9]\\]", "noc_ni_slv\\.sv$",
              f"{ad} takes the next burst only when idle: one burst in flight")
        if t.protocol in ("ahb", "apb") or t.kind == "apb_bridge":
            why = "answers OKAY / SLVERR only (AHB / APB have one error response)"
            T(N, "(m_[br]resp\\[0\\]|r_resp\\[\\d+\\]\\[0\\])", "noc_ni_slv\\.sv$", why)
            T("\\.u_noc", f"{t.name}_(ax_)?[br]resp\\[0\\]", NOC, why)
        if t.protocol in ("ahb", "axi4lite"):
            # the NoC-side adapter, fed by the slave NI only (a separate coverage
            # scope unless Verilator merges it with a test shim of the same module)
            A = f"\\.u_{t.name}_{'ahb' if t.protocol == 'ahb' else 'lite'}"
            af = "noc_axi2ahb" if t.protocol == "ahb" else "noc_axi2lite"
            why = "fed by the slave NI: ID 0, at most 8 beats, FIXED / INCR"
            T(A, "(s_a[rw]id\\[|s_[br]id\\[|id_q\\[|(s_a[rw]len|len_q|beat_q)\\[[3-7]\\]|(s_a[rw]burst|burst_q)\\[1\\])",
              f"rtl/noc/{af}\\.sv$", why)
            if w < 32:
                T(A, f"(s_a[rw]addr|m_a[rw]addr|addr_q|start_q|haddr)\\[({rng(w, 32)})\\]", f"rtl/noc/{af}\\.sv$",
                  f"window 0x{t.base:08X} / 0x{t.size:X}: address bits {w}..31 are constant")
            wl = _rtl_line(f"{af}.sv", chr(39).join(["2", "b10: begin"]))
            L.append(f"line {A} \\S+ \\S*rtl/noc/{af}[.]sv:({wl}|{wl + 4})$ # {why}: no WRAP bursts")
            L.append(f"branch {A} \\S+ \\S*rtl/noc/{af}[.]sv:{wl + 4}$ # {why}: no WRAP bursts")
            wd = _rtl_line(f"{af}.sv", "WDATA: if (s_wvalid)")
            L.append(f"branch {A} else \\S*rtl/noc/{af}[.]sv:{wd}$ # the slave NI drives W the cycle after the AW "
                     "handshake, so W is always valid in WDATA")
        if t.kind == "apb_bridge":
            T("\\.u_apb", "((awid|arid|bid|rid)\\[|a[rw]len\\[[3-7]\\]|a[rw]burst\\[1\\])", "\\.sv$",
              "the slave NI issues ID 0, at most 8 beats, FIXED / INCR")
        if t.protocol == "ahb":
            T("\\.u_noc", f"{t.name}_(hburst\\[|hprot\\[[23]\\]|htrans\\[0\\]|hsel:1->0|hsize\\[2\\])", NOC,
              "noc_axi2ahb issues SINGLE NONSEQ transfers, HPROT[3:2] = 0, HSIZE <= 2; HSEL tied high")
    # ---- not reached (Tony, 2026-11-15: waive with the analysis, not as proven unreachable) ----
    # Every master NI has at most MAXB bursts / MAXO chunks per direction in
    # flight, and every NI ejects at once, so a router input FIFO (or a
    # gateway queue, or a slave NI's response injection) only backs up when
    # several masters' flit trains reach one output in the same few cycles.
    # The cov test's hot-spot, stream, link-fill and router-fill phases get the
    # FIFOs to 4..7 entries but not to all of them full on every link.
    NR = ("NOT REACHED (analysis, not a proof): needs several masters' flit trains to meet at one router output "
          f"within a few cycles while each master NI holds at most {ni.maxb} bursts / {ni.maxo} chunks in flight; "
          "the cov test's stress phases fill these buffers part way")
    T(MESH + "\\.g_r\\[\\d+\\]\\.u_rt", "(in_r\\[\\d\\]:1->0|out_r\\[[0-3]\\]:1->0|"
      "(north|south|east|west|local)_(rx|tx)_ready:1->0|g_in\\[\\d\\]\\.cnt\\[[2-9]\\])", "noc_router_open\\.sv$", NR)
    T(MESH, "((rx_r|tx_r)\\[\\d+\\]\\[\\d\\]|l_rx_r\\[\\d+\\]):1->0", "rtl/noc/noc_mesh\\.sv$", NR)
    if m.chiplet.dies > 1:
        T("\\.u_gw\\d+", "(tx|rx)_(cnt|level)\\[[2-9]\\]", "noc_d2d_gw\\.sv$", NR)
    for j, t in enumerate(m.targets):
        L.append(f"user \\.g_s\\[{j}\\]\\.u_sva\\.c_[rb]_wait # {NR} (the slave NI holds READY low only while "
                 "its previous response flit waits for injection)")
        if t.protocol in ("ahb", "axi4lite"):
            A = f"\\.u_{t.name}_{'ahb' if t.protocol == 'ahb' else 'lite'}"
            af = "noc_axi2ahb" if t.protocol == "ahb" else "noc_axi2lite"
            for txt in ("BRESP: if (s_bready)", "RDATA: if (s_rready)"):
                L.append(f"branch {A} else \\S*rtl/noc/{af}[.]sv:{_rtl_line(f'{af}.sv', txt)}$ # {NR} "
                         "(the slave NI's READY is low only while a response flit waits for injection)")
    # SVA cover properties on the slave VIP ports
    for j, t in enumerate(m.targets):
        g = f"\\.g_s\\[{j}\\]\\.u_sva\\."
        L.append(f"user {g}c_a[rw]_wrap # the slave NI issues FIXED / INCR chunks only (WRAP split at the wrap point)")
        if t.protocol in ("ahb", "axi4lite", "apb"):
            L.append(f"user {g}c_a[rw]_fixed # behind the {t.protocol} adapter the VIP sees single INCR beats")
            L.append(f"user {g}c_[rb]_wait # the {t.protocol} test shim raises READY in the state after the "
                     "request handshake, before the slave can answer")
    if m.chi.rn:
        L += _chi_cov_waivers(m, NR)
    return L


def _chi_cov_waivers(m, NR):
    """CHI meshes: what the HN-Fs (noc_hnf), the RN-F NIs (noc_ni_chi) and the
    ACE-Lite adapters (noc_acelite2axi) structurally cannot do in this SoC, the
    bench models in front of them, and the configuration (DMT, DCT)."""
    L = []
    T = lambda h, pt, f, why: L.append(f"toggle {h} {pt}\\S* \\S*{f} # {why}")   # noqa: E731
    B = lambda h, kind, f, txt, why, nth=0: L.append(                                 # noqa: E731
        f"{kind.split()[0]} {h} {kind.split()[1]} \\S*rtl/noc/{f.replace('.', '[.]')}:{_rtl_line(f, txt, nth)}$ # {why}")
    rng = lambda lo, hi: "|".join(str(b) for b in range(lo, hi))   # noqa: E731
    pkg = nocgen.cfg_pkg(m)

    def const(name):
        mt = re.search(name + r"\s*=\s*\d+'[hd]([0-9A-Fa-f]+)", pkg)
        return int(mt.group(1), 16 if "'h" in mt.group(0) else 10)
    nm, ns = len(m.masters), len(m.targets)
    ngw = len(m.chiplet.gateways) if m.chiplet.dies > 1 else 0
    hn = [nm + ns + ngw + i for i in range(len(m.chi.homes))]
    rn = list(m.chi.rn)
    epb = max(1, (nm + ns + ngw + len(hn)).bit_length())
    never = lambda vals, w: [b for b in range(w) if not any(v >> b & 1 for v in vals)]   # noqa: E731
    H, HF = "\\.u_hnf\\d+", "noc_hnf\\.sv$"
    # ---- bench models in <soc>_tb_top (stand-ins for CPUs / IO masters, like the VIPs) ----
    for f, what in (("noc_chi_rnf", "the CHI RN-F model (AXI4 VIP -> MESI cache -> CHI) standing in for a CPU"),
                    ("noc_axi2acelite", "the ACE-Lite source (AXI4 VIP -> ACE-Lite, own barriers and CMOs) "
                                        "standing in for an IO-coherent master")):
        for met in ("line", "branch", "toggle"):
            L.append(f"{met} \\.u_\\S+_shim \\S+ \\S*rtl/noc/{f}[.]sv(:\\d+)?$ # bench model: {what}; a "
                     "testbench instance in the tb_top like the VIPs, not NoC RTL (what it sends is checked by "
                     "the home's single-writer assertion, its own assertions and the coherence test)")
    # ---- HN-F ----
    T(H, "ej_ready", HF, "the home always ejects (ej_ready tied high)")
    cap = sum(1 if x.index in rn else m.noc_ni.maxo if x.protocol in ("axi4", "ace_lite") else 1 for x in m.masters)
    T(H, f"rq_cnt\\[({rng(cap.bit_length(), 8)})\\]", HF,
      f"at most {cap} requests in flight to a home (one per RN-F, MAXO = {m.noc_ni.maxo} chunks per AXI4 / "
      "ACE-Lite master, one per AXI4-Lite / AHB master)")
    T(H, "overflow", HF, f"the request queue (64) holds every request the masters can have in flight ({cap})")
    B(H, "branch if", "noc_hnf.sv", "if (rq_cnt == (QB+1)'(QD)) overflow", f"the request queue holds all {cap}")
    T(H, "mem_pend\\[\\d+\\]\\[2\\]", HF, "a slot has at most two memory chunks in flight (the halves of one line)")
    B(H, "line case", "noc_hnf.sv", "default: st[k] <= H_IDLE;", "FSM default arm: every state is decoded")
    B(H, "line case", "noc_hnf.sv", "          default: ;", "a home is sent requests, memory responses, CHI RSP and "
      "DAT only (requests are taken above, snoops go to RN-Fs)")
    B(H, "branch else", "noc_hnf.sv", "end else if ((ej.copc[3:0] == RSP_SNPRESP", "RN-Fs send a home CompAck, "
      "SnpResp and SnpRespFwded on RSP, nothing else")
    for nth in (0, 1):
        B(H, "branch else", "noc_hnf.sv", "if (holds(r, L[ej_kt])) begin", "a home snoops only RN-Fs its exact filter "
          "lists, and the entry stays until the snoop response (the set is busy in this slot)", nth)
    B(H, "branch else", "noc_hnf.sv", "if (ej.cresp[2]) dirty[ej_kt]", "an RN-F answers a snoop with data only "
      "for a dirty line (SnpRespData_PD / SnpRespDataFwded_PD)")
    if m.chi.dmt:
        why = ("DMT: the home never reads memory for itself (ReadShared / ReadUnique data goes from the slave to "
               "the requester; RN-I chunks and NoSnp requests are forwarded)")
        B(H, "branch cond_else", "noc_hnf.sv", "np.op     = (st[k] == H_WB) ? OP_WR : OP_RD;", why)
        B(H, "branch if", "noc_hnf.sv", "else if (ej.op == OP_RDATA) lbuf", why)
    if m.chi.dmt and m.chi.dct:
        why = ("DMT and DCT: the home never sends ReadShared / ReadUnique data itself (memory data comes straight "
               "from the slave, a unique owner forwards its line, and only a unique owner can hold it dirty)")
        B(H, "line elsif", "noc_hnf.sv", "end else if (is_rs[k] || is_ru[k]) begin", why)
        B(H, "branch else", "noc_hnf.sv", "if (rep_n[k] + 2'd1 ==", why)
        T(H, "(rep_n\\[\\d+\\]\\[1\\]|gr_cresp\\[\\d+\\]\\[2\\])", HF, why)
    if not m.chi.dct:
        why = "DCT off (chi.dct: false): no SnpSharedFwd / SnpUniqueFwd, so no forwarded CompData"
        B(H, "branch if", "noc_hnf.sv", "if (CHI_DCT && (is_rs[k] || is_ru[k]))", why)
        B(H, "line block", "noc_hnf.sv", "if (CHI_DCT && (is_rs[k] || is_ru[k]))", why)
        L.append(f"line {H} block \\S*rtl/noc/noc_hnf[.]sv:{_rtl_line('noc_hnf.sv', 'if (CHI_DCT && (is_rs[k] || is_ru[k]))') + 1}$ # {why}")
        for kind in ("branch if", "branch else"):
            B(H, kind, "noc_hnf.sv", "if (r != rqr[k] && holds(r, L[k]) && sf_u[r][LS[k]]) begin", why)
        for kind in ("branch cond_then", "branch cond_else"):
            B(H, kind, "noc_hnf.sv", "so = is_rs[k] ? SNP_SHAREDFWD : SNP_UNIQUEFWD;", why)
            B(H, kind, "noc_hnf.sv", "st[k] <= dirty[k] ? H_WB : H_GRANT;   // SnpSharedFwd", why)
        B(H, "line elsif", "noc_hnf.sv", "end else if (fwded[k]) begin", why)
        B(H, "branch if", "noc_hnf.sv", "if (ej.copc[3:0] == RSP_SNPRESPFWDED) fwded", why)
        B(H, "branch if", "noc_hnf.sv", "if (ej.copc[3:0] == DAT_SNPRESPDATAFWDED) fwded", why)
        B(H, "branch if", "noc_hnf.sv", "if (snp_op[ps] == SNP_SHAREDFWD || snp_op[ps] == SNP_UNIQUEFWD) n_dct++;", why)
        T(H, "(fwded|snp_op\\[\\d+\\]\\[4\\])", HF, why)
        L.append(f"user \\.u_\\S+_shim\\.c_ufwd_ # {why}")
    if not m.chi.dmt:
        why = "DMT off (chi.dmt: false): the home reads memory itself, no slave sends CompData"
        B(H, "line case", "noc_hnf.sv", "H_DMT: begin                          // DMT", why)
        B(H, "line case", "noc_hnf.sv", "H_DMT: if (gnt[k]) begin", why)
        for kind in ("branch if", "branch else"):
            B(H, kind, "noc_hnf.sv", "H_DMT: if (gnt[k]) begin", why)
            B(H, kind, "noc_hnf.sv", "if (mem_sent[k] == 2'd1) begin", why)
        B(H, "branch if", "noc_hnf.sv", "if (push && st[ps] == H_DMT) n_dmt++;", why)
        T("\\.u_ni_\\w+", "dmt", "noc_ni_chi\\.sv$", why)
    T(H, "(oq_cnt\\[2\\]|can_push:1->0)", HF, NR + " (the home's output queue fills only while its "
      "router input is full)")
    NRS = ("NOT REACHED in every slot (analysis, not a proof): home slot k >= 1 takes a request only while the "
           "lower slots are busy, so the rarer values (address bits only decode misses carry, NoSnp kinds and "
           "strobes, race outcomes such as a CleanUnique losing its line or a write-back after a SnpSharedFwd) "
           "do not all reach every upper slot; slot 0 takes each of them (the K slots are identical registers "
           "written by one loop, and every slot's state machine is covered)")
    T(H, "((L|LT|lost|nderr|is_\\w+|wd_resp|wd_be|after_wb)\\[[1-9]\\d*\\]|ln\\[[1-9]\\d*\\]\\[[01]\\])", HF, NRS)
    hw = max(1, (m.chi.slots - 1).bit_length()) + 2
    for t in m.targets:
        N = f"\\.u_ni_{t.name}"
        if t.index not in m.chi.coh_targets:
            T(N, f"(rp|wp)\\[\\d+\\]\\.tag\\[{hw - 1}\\]", "noc_ni_slv\\.sv$",
              "NOT REACHED (analysis, not a proof): a NoSnp request forwarded from home slot "
              f"{1 << (hw - 3)} or above to this slave (the home's lower slots busy at that moment); "
              "the lower slots' tags are covered")
        elif m.chi.dmt:
            T(N, "rp\\[\\d+\\]\\.cresp\\[0\\]", "noc_ni_slv\\.sv$",
              "NOT REACHED in every queue entry (analysis, not a proof): a DMT read granting SC (ReadShared of a "
              "line another RN-F holds) is taken by the other pending-read entries")
    # slave NI queues: the chunks to a slave come from the homes' slots (one line
    # at a time each) and the RN-I masters; the stress phases fill them part way
    for t in m.targets:
        T(f"\\.u_ni_{t.name}", "((rq_cnt|wq_cnt)\\[3\\]|(rp_cnt|wp_cnt)\\[2\\])", "noc_ni_slv\\.sv$",
          NR + " (eight chunks queued at one slave NI, or four bursts pending: the RN-Fs reach it one line at a "
          "time per home slot, and only the RN-I masters send chunks of their own)")
    # ---- RN-F NIs (noc_ni_chi), fed by the RN-F model ----
    for x in m.masters:
        if x.index not in rn:
            continue
        N, NF = f"\\.u_ni_{x.name}", "noc_ni_chi\\.sv$"
        T(N, "ej_ready", NF, "an RN-F takes every response, data and snoop (ej_ready tied high)")
        T(N, "txrsp_flit\\.(dbid|resperr)\\[", NF, "the RN-F sends CompAck, SnpResp and SnpRespFwded on RSP: "
          "no DBID, no RespErr")
        T(N, "txrsp_flit\\.resp\\[2\\]", NF, "RSP carries no PassDirty (dirty data goes on DAT)")
        ops = [const(n) for n in ("RSP_SNPRESP", "RSP_COMPACK") + (("RSP_SNPRESPFWDED",) if m.chi.dct else ())]
        for b in never(ops, 4):
            T(N, f"txrsp_flit\\.opcode\\[{b}\\]", NF, f"RSP opcodes of an RN-F: {[hex(v) for v in ops]}")
        ops = [const(n) for n in ("REQ_READSHARED", "REQ_READNOSNP", "REQ_READUNIQUE", "REQ_CLEANUNIQUE",
                                  "REQ_EVICT", "REQ_WRITEBACKFULL", "REQ_WRITENOSNPPTL")]
        for b in never(ops, 6):
            T(N, f"txreq_flit\\.opcode\\[{b}\\]", NF, f"REQ opcodes of the RN-F: {[hex(v) for v in ops]}")
        for b in never(hn, epb):
            T(N, f"txrsp_flit\\.nid\\[{b}\\]", NF, f"RSP goes to a home ({hn}): CompAck to the HomeNID, snoop "
              "responses to the snooping home")
        for b in never(rn, epb):
            T(N, f"rxsnp_flit\\.fwdnid\\[{b}\\]", NF, f"FwdNID is a requesting RN-F ({rn})")
        if not m.chi.dct:
            sops = [const(n) for n in ("SNP_SHARED", "SNP_UNIQUE", "SNP_CLEANSHARED")]
            for b in never(sops, 5):
                T(N, f"rxsnp_flit\\.opcode\\[{b}\\]", NF, f"DCT off: snoops {[hex(v) for v in sops]} only")
        srcs = hn + ([nm + t for t in sorted(m.chi.coh_targets)] if m.chi.dmt else []) \
            + ([r for r in rn if r != x.index] if m.chi.dct else [])
        for b in never(srcs, epb):
            T(N, f"rx(rsp|dat|snp)_flit\\.nid\\[{b}\\]", NF, f"flits reach an RN-F from {srcs} only (homes"
              + (", DMT slaves" if m.chi.dmt else "") + (", DCT RN-Fs" if m.chi.dct else "") + ")")
    # snoop addresses: lines of the coherent memory
    coh = [t for t in m.targets if t.index in m.chi.coh_targets]
    lo, hi = min(t.base for t in coh), max(t.base + t.size for t in coh) - 1
    zb = [b for b in range(6, 32) if not any(a >> b & 1 for a in (lo, hi)) and (hi - lo) < (1 << b)]
    if zb:
        T("\\.u_ni_\\w+", f"rxsnp_flit\\.addr\\[({'|'.join(map(str, zb))})\\]", "noc_ni_chi\\.sv$",
          f"snoops carry lines of the coherent memory 0x{lo:08X}..0x{hi:08X}: these address bits are 0")
    T("\\.u_ni_\\w+", "rxsnp_flit\\.addr\\[[0-5]\\]", "noc_ni_chi\\.sv$", "snoops carry line addresses")
    # ---- ACE-Lite adapters (noc_acelite2axi), fed by the bench's ACE-Lite source ----
    A, AF = "\\.u_\\w+_acel", "noc_acelite2axi\\.sv$"
    T(A, "(s_a[rw]size|m_a[rw]size)\\[2\\]", AF, "32-bit data bus: AxSIZE <= 2")
    T(A, "s_arsnoop\\[1\\]", AF, "ACE-Lite read snoop codes: ReadNoSnoop / ReadOnce 0000, CleanShared 1000, "
      "CleanInvalid 1001, MakeInvalid 1101 (bit 1 only in ACE5 CleanSharedPersist, not supported)")
    T(A, "s_awsnoop\\[[12]\\]", AF, "ACE-Lite write snoop codes: WriteNoSnoop / WriteUnique 000, "
      "WriteLineUnique 001 (bits 1, 2 only in ACE5 WriteUniquePtlStash etc., not supported)")
    nb = m.noc_ni.maxb + m.noc_ni.maxo
    T(A, f"r_out\\[({rng(nb.bit_length(), 8)})\\]", AF,
      f"at most MAXB + MAXO = {nb} reads without their last beat: the master NI holds MAXB = {m.noc_ni.maxb} "
      f"bursts until issued and MAXO = {m.noc_ni.maxo} chunks until answered")
    T(A, f"w_out\\[({rng(m.noc_ni.maxb.bit_length(), 8)})\\]", AF,
      f"at most MAXB = {m.noc_ni.maxb} writes without their B: the master NI holds a write burst until its B")
    return L


def _cov_waivers(m, spec_rel):
    """Coverage waivers that follow from the generated structure (score_cov.py
    format: '<metric> <regex> # reason'). Hierarchy: <soc>_tb_top.u_apb..."""
    L = [f"# generated by socgen from {spec_rel}: coverage waivers implied by the generated RTL",
         "# (scripts/cov/score_cov.py; <metric> <regex> # reason)",
         f"line {m.name}_pkg  # package functions are called only by testbench classes (no hardware)",
         f"branch {m.name}_pkg  # package functions are called only by testbench classes (no hardware)"]
    if m.noc.model == "mesh":
        L += _mesh_cov_waivers(m)
    if not m.apb:
        return "\n".join(L) + "\n"
    win = (m.apb.size - 1).bit_length()
    hi = (1 << 32) - (1 << win)
    L.append(f"toggle u_apb (awaddr|araddr|paddr|\\w+_paddr)\\[({_bits(hi)})\\] # APB window "
             f"0x{m.apb.base:08X}/0x{m.apb.size:X}: address bits {win}..31 are constant")
    if m.id_width < 8:
        L.append(f"toggle u_apb (awid|arid|bid|rid)\\[({_bits(0xFF & ~((1 << m.id_width) - 1))})\\] "
                 f"# the NoC forwards {m.id_width}-bit master IDs into the 8-bit APB-port ID")
    L.append("toggle u_apb [br]resp\\[0\\] # axi2apb_bridge answers OKAY/SLVERR only")
    if m.data_width == 32:
        L.append("toggle u_apb \\w*a[rw]size\\[2\\] # 32-bit data bus: AxSIZE <= 2, bit 2 is always 0")
    L.append("toggle u_apb(\\.[\\w*]+)? (rst_n|PRESETN):1->0 # power-on reset only: the socgen benches do not "
             "reset mid-run (each block's reset is checked by its own bench and the RAL reset test)")
    L.append("toggle u_apb irq\\[ # peripheral interrupts are IP pins (closed by each IP's own bench); "
             "register blocks and APB VIP slots tie theirs to 0")
    for sl in m.apb.slots:
        if sl.kind == "ip":
            axi = {x.pin for x in getattr(sl, "axi_ports", [])}
            pins = [p.name for p in sl.wrapper.pins if p.name not in axi]
            if pins:
                L.append(f"toggle u_apb {sl.name}_({'|'.join(pins)})(\\[|:) # {sl.ip} pins: "
                         f"IP function, closed at 100% by its own bench in open-ip-portfolio")
            if sl.dev:
                L.append(f"toggle u_apb {sl.name}_vip_\\w+ # device model on {sl.name}'s pins (IP function)")
            if getattr(sl, "axi_slave", None):
                t = next((x for x in m.slaves if x.name == sl.axi_slave.name), None)
                if t is not None:
                    w = (t.size - 1).bit_length()
                    L.append(f"toggle u_apb {sl.name}_\\w*a[rw]addr\\[({_bits((1 << 32) - (1 << w))})\\] "
                             f"# {sl.name} AXI port window 0x{t.base:08X}/0x{t.size:X}: bits {w}..31 are constant")
    L.append(f"branch u_apb cond_(then|else) \\S*{m.name}_apb_subsys\\.sv:\\d+$ # device-model pin hookups "
             f"(open-drain lines): IP function, see the IP pin waivers")
    for bn in dict.fromkeys(sl.regs for sl in m.apb.slots if sl.kind == "regs"):
        b = m.register_blocks[bn]
        f = f"{m.name}_{bn}_regs\\.sv$"          # every instance of the block (Verilator may merge them)
        ones = 0
        for r in b.regs:
            mask = sum(x.mask for x in r.fields) & 0xFFFFFFFF
            n = r.name.lower()
            if r.name == "ID":
                ones |= r.reset
            elif r.access in ("RW", "WO"):
                if r.access == "RW":
                    ones |= mask
                if mask != 0xFFFFFFFF:
                    L.append(f"toggle (?<= )[rq]_{n}\\[({_bits(~mask & 0xFFFFFFFF)})\\]\\S* \\S*{f} "
                             f"# {bn}.{r.name}: bits outside its fields")
            elif r.access == "W1C":
                L.append(f"toggle (?<= )r_{n}\\[\\S* \\S*{f} # {bn}.{r.name} W1C: set only by hw_{n}, "
                         f"tied to 0 (register-only block)")
        L.append(f"toggle (?<= )hw_\\w+\\[\\S* \\S*{f} # register-only block {bn}: hw_* inputs tied to 0 "
                 f"in the APB subsystem")
        never = ~ones & 0xFFFFFFFF
        if never:
            L.append(f"toggle (?<= )PRDATA\\[({_bits(never)})\\]\\S* \\S*{f} # {bn}: no readable register "
                     f"drives these bits (hw_* tied to 0, bits outside fields)")
    return "\n".join(L) + "\n"


def _paths_csv(m):
    L = ["master,slave,hops,req_cycles,rsp_cycles,access_cycles,ideal_read_cycles"]
    for x in m.masters:
        for t, h, rq, rs, idl in zip(m.targets, x.hops, x.req, x.rsp, x.ideal):
            L.append(f"{x.name},{t.name},{h},{rq},{rs},{t.access},{idl}")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spec")
    ap.add_argument("-o", "--out", help="output directory (default socgen/out/<soc>)")
    ap.add_argument("--ip-root", default=os.environ.get("OPEN_IP_ROOT", os.path.join(ROOT, "..", "open-ip-portfolio")),
                    help="open-ip-portfolio checkout (env OPEN_IP_ROOT)")
    ap.add_argument("--vip-root", default=VIP_ROOT,
                    help="open-vip-portfolio checkout for pins_vip device models (env OPEN_VIP_ROOT)")
    ap.add_argument("--check", action="store_true", help="validate the spec only")
    ap.add_argument("--no-repo-files", action="store_true", help="don't write regress/ lists and suite")
    ap.add_argument("--noc-model", choices=["behavioral", "mesh"],
                    help="override noc.model; mesh also renames the SoC <name>_mesh, so both benches "
                         "can sit side by side for a latency comparison")
    ap.add_argument("--no-direct", action="store_true",
                    help="CHI: turn DMT and DCT off and rename the SoC <name>_nodirect, for a latency "
                         "comparison against the same spec with them on")
    a = ap.parse_args()
    try:
        if a.noc_model or a.no_direct:
            import yaml
            with open(a.spec) as f:
                raw = yaml.safe_load(f)
            if a.noc_model and raw["noc"].get("model", "behavioral") != a.noc_model:
                raw["noc"]["model"] = a.noc_model
                if a.noc_model == "mesh":
                    raw["soc"]["name"] += "_mesh"
                    raw["soc"]["prefix"] = raw["soc"].get("prefix", raw["soc"]["name"][:-5]) + "_mesh"
            if a.no_direct:
                if not raw.get("chi"):
                    raise SpecError("--no-direct: the spec has no chi section")
                raw["chi"]["dmt"] = raw["chi"]["dct"] = False
                pre = raw["soc"].get("prefix", raw["soc"]["name"])
                raw["soc"]["name"] += "_nodirect"
                raw["soc"]["prefix"] = pre + "_nd"
            m = specmod.elaborate(raw, a.spec)
        else:
            m = specmod.load(a.spec)
        if a.check:
            print(f"{a.spec}: ok ({len(m.masters)} masters, {len(m.targets)} slave ports, "
                  f"{len(m.apb.slots) if m.apb else 0} APB slots, {len(m.scenarios)} scenarios)")
            return 0
        out = a.out or os.path.join(HERE, "out", m.name)
        files = generate(m, out, os.path.abspath(a.ip_root), a.spec, not a.no_repo_files,
                         os.path.abspath(a.vip_root))
    except SpecError as ex:
        print(f"socgen: {a.spec}: {ex}", file=sys.stderr)
        return 2
    print(f"socgen: {m.name}: {len(files)} files in {os.path.relpath(out, os.getcwd())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
