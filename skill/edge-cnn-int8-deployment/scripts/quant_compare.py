#!/usr/bin/env python3
"""FP32 vs INT8 quantization-accuracy comparison (no board needed).

Data / models
-------------
cnn_subsystem/model/checkpoint.npz  float32 master weights + per-layer scales
cnn_subsystem/model/dataset.npz     X (uint8 48x48), y, splits, groups
cnn_subsystem/scripts/int_reference  bit-exact INT8 reference (same math as RTL)

For each split we run:
  FP32 : Net.forward(to_qin(X) * S_IN, quant=False)   (pure float)
  INT8 : int_reference.infer(X[i])                    (what the FPGA computes)

and report accuracy / per-class recall+precision / macro recall / top-1
agreement / logit MAE (INT8 dequantised with s4 vs FP32).

This satisfies the "量化精度与资源" evidence item: it shows what the INT8
quantization costs relative to the trained FP32 network, on the same test split.
The RTL is bit-exact with the INT8 reference (golden cases in sim/golden).
"""
import argparse
import sys
from pathlib import Path

import numpy as np

CLASS_ORDER = ["normal", "fall", "other"]


def metrics(y, p, n=3):
    cm = np.zeros((n, n), dtype=np.int64)
    for t, q in zip(y, p):
        cm[int(t), int(q)] += 1
    rec = [cm[c, c] / max(1, cm[c].sum()) for c in range(n)]
    prec = [cm[c, c] / max(1, cm[:, c].sum()) for c in range(n)]
    return {
        "n": int(cm.sum()),
        "acc": float(np.trace(cm) / max(1, cm.sum())),
        "recall": rec,
        "precision": prec,
        "macro_recall": float(np.mean(rec)),
        "confusion": cm,
    }


def predict_float(net, tm, X, batch=128):
    out = []
    for i in range(0, len(X), batch):
        xq = tm.to_qin(X[i:i + batch]) * tm.S_IN
        out.append(net.forward(xq, quant=False)["logits"])
    return np.concatenate(out, axis=0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cnn-root", default=r"C:/Users/Xdoor/Desktop/fpga/cnn/cnn_subsystem")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "quant_compare_report.md"))
    ap.add_argument("--splits", default="test,val")
    ap.add_argument("--max-samples", type=int, default=0,
                    help="limit samples per split (0 = all); for quick smoke tests")
    args = ap.parse_args()

    cnn = Path(args.cnn_root)
    here = Path(__file__).resolve().parent
    sys.path.insert(0, str(cnn / "scripts"))
    sys.path.insert(0, str(here))
    import train_model as tm
    # 用本目录的 cnn_int_reference（权重指向 final_test/ablation_code/weights，
    # 与 checkpoint.npz 的 SHA256 对齐）；cnn_subsystem/weights 是另一版导出。
    import cnn_int_reference as iref

    d = np.load(cnn / "model" / "dataset.npz")
    X, y, splits = d["X"], d["y"].astype(int), d["splits"]
    ck = np.load(cnn / "model" / "checkpoint.npz")

    net = tm.Net(np.random.default_rng(0))
    net.load_state({k: ck[k] for k in ck.files})
    model = iref.load_model()
    s4 = float(net.s4)

    lines = [
        "# 量化精度对比（FP32 vs INT8 整数参考）",
        "",
        f"权重：`{cnn / 'model' / 'checkpoint.npz'}`",
        f"数据：`{cnn / 'model' / 'dataset.npz'}`",
        f"INT8 参考：`cnn_int_reference.py`（读 `ablation_code/weights/`，与 RTL 逐位一致）；"
        f"FC 输出反量化尺度 s4={s4:.6f}",
        "",
        "| split | model | n | accuracy | fall recall | fall precision | macro recall | top-1 agreement | logit MAE |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]

    for split in [s.strip() for s in args.splits.split(",") if s.strip()]:
        sel = np.where(splits == split)[0]
        if args.max_samples:
            sel = sel[:args.max_samples]
        if len(sel) == 0:
            continue
        Xs, ys = X[sel], y[sel]

        lf = predict_float(net, tm, Xs)
        ai = np.empty(len(Xs), dtype=np.int64)
        li = np.empty((len(Xs), 3), dtype=np.int64)
        for i in range(len(Xs)):
            r = iref.infer(Xs[i], model)
            ai[i] = int(r["pred"])
            li[i] = np.asarray(r["logits"], dtype=np.int64)
        af = lf.argmax(axis=1)

        mf = metrics(ys, af)
        mi = metrics(ys, ai)
        agree = float(np.mean(af == ai))
        mae = float(np.mean(np.abs(lf - li * s4)))

        for name, m in (("FP32", mf), ("INT8", mi)):
            lines.append(
                f"| {split} | {name} | {m['n']} | {m['acc']:.4f} | "
                f"{m['recall'][1]:.4f} | {m['precision'][1]:.4f} | "
                f"{m['macro_recall']:.4f} | "
                f"{agree:.4f} | {mae:.4f} |")
        lines.append("")
        lines.append(f"### {split} 混淆矩阵（行=真实，列=预测）")
        lines.append("")
        lines.append("| model | normal | fall | other |")
        lines.append("|---|---:|---:|---:|")
        for name, m in (("FP32", mf), ("INT8", mi)):
            cm = m["confusion"]
            lines.append(f"| {name} | {cm[0,0]} / {cm[0,1]} / {cm[0,2]} | "
                         f"{cm[1,0]} / {cm[1,1]} / {cm[1,2]} | "
                         f"{cm[2,0]} / {cm[2,1]} / {cm[2,2]} |")
        lines.append("")

    lines += [
        "说明：",
        "- FP32 是训练得到的 float32 主权重直接前向；INT8 是导出权重经整数管线（与 FPGA 完全一致）。",
        "- `top-1 agreement` = 同一测试样本 FP32 与 INT8 预测类别一致比例。",
        "- `logit MAE` = |FP32 logit - INT8 logit×s4| 的均值（量化引起的 logit 偏差）。",
        "- 资源行（BRAM/DSP/LUT/权重位宽）来自 `资源利用情况/` 的 post-route 报告，与精度表并列写入报告即可。",
    ]
    out = Path(args.out)
    out.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
