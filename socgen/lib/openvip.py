# SPDX-License-Identifier: Apache-2.0
"""Pin-level device models for peripherals (peripherals[].pins_vip).

open-vip-portfolio ships each device VIP as vips/<VIP>.zip (or an unpacked
vips/<VIP>/ directory). Its behavioural device model is a plain-port module
in tb/top_tb.sv (for example sdc_model in SD_Card-UVM-VIP). socgen cuts that
module out into out/rtl/vip/<model>.sv, reads its port list and wires it to
the IP's pins in the APB subsystem.

Inout pins: the IP drives its own side of the wire (assign p = oe ? o : 'z).
socgen resolves the model's side by port names:
  * <p>_s / <p>_s_oe outputs  -> assign p[i] = <p>_s_oe[i] ? <p>_s[i] : 1'bz
    <p>_m input <- the wire,   <p>_m_oe input <- '1 (the model then reads the
    resolved wire, which includes its own drive and the pull-up)
  * <p>_s_lo output (open drain) -> assign p[i] = <p>_s_lo[i] ? 1'b0 : 1'bz
    <p>_m_lo input <- ~wire
"""
import os
import re
import zipfile

from spec import Obj, SpecError


def _top_tb(vip_root, vip):
    d = os.path.join(vip_root, "vips", vip, "tb", "top_tb.sv")
    if os.path.exists(d):
        return open(d).read(), d
    z = os.path.join(vip_root, "vips", f"{vip}.zip")
    if os.path.exists(z):
        with zipfile.ZipFile(z) as f:
            name = next((n for n in f.namelist() if n.endswith(f"{vip}/tb/top_tb.sv")
                         or n == "tb/top_tb.sv"), None)
            if name:
                return f.read(name).decode(), f"{z}:{name}"
    raise SpecError(f"open-vip VIP {vip!r}: no vips/{vip}/tb/top_tb.sv or vips/{vip}.zip "
                    f"under {vip_root} (check --vip-root / OPEN_VIP_ROOT)")


def cut_module(src, model, where):
    m = re.search(rf"^module\s+{re.escape(model)}\b.*?^endmodule\b[^\n]*\n?", src, re.M | re.S)
    if not m:
        raise SpecError(f"{where}: module {model} not found")
    return m.group(0)


def model_source(vip_root, vip, model):
    src, where = _top_tb(vip_root, vip)
    return cut_module(src, model, where), where


def header(text, model):
    """(params {name: default}, ports [Obj(dir, name, width_expr)])"""
    m = re.search(rf"^module\s+{re.escape(model)}\s*(#\s*\((.*?)\))?\s*\((.*?)\);", text, re.M | re.S)
    if not m:
        raise SpecError(f"module {model}: header not found")
    params = {}
    for pm in re.finditer(r"parameter\s+(?:\w+\s+)*?(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^,\n)]+)", m.group(2) or ""):
        params[pm.group(1)] = pm.group(2).strip()
    ports = []
    for line in m.group(3).split(","):
        line = re.sub(r"//.*", "", line).strip()
        pm = re.match(r"(input|output|inout)\s+(?:wire|logic|tri|reg)?\s*(?:logic)?\s*(\[[^\]]+\])?\s*(\w+)$",
                      " ".join(line.split()))
        if pm:
            ports.append(Obj(dir=pm.group(1), name=pm.group(3), range=pm.group(2) or ""))
    return params, ports


def width(rng, params):
    if not rng:
        return 1
    m = re.fullmatch(r"\[(.+):(.+)\]", rng.replace(" ", ""))
    env = {}
    for k, v in params.items():
        try:
            env[k] = int(str(v).replace("_", ""), 0)
        except ValueError:
            pass
    try:
        return int(eval(m.group(1), {"__builtins__": {}}, env)) - int(eval(m.group(2), {"__builtins__": {}}, env)) + 1
    except Exception as ex:                                             # noqa: BLE001
        raise SpecError(f"can't size port range {rng}: {ex}")


