#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""IPCAM real-IP unit bench: run the c1p HEVC / JPEG encoders and the xuanji NPU
through their AXI wrappers (tb/ipcam_ip) and check the results.

For each vector: ffmpeg makes an NV12 frame, the bench encodes it (JPEG and
HEVC, separately, then all three IPs at once with slower memory), and the
outputs must be byte-identical to the c1p Python reference models and decode
with ffmpeg. The NPU test moves random lines DRAM -> L2 -> DRAM.

Usage:  make build TB=ipcam_ip && python3 scripts/ipcam_ip_check.py [--out DIR] [--save-vectors]
--save-vectors copies each frame and its reference streams to regress/vectors/ipcam
(used by the regress/suites/ipcam_media.yaml suite).
Needs ext/ from scripts/fetch_ext_ip.sh and ffmpeg.
"""
import argparse
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(REPO, "build/verilator/ipcam_ip/obj/Vipcam_ip_tb_top")
MODELS = os.path.join(REPO, "ext/c1p-codec/c1p/scripts")

# name, lavfi source, width, height, qp
VECTORS = [
    ("t2_64x48", "testsrc2", 64, 48, 30),
    ("mb_176x144", "mandelbrot", 176, 144, 26),
    ("bars_96x64", "smptebars", 96, 64, 34),
]


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def sim(test, log, args):
    r = subprocess.run([EXE, f"+UVM_TESTNAME={test}"] + args, capture_output=True, text=True, timeout=3600)
    with open(log, "w") as f:
        f.write(r.stdout + r.stderr)
    ok = "SB_PASS" in r.stdout and "UVM_ERROR :    0" in r.stdout and "UVM_FATAL :    0" in r.stdout
    return ok, r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "regress_out/ipcam_ip"))
    ap.add_argument("--save-vectors", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if not os.path.exists(EXE):
        sys.exit("build first: make build TB=ipcam_ip")
    sys.path.insert(0, MODELS)
    import c1p_hve_model as H  # noqa: E402
    from c1p_jpe_model import QL, QC  # noqa: E402
    ql, qc = os.path.join(a.out, "ql"), os.path.join(a.out, "qc")
    open(ql, "w").write(" ".join(map(str, QL)))
    open(qc, "w").write(" ".join(map(str, QC)))

    fails, rows = 0, []
    for name, src, w, h, qp in VECTORS:
        p = os.path.join(a.out, name)
        yuv = p + ".yuv"
        sh(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"{src}=size={w}x{h}",
            "-frames", "1", "-pix_fmt", "nv12", "-f", "rawvideo", yuv])
        lv = H.pick_level((w + 15) // 16 * 16, (h + 15) // 16 * 16)
        sh([sys.executable, os.path.join(MODELS, "c1p_jpe_model.py"), "enc", yuv, "nv12", str(w), str(h),
            "file:" + ql, "file:" + qc, "0", p + ".ref.jpg"])
        sh([sys.executable, os.path.join(MODELS, "c1p_hve_model.py"), "enc", yuv, str(w), str(h), p + ".ref.265",
            "--qp", str(qp), "--slice-rows", "0", "--nal", "19", "--poc", "0", "--level", str(lv),
            "--mask", "0x%x" % H.DEF_MASK])
        if a.save_vectors:
            vd = os.path.join(REPO, "regress/vectors/ipcam")
            os.makedirs(vd, exist_ok=True)
            for ext in (".yuv", ".ref.jpg", ".ref.265"):
                shutil.copy(p + ext, os.path.join(vd, name + ext))
        common = [f"+in={yuv}", f"+jpg_ref={p}.ref.jpg", f"+hevc_ref={p}.ref.265", f"+w={w}", f"+h={h}", f"+qp={qp}", f"+level={lv}"]
        runs = [
            ("jpeg", "ipcam_ip_jpeg_test", [f"+jpg_out={p}.jpeg.jpg"], [(p + ".jpeg.jpg", p + ".ref.jpg")]),
            ("venc", "ipcam_ip_venc_test", [f"+hevc_out={p}.venc.265"], [(p + ".venc.265", p + ".ref.265")]),
            ("all", "ipcam_ip_all_test", [f"+jpg_out={p}.all.jpg", f"+hevc_out={p}.all.265", "+IP_LAT=60", "+IP_BP=4"],
             [(p + ".all.jpg", p + ".ref.jpg"), (p + ".all.265", p + ".ref.265")]),
        ]
        for tag, test, extra, cmps in runs:
            ok, _ = sim(test, f"{p}.{tag}.log", common + extra)
            notes = []
            if not ok:
                notes.append("sim")
            for got, ref in cmps:
                if not os.path.exists(got) or open(got, "rb").read() != open(ref, "rb").read():
                    notes.append("mismatch " + os.path.basename(got))
                elif subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", got, "-f", "null", "-"],
                                    capture_output=True).returncode != 0:
                    notes.append("ffmpeg cannot decode " + os.path.basename(got))
            status = "PASS" if not notes else "FAIL"
            fails += bool(notes)
            rows.append((name, tag, status, ", ".join(notes) or "bit-exact vs c1p model, decodes"))
    ok, _ = sim("ipcam_ip_npu_test", os.path.join(a.out, "npu.log"), ["+npu_rounds=4", "+npu_lines=32"])
    fails += not ok
    rows.append(("random lines", "npu", "PASS" if ok else "FAIL", "DMA_LD/ST 4 x 32 lines, data and completions"))

    with open(os.path.join(a.out, "summary.md"), "w") as f:
        f.write("| vector | test | result | notes |\n|---|---|---|---|\n")
        for r in rows:
            f.write("| %s | %s | %s | %s |\n" % r)
    for r in rows:
        print("%-5s %-14s %-5s %s" % (r[2], r[0], r[1], r[3]))
    print(f"{len(rows) - fails}/{len(rows)} passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
