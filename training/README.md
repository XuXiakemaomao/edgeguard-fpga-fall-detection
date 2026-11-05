# CNN 训练与量化材料

## 数据

- `model/dataset.npz`：8985 个 48×48 灰度样本，train 6743 / val 1100 / test 1142；
  类别 `normal / fall / other`（0/1/2）。
- `data_split.csv`：按视频级划分，避免同一视频跨 split 泄漏。

## 模型与训练

- `model/checkpoint.npz`：float32 主权重 + 每层 scale（本工程导出的源 checkpoint，
  SHA256 `ed9d5ccd9a23f8f4618f9a9265b612ef6d54013450227d8c9e8f5ecf93202d2f`）。
- `model/checkpoint_best.npz`：训练过程中 val macro 最好的快照。
- `scripts/train_model.py`：QAT 训练（fake-quant 前向，Adam，类别均衡采样）。
- `scripts/evaluate_model.py`：用整数参考评估 train/val/test，输出
  `reports/test_metrics.json` 与 `confusion_matrix.png`。
- `scripts/gen_model.py`：导出 `weights/*.mem`、`mult.mem`、`shift.mem`。
- `scripts/int_reference.py`：与 RTL 逐位一致的整数参考。

## 权重

`weights/`：`w1..w4`、`b1..b4`、`qin`、`mult`、`shift` 的 `.mem`，
`manifest.json` 记录 SHA256 与层参数，`SHA256SUMS.txt` 为校验清单。

> 注意：`cnn_subsystem/weights` 与 `final_test/ablation_code/weights` 是两版不同导出。
> 只有后者与 `checkpoint.npz` 的 SHA256 对齐；做量化对比时用 `weights/`（本目录）。

## Golden 用例

`golden/`：case0_normal / case1_fall / case2_other / sat_pos / sat_neg，
含 `f1/f2/f3/p1/p2/roi_q/gap/logits` 的 `.mem` 与 `golden_index.json`，
用于证明 RTL 与整数参考逐位一致。

## 关键指标（test，1142 样本）

- INT8 accuracy 0.8196，fall recall 0.9096，fall precision 0.7917；
- FP32 accuracy 0.8187，fall recall 0.9255，fall precision 0.7945；
- FP32↔INT8 top-1 一致率 92.99%。

详细见 `量化精度与资源/quant_compare_report.md` 与
`reports/test_metrics.json`。
