"""Evaluate the exported INT8 model with the bit-exact integer reference.

The metrics are computed from `weights/*.mem` through `int_reference.py`, i.e.
the same arithmetic the RTL executes, so the reported accuracy is what the FPGA
will actually produce (not a float-model estimate).

Outputs:
    reports/test_metrics.json     accuracy / recall / precision / confusion,
                                  per-video table, acceptance flags
    reports/confusion_matrix.png  rendered confusion matrix
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from int_reference import CLASS_ORDER, infer, load_model

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "model"
REPORTS = ROOT / "reports"


def predict_all(model: dict, X: np.ndarray) -> np.ndarray:
    preds = np.empty(len(X), dtype=np.int64)
    for i in range(len(X)):
        preds[i] = int(infer(X[i], model)["pred"])
    return preds


def confusion(y: np.ndarray, p: np.ndarray, n: int = 3) -> np.ndarray:
    cm = np.zeros((n, n), dtype=np.int64)
    for t, q in zip(y, p):
        cm[int(t), int(q)] += 1
    return cm


def main() -> None:
    d = np.load(MODEL / "dataset.npz")
    X, y, splits, groups = d["X"], d["y"].astype(int), d["splits"], d["groups"]
    model = load_model()

    result = {}
    cms = {}
    for split in ("train", "val", "test"):
        sel = np.where(splits == split)[0]
        # the test split is what the reported metrics must describe; train is a
        # sanity check only (and is subsampled for speed)
        if split == "train" and len(sel) > 3000:
            sel = sel[:: max(1, len(sel) // 3000)]
        p = predict_all(model, X[sel])
        cm = confusion(y[sel], p)
        cms[split] = cm
        rec = [float(cm[c, c] / max(1, cm[c].sum())) for c in range(3)]
        prec = [float(cm[c, c] / max(1, cm[:, c].sum())) for c in range(3)]
        result[split] = {
            "n": int(len(sel)),
            "accuracy": float(np.trace(cm) / max(1, cm.sum())),
            "recall": dict(zip(CLASS_ORDER, rec)),
            "precision": dict(zip(CLASS_ORDER, prec)),
            "confusion": cm.tolist(),
            "macro_recall": float(np.mean(rec)),
            "per_class_n": {c: int(cm[i].sum()) for i, c in enumerate(CLASS_ORDER)},
        }
        print(split, {k: round(v, 4) for k, v in zip(CLASS_ORDER, rec)},
              "acc", round(result[split]["accuracy"], 4))

    # video-level behaviour on the held-out test clips: each clip must be
    # dominated by the right class (this is what the fall latch integrates)
    test_sel = np.where(splits == "test")[0]
    p_all = predict_all(model, X[test_sel])
    videos = {}
    for i, idx in enumerate(test_sel):
        g = str(groups[idx])
        key = (g, int(y[idx]))
        v = videos.setdefault(key, {"n": 0, "pred": np.zeros(3, dtype=np.int64)})
        v["n"] += 1
        v["pred"][int(p_all[i])] += 1
    vrows = []
    for (name, true_cls), v in sorted(videos.items()):
        frac = v["pred"] / max(1, v["n"])
        vrows.append({"video": name, "true_class": CLASS_ORDER[true_cls],
                      "n": int(v["n"]),
                      "pred_frac": {c: float(frac[i]) for i, c in enumerate(CLASS_ORDER)},
                      "dominant": CLASS_ORDER[int(np.argmax(v["pred"]))]})
    correct_clips = sum(1 for r in vrows if r["dominant"] == r["true_class"])
    result["test"]["video_level"] = {
        "clips": len(vrows),
        "clips_dominated_by_true_class": correct_clips,
        "clip_accuracy": float(correct_clips / max(1, len(vrows))),
        "table": vrows,
    }

    t = result["test"]
    result["acceptance"] = {
        "fall_recall_ge_0.90": t["recall"]["fall"] >= 0.90,
        "fall_precision_ge_0.85": t["precision"]["fall"] >= 0.85,
        "all_class_recall_nonzero": all(v > 0 for v in t["recall"].values()),
        "all_class_recall_ge_0.90": all(v >= 0.90 for v in t["recall"].values()),
        "thresholds": {"fall_recall": 0.90, "fall_precision": 0.85,
                       "each_recall": 0.90},
    }
    result["class_order"] = CLASS_ORDER
    result["evaluation"] = "integer reference (bit-exact with cnn_core.v)"
    REPORTS.mkdir(parents=True, exist_ok=True)
    (REPORTS / "test_metrics.json").write_text(json.dumps(result, indent=2) + "\n")

    # ---------------------------------------------------------------- confusion png
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cm = cms["test"]
    norm = cm / np.maximum(1, cm.sum(axis=1, keepdims=True))
    fig, ax = plt.subplots(figsize=(5.6, 4.8), dpi=140)
    im = ax.imshow(norm, cmap="Blues", vmin=0, vmax=1)
    ax.set_xticks(range(3)); ax.set_yticks(range(3))
    ax.set_xticklabels(CLASS_ORDER); ax.set_yticklabels(CLASS_ORDER)
    ax.set_xlabel("predicted"); ax.set_ylabel("true")
    ax.set_title("test confusion (row-normalised)")
    for i in range(3):
        for j in range(3):
            ax.text(j, i, f"{cm[i, j]}\n{norm[i, j]*100:.1f}%", ha="center", va="center",
                    color="white" if norm[i, j] > 0.55 else "black", fontsize=9)
    fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    fig.tight_layout()
    fig.savefig(REPORTS / "confusion_matrix.png")
    print("acceptance", json.dumps(result["acceptance"], indent=2))


if __name__ == "__main__":
    main()
