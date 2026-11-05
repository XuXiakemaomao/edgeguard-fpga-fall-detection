# 量化规格与权重导出（v1.0）

本文件与 `weights/manifest.json`、`scripts/gen_model.py`、`scripts/int_reference.py`、`rtl/qparams.vh` 共同构成数值合同。RTL、整数 Python reference、导出脚本三者必须同时满足本文件。

## 1. 类别顺序（强绑定）

```
class_order = ["normal", "fall", "other"]
编码：0 = normal, 1 = fall, 2 = other
```

UART 第 4 byte 的 logits、`pred`、README、显示缩写都使用这一顺序。禁止依赖目录名字符串排序。

## 2. 处理链

```
gray ROI 48x48 (uint8)
  -> q_in LUT (int8)
  -> Conv3x3(1->8)   + bias(int32) + requant + ReLU
  -> MaxPool 2x2
  -> Conv3x3(8->16)  + bias + requant + ReLU
  -> MaxPool 2x2
  -> Conv3x3(16->32) + bias + requant + ReLU
  -> GAP(1x1) 整数均值
  -> FC(32->3) + bias + requant -> int8 logits
```

## 3. 输入量化

`q_in = clamp(round((g - 127.5) * 256 / 255), -128, 127)`

- 由 `weights/qin.mem` 的 256 项 LUT 实现（RTL 中为 `qin_rom`），crop 在写 ROI 前查表。
- 与 `g ^ 8'h80` 的区别：后者是 `g-128`，缺少 255/256 的尺度修正和 0.5 LSB 偏移；本工程使用精确 LUT，Python/RTL 完全一致。

## 4. 每层量化参数

| 层 | s_in | s_w | s_out | M (int16) | S |
|---|---|---|---|---|---|
| Conv1 | 1/128 | 1/512 | 1/512 | 16384 | 21 |
| Conv2 | 1/512 | 1/512 | 1/1024 | 16384 | 22 |
| Conv3 | 1/1024 | 1/512 | 1/2048 | 16384 | 22 |
| FC | 1/2048 | 1/512 | 1/4096 | 16384 | 22 |

说明：本工程当前使用**结构化黄金权重**（固定种子生成，非训练语义模型），因此上表是"自洽即可"的量化参数；接真实 checkpoint 时必须由校准重新生成，并保持同样的导出格式与公式。

M/S 的唯一来源是 `scripts/gen_model.py`：它同时写出 `weights/mult.mem`、`weights/shift.mem` 与 `rtl/qparams.vh`（`M_L1..M_FC`、`QS_L1..QS_FC` 的 localparam）。`cnn_core.v` 通过 `` `include "rtl/qparams.vh" `` 使用这些常量，避免 4 项小 ROM 在 Vivado 中被误判为普通线网。

## 5. 重量化（requant）

```
p = acc * M              // acc:int32, M:int16 -> 64bit
q = round_half_away(p / 2^S)
  = (p >= 0) ? ((p + 2^(S-1)) >>> S)
             : -(((-p) + 2^(S-1)) >>> S)
q = clamp(q, -128, 127)
```

- `S >= 1`，本工程 21/22。
- 饱和在 requant 之后；Conv 输出再做 ReLU：`relu_q = (q < 0) ? 0 : q`。
- MaxPool 取四个 int8 的最大值，不改变 signed 表示。

## 6. GAP

144 个 int8 求和（非负，因为前面有 ReLU）：

```
gap = clamp((sum * 116508 + 2^23) >>> 24, -128, 127)
```

即 `floor(sum/144 + 0.5)` 的定点近似，误差 < 1 LSB，Python/RTL 使用同一公式。

## 7. FC

```
acc = b4[oc] + sum_k w4[oc][k] * gap[k]
logit = requant(acc, M_FC, QS_FC)
```

## 8. 权重布局

```
Conv: idx = (oc*IC + ic)*9 + (kh*3 + kw)     // OC 外层，IC 次层，kernel 行优先
FC  : idx = oc*32 + k
```

`.mem` 文件为每行一个十六进制数（补码）：

| 文件 | 深度 | 位宽 | 说明 |
|---|---|---|---|
| qin.mem | 256 | 8 | 输入 LUT |
| w1.mem | 72 | 8 | Conv1 权重 |
| w2.mem | 1152 | 8 | Conv2 权重 |
| w3.mem | 4608 | 8 | Conv3 权重 |
| w4.mem | 96 | 8 | FC 权重 |
| b1/b2/b3/b4 | 8/16/32/3 | 32 | INT32 bias |
| mult.mem | 32 | 32 | 前 4 项有效，其余补 0（Vivado ROM 兼容） |
| shift.mem | 32 | 32 | 前 4 项有效，其余补 0 |

加载校验：`manifest.json` 记录每个文件的 SHA256 与长度；RTL 侧以 `$readmemh` 读取权重与 bias，`qparams.vh` 提供 M/S；仿真 TB 在文件缺失或数值不一致时失败。

## 9. 与 PyTorch 的关系

- PyTorch 权重布局为 `[OC, IC, KH, KW]`，导出时必须按 §8 显式转换，不能只改文件名。
- 浮点 PyTorch logits 只用于评估量化误差；**RTL 对齐只认本文件的整数 reference**。
- 结构化黄金权重的 SHA256 与生成种子（20261030）见 `weights/SHA256SUMS.txt` 与 `manifest.json`。
