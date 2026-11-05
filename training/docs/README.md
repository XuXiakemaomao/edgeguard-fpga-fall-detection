# CNN 训练与量化材料（最终版）

## 模型

- 任务：48×48 灰度，3 类 `normal / fall / other`（0/1/2）；
- 训练：QAT（quantization-aware training），float32 主权重 + fake-quant 前向；
- checkpoint：`model/checkpoint.npz`（SHA256 `ed9d5ccd9a23f8f4618f9a9265b612ef6d54013450227d8c9e8f5ecf93202d2f`）；
- 导出：`weights/*.mem` + `manifest.json` + `SHA256SUMS.txt`。

## 数据

- `model/dataset.npz`：8985 个 48×48 灰度样本；
- train 6743 / val 1100 / test 1142；
- 按视频级划分，避免同视频跨 split 泄漏。

## 评估结果（INT8 整数参考，test 1142 样本）

| 指标 | 数值 |
|---|---:|
| accuracy | 0.8196 |
| fall recall | 0.9096 |
| fall precision | 0.7917 |
| FP32 accuracy（对照） | 0.8187 |
| FP32 fall recall（对照） | 0.9255 |
| FP32↔INT8 top-1 一致率 | 92.99% |

详细见 `量化精度与资源/quant_compare_report.md` 与
`reports/test_metrics.json`。

## 脚本

- `scripts/train_model.py`：QAT 训练；
- `scripts/evaluate_model.py`：用整数参考评估 train/val/test，输出
  `reports/test_metrics.json`、`reports/confusion_matrix.png`；
- `scripts/gen_model.py`：导出 `weights/*.mem`、`mult.mem`、`shift.mem`；
- `scripts/int_reference.py`：与 RTL 逐位一致的整数参考。

## Golden 用例

`golden/`：case0_normal / case1_fall / case2_other / sat_pos / sat_neg，
含 `f1/f2/f3/p1/p2/roi_q/gap/logits` 的 `.mem` 与 `golden_index.json`，
用于证明 RTL 与整数参考逐位一致。

## 重要说明

- `weights/` 是最终 INT8 导出，和 `checkpoint.npz` 的 SHA256 对齐；
- `cnn_subsystem/weights` 是另一版导出，不要混用；
- RTL 的 `$readmemh` 使用相对路径 `weights/...`，构建时 CWD 必须是 `project_code` 根目录；
- 上板/软件对比时，以 `量化精度与资源/quant_compare_report.md` 和
  `软件端与PL对比/software_report.md` 的数字为准。
