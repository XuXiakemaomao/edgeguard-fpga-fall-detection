"""Quantisation-aware training for the 48x48 three-class fall classifier.

The network shape is frozen by `cnn_core.v`:

    Conv(1->8,3x3,SAME) -> ReLU -> MaxPool2 -> Conv(8->16,3x3,SAME) -> ReLU
    -> MaxPool2 -> Conv(16->32,3x3,SAME) -> ReLU -> GAP(12x12) -> FC(32->3)

Training runs in float32 on top of a fake-quantisation forward pass that mirrors
the RTL integer pipeline: per-tensor symmetric int8 weights, int8 activations
quantised with a per-layer output scale, ReLU saturated to [0,127], max pooling,
GAP computed as round(sum/144) in int8, FC requantised to int8.

Optimiser: Adam.  The loss is class-balanced cross entropy; batches are drawn
with balanced class sampling so the small `fall` class is not swamped.

Outputs (all under cnn_subsystem/model/):
    checkpoint.npz        float32 weights + per-layer scales
    train_history.json    per-epoch loss / val recall
"""
from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "model"
CLASS_ORDER = ["normal", "fall", "other"]
S_IN = 255.0 / 256.0          # q_in dequantisation scale (fixed by qin.mem)


# --------------------------------------------------------------------------- data
def qin_table() -> np.ndarray:
    out = np.zeros(256, dtype=np.int64)
    for g in range(256):
        n = 256 * g - 32640
        q = (abs(n) + 127) // 255
        out[g] = q if n >= 0 else -q
    return np.clip(out, -128, 127)


QIN = qin_table().astype(np.float32)


