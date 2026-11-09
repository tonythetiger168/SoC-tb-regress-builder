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
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, "lib"))

import jinja2  # noqa: E402

import openip  # noqa: E402
import openvip  # noqa: E402
import spec as specmod  # noqa: E402
from spec import Obj, SpecError  # noqa: E402

AXI_SIGS = ["awid", "awaddr", "awlen", "awsize", "awburst", "awprot", "awvalid", "awready",
            "wdata", "wstrb", "wlast", "wvalid", "wready", "bid", "bresp", "bvalid", "bready",
            "arid", "araddr", "arlen", "arsize", "arburst", "arprot", "arvalid", "arready",
            "rid", "rdata", "rresp", "rlast", "rvalid", "rready"]
DDR4_IP_FILES = ["rtl/ddr4_jedec_ctrl.sv", "rtl/DDR4_JEDEC_AXI_top.sv", "tb/ddr4_phy_beh.sv", "tb/ddr4_dev_model.sv"]
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
    axi_slaves = [t for t in m.targets if t.kind in ("memory", "vip") or
                  (t.kind == "channel" and t.model == "vip")]
    dram_chans = [t for t in m.targets if t.kind == "channel" and t.model != "vip"]
    ctx = dict(m=m, M=M, spec_rel=spec_rel, apb_slot_bits=slot_bits, apb_nslots=nslots,
               slot_ids=slot_ids, iommu_of=[next((io.index for io in m.iommus if io.name == x.iommu), -1)
                                            for x in m.masters],
               unmapped=specmod.unmapped(m), ral_blocks=blocks, ip_commit=ip_commit,
               vip_slots=vip_slots, ext_slots=ext_slots, axi_slaves=axi_slaves, axi_sigs=AXI_SIGS,
               rtl_axi_sigs=[x for x in AXI_SIGS if not x.endswith("prot")],
               rtl_masters=[x for x in m.masters if x.kind == "rtl"],
               rtl_slaves=[t for t in m.slaves if t.kind == "rtl"], dram_chans=dram_chans,
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
    dram_files = []
    if dram_chans:
        # open-ip-portfolio DDR4_JEDEC_AXI controller, its behavioural PHY and
        # device model; the channel wrapper and CDC are this repo's
        for src in DDR4_IP_FILES:
            sp = os.path.join(ip_root, src)
            if not os.path.exists(sp):
                raise SpecError(f"memories[].model ddr4: {sp} not found (open-ip-portfolio with DDR4_JEDEC_AXI)")
            shutil.copy(sp, os.path.join(out, "rtl", "ip", os.path.basename(src)))
            ip_files.append(f"rtl/ip/{os.path.basename(src)}")
        dram_files = ["vip/dram/axi_async_bridge.sv", "vip/dram/soc_ddr4_chan.sv"]
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
    fl += COMMON[:1] + [f"{rel_out}/{f}" for f in ip_files] + dram_files + ext + \
        (dev_files if m.apb else []) + [f"{rel_out}/{f}" for f in rtl_files]
    fl = list(dict.fromkeys(fl))          # several RTL masters may share one filelist
    # PR #5's coverage/latency packages: axi4_pkg / apb_pkg import them where they exist
    common = [f for f in COMMON[1:] if f != "vip/mem/mem_vip_pkg.sv"]
    pre = [f for f in ("vip/common/fcov_pkg.sv", "vip/common/lat_pkg.sv") if os.path.exists(os.path.join(ROOT, f))]
    i = common.index("vip/axi4/axi4_pkg.sv")
    common[i:i] = pre + ["vip/mem/mem_vip_pkg.sv"]
    fl += common + [f"{rel_out}/tb/{m.name}_{x}.sv" for x in ("ral_pkg", "env_pkg", "test_pkg", "tb_top")]
    put("sim/files.f", "\n".join(fl) + "\n")
    put("socgen.mk", f"# generated by socgen from {spec_rel}\n"
                     f"TOP_{m.name} := {m.name}_tb_top\nFLIST_{m.name} := {rel_out}/sim/files.f\n")
    if m.sources:
        put("fetch_sources.sh", _fetch_script(m))
        os.chmod(os.path.join(out, "fetch_sources.sh"), 0o755)
    put(f"doc/{m.name}.md", _doc(m, spec_rel, slot_ids, ip_commit))
    put(f"doc/{m.name}_memmap.h", _header(m))
    put(f"doc/{m.name}_paths.csv", _paths_csv(m))

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
        p = os.path.join(ROOT, "regress", "suites", f"{m.name}.yaml")
        first = next(iter(m.lists))
        lists = "".join(f"  {'default' if ln == first else ln}: regress/{m.name}_{ln}.txt\n" for ln in m.lists)
        with open(p, "w") as f:
            f.write(f"# generated by socgen from {spec_rel}\n"
                    f"name: {m.name}\nlevel: soc\nsoc: {m.prefix}\n"
                    f"filelist: {rel_out}/sim/files.f\ntop: {m.name}_tb_top\n"
                    f"list:\n{lists}"
                    f"cov_include: ['{rel_out}/rtl/*']\n")
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
    L = [f"# {m.name}", "", f"Generated by socgen from `{spec_rel}`. {m.desc}", "",
         f"NoC: {m.noc.topology} {m.noc.cols}x{m.noc.rows}, XY routing, one way = "
         f"2*{m.noc.ni} + (hops+1)*{m.noc.router} + hops*{m.noc.link} cycles, clock {m.clock.period_ns} ns.", "",
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
    a = ap.parse_args()
    try:
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
