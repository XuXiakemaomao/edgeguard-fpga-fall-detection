"""Rebuild model/checkpoint.npz from the exported INT8 files.

The training run that produced the delivered weights wrote `model/checkpoint.npz`
in float form; if that file is lost the INT8 export is still the ground truth for
the FPGA.  This script dequantises the `.mem` files back into a checkpoint whose
re-export is bit-identical (the per-tensor scales are chosen so that the
round-trip `w -> round(w/s_w) -> w_q` is exact).

Usage: python scripts/restore_checkpoint.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from int_reference import load_model

ROOT = Path(__file__).resolve().parents[1]
W = ROOT / "weights"
MODEL = ROOT / "model"
S_IN = 255.0 / 256.0


def main() -> None:
    m = load_model()
    w = {k: m[k].astype(np.int64) for k in ("w1", "w2", "w3", "w4")}
    b = {k: m[k].astype(np.int64) for k in ("b1", "b2", "b3", "b4")}
    mult = m["mult"][:4]
    shift = m["shift"][:4]

    scales = {}
    s_in = S_IN
    for i, (wk, bk) in enumerate([("w1", "b1"), ("w2", "b2"), ("w3", "b3"), ("w4", "b4")]):
        # only r = M/2^S is observable from the INT8 export.  Normalise each
        # layer to s_out = 1.0, which fixes s_w = r * s_out / s_in; the round
        # trip is exact because max|w_q| == 127 makes s_w recoverable.
        r = float(mult[i]) / float(1 << int(shift[i]))
        s_w = r * 1.0 / s_in
        scales[f"w{wk[1:]}"] = (w[wk].astype(np.float32) * s_w,
                                b[bk].astype(np.float32) * (s_in * s_w))
        scales[f"s{i + 1}"] = 1.0
        s_in = 1.0

    out = {}
    for i in range(1, 5):
        out[f"w{i}"], out[f"b{i}"] = scales[f"w{i}"]
    out.update(s1=scales["s1"], s2=scales["s2"], s3=scales["s3"], s4=scales["s4"])
    np.savez(MODEL / "checkpoint.npz", **out)
    (MODEL / "checkpoint_restored.json").write_text(
        json.dumps({k: float(v) for k, v in out.items() if k.startswith("s")}, indent=2) + "\n")
    print("restored checkpoint from INT8 export; scales",
          [round(float(out[f"s{i}"]), 6) for i in range(1, 5)])


if __name__ == "__main__":
    main()