def augment(x: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """x: uint8 [B,48,48].  Geometric + photometric jitter, all label preserving."""
    b = x.shape[0]
    out = x.astype(np.float32)

    flip = rng.random(b) < 0.5
    out[flip] = out[flip][:, :, ::-1]

    contrast = rng.uniform(0.7, 1.4, size=(b, 1, 1)).astype(np.float32)
    gamma = rng.uniform(0.75, 1.3, size=(b, 1, 1)).astype(np.float32)
    bright = rng.uniform(-22, 22, size=(b, 1, 1)).astype(np.float32)
    out = np.clip(out, 0, 255) / 255.0
    out = np.power(out, gamma) * 255.0
    out = (out - 127.5) * contrast + 127.5 + bright
    out += rng.normal(0.0, 4.0, size=out.shape).astype(np.float32)
    out = np.clip(out, 0, 255)

    # vectorised nearest-neighbour translate + zoom
    base = np.arange(48, dtype=np.float32) - 23.5
    s = rng.uniform(0.88, 1.12, size=b)
    tx = rng.uniform(-2.5, 2.5, size=b)
    ty = rng.uniform(-2.5, 2.5, size=b)
    idx = base[None, :] / s[:, None] + 23.5
    ix = np.clip(np.rint(idx - tx[:, None]).astype(np.int64), 0, 47)
    iy = np.clip(np.rint(idx - ty[:, None]).astype(np.int64), 0, 47)
    rows = out[np.arange(b)[:, None], iy]
    out = np.take_along_axis(rows, ix[:, None, :], axis=2)
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


def to_qin(x_u8: np.ndarray) -> np.ndarray:
    return QIN[x_u8][:, None, :, :]


# --------------------------------------------------------------------------- ops
def conv_forward(x: np.ndarray, w: np.ndarray, b: np.ndarray):
    n, h, wd, c = x.shape
    oc = w.shape[0]
    xp = np.pad(x, ((0, 0), (1, 1), (1, 1), (0, 0)))
    cols = np.lib.stride_tricks.sliding_window_view(xp, (3, 3), axis=(1, 2))
    col2 = cols.reshape(n * h * wd, c * 9)
    y = col2 @ w.reshape(oc, c * 9).T + b
    return y.reshape(n, h, wd, oc), (cols, xp.shape)


def conv_backward(dy: np.ndarray, cache, w: np.ndarray):
    cols, xp_shape = cache
    n, h, wd, c = cols.shape[0], cols.shape[1], cols.shape[2], cols.shape[3]
    oc = w.shape[0]
    d2 = dy.reshape(n * h * wd, oc)
    col2 = cols.reshape(n * h * wd, c * 9)
    dw = (d2.T @ col2).reshape(w.shape)
    dcols = (d2 @ w.reshape(oc, c * 9)).reshape(n, h, wd, c, 3, 3)
    dxp = np.zeros(xp_shape, dtype=np.float32)
    for kh in range(3):
        for kw in range(3):
            dxp[:, kh:kh + h, kw:kw + wd, :] += dcols[:, :, :, :, kh, kw]
    dx = dxp[:, 1:-1, 1:-1, :]
    db = d2.sum(axis=0)
    return dx, dw, db


def pool_forward(x: np.ndarray):
    n, h, w, c = x.shape
    r = x.reshape(n, h // 2, 2, w // 2, 2, c)
    return r.max(axis=(2, 4)), r


def pool_backward(dy: np.ndarray, r: np.ndarray):
    n, c = r.shape[0], r.shape[5]
    h, w = r.shape[1] * 2, r.shape[3] * 2
    mask = (r == r.max(axis=(2, 4), keepdims=True))
    cnt = mask.sum(axis=(2, 4), keepdims=True)
    dr = mask * (dy[:, :, None, :, None, :] / cnt)
    return dr.reshape(n, h, w, c)


def requant_q(y: np.ndarray, s: float) -> np.ndarray:
    return np.clip(np.rint(y / s), -128, 127)


def quantize_w(w: np.ndarray) -> tuple[np.ndarray, float]:
    sw = max(float(np.max(np.abs(w))) / 127.0, 1e-8)
    return np.clip(np.rint(w / sw), -127, 127), sw


# --------------------------------------------------------------------------- net
class Net:
    def __init__(self, rng: np.random.Generator):
        def he(shape, fan_in):
            return (rng.standard_normal(shape) * math.sqrt(2.0 / fan_in)).astype(np.float32)
        self.w1 = he((8, 1, 3, 3), 9)
        self.b1 = np.zeros(8, np.float32)
        self.w2 = he((16, 8, 3, 3), 72)
        self.b2 = np.zeros(16, np.float32)
        self.w3 = he((32, 16, 3, 3), 144)
        self.b3 = np.zeros(32, np.float32)
        self.w4 = (rng.standard_normal((3, 32)) * math.sqrt(2.0 / 32)).astype(np.float32)
        self.b4 = np.zeros(3, np.float32)
        self.s1 = 1.0
        self.s2 = 1.0
        self.s3 = 1.0
        self.s4 = 0.06
        self.params = ["w1", "b1", "w2", "b2", "w3", "b3", "w4", "b4"]
        self.m = {p: np.zeros_like(getattr(self, p)) for p in self.params}
        self.v = {p: np.zeros_like(getattr(self, p)) for p in self.params}

    def forward(self, x_q: np.ndarray, quant: bool = True):
        """x_q [N,1,48,48] holds q_in * S_IN (dequantised float)."""
        x = x_q.transpose(0, 2, 3, 1)
        if quant:
            w1q, sw1 = quantize_w(self.w1); w2q, sw2 = quantize_w(self.w2)
            w3q, sw3 = quantize_w(self.w3); w4q, sw4 = quantize_w(self.w4)
            w1, w2, w3, w4 = w1q * sw1, w2q * sw2, w3q * sw3, w4q * sw4
        else:
            w1, w2, w3, w4 = self.w1, self.w2, self.w3, self.w4

        y1, c1 = conv_forward(x, w1, self.b1)
        q1 = np.maximum(requant_q(y1, self.s1) if quant else y1, 0).astype(np.float32)
        p1, pc1 = pool_forward(q1)
        a1 = p1 * self.s1 if quant else p1

        y2, c2 = conv_forward(a1, w2, self.b2)
        q2 = np.maximum(requant_q(y2, self.s2) if quant else y2, 0).astype(np.float32)
        p2, pc2 = pool_forward(q2)
        a2 = p2 * self.s2 if quant else p2

        y3, c3 = conv_forward(a2, w3, self.b3)
        q3 = np.maximum(requant_q(y3, self.s3) if quant else y3, 0).astype(np.float32)
        gap_q = (np.clip(np.rint(q3.sum(axis=(1, 2)) / 144.0), -128, 127) if quant
                 else q3.sum(axis=(1, 2)) / 144.0).astype(np.float32)
        a3 = gap_q * self.s3 if quant else gap_q

        y4 = a3 @ w4.T + self.b4
        logits = requant_q(y4, self.s4) if quant else y4
        return dict(logits=logits, cache=(c1, c2, c3, pc1, pc2),
                    w1=w1, w2=w2, w3=w3, w4=w4, q1=q1, q2=q2, q3=q3, a3=a3)

    def backward(self, dlogits: np.ndarray, fw: dict):
        c1, c2, c3, pc1, pc2 = fw["cache"]
        q1, q2, q3 = fw["q1"], fw["q2"], fw["q3"]
        w1, w2, w3, w4 = fw["w1"], fw["w2"], fw["w3"], fw["w4"]
        g = {}

        dy4 = dlogits / self.s4
        g["w4"] = dy4.T @ fw["a3"]
        g["b4"] = dy4.sum(axis=0)
        dgap = (dy4 @ w4) * self.s3
        dq3 = (dgap / 144.0)[:, None, None, :].repeat(12, 1).repeat(12, 2) * (q3 > 0)
        dy3 = dq3 / self.s3
        da2, g["w3"], g["b3"] = conv_backward(dy3, c3, w3)

        dp2 = da2 * self.s2
        dq2 = pool_backward(dp2, pc2) * (q2 > 0)
        dy2 = dq2 / self.s2
        da1, g["w2"], g["b2"] = conv_backward(dy2, c2, w2)

        dp1 = da1 * self.s1
        dq1 = pool_backward(dp1, pc1) * (q1 > 0)
        dy1 = dq1 / self.s1
        _, g["w1"], g["b1"] = conv_backward(dy1, c1, w1)
        return g

    def step(self, grads: dict, lr: float, t: int, b1=0.9, b2=0.999, eps=1e-8):
        for p in self.params:
            g = grads[p]
            self.m[p] = b1 * self.m[p] + (1 - b1) * g
            self.v[p] = b2 * self.v[p] + (1 - b2) * (g * g)
            mh = self.m[p] / (1 - b1 ** t)
            vh = self.v[p] / (1 - b2 ** t)
            getattr(self, p)[...] -= lr * mh / (np.sqrt(vh) + eps)

    def save(self, path: Path):
        np.savez(path, w1=self.w1, b1=self.b1, w2=self.w2, b2=self.b2,
                 w3=self.w3, b3=self.b3, w4=self.w4, b4=self.b4,
                 s1=self.s1, s2=self.s2, s3=self.s3, s4=self.s4)

    def state(self) -> dict:
        st = {p: getattr(self, p).copy() for p in self.params}
        st.update(s1=self.s1, s2=self.s2, s3=self.s3, s4=self.s4)
        return st

    def load_state(self, st: dict):
        for p in self.params:
            setattr(self, p, st[p].copy())
        self.s1, self.s2, self.s3, self.s4 = st["s1"], st["s2"], st["s3"], st["s4"]


def softmax_ce(logits, y):
    z = logits - logits.max(axis=1, keepdims=True)
    p = np.exp(z) / np.exp(z).sum(axis=1, keepdims=True)
    n = len(y)
    loss = -np.log(np.clip(p[np.arange(n), y], 1e-9, None)).mean()
    dl = p.copy()
    dl[np.arange(n), y] -= 1.0
    return loss, dl / n


def metrics(pred, y, n_cls=3):
    cm = np.zeros((n_cls, n_cls), dtype=np.int64)
    for t, p in zip(y, pred):
        cm[int(t), int(p)] += 1
    rec = [float(cm[c, c] / max(1, cm[c].sum())) for c in range(n_cls)]
    prec = [float(cm[c, c] / max(1, cm[:, c].sum())) for c in range(n_cls)]
    return cm, rec, prec


def calibrate(net: Net, X: np.ndarray, q=99.8, chunk=200) -> None:
    """Sequential activation calibration, mirroring the deployed forward pass.

    For each layer the scale is derived from the *raw* activation quantile, then
    the activation is quantised with that scale before feeding the next layer,
    exactly like the RTL pipeline.  One sequential pass therefore fixes all
    four scales without iterating.
    """
    y1s, y2s, y3s, y4s = [], [], [], []
    for i in range(0, len(X), chunk):
        x = to_qin(X[i:i + chunk]) * S_IN
        xa = x.transpose(0, 2, 3, 1)
        y1, _ = conv_forward(xa, net.w1, net.b1)
        s1 = max(float(np.percentile(np.maximum(y1, 0), q) / 127.0), 1e-3)
        q1 = np.maximum(np.clip(np.rint(y1 / s1), -128, 127), 0)
        p1, _ = pool_forward(q1)
        y2, _ = conv_forward(p1 * s1, net.w2, net.b2)
        s2 = max(float(np.percentile(np.maximum(y2, 0), q) / 127.0), 1e-3)
        q2 = np.maximum(np.clip(np.rint(y2 / s2), -128, 127), 0)
        p2, _ = pool_forward(q2)
        y3, _ = conv_forward(p2 * s2, net.w3, net.b3)
        s3 = max(float(np.percentile(np.maximum(y3, 0), q) / 127.0), 1e-3)
        q3 = np.maximum(np.clip(np.rint(y3 / s3), -128, 127), 0)
        gap = np.clip(np.rint(q3.sum(axis=(1, 2)) / 144.0), -128, 127)
        y4 = (gap * s3) @ net.w4.T + net.b4
        y1s.append(np.maximum(y1, 0).reshape(-1))
        y2s.append(np.maximum(y2, 0).reshape(-1))
        y3s.append(np.maximum(y3, 0).reshape(-1))
        y4s.append(y4.reshape(-1))
    # the scales are recomputed from the pooled raw values in a second sweep so
    # every layer uses the same batch statistics
    net.s1 = max(float(np.percentile(np.concatenate(y1s), q) / 127.0), 1e-3)
    net.s2 = max(float(np.percentile(np.concatenate(y2s), q) / 127.0), 1e-3)
    net.s3 = max(float(np.percentile(np.concatenate(y3s), q) / 127.0), 1e-3)
    net.s4 = max(float(np.percentile(np.abs(np.concatenate(y4s)), 99.5) / 127.0), 1e-3)


def evaluate(net: Net, X: np.ndarray, y: np.ndarray) -> tuple:
    preds = []
    for i in range(0, len(y), 256):
        preds.append(net.forward(to_qin(X[i:i + 256]) * S_IN)["logits"].argmax(axis=1))
    return metrics(np.concatenate(preds), y)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=50)
    ap.add_argument("--warmup", type=int, default=4)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--data", default=str(MODEL / "dataset.npz"))
    ap.add_argument("--seed", type=int, default=20261031)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    d = np.load(args.data)
    X, y, splits = d["X"], d["y"].astype(np.int64), d["splits"]
    tr, va = splits == "train", splits == "val"
    print("train", int(tr.sum()), "val", int(va.sum()),
          "counts", np.bincount(y[tr], minlength=3), flush=True)

    net = Net(rng)
    calibrate(net, X[tr][:2000])
    print("init scales %.4f %.4f %.4f %.5f" % (net.s1, net.s2, net.s3, net.s4), flush=True)

    Xtr, ytr = X[tr], y[tr]
    Xva, yva = X[va], y[va]
    cls_idx = [np.where(ytr == c)[0] for c in range(3)]
    hist, t, best, best_state = [], 0, -1.0, None
    for ep in range(args.epochs):
        if ep == args.warmup:
            calibrate(net, Xtr[:3000])
            print("recalibrated %.4f %.4f %.4f %.5f" % (net.s1, net.s2, net.s3, net.s4))
        order = []
        per = args.batch // 3
        for _ in range(len(ytr) // args.batch):
            for c in range(3):
                order.append(rng.choice(cls_idx[c], size=per, replace=len(cls_idx[c]) < per))
        order = np.concatenate(order)
        rng.shuffle(order)
        lr = args.lr * 0.5 * (1 + math.cos(math.pi * ep / max(1, args.epochs - 1)))
        tot, nb = 0.0, 0
        for i in range(0, len(order) - args.batch + 1, args.batch):
            idx = order[i:i + args.batch]
            xq = to_qin(augment(Xtr[idx], rng)) * S_IN
            fw = net.forward(xq, quant=True)
            loss, dl = softmax_ce(fw["logits"], ytr[idx])
            grads = net.backward(dl, fw)
            t += 1
            net.step(grads, lr, t)
            tot += loss
            nb += 1
        cm, rec, prec = evaluate(net, Xva, yva)
        macro = float(np.mean(rec))
        hist.append({"epoch": ep, "loss": float(tot / max(1, nb)),
                     "val_recall": [float(r) for r in rec],
                     "val_macro": float(macro)})
        flag = ""
        if macro > best:
            best, best_state = macro, net.state()
            store = net.state()
            np.savez(MODEL / "checkpoint_best.npz",
                     **{k: v for k, v in store.items()},
                     epoch=ep, val_macro=macro)
            flag = " *"
        msg = (f"ep {ep:3d} loss {tot/max(1,nb):.4f} rec "
               f"{['%.3f' % r for r in rec]} macro {macro:.4f}{flag}")
        print(msg, flush=True)
        with (ROOT / "reports" / "train_progress.log").open("a") as fh:
            fh.write(msg + "\n")
        (MODEL / "train_history.json").write_text(json.dumps(hist, indent=2) + "\n")

    net.load_state(best_state)
    MODEL.mkdir(parents=True, exist_ok=True)
    net.save(MODEL / "checkpoint.npz")
    (MODEL / "train_history.json").write_text(json.dumps(hist, indent=2) + "\n")
    print("best val macro", best, "scales %.5f %.5f %.5f %.5f"
          % (net.s1, net.s2, net.s3, net.s4))


if __name__ == "__main__":
    main()
