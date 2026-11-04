# 构建与复现说明

## 方式一：Vivado 图形界面手动复现

这种方式不需要运行任何项目脚本，适合直接检查源码、综合和上板。

1. 打开 Vivado 2023.1，新建 RTL 工程，器件选择 `xc7a200tfbg484-2`。
2. 选择 **Add Sources**，把 `src/rtl/` 下五个子目录中的全部 `.v` 文件加入
   Design Sources。
3. 添加约束文件 `src/xdc/hdmi_wrapper.xdc`。
4. 保持 `weights/` 位于仓库根目录。Vivado 2023.1 对嵌套 HDL 文件中的
   `$readmemh("...")` 按 RTL 文件所在目录解析，因此源码使用
   `../../../weights/...` 指向根目录权重。
5. 在 Sources 窗口中确认顶层设置为 `hdmi_wrapper`。
6. 依次执行 **Run Synthesis**、**Run Implementation** 和
   **Generate Bitstream**。

仅把 `.mem` 文件加入工程 Sources 并不能自动修正嵌套 HDL 文件中的相对路径。
Vivado 可能生成 `read_mem` 命令，但 `$readmemh` 仍可能报：

```text
Synth 8-4445 could not open $readmem data file 'weights/...'
```

成功加载时，综合日志应出现类似内容：

```text
$readmem data file '../../../weights/qin.mem' is read successfully
```

综合结束后检查日志中 `Critical Warnings` 为 0，再继续实现和生成比特流。

## 方式二：Vivado Tcl 自动构建

项目也保留了 `build/run_vivado_timing.tcl`，用于需要重复构建和自动生成报告的
场景。打开 Vivado 2023.1，在 Tcl Console 中执行：

```tcl
cd /path/to/edgeguard-repository
source build/run_vivado_timing.tcl
```

也可以在配置好 Vivado 环境的系统终端中执行：

```text
cd /path/to/edgeguard-repository
vivado -mode batch -source build/run_vivado_timing.tcl
```

Tcl 脚本会自动检查权重、执行综合、实现和布线，将报告写入 `build/reports/`，
把比特流写入 `board/hdmi_wrapper.bit`，成功时输出 `BUILD_COMPLETE`。

## 目录要求

源码、约束和权重必须保持当前目录结构。权重路径是相对于 RTL 源文件解析的，
不是相对于 Vivado 工程文件或运行目录解析的。本提交包中：

```text
src/rtl/cnn_alarm/cnn_core.v
src/rtl/cnn_alarm/qin_rom.v
weights/*.mem
```

因此 RTL 使用 `../../../weights/...`。如果改变目录层级，必须同步修改路径。
不要把手动复制到 `project.runs/synth_1` 当作复现方案。
