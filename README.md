# EdgeGuard

FPGA-based suspected fall detection for fixed-camera corridor environments.

本项目在单块 AMD Artix-7 FPGA 上完成视频输入、灰度预处理、背景建模、运动检测、
多目标跟踪、48×48 目标裁剪、INT8 CNN 分类、连续确认、证据门控和 HDMI 告警显示。
运行过程不依赖电脑、网络或串口。

## 核心特点

- 事件门控：仅在存在有效运动目标时运行 CNN。
- 目标 ROI：只将主目标裁剪为 48×48 灰度图送入网络。
- INT8 推理：三层卷积、池化和三分类输出。
- 双门控：连续确认、置信度边距和 5 秒告警保持。
- 单芯片本地处理：视频数据不离开设备。

## 最终结果

| 指标 | 结果 |
|---|---|
| WNS | +0.099 ns |
| WHS | +0.056 ns |
| 失败端点 | 0 / 91,716 |
| LUT | 24.67% |
| BRAM | 36.30% |
| DSP | 2.70% |
| 功耗估算 | 0.582 W |
| INT8 测试准确率 | 81.96% |
| INT8 摔倒召回率 | 90.96% |

板级小样本测试检出三段真实摔倒，记录到两次误报。

## 目录

```text
src/rtl/        Verilog RTL
src/xdc/        板级约束
weights/        运行时 INT8 权重
build/          Vivado Tcl 构建脚本
vivado_project/ 可直接打开的 Vivado 工程
training/       训练、量化和评估材料
results/        板级逐帧结果与真实时间窗口
sim/            仿真与语法验证说明
skill/          可复用工程技能包
docs/           架构、验证、复现和已知问题
```

## 构建

安装 Vivado 2023.1，在仓库根目录运行：

```text
vivado -mode batch -source build/run_vivado_timing.tcl
```

或在 Vivado Tcl Console 中运行：

```tcl
cd /path/to/repository
source build/run_vivado_timing.tcl
```

目标器件：`xc7a200tfbg484-2`。

## `$readmemh` 路径说明

Vivado 2023.1 相对于 HDL 文件所在目录解析 `$readmemh` 相对路径。仓库中的 RTL 使用：

```verilog
$readmemh("../../../weights/w1.mem", w1);
```

因此必须保持 `src/rtl/cnn_alarm/` 与根目录 `weights/` 的相对层级。仅把 `.mem`
文件加入 Vivado Sources，或复制到 `project.runs/synth_1`，都不是可移植的解决方案。

## 数据说明

原始第三方训练视频和大型测试视频不在仓库中重复分发，使用前请阅读
`docs/DATASETS.md` 中的来源和许可说明。训练脚本、量化规范、权重和评估结果已保留。
`docs/design_report.pdf` 是移除队伍信息后的公开版本。

## 应用边界

本项目面向走廊、通道和养老机构公共区域等固定机位场景，不用于卧室，也不输出医学诊断。
板级测试样本数量有限，慢速摔倒、遮挡、远景和复杂光照仍需继续验证。

## License

见 `LICENSE`。
