"""Run every example and check the profile is consistent with the latency model."""
import json
import os
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLES = sorted(f for f in os.listdir(os.path.join(ROOT, "examples")) if f.endswith((".yaml", ".json")))


def run(cfg, out):
    subprocess.run([sys.executable, os.path.join(ROOT, "nocgen.py"), os.path.join(ROOT, "examples", cfg),
                    "-o", str(out)], check=True, capture_output=True)
    with open(os.path.join(out, "profile", "profile.json")) as f:
        return json.load(f)


@pytest.mark.parametrize("cfg", EXAMPLES)
def test_profile_consistent(cfg, tmp_path):
    p = run(cfg, tmp_path)
    lat = {(x["master"], x["slave"]): x["min_read"] for x in p["pairs"]}
    t = p["timing"]
    for x in p["pairs"]:
        for h, c in ((x["hops_req"], x["req"]), (x["hops_rsp"], x["rsp"])):
            assert c == t["ni_cycles"] + (h + 1) * t["router_cycles"] + h * t["link_cycles"]
    # Optimised result is never worse than the baseline.
    before, after = p["stages"]["before"]["avg"], p["stages"]["after"]["avg"]
    assert before is None or after <= before + 1e-9
    assert after >= p["floor"] - 1e-9
    # Regions fit their memory, don't overlap, and each caller uses its nearest copy.
    size = {a["slave"]: a for a in p["address_map"]}
    spans = []
    for r in p["regions"]:
        for c in r["copies"]:
            s = size[c["slave"]]
            assert s["base"] <= c["base"] and c["base"] + r["size"] <= s["base"] + s["size"]
            spans.append((c["base"], c["base"] + r["size"]))
        for m, v in r["callers"].items():
            assert v["min_read"] == min(lat[m, c["slave"]] for c in r["copies"])
    spans.sort()
    assert all(b0 >= a1 for (_, a1), (b0, _) in zip(spans, spans[1:]))
    for f in ("noc_params_pkg.sv", "axi_if.sv", "noc_tb_pkg.sv", "noc_mesh_stub.sv", "tb_top.sv", "files.f"):
        assert (tmp_path / "tb" / f).exists()


def test_regions_beat_placement_only(tmp_path):
    p = run("mesh4x4_regions.yaml", tmp_path)
    assert p["stages"]["after"]["avg"] < p["stages"]["placement"]["avg"] < p["stages"]["before"]["avg"]
