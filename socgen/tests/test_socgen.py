# SPDX-License-Identifier: Apache-2.0
"""socgen checks that need no simulator: python3 -m unittest discover -s socgen/tests"""
import copy
import os
import re
import sys
import tempfile
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
SOCGEN = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SOCGEN, "lib"))
sys.path.insert(0, SOCGEN)

import spec  # noqa: E402
from spec import SpecError  # noqa: E402

IP_ROOT = os.environ.get("OPEN_IP_ROOT", os.path.join(SOCGEN, "..", "..", "open-ip-portfolio"))
HAVE_IP = os.path.exists(os.path.join(IP_ROOT, "docs", "ip", "GPIO.md"))


def raw(name):
    with open(os.path.join(SOCGEN, "specs", name)) as f:
        return yaml.safe_load(f)


class PhoneSpec(unittest.TestCase):
    """The phone instance must keep the names and map the phone TB uses."""

    @classmethod
    def setUpClass(cls):
        cls.m = spec.load(os.path.join(SOCGEN, "specs", "phone_soc.yaml"))

    def test_counts(self):
        m = self.m
        self.assertEqual(len(m.masters), 15)
        self.assertEqual(m.nch, 32)
        self.assertEqual(len(m.targets), 34)
        names = [t.name for t in m.targets]
        self.assertEqual(names.index("boot_sram"), 32)
        self.assertEqual(names.index("periph"), 33)
        self.assertEqual(len(m.iommus), 6)

    def test_hash_matches_phone_tb(self):
        mem = self.m.memories[0]
        for a in range(0x8000_0000, 0x8100_0000, 0x1000 * 7 + 0x40):
            ch = ((a >> 12) & 31) ^ ((a >> 17) & 31)
            self.assertEqual(spec.chan_of(mem, a), ch, hex(a))
            self.assertEqual(spec.decode(self.m, a), ch)
            off = a - mem.base
            self.assertEqual(spec.local_of(mem, a), (((off >> 17) << 12) | (off & 0xFFF)))

    def test_placement(self):
        t = self.m.targets
        for c in range(16):
            self.assertEqual(t[c].node, (c // 4, 0))
            self.assertEqual(t[16 + c].node, (c // 4, 3))

    def test_apb_slots(self):
        slots = {s.name: s.slot for s in self.m.apb.slots}
        self.assertEqual(slots["gpio"], 0)
        self.assertEqual(slots["apb_ext"], 2)
        self.assertEqual(slots["trng"], 6)
        self.assertEqual([slots[f"{io.name}_regs"] for io in self.m.iommus], list(range(7, 13)))

    def test_latency(self):
        cpu = self.m.masters[0]
        # CPU (1,1) -> lpddr0 (0,0): 2 hops, one way 2*1 + 3*1 + 2*1 = 7
        self.assertEqual(cpu.hops[0], 2)
        self.assertEqual(cpu.req[0], 7)
        self.assertEqual(cpu.ideal[0], 7 + 24 + 7)
        apu = next(x for x in self.m.masters if x.name == "apu")
        self.assertEqual(apu.req[0] - apu.rsp[0], 2)    # IOMMU TLB hit

    def test_path_addrs_decode(self):
        for x in self.m.masters:
            for t, a in zip(self.m.targets, x.path_addr):
                self.assertEqual(spec.decode(self.m, a), t.index, f"{x.name} -> {t.name}")


class Validation(unittest.TestCase):
    def bad(self, mutate, msg):
        r = raw("mini_soc.yaml")
        mutate(r)
        with self.assertRaisesRegex(SpecError, msg):
            spec.elaborate(r)

    def test_mini_ok(self):
        m = spec.elaborate(raw("mini_soc.yaml"))
        self.assertEqual(len(m.scenarios), 2)

    def test_unknown_key(self):
        self.bad(lambda r: r["masters"][0].update(nod=[0, 0]), "unknown key")

    def test_overlap(self):
        self.bad(lambda r: r["slaves"][0].update(base=0x8000_0000), "overlap")

    def test_granule(self):
        self.bad(lambda r: r["memories"][0]["interleave"].update(granule=0x800), "granule")

    def test_slot_clash(self):
        self.bad(lambda r: r["slaves"][1]["peripherals"][1].update(slot=0), "already used")

    def test_region_overlap(self):
        def f(r):
            r["traffic"]["dma"]["region"] = {"offset": "0x600_0000", "size": "0x8000"}
            r["traffic"]["dma"]["targets"] = ["ddr"]
        self.bad(f, "overlap")

    def test_clock(self):
        self.bad(lambda r: r["clock"].update(period_ns=1.0), "2 ns")

    def test_scenario_unknown_master(self):
        self.bad(lambda r: r["scenarios"]["blit"]["masters"].update(gpu="dma"), "not a master")

    def test_block2d_needs_stride(self):
        self.bad(lambda r: r["traffic"]["blk"].pop("stride"), "block2d")

    def test_fixed_beats(self):
        r = raw("mini_soc.yaml")
        r["traffic"]["dma"]["beats"] = 47
        self.assertEqual(spec.elaborate(r).masters[2].traffic.beats, (47, 47))

    def test_32_slots(self):
        r = raw("mini_soc.yaml")
        r["slaves"][1]["size"] = 0x2_0000
        r["slaves"][1]["peripherals"][2]["slot"] = 31
        m = spec.elaborate(r)
        self.assertEqual(m.apb.slots[-1].slot, 31)

    def test_crossbar(self):
        r = raw("mini_soc.yaml")
        r["noc"] = {"topology": "crossbar", "timing": {"ni_cycles": 1, "router_cycles": 1, "link_cycles": 1}}
        for x in r["masters"] + r["slaves"]:
            x.pop("node", None)
        r["memories"][0].pop("placement")
        m = spec.elaborate(r)
        self.assertTrue(all(h == 0 for x in m.masters for h in x.hops))


@unittest.skipUnless(HAVE_IP, "open-ip-portfolio checkout not found (set OPEN_IP_ROOT)")
class Generate(unittest.TestCase):
    def test_openip_registers(self):
        import openip
        r = openip.registers(IP_ROOT, "GPIO")
        self.assertEqual(r.id, 0x4750_0200)
        self.assertEqual([x.offset for x in r.regs][:5], [0, 4, 8, 12, 16])

    def test_generate_phone(self):
        import socgen
        m = spec.load(os.path.join(SOCGEN, "specs", "phone_soc.yaml"))
        with tempfile.TemporaryDirectory() as d:
            socgen.generate(m, d, IP_ROOT, os.path.join(SOCGEN, "specs", "phone_soc.yaml"), False)
            pkg = open(os.path.join(d, "rtl", "phone_soc_pkg.sv")).read()
            for want in ("localparam int NM  = 15", "localparam int NS  = 34", "localparam int S_APB = 33",
                         "localparam int M_CPU = 0", "function automatic int phone_decode",
                         "function automatic int dram_channel", "function automatic int noc_lat",
                         "function automatic int iommu_of"):
                self.assertIn(want, pkg)
            ral = open(os.path.join(d, "tb", "phone_soc_ral_pkg.sv")).read()
            self.assertIn("map.add_submap(iommu_disp_regs.default_map, 'h1000C000)", ral)
            self.assertEqual(len(re.findall(r"add_submap", ral)), 12)    # 13 slots minus the APB VIP


if __name__ == "__main__":
    unittest.main()
