# 复现步骤

## 环境

- Vivado 2023.1
- 目标器件：`xc7a200tfbg484-2`
- 输入：1280×720、60 fps HDMI 视频

## 自动构建

在仓库根目录运行：

```text
vivado -mode batch -source build/run_vivado_timing.tcl
```

构建脚本会检查 9 个 CNN 权重，依次执行综合、实现、布线和比特流生成。

## 图形界面

1. 新建 RTL 工程并选择 `xc7a200tfbg484-2`。
2. 递归加入 `src/rtl/` 下全部 `.v` 文件。
3. 加入 `src/xdc/hdmi_wrapper.xdc`。
4. 保持根目录 `weights/` 与 `src/rtl/cnn_alarm/` 的相对层级不变。
5. 顶层设置为 `hdmi_wrapper`。
6. 执行综合、实现和比特流生成。

## 检查

综合日志应出现：

```text
$readmem data file '../../../weights/qin.mem' is read successfully
```

且不应出现：

```text
Synth 8-4445
```

成功时序应为 WNS 为正、失败端点为 0。
