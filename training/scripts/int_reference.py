"""Integer-only reference for the cnn_subsystem classifier.

Every arithmetic step matches the RTL bit-for-bit:
  q_in        : 256-entry lookup table (weights/qin.mem)
  conv3x3     : int8 x int8 -> int32 accumulate + int32 bias
  requant     : acc * M (int16), round-half-away-from-zero, >> S, clamp [-128,127]
  relu        : clamp to [0,127]
  maxpool     : 2x2 max
  gap         : floor((sum * 116508 + 2^23) / 2^24), clamp
  fc          : int8 x int8 -> int32 + bias -> requant -> int8
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
W = ROOT / "weights"

CLASS_ORDER = ["normal", "fall", "other"]


def _read_hex(path: Path, width: int) -> np.ndarray:
    vals = []
    for line in path.read_text().split():
        v = int(line, 16)
        if v >= 1 << (width - 1):
            v -= 1 << width
        vals.append(v)
    return np.array(vals, dtype=np.int64)


def load_model() -> dict:
    return {
        "qin": _read_hex(W / "qin.mem", 8),
        "w1": _read_hex(W / "w1.mem", 8).reshape(8, 1, 9),
        "b1": _read_hex(W / "b1.mem", 32),
        "w2": _read_hex(W / "w2.mem", 8).reshape(16, 8, 9),
        "b2": _read_hex(W / "b2.mem", 32),
        "w3": _read_hex(W / "w3.mem", 8).reshape(32, 16, 9),
        "b3": _read_hex(W / "b3.mem", 32),
        "w4": _read_hex(W / "w4.mem", 8).reshape(3, 32),
        "b4": _read_hex(W / "b4.mem", 32),
        "mult": _read_hex(W / "mult.mem", 16),
        "shift": _read_hex(W / "shift.mem", 8),
    }


def requant(acc: np.ndarray, mult: int, shift: int) -> np.ndarray:
    p = acc.astype(np.int64) * np.int64(mult)
    half = np.int64(1 << (shift - 1))
    q = np.where(p >= 0, (p + half) >> shift, -(((-p) + half) >> shift))
    return np.clip(q, -128, 127).astype(np.int64)


def conv3x3(x: np.ndarray, w: np.ndarray, b: np.ndarray, mult: int, shift: int) -> np.ndarray:
    oc, ic, _ = w.shape
    h, wd = x.shape[0], x.shape[1]
    xp = np.zeros((h + 2, wd + 2, ic), dtype=np.int64)
    xp[1:-1, 1:-1, :] = x
    acc = np.zeros((h, wd, oc), dtype=np.int64)
    for kh in range(3):
        for kw in range(3):
            patch = xp[kh:kh + h, kw:kw + wd, :]          # h,w,ic
            wk = w[:, :, kh * 3 + kw]                      # oc,ic
            acc += patch @ wk.T
    acc += b.reshape(1, 1, oc)
    return requant(acc, mult, shift)


def relu_q(x: np.ndarray) -> np.ndarray:
    return np.clip(x, 0, 127).astype(np.int64)


def maxpool2(x: np.ndarray) -> np.ndarray:
    h, w, c = x.shape
    return x.reshape(h // 2, 2, w // 2, 2, c).max(axis=(1, 3))


def gap_q(x: np.ndarray) -> np.ndarray:
    s = x.reshape(-1, x.shape[-1]).sum(axis=0).astype(np.int64)
    q = (s * 116508 + (1 << 23)) >> 24
    return np.clip(q, -128, 127).astype(np.int64)


def infer(roi_u8: np.ndarray, m: dict, dump: bool = False) -> dict:
    x = m["qin"][np.asarray(roi_u8, dtype=np.int64)][:, :, None]   # 48x48x1 int8
    a1 = relu_q(conv3x3(x, m["w1"], m["b1"], m["mult"][0], m["shift"][0]))
    p1 = maxpool2(a1)
    a2 = relu_q(conv3x3(p1, m["w2"], m["b2"], m["mult"][1], m["shift"][1]))
    p2 = maxpool2(a2)
    a3 = relu_q(conv3x3(p2, m["w3"], m["b3"], m["mult"][2], m["shift"][2]))
    g = gap_q(a3)
    logits = requant(g @ m["w4"].T + m["b4"], m["mult"][3], m["shift"][3])
    out = {"logits": logits.astype(np.int64), "pred": int(np.argmax(logits))}
    if dump:
        out.update({"f1": a1.transpose(2,0,1), "f2": a2.transpose(2,0,1), "f3": a3.transpose(2,0,1), "gap": g, "p1": p1.transpose(2,0,1), "p2": p2.transpose(2,0,1)})
    return out


def write_hex(path: Path, values: np.ndarray, width: int) -> None:
    mask = (1 << width) - 1
    lines = [f"{int(v) & mask:0{width // 4}x}" for v in np.asarray(values).reshape(-1)]
    path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    model = load_model()
    info = json.loads((W / "manifest.json").read_text())
    sample = np.zeros((48, 48), dtype=np.uint8)
    sample[8:40, 20:28] = 200
    r = infer(sample, model, dump=True)
    print("logits", r["logits"], "pred", r["pred"], CLASS_ORDER[info["class_order"]] if False else "")
    print("manifest classes:", info["class_order"])
