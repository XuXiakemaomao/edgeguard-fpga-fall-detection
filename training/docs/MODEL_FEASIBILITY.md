# 模型可行性判断（G3）

日期：2026-10-30
结论先行：**`py_cnn_v1` 当前 checkpoint 不可部署**，本阶段交付的是"数值通路 + 调度 + 协议"全部可验证的 FPGA 子系统，分类语义等待真实 `normal/fall/other` checkpoint。

## 1. 现状证据

| 项 | 实测 | 位置 |
|---|---|---|
| 类别 | animal / car / person | `py_cnn_v1/outputs/test_metrics.json` |
| 测试集 | 42 张（每类 14） | 同上 |
| Accuracy | 0.3333 | 同上 |
| 混淆矩阵 | `[[0,14,0],[0,12,2],[0,12,2]]` | 同上 |
| 每类 recall | animal 0 / car 0.857 / person 0.143 | 同上 |
| 网络 | Conv8-Pool-Conv16-Pool-Conv32-GAP32-FC3 | `src/model.py` |
| 量化 | 仅 Linear 动态量化 | `src/quantize.py` |
| 导出 | 仅 weight scale + 浮点 bias | `fpga_weights/manifest.json` |

判读：模型把所有输入几乎都判成 car，等价于退化模型；即使 RTL 完全正确，也只是稳定输出错误类别。且当前导出缺 INT32 bias、input/output scale、zero-point、mult/shift 和 RTL 权重布局，不能驱动本子系统。

## 2. 为什么不能"改个名字"部署

1. 类别语义错误：animal/car/person ≠ normal/fall/other。
2. 结构不同：`v4.1_cnn` 是 128 维 GAP + 3×128 FC；当前 Python 是 32 维 GAP + 3×32 FC。
3. 量化不完整：Conv 未做静态 PTQ/QAT，bias 仍是浮点。
4. 布局不同：PyTorch `[OC,IC,KH,KW]` 与 RTL 索引顺序不一致，直接换文件会转置错。

## 3. 本阶段采用的替代方案（合同允许）

按任务书"只负责 FPGA"分支执行：

- 使用**固定种子的结构化黄金权重**（`scripts/gen_model.py`，seed=20261030）驱动 RTL；
- 整数 Python reference 与 RTL 逐层 bit-exact（`docs/RTL_PY_ALIGNMENT.md`）；
- 所有仿真、时序、资源结论只证明"数值通路/调度/协议正确"，**不证明分类语义**；
- `sim/golden` 与 `weights/manifest.json` 明确标注 `checkpoint_sha256 = N/A-structural-golden`。

## 4. 接真实 checkpoint 的最小改动集

1. 训练 `normal/fall/other`（或四类），视频级切分，test acc ≥ 90%、fall recall ≥ 90%、fall precision ≥ 85%，每类 recall 非零。
2. 静态 PTQ 或 QAT，按 `docs/QUANT_SPEC.md` 的格式导出：
   - 每层 `s_in / s_w / s_out / zp`、`M / S`；
   - INT32 bias；
   - 权重按 §8 布局转换；
   - `manifest.json` 增加 `class_order`、checkpoint SHA256、每文件 SHA256 与长度。
3. 保持网络结构不变（Conv8-Pool-Conv16-Pool-Conv32-GAP-FC32→3），否则必须同步改 RTL 的循环边界与地址。
4. 重新生成 `sim/golden/*`，跑 `scripts/run_sim.ps1`：`tb_cnn_core_golden` 必须逐层 0 误差。
5. 只有第 4 步通过后，才允许把 `TEST_INJECT` 置 0 并宣称语义功能完成。

## 5. 风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 真实权重动态范围超出当前 M/S | 饱和、精度下降 | 用校准集重算 `s_out`/`M`/`S`，保持 int16 M |
| 训练数据与板端预处理不一致 | 精度断崖 | 用实际 crop 输出（q_in 之后）做训练/验证输入 |
| 类别顺序被 ImageFolder 排序改变 | 语义错位 | manifest 显式 `class_order`，UART/显示/README 同源 |
| 结构化黄金被误当最终模型 | 交付误判 | manifest 与 README 均标注 `structural-golden` |