def wire(s, pv, ports, mparams, ip_pins):
    """Connect model ports for APB slot s. Returns Obj(decl, inst_conns, assigns, ip_inputs)
    ip_inputs: IP input pin -> SV expression (model outputs that feed the IP)."""
    pins = {p.name: p for p in ip_pins}
    eff = {**mparams, **{k: str(v) for k, v in pv.params.items()}}
    byname = {p.name: p for p in ports}
    pre = f"{s.name}_vip"
    decl, conns, assigns, ip_in = [], {}, [], {}
    for k in pv.params:
        if k not in mparams:
            raise SpecError(f"peripheral {s.name}: {pv.model} has no parameter {k!r} (has {sorted(mparams)})")
    for k in pv.map:
        if k not in byname:
            raise SpecError(f"peripheral {s.name}.pins_vip.map: {pv.model} has no port {k!r}")

    def need(name, d):
        p = byname.get(name)
        if p is None or p.dir != d:
            return None
        return p

    for io in pv.inout:
        pin, port = io.pin, io.port
        ip = pins.get(pin)
        if ip is None or ip.dir != "inout":
            raise SpecError(f"peripheral {s.name}.pins_vip.inout: {s.ip}_apb has no inout pin {pin!r}")
        lo, hi = (0, ip.width - 1) if io.hi is None else (io.lo, io.hi)
        if hi >= ip.width:
            raise SpecError(f"peripheral {s.name}.pins_vip.inout: {pin}[{hi}] outside {pin}[{ip.width - 1}:0]")
        base = f"{s.name}_{pin}"
        net = base if io.hi is None else (f"{base}[{hi}:{lo}]" if hi != lo else f"{base}[{lo}]")
        so, soe, mi, moe = (need(f"{port}_s", "output"), need(f"{port}_s_oe", "output"),
                            need(f"{port}_m", "input"), need(f"{port}_m_oe", "input"))
        slo, mlo = need(f"{port}_s_lo", "output"), need(f"{port}_m_lo", "input")
        if so and soe:
            ow, oew = width(so.range, eff), width(soe.range, eff)
            decl.append(f"logic [{ow - 1}:0] {pre}_{so.name};")
            decl.append(f"logic [{oew - 1}:0] {pre}_{soe.name};")
            conns[so.name], conns[soe.name] = f"{pre}_{so.name}", f"{pre}_{soe.name}"
            for b in range(lo, hi + 1):
                k = b - lo
                assigns.append(f"assign {base}[{b}] = {pre}_{soe.name}[{k if oew > 1 else 0}] ? "
                               f"{pre}_{so.name}[{k if ow > 1 else 0}] : 1'bz;")
            if mi:
                conns[mi.name] = net
            if moe:
                conns[moe.name] = "'1"
        elif slo:
            sw = width(slo.range, eff)
            decl.append(f"logic [{sw - 1}:0] {pre}_{slo.name};")
            conns[slo.name] = f"{pre}_{slo.name}"
            for b in range(lo, hi + 1):
                assigns.append(f"assign {base}[{b}] = {pre}_{slo.name}[{b - lo if sw > 1 else 0}] ? 1'b0 : 1'bz;")
            if mlo:
                conns[mlo.name] = f"~{net}"
        else:
            raise SpecError(f"peripheral {s.name}: {pv.model} has neither {port}_s/{port}_s_oe nor "
                            f"{port}_s_lo for inout pin {pin!r} (set port: to the model's port prefix)")
    for p in ports:
        if p.name in conns and p.name not in pv.map:
            continue
        t = pv.map.get(p.name)
        if t is None:
            if p.name == pv.clock:
                t = "clk"
            elif p.name == pv.reset:
                t = "rst_n"
            elif p.name in pins and (p.dir == "input") == (pins[p.name].dir != "input"):
                t = p.name
        if p.dir == "input":
            if t is None:
                raise SpecError(f"peripheral {s.name}: {pv.model} input {p.name!r} is not connected "
                                f"(add it to pins_vip.map)")
            ip = pins.get(t) if isinstance(t, str) else None
            if ip is not None and ip.dir == "input":
                raise SpecError(f"peripheral {s.name}: {pv.model} input {p.name} mapped to {s.ip} input {t}")
            conns[p.name] = f"{s.name}_{t}" if ip is not None else str(t)
        else:
            w = width(p.range, eff)
            decl.append(f"logic [{w - 1}:0] {pre}_{p.name};")
            conns[p.name] = f"{pre}_{p.name}"
            if t is not None:
                ip = pins.get(t)
                if ip is None or ip.dir != "input":
                    raise SpecError(f"peripheral {s.name}: {pv.model} output {p.name} must map to an input "
                                    f"pin of {s.ip}_apb, not {t!r}")
                if t in s.pins:
                    raise SpecError(f"peripheral {s.name}: pin {t} is set in both pins and pins_vip.map")
                ip_in[t] = f"{pre}_{p.name}"
    order = [p.name for p in ports]
    return Obj(decl=decl, conns=[(k, conns[k]) for k in order if k in conns], assigns=assigns,
               ip_inputs=ip_in, model=pv.model, params=pv.params)
