"""Build the normal/fall/other ROI dataset from URFD.

The FPGA pipeline this file emulates is fixed:

    gray_360p (320x240 RGB view, Y=(77R+150G+29B)>>8)
      -> motion / ROI box (x0,y0,x1,y1)
      -> nearest-neighbour inverse mapping to 48x48
      -> q_in = clamp(round((g-127.5)*256/255))          [int8]

Source material: the distributed URFD mp4 files are 640x240 composites of two
320x240 views (left = depth/IR, right = RGB).  Only the RGB half is used, at its
native 4:3 geometry, so the crops match the board camera domain.

Tracker emulation is causal and label-free: per-pixel temporal-median background,
blurred absolute difference, 3x3 opening + 7x7 closing, largest connected
component, then a padded bounding box with a short hold while a fallen person is
still.  This is the same class of box the v4.4 motion/ROI chain produces.

Class definition (fixed order, matches weights/manifest.json):

    0 normal  person clearly upright and not low in the frame
    1 fall    URFD pose label says fallen AND the box is actually on the ground
              (clearly wider than tall, or low and squat)
    2 other   background-only patches and targets partially out of frame;
              frames whose pose is ambiguous are dropped, never guessed

Outputs:
    cnn_subsystem/data_split.csv        video-level split (no frame leakage)
    cnn_subsystem/model/dataset.npz     X uint8 [N,48,48], y int8, meta
    cnn_subsystem/reports/dataset_stats.json
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
URFD = ROOT / "datasets" / "URFD"
OUT = Path(__file__).resolve().parents[1]
MODEL_DIR = OUT / "model"

R = 48
GAIN = 43691          # 2**22 / 96 rounded, same constant as cnn_roi_crop.v
MOTION_THR = 20
MOVE_THR = 5
HOLD_FRAMES = 15
MIN_AREA = 250
EDGE_MIN = 10.0
SRC_W, SRC_H = 320, 240      # RGB half of the 640x240 composite
SEED = 20261031

CLASS_ORDER = ["normal", "fall", "other"]


def gray_of(rgb: np.ndarray) -> np.ndarray:
    """Exact copy of v4.4 rgb2gray.v: Y = (77R + 150G + 29B) >> 8."""
    r = rgb[:, :, 0].astype(np.int32)
    g = rgb[:, :, 1].astype(np.int32)
    b = rgb[:, :, 2].astype(np.int32)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def bbox_48(gray: np.ndarray, x0: int, y0: int, x1: int, y1: int) -> np.ndarray:
    """Nearest-neighbour resample of a box, bit-identical to cnn_roi_crop.v."""
    h, w = gray.shape
    x0 = max(0, min(w - 1, int(x0)))
    y0 = max(0, min(h - 1, int(y0)))
    x1 = max(x0, min(w - 1, int(x1)))
    y1 = max(y0, min(h - 1, int(y1)))
    src_w = x1 - x0 + 1
    src_h = y1 - y0 + 1
    dy = np.arange(R, dtype=np.int64)
    dx = np.arange(R, dtype=np.int64)
    sy = y0 + (((2 * dy + 1) * src_h * GAIN) >> 22)
    sx = x0 + (((2 * dx + 1) * src_w * GAIN) >> 22)
    return gray[sy[:, None], sx[None, :]]


def motion_box(gray: np.ndarray, bg: np.ndarray, pad: float = 0.10,
               prev: np.ndarray | None = None):
    """Largest blob that both differs from the background and recently moved.

    The temporal gate removes static structure the median background disagrees
    with (open doors, lighting steps), which otherwise wins the largest
    connected component contest on some clips.
    """
    f = ndimage.uniform_filter(gray.astype(np.float32), 5)
    b = ndimage.uniform_filter(bg, 5)
    mask = np.abs(f - b) > MOTION_THR
    if prev is not None:
        d = np.abs(gray.astype(np.int16) - prev.astype(np.int16)).astype(np.float32)
        mask &= ndimage.uniform_filter(d, 5) > MOVE_THR
    mask = ndimage.binary_opening(mask, structure=np.ones((3, 3), bool))
    mask = ndimage.binary_closing(mask, structure=np.ones((7, 7), bool))
    lab, n = ndimage.label(mask)
    if n == 0:
        return None
    sizes = ndimage.sum(mask, lab, range(1, n + 1))
    idx = int(np.argmax(sizes)) + 1
    if sizes[idx - 1] < MIN_AREA:
        return None
    ys, xs = np.where(lab == idx)
    x0, x1 = int(xs.min()), int(xs.max())
    y0, y1 = int(ys.min()), int(ys.max())
    bw = x1 - x0 + 1
    bh = y1 - y0 + 1
    # reject blobs that cannot be a person: too small, or covering a large part
    # of the frame
    if bw * bh < 500 or bh < 20:
        return None
    pw = max(5, int(round(bw * pad)))
    ph = max(5, int(round(bh * pad)))
    h, w = gray.shape
    x0 = max(0, x0 - pw); x1 = min(w - 1, x1 + pw)
    y0 = max(0, y0 - ph); y1 = min(h - 1, y1 + ph)
    if (x1 - x0 + 1) < 12 or (y1 - y0 + 1) < 12:
        return None
    return x0, y0, x1, y1


def load_pose(path: Path) -> dict[str, dict[int, int]]:
    seqs: dict[str, dict[int, int]] = {}
    with path.open() as fh:
        for row in csv.reader(fh):
            if len(row) < 3:
                continue
            seqs.setdefault(row[0], {})[int(row[1])] = int(row[2])
    return seqs


def split_for(prefix: str, index: int) -> str:
    if prefix == "fall":
        return "train" if index <= 20 else ("val" if index <= 25 else "test")
    return "train" if index <= 28 else ("val" if index <= 34 else "test")


def decode_gray(path: Path) -> list[np.ndarray]:
    import imageio.v3 as iio
    out = []
    for rgb in iio.imiter(str(path), plugin="FFMPEG"):
        g = gray_of(rgb)
        if g.shape[1] >= 2 * SRC_W:
            g = g[:, SRC_W:]          # right half = RGB view
        if g.shape != (SRC_H, SRC_W):
            g = np.asarray(Image.fromarray(g).resize((SRC_W, SRC_H), Image.BILINEAR))
        out.append(g)
    return out


def boxes_for_clip(gray_frames: list[np.ndarray]):
    if not gray_frames:
        return []
    sub = gray_frames[::3]
    bg = np.median(np.stack(sub), axis=0).astype(np.float32)
    boxes = []
    last = None
    hold = 0
    for ti, g in enumerate(gray_frames):
        pad = 0.04 + ((ti * 2654435761) % 1000) / 1000.0 * 0.11
        prev = gray_frames[ti - 2] if ti >= 2 else None
        box = motion_box(g, bg, pad, prev)
        if box is None and last is not None and hold < HOLD_FRAMES:
            box = last
            hold += 1
        elif box is not None:
            last = box
            hold = 0
        boxes.append(box)
    return boxes


def add_other_for_frame(store: dict, key, g: np.ndarray, box, rng) -> None:
    """Background-only patch or a partially visible target."""
    x0, y0, x1, y1 = box
    h, w = g.shape
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    split, group, idx = key
    if rng.random() < 0.6:
        for _ in range(8):
            px0 = int(rng.integers(0, w - 24))
            py0 = int(rng.integers(0, h - 24))
            pw = int(rng.integers(16, 90))
            ph = int(rng.integers(16, 90))
            px1 = min(w - 1, px0 + pw)
            py1 = min(h - 1, py0 + ph)
            if px1 < x0 - 8 or px0 > x1 + 8 or py1 < y0 - 8 or py0 > y1 + 8:
                store["other"].append((bbox_48(g, px0, py0, px1, py1), split, group, idx))
                return
    else:
        dx = int(rng.integers(-int(bw * 1.1), int(bw * 1.1) + 1))
        dy = int(rng.integers(-int(bh * 1.1), int(bh * 1.1) + 1))
        store["other"].append((bbox_48(g, x0 + dx, y0 + dy, x1 + dx, y1 + dy),
                               split, group, idx))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(MODEL_DIR / "dataset.npz"))
    args = ap.parse_args()
    rng = np.random.default_rng(SEED)
    store: dict[str, list] = {c: [] for c in CLASS_ORDER}
    rows: list[dict] = []

    falls = load_pose(URFD / "urfall-cam0-falls.csv")
    adls = load_pose(URFD / "urfall-cam0-adls.csv")

    seqs = [(f"fall-{i:02d}", "fall", falls) for i in range(1, 31)]
    seqs += [(f"adl-{i:02d}", "normal", adls) for i in range(1, 41)]

    for seq, kind, pose in seqs:
        prefix, index = seq.split("-")[0], int(seq.split("-")[1])
        split = split_for(prefix, index)
        name = f"{seq}-cam0.mp4"
        gray = decode_gray(URFD / name)
        boxes = boxes_for_clip(gray)
        n_norm = n_fall = n_other = 0
        for t, (g, box) in enumerate(zip(gray, boxes)):
            if box is None:
                continue
            x0, y0, x1, y1 = box
            bw, bh = x1 - x0 + 1, y1 - y0 + 1
            aspect = bw / max(1, bh)
            bottom = y1 / float(g.shape[0] - 1)
            on_ground = (aspect >= 1.10) or (bottom >= 0.85 and aspect >= 0.80)
            upright = (aspect <= 1.05) and (bottom < 0.92)
            img = bbox_48(g, *box)
            # a usable ROI must contain structure: flat crops are tracker
            # failures (empty wall / bed) and must not teach the classifier
            gx = np.abs(np.diff(img.astype(np.int16), axis=1)).mean()
            gy = np.abs(np.diff(img.astype(np.int16), axis=0)).mean()
            if (gx + gy) < EDGE_MIN:
                continue
            if kind == "fall":
                p = pose.get(seq, {}).get(t + 1, -1)
                if p in (0, 1) and on_ground:
                    store["fall"].append((img, split, name, t)); n_fall += 1
                elif p == -1 and upright:
                    store["normal"].append((img, split, name, t)); n_norm += 1
            elif upright:
                store["normal"].append((img, split, name, t)); n_norm += 1
            if ((t * 2654435761) % 10) < 5:
                add_other_for_frame(store, (split, name, t), g, box, rng)
                n_other += 1
        rows.append({"file": name, "split": split,
                     "class": "fall" if kind == "fall" else "normal",
                     "source": "URFD", "frames": len(gray),
                     "crops": f"{n_norm}n/{n_fall}f/{n_other}o"})
        print(f"  {name} [{split}] norm={n_norm} fall={n_fall} other={n_other}", flush=True)

    split_rows = sorted(rows, key=lambda r: (r["split"], r["class"], r["file"]))
    data_split = OUT / "data_split.csv"
    with data_split.open("w", newline="", encoding="utf-8") as fh:
        wr = csv.DictWriter(fh, fieldnames=["split", "class", "source", "file", "frames", "crops"])
        wr.writeheader()
        wr.writerows(split_rows)

    xs, ys, groups, splits = [], [], [], []
    for cls, items in store.items():
        for img, split, group, idx in items:
            xs.append(img); ys.append(CLASS_ORDER.index(cls))
            groups.append(group); splits.append(split)
    X = np.stack(xs).astype(np.uint8)
    y = np.asarray(ys, dtype=np.int8)
    groups = np.asarray(groups); splits = np.asarray(splits)

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.out, X=X, y=y, groups=groups, splits=splits,
                        class_order=np.asarray(CLASS_ORDER))
    stats = {}
    for split in ("train", "val", "test"):
        sel = splits == split
        stats[split] = {
            "total": int(sel.sum()),
            "per_class": {c: int(((y == i) & sel).sum()) for i, c in enumerate(CLASS_ORDER)},
            "videos": int(len(set(groups[sel]))),
        }
    stats["files"] = {"dataset": str(args.out), "split_csv": str(data_split)}
    (OUT / "reports" / "dataset_stats.json").write_text(json.dumps(stats, indent=2) + "\n")
    print(json.dumps(stats, indent=2))


if __name__ == "__main__":
    main()
